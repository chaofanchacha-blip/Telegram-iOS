import Foundation
import Darwin
import SwiftSignalKit

public enum PorProxyHealthStatus: Equatable {
    case unknown
    case checking
    case alive
    case dead
}

public final class PorProxyHealth {
    public static let shared = PorProxyHealth()
    
    private let statusesKey = "porProxyHealth.v1"
    private var statuses: [String: PorProxyHealthStatus] = [:]
    private var loaded = false
    
    public let statusesValue = ValuePromise<[String: PorProxyHealthStatus]>([:])
    
    private init() {
    }
    
    private func ensureLoaded() {
        if !self.loaded {
            self.loaded = true
            guard let data = UserDefaults.standard.data(forKey: self.statusesKey) else {
                return
            }
            guard let dict = try? JSONDecoder().decode([String: Int].self, from: data) else {
                return
            }
            for (spec, code) in dict {
                self.statuses[spec] = code == 1 ? .alive : .dead
            }
        }
    }
    
    public func status(for spec: String) -> PorProxyHealthStatus {
        self.ensureLoaded()
        return self.statuses[spec] ?? .unknown
    }
    
    public func record(spec: String, status: PorProxyHealthStatus, persist: Bool) {
        self.ensureLoaded()
        self.statuses[spec] = status
        if persist {
            var persistable: [String: Int] = [:]
            for (key, value) in self.statuses {
                if value == .alive {
                    persistable[key] = 1
                } else if value == .dead {
                    persistable[key] = 0
                }
            }
            if let data = try? JSONEncoder().encode(persistable) {
                UserDefaults.standard.set(data, forKey: self.statusesKey)
            }
        }
        self.statusesValue.set(self.statuses)
    }
    
    public func check(spec: String, completion: @escaping (String, Bool) -> Void) {
        guard let server = PorDeviceProfileStore.proxyServer(fromSpec: spec) else {
            DispatchQueue.main.async {
                completion(spec, false)
            }
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let alive = PorProxyHealth.performSocks5Handshake(host: server.host, port: server.port, timeoutSeconds: 10.0)
            DispatchQueue.main.async {
                completion(spec, alive)
            }
        }
    }
    
    public func fetchEgressIp(spec: String, completion: @escaping (String?, String?) -> Void) {
        guard let server = PorDeviceProfileStore.proxyServer(fromSpec: spec) else {
            DispatchQueue.main.async {
                completion(nil, "出口配置无法解析")
            }
            return
        }
        var username: String? = nil
        var password: String? = nil
        if case let .socks5(user, pass) = server.connection {
            username = user
            password = pass
        }
        DispatchQueue.global(qos: .utility).async {
            let (ip, error) = PorProxyHealth.performSocks5Fetch(host: server.host, port: server.port, username: username, password: password, timeoutSeconds: 10.0)
            DispatchQueue.main.async {
                completion(ip, error)
            }
        }
    }
    
    private static func performSocks5Fetch(host: String, port: Int32, username: String?, password: String?, timeoutSeconds: Double) -> (String?, String?) {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var infoPtr: UnsafeMutablePointer<addrinfo>? = nil
        let resolveResult = getaddrinfo(host, "\(port)", &hints, &infoPtr)
        guard resolveResult == 0, let info = infoPtr else {
            return (nil, "无法解析或连接代理服务器")
        }
        defer {
            freeaddrinfo(infoPtr)
        }
        
        let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard fd >= 0 else {
            return (nil, "创建套接字失败")
        }
        defer {
            close(fd)
        }
        
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
        
        let connectResult = connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen)
        if connectResult != 0 && errno != EINPROGRESS {
            return (nil, "连接代理服务器失败")
        }
        
