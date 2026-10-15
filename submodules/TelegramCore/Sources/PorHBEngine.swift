import Foundation
import Postbox
import SwiftSignalKit
import TelegramApi
import MtProtoKit

/// Por HB Engine — 原生红包引擎 v1
///
/// 挂载点: AccountStateManagementUtils.finalStateWithUpdatesAndServerTime —
/// 所有 MTProto 更新的唯一汇流函数, 每条 Api.Update 必经此处。
///
/// v1 能力: A 型 inline 按钮红包 (\w+--get_lucky_money--\d+) 的
/// 检测 -> 去重 -> 抖动延迟 -> getBotCallbackAnswer 直调 -> 台账。
/// 多账号: 每个已登录账号的更新流都会流经本引擎, 天然多号分食。
public final class PorHBEngine {
    public static let shared = PorHBEngine()

    private let lock = NSLock()
    private let ledgerQueue = DispatchQueue(label: "por.hb.ledger")

    private var seen: Set<String> = []
    private var disposables: [Int64: Disposable] = [:]
    private var disposableCounter: Int64 = 0
    private var accountHeartbeats: [PeerId: Date] = [:]

    private let ledgerURL: URL? = {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return dir.appendingPathComponent("por_hb_hits.jsonl")
    }()

    // MARK: - Settings (persisted, UI writes directly)

    private static let masterKey = "porHBEngine.v1.master"
    private static let claimInlineKey = "porHBEngine.v1.claimInline"
    private static let delayProfileKey = "porHBEngine.v1.delayProfile"
    private static let seenKey = "porHBEngine.v1.seen"
    private static let totalKey = "porHBEngine.v1.totalClaims"
    private static let lastTsKey = "porHBEngine.v1.lastClaimTs"

    public var masterEnabled: Bool {
        get {
            return UserDefaults.standard.bool(forKey: PorHBEngine.masterKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: PorHBEngine.masterKey)
            if !newValue {
                self.cancelPending()
            }
        }
    }

