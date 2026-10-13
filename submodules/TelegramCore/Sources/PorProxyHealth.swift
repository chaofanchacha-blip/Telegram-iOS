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
            let alive = PorProxyHealth.performSocks5Handshake(host: server.host, port: server.port, timeoutSeconds: 5.0)
            DispatchQueue.main.async {
                completion(spec, alive)
            }
        }
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
    private var timer: Timer?
    
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
            self.entries.removeValue(forKey: accountId.int64)
        }
    }
    
    private func ensureTimer() {
        if self.timer == nil {
            self.timer = Timer.scheduledTimer(withTimeInterval: 90.0, repeats: true) { [weak self] _ in
                self?.runCheck()
            }
        }
    }
    
    public func consumeRotation(accountId: AccountRecordId) {
        self.accessQueue.sync {
            self.lastRotations.removeValue(forKey: String(accountId.int64))
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