        var outbound = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&outbound, 1, Int32(timeoutSeconds * 1000.0)) > 0 else {
            return (nil, "连接代理超时")
        }
        
        var soError: Int32 = 0
        var soErrorLength = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &soErrorLength) == 0, soError == 0 else {
            return (nil, "代理服务器连接错误")
        }
        
        func sendAll(_ bytes: [UInt8]) -> Bool {
            var offset = 0
            while offset < bytes.count {
                let chunk = Array(bytes[offset...])
                let n = send(fd, chunk, chunk.count, 0)
                if n > 0 {
                    offset += n
                } else {
                    var wait = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    if poll(&wait, 1, Int32(timeoutSeconds * 1000.0)) <= 0 {
                        return false
                    }
                }
            }
            return true
        }
        
        func receiveSome(_ count: Int) -> [UInt8]? {
            var buffer = [UInt8](repeating: 0, count: count)
            var wait = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&wait, 1, Int32(timeoutSeconds * 1000.0)) > 0 else {
                return nil
            }
            let n = recv(fd, &buffer, count, 0)
            guard n > 0 else {
                return nil
            }
            return Array(buffer[0..<n])
        }
        
        func receiveExact(_ count: Int) -> [UInt8]? {
            var out: [UInt8] = []
            while out.count < count {
                if let part = receiveSome(count - out.count) {
                    out += part
                } else {
                    return nil
                }
            }
            return out
        }
        
        let hasAuth = username != nil || password != nil
        let greeting: [UInt8] = hasAuth ? [0x05, 0x02, 0x00, 0x02] : [0x05, 0x01, 0x00]
        guard sendAll(greeting), let method = receiveExact(2), method[0] == 0x05 else {
            return (nil, "代理握手失败")
        }
        if method[1] == 0x02 {
            guard let username = username else {
                return (nil, "代理要求账号密码，但未配置")
            }
            let userBytes = Array(username.utf8)
            let passBytes = Array((password ?? "").utf8)
            let auth: [UInt8] = [0x01, UInt8(userBytes.count)] + userBytes + [UInt8(passBytes.count)] + passBytes
            guard sendAll(auth), let authResult = receiveExact(2), authResult[0] == 0x01, authResult[1] == 0x00 else {
                return (nil, "代理认证失败（账号或密码错误）")
            }
        } else if method[1] != 0x00 {
            return (nil, "代理拒绝了此认证方式")
        }
        
        let target = "api.ipify.org"
        let targetBytes = Array(target.utf8)
        let connectRequest: [UInt8] = [0x05, 0x01, 0x00, 0x03, UInt8(targetBytes.count)] + targetBytes + [0x00, 0x50]
        guard sendAll(connectRequest), let reply = receiveExact(4), reply[0] == 0x05, reply[1] == 0x00 else {
            return (nil, "代理无法建立到外网的通道")
        }
        switch reply[3] {
        case 0x01:
            guard receiveExact(4) != nil else {
                return (nil, "代理响应不完整")
            }
        case 0x04:
            guard receiveExact(16) != nil else {
                return (nil, "代理响应不完整")
            }
        case 0x03:
            guard let lengthByte = receiveExact(1) else {
                return (nil, "代理响应不完整")
            }
            guard receiveExact(Int(lengthByte[0])) != nil else {
                return (nil, "代理响应不完整")
            }
        default:
            break
        }
        
        let request = Array("GET / HTTP/1.0\r\nHost: api.ipify.org\r\nUser-Agent: Mozilla/5.0\r\n\r\n".utf8)
        guard sendAll(request) else {
            return (nil, "发送检测请求失败")
        }
        var body: String? = nil
        var collected: [UInt8] = []
        for _ in 0..<16 {
            guard let chunk = receiveSome(2048), !chunk.isEmpty else {
                break
            }
            collected += chunk
            if let text = String(bytes: collected, encoding: .utf8) {
                if let range = text.range(of: "\r\n\r\n") {
                    let candidate = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !candidate.isEmpty {
                        body = candidate
                        break
                    }
                }
            }
            if collected.count > 8192 {
                break
            }
        }
        guard let body = body else {
            return (nil, "出口未返回有效响应")
        }
        let firstLine = body.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).first.map(String.init) ?? body
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 45 else {
            return (nil, "出口返回内容异常")
        }
        return (trimmed, nil)
    }
    
    private static func performSocks5Handshake(host: String, port: Int32, timeoutSeconds: Double) -> Bool {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var infoPtr: UnsafeMutablePointer<addrinfo>? = nil
        let resolveResult = getaddrinfo(host, "\(port)", &hints, &infoPtr)
        guard resolveResult == 0, let info = infoPtr else {
            return false
        }
        defer {
            freeaddrinfo(infoPtr)
        }
        
        let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard fd >= 0 else {
            return false
        }
        defer {
            close(fd)
        }
        
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
        
        let connectResult = connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen)
        if connectResult != 0 && errno != EINPROGRESS {
            return false
        }
        
        var outbound = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let connectPollResult = poll(&outbound, 1, Int32(timeoutSeconds * 1000.0))
        guard connectPollResult > 0 else {
            return false
        }
        
        var soError: Int32 = 0
        var soErrorLength = socklen_t(MemoryLayout<Int32>.size)
        let sockoptResult = getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &soErrorLength)
        guard sockoptResult == 0, soError == 0 else {
            return false
        }
        
        let greeting: [UInt8] = [0x05, 0x01, 0x00]
        let sent = send(fd, greeting, greeting.count, 0)
        guard sent == greeting.count else {
            return false
        }
        
        var inbound = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let readPollResult = poll(&inbound, 1, Int32(timeoutSeconds * 1000.0))
        guard readPollResult > 0 else {
            return false
        }
        
        var response = [UInt8](repeating: 0, count: 2)
        let received = recv(fd, &response, response.count, 0)
        guard received >= 2 else {
            return false
        }
        // 0x00 = no-auth ok, 0x02 = username/password available; both mean the proxy is alive
        return response[0] == 0x05 && (response[1] == 0x00 || response[1] == 0x02)
    }
}