    public var claimInlineEnabled: Bool {
        get {
            return UserDefaults.standard.object(forKey: PorHBEngine.claimInlineKey) as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: PorHBEngine.claimInlineKey)
        }
    }

    /// 0 = 激进 (0.08-0.25s) / 1 = 均衡 (0.12-0.38s) / 2 = 拟人 (0.30-0.90s)
    public var delayProfile: Int {
        get {
            return UserDefaults.standard.integer(forKey: PorHBEngine.delayProfileKey)
        }
        set {
            UserDefaults.standard.set(max(0, min(2, newValue)), forKey: PorHBEngine.delayProfileKey)
        }
    }

    public func delayBounds() -> (Double, Double) {
        switch self.delayProfile {
        case 0:
            return (0.08, 0.25)
        case 2:
            return (0.30, 0.90)
        default:
            return (0.12, 0.38)
        }
    }

    public var totalClaims: Int {
        get {
            return UserDefaults.standard.integer(forKey: PorHBEngine.totalKey)
        }
        private set {
            UserDefaults.standard.set(newValue, forKey: PorHBEngine.totalKey)
        }
    }

    public var lastClaimDate: Date? {
        get {
            let ts = UserDefaults.standard.double(forKey: PorHBEngine.lastTsKey)
            return ts > 0 ? Date(timeIntervalSince1970: ts) : nil
        }
        private set {
            if let newValue = newValue {
                UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: PorHBEngine.lastTsKey)
            }
        }
    }

    /// 最近 10 分钟内收到过更新流的账号数 (供 UI 状态显示)
    public var activeAccountCount: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        let cutoff = Date().addingTimeInterval(-600.0)
        var count = 0
        for (_, date) in self.accountHeartbeats {
            if date >= cutoff {
                count += 1
            }
        }
        return count
    }

    public func resetStats() {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.totalClaims = 0
        self.lastClaimDate = nil
        self.seen.removeAll()
        UserDefaults.standard.removeObject(forKey: PorHBEngine.seenKey)
    }

    public func ledgerContents(maxBytes: Int) -> String {
        guard let url = self.ledgerURL, let data = try? Data(contentsOf: url), !data.isEmpty else {
            return ""
        }
        var trimmed = data
        if trimmed.count > maxBytes {
            trimmed = trimmed.suffix(maxBytes)
            if let firstNewline = trimmed.firstIndex(of: UInt8(10)) {
                trimmed = trimmed[trimmed.index(after: firstNewline)...]
            }
        }
        return String(data: trimmed, encoding: .utf8) ?? ""
    }

    // MARK: - Update hook

    func handleUpdates(accountPeerId: PeerId, postbox: Postbox, network: Network, updates: [Api.Update]) {
        self.lock.lock()
        self.accountHeartbeats[accountPeerId] = Date()
        self.lock.unlock()

        guard updates.isEmpty == false, self.masterEnabled, self.claimInlineEnabled else {
            return
        }

        for update in updates {
            switch update {
            case let .updateNewMessage(data):
                self.consider(accountPeerId: accountPeerId, postbox: postbox, network: network, apiMessage: data.message)
            case let .updateNewChannelMessage(data):
                self.consider(accountPeerId: accountPeerId, postbox: postbox, network: network, apiMessage: data.message)
            default:
                break
            }
        }
    }

    private func consider(accountPeerId: PeerId, postbox: Postbox, network: Network, apiMessage: Api.Message) {
        guard let message = StoreMessage(apiMessage: apiMessage, accountPeerId: accountPeerId, peerIsForum: false), case let .Id(messageId) = message.id else {
            return
        }
        guard Namespaces.Message.allEphemeral.contains(messageId.namespace) == false else {
            return
        }
        guard message.flags.contains(.Incoming) else {
            return
        }
        guard let markup = message.attributes.first(where: { $0 is ReplyMarkupMessageAttribute }) as? ReplyMarkupMessageAttribute else {
            return
        }
        for row in markup.rows {
            for button in row.buttons {
                if case let .callback(requiresPassword, data) = button.action, requiresPassword == false {
                    if let payload = String(data: data.makeData(), encoding: .utf8), payload.contains("--get_lucky_money--") {
                        let key = "\(accountPeerId.toInt64())|\(messageId.peerId.toInt64())|\(messageId.id)"
                        if self.markSeen(key) {
                            self.claim(accountPeerId: accountPeerId, postbox: postbox, network: network, messageId: messageId, data: data, buttonTitle: button.title)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Claim

    private func markSeen(_ key: String) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        if self.seen.contains(key) {
            return false
        }
        self.seen.insert(key)
        if self.seen.count > 4000 {
            var kept = Array(self.seen)
            kept.removeFirst(kept.count - 3000)
            self.seen = Set(kept)
        }
        UserDefaults.standard.set(Array(self.seen), forKey: PorHBEngine.seenKey)
        return true
    }

    private func cancelPending() {
        self.lock.lock()
        let disposables = Array(self.disposables.values)
        self.disposables.removeAll()
        self.lock.unlock()
        for disposable in disposables {
            disposable.dispose()
        }
    }

    private func claim(accountPeerId: PeerId, postbox: Postbox, network: Network, messageId: MessageId, data: MemoryBuffer, buttonTitle: String) {
        let (minDelay, maxDelay) = self.delayBounds()
        let delay = Double.random(in: minDelay...maxDelay)

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.masterEnabled else {
                return
            }

            enum PorHBClaimError {
                case failed(String)
            }

            let pipeline: Signal<String, PorHBClaimError> = postbox.loadedPeerWithId(messageId.peerId)
            |> take(1)
            |> castError(PorHBClaimError.self)
            |> mapToSignal { peer -> Signal<String, PorHBClaimError> in
                guard let inputPeer = apiInputPeer(peer) else {
                    return .fail(.failed("无法解析会话 (apiInputPeer nil)"))
                }
                return network.request(Api.functions.messages.getBotCallbackAnswer(flags: Int32(1 << 0), peer: inputPeer, msgId: messageId.id, data: Buffer(data: data.makeData()), password: nil))
                |> map { result -> String in
                    if case let .botCallbackAnswer(answer) = result {
                        if let answerMessage = answer.message {
                            return answerMessage
                        }
                        if let url = answer.url {
                            return "已提交 · 跳转: \(url)"
                        }
                    }
                    return "已提交 (无返回文本)"
                }
                |> mapError { error -> PorHBClaimError in
                    return .failed(error.errorDescription)
                }
            }

            self.lock.lock()
            self.disposableCounter += 1
            let token = self.disposableCounter
            self.lock.unlock()

            var finished = false
            let disposable = pipeline.start(next: { [weak self] answer in
                self?.record(accountId: accountPeerId, messageId: messageId, button: buttonTitle, status: "claimed", detail: answer)
                finished = true
                self?.removeDisposable(token)
            }, error: { [weak self] error in
                if case let .failed(detail) = error {
                    self?.record(accountId: accountPeerId, messageId: messageId, button: buttonTitle, status: "error", detail: detail)
                }
                finished = true
                self?.removeDisposable(token)
            })
            self.lock.lock()
            if finished {
                self.disposables.removeValue(forKey: token)
            } else {
                self.disposables[token] = disposable
            }
            self.lock.unlock()
        }
    }

    private func removeDisposable(_ token: Int64) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.disposables.removeValue(forKey: token)
    }

    // MARK: - Ledger

    private func record(accountId: PeerId, messageId: MessageId, button: String, status: String, detail: String) {
        if status == "claimed" {
            self.lock.lock()
            self.totalClaims += 1
            self.lastClaimDate = Date()
            self.lock.unlock()
        }
        var entry: [String: Any] = [
            "ts": Int(Date().timeIntervalSince1970),
            "account": accountId.toInt64(),
            "chat": messageId.peerId.toInt64(),
            "msg": messageId.id,
            "btn": button,
            "status": status,
            "detail": String(detail.prefix(200))
        ]
        #if DEBUG
        entry["dbg"] = true
        #endif
        guard let url = self.ledgerURL, let data = (try? JSONSerialization.data(withJSONObject: entry)) else {
            return
        }
        self.ledgerQueue.async {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            if let handle = FileHandle(forWritingAtPath: url.path) {
                handle.seekToEndOfFile()
                var line = data
                line.append(0x0A)
                handle.write(line)
                handle.closeFile()
            }
        }
    }
}