public final class PorProxyWatchdog {
    public static let shared = PorProxyWatchdog()
    
    private let accessQueue = DispatchQueue(label: "org.por.proxy.watchdog")
    private var entries: [Int64: (accountId: AccountRecordId, apply: (ProxyServerSettings?) -> Void)] = [:]
    private var lastRotations: [String: String] = [:]
    private var timer: Foundation.Timer?
    
    public let rotationsValue = ValuePromise<[String: String]>([:])
    
    private init() {
    }
    
    public func register(accountId: AccountRecordId, apply: @escaping (ProxyServerSettings?) -> Void) {
        self.accessQueue.sync {
            self.entries[accountId.int64] = (accountId, apply)
        }
        DispatchQueue.main.async { [weak self] in
            self?.ensureTimer()
        }
    }
    
    public func unregister(accountId: AccountRecordId) {
        self.accessQueue.sync {
            self.entries[accountId.int64] = nil
        }
    }
    
    private func ensureTimer() {
        if self.timer == nil {
            self.timer = Foundation.Timer.scheduledTimer(withTimeInterval: 90.0, repeats: true) { [weak self] _ in
                self?.runCheck()
            }
        }
    }
    
    public func consumeRotation(accountId: AccountRecordId) {
        self.accessQueue.sync {
            self.lastRotations[String(accountId.int64)] = nil
            let snapshot = self.lastRotations
            DispatchQueue.main.async {
                self.rotationsValue.set(snapshot)
            }
        }
    }
    
    public func runCheck() {
        let snapshot: [Int64: (accountId: AccountRecordId, apply: (ProxyServerSettings?) -> Void)] = self.accessQueue.sync {
            return self.entries
        }
        for (_, entry) in snapshot {
            guard let profile = PorDeviceProfileStore.shared.profile(accountId: entry.accountId) else {
                continue
            }
            guard let pool = profile.proxyPool, !pool.isEmpty else {
                continue
            }
            guard let activeSpec = profile.proxySpec, pool.contains(activeSpec) else {
                continue
            }
            PorProxyHealth.shared.check(spec: activeSpec) { [weak self] spec, alive in
                guard let self = self else {
                    return
                }
                PorProxyHealth.shared.record(spec: spec, status: alive ? .alive : .dead, persist: true)
                if !alive {
                    let currentIndex = pool.firstIndex(of: activeSpec) ?? -1
                    self.rotateAfterFailure(accountId: entry.accountId, pool: pool, currentIndex: currentIndex, tried: [activeSpec], apply: entry.apply)
                }
            }
        }
    }
    
    private func rotateAfterFailure(accountId: AccountRecordId, pool: [String], currentIndex: Int, tried: [String], apply: @escaping (ProxyServerSettings?) -> Void) {
        guard tried.count < pool.count else {
            return
        }
        let nextIndex = (currentIndex + 1) % pool.count
        let nextSpec = pool[nextIndex]
        PorProxyHealth.shared.check(spec: nextSpec) { [weak self] spec, alive in
            guard let self = self else {
                return
            }
            PorProxyHealth.shared.record(spec: spec, status: alive ? .alive : .dead, persist: true)
            if alive {
                guard var profile = PorDeviceProfileStore.shared.profile(accountId: accountId) else {
                    return
                }
                profile.proxySpec = spec
                PorDeviceProfileStore.shared.setProfile(profile, accountId: accountId)
                apply(PorDeviceProfileStore.proxyServer(fromSpec: spec))
                self.accessQueue.sync {
                    self.lastRotations[String(accountId.int64)] = spec
                    let snapshot = self.lastRotations
                    DispatchQueue.main.async {
                        self.rotationsValue.set(snapshot)
                    }
                }
            } else {
                self.rotateAfterFailure(accountId: accountId, pool: pool, currentIndex: nextIndex, tried: tried + [spec], apply: apply)
            }
        }
    }
}
