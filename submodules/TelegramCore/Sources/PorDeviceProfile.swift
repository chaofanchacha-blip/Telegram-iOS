import Foundation

public struct PorDeviceProfile: Codable, Equatable {
    public var name: String
    public var model: String?
    public var systemVersion: String?
    public var appVersion: String?
    public var proxySpec: String?
    public var proxyPool: [String]?
    
    public init(name: String, model: String?, systemVersion: String?, appVersion: String?, proxySpec: String?, proxyPool: [String]? = nil) {
        self.name = name
        self.model = model
        self.systemVersion = systemVersion
        self.appVersion = appVersion
        self.proxySpec = proxySpec
        self.proxyPool = proxyPool
    }
}

public final class PorDeviceProfileStore {
    public static let shared = PorDeviceProfileStore()
    
    private let key = "porDeviceProfiles.v1"
    
    private init() {
    }
    
    public static let catalog: [PorDeviceProfile] = [
        PorDeviceProfile(name: "iPhone 18 Pro Max", model: "iPhone 18 Pro Max", systemVersion: "27.0.1", appVersion: "12.8.1 (33181)", proxySpec: nil),
        PorDeviceProfile(name: "iPhone 18 Pro", model: "iPhone 18 Pro", systemVersion: "27.0.1", appVersion: "12.8.1 (33181)", proxySpec: nil),
        PorDeviceProfile(name: "iPhone 18", model: "iPhone 18", systemVersion: "27.0.1", appVersion: "12.8.1 (33181)", proxySpec: nil),
        PorDeviceProfile(name: "iPhone 17 Pro Max", model: "iPhone 17 Pro Max", systemVersion: "26.1", appVersion: "12.8.1 (33181)", proxySpec: nil),
        PorDeviceProfile(name: "iPhone 17 Pro", model: "iPhone 17 Pro", systemVersion: "26.1", appVersion: "12.8.1 (33181)", proxySpec: nil),
        PorDeviceProfile(name: "iPhone 17", model: "iPhone 17", systemVersion: "26.1", appVersion: "12.8.1 (33181)", proxySpec: nil),
        PorDeviceProfile(name: "iPhone 16 Pro Max", model: "iPhone 16 Pro Max", systemVersion: "26.0.3", appVersion: "12.8.1 (33181)", proxySpec: nil),
        PorDeviceProfile(name: "iPhone 16 Pro", model: "iPhone 16 Pro", systemVersion: "26.0.3", appVersion: "12.8.1 (33181)", proxySpec: nil),
        PorDeviceProfile(name: "iPhone 16", model: "iPhone 16", systemVersion: "26.0.3", appVersion: "12.8.1 (33181)", proxySpec: nil),
        PorDeviceProfile(name: "iPhone 15 Pro Max", model: "iPhone 15 Pro Max", systemVersion: "26.0.2", appVersion: "12.8.1 (33181)", proxySpec: nil),
        PorDeviceProfile(name: "iPhone 15 Pro", model: "iPhone 15 Pro", systemVersion: "26.0.2", appVersion: "12.8.1 (33181)", proxySpec: nil),
        PorDeviceProfile(name: "iPhone 15", model: "iPhone 15", systemVersion: "26.0.2", appVersion: "12.8.1 (33181)", proxySpec: nil),
        PorDeviceProfile(name: "iPhone 14 Pro Max", model: "iPhone 14 Pro Max", systemVersion: "26.0.1", appVersion: "12.8.1 (33181)", proxySpec: nil),
        PorDeviceProfile(name: "iPhone 14 Pro", model: "iPhone 14 Pro", systemVersion: "26.0.1", appVersion: "12.8.1 (33181)", proxySpec: nil),
        PorDeviceProfile(name: "iPhone 14", model: "iPhone 14", systemVersion: "26.0.1", appVersion: "12.8.1 (33181)", proxySpec: nil),
        PorDeviceProfile(name: "iPhone 13 Pro Max", model: "iPhone 13 Pro Max", systemVersion: "26.0", appVersion: "12.8.1 (33181)", proxySpec: nil),
        PorDeviceProfile(name: "iPhone 13 Pro", model: "iPhone 13 Pro", systemVersion: "26.0", appVersion: "12.8.1 (33181)", proxySpec: nil),
        PorDeviceProfile(name: "iPhone 13", model: "iPhone 13", systemVersion: "26.0", appVersion: "12.8.1 (33181)", proxySpec: nil),
        PorDeviceProfile(name: "iPhone 12 Pro Max", model: "iPhone 12 Pro Max", systemVersion: "18.5.1", appVersion: "12.8.1 (33181)", proxySpec: nil),
        PorDeviceProfile(name: "iPhone 12 Pro", model: "iPhone 12 Pro", systemVersion: "18.5.1", appVersion: "12.8.1 (33181)", proxySpec: nil),
        PorDeviceProfile(name: "iPhone 12", model: "iPhone 12", systemVersion: "18.5.1", appVersion: "12.8.1 (33181)", proxySpec: nil),
        PorDeviceProfile(name: "iPhone 11 Pro Max", model: "iPhone 11 Pro Max", systemVersion: "18.4.1", appVersion: "12.8.1 (33181)", proxySpec: nil),
        PorDeviceProfile(name: "iPhone 11 Pro", model: "iPhone 11 Pro", systemVersion: "18.4.1", appVersion: "12.8.1 (33181)", proxySpec: nil),
        PorDeviceProfile(name: "iPhone 11", model: "iPhone 11", systemVersion: "18.4.1", appVersion: "12.8.1 (33181)", proxySpec: nil),
        PorDeviceProfile(name: "Por Max", model: "Por Max", systemVersion: "27.0.1", appVersion: "12.8.1 (33181)", proxySpec: nil),
        PorDeviceProfile(name: "Por", model: "Por", systemVersion: "27.0.1", appVersion: "12.8.1 (33181)", proxySpec: nil)
    ]
    
    public static func randomProfile(excludingModel: String?) -> PorDeviceProfile {
        var candidates = catalog
        if let current = excludingModel, candidates.count > 1 {
            candidates = candidates.filter { $0.model != current }
        }
        return candidates[Int.random(in: 0..<candidates.count)]
    }
    
    public static func parseProxyPool(_ text: String) -> [String] {
        return text.split(whereSeparator: { $0 == ";" || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    
    public func profile(accountId: AccountRecordId) -> PorDeviceProfile? {
        guard let data = UserDefaults.standard.data(forKey: self.key) else {
            return nil
        }
        guard let dict = try? JSONDecoder().decode([String: PorDeviceProfile].self, from: data) else {
            return nil
        }
        return dict[String(accountId.int64)]
    }
    
    public func setProfile(_ profile: PorDeviceProfile?, accountId: AccountRecordId) {
        var dict: [String: PorDeviceProfile] = [:]
        if let data = UserDefaults.standard.data(forKey: self.key), let existing = try? JSONDecoder().decode([String: PorDeviceProfile].self, from: data) {
            dict = existing
        }
        if let profile = profile {
            dict[String(accountId.int64)] = profile
        } else {
            dict.removeValue(forKey: String(accountId.int64))
        }
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: self.key)
        }
    }
    
    public func resolveProxy(accountId: AccountRecordId, shared: ProxySettings?) -> ProxySettings? {
        guard let profile = self.profile(accountId: accountId) else {
            return shared
        }
        guard let server = PorDeviceProfileStore.proxyServer(fromSpec: profile.proxySpec) else {
            return shared
        }
        var settings = shared ?? ProxySettings.defaultSettings
        settings.enabled = true
        if settings.activeServer != server {
            var servers = settings.servers.filter { $0 != server }
            servers.append(server)
            settings.servers = servers
            settings.activeServer = server
        }
        return settings
    }
    
    public static func proxyServer(fromSpec spec: String?) -> ProxyServerSettings? {
        guard let spec = spec?.trimmingCharacters(in: .whitespacesAndNewlines), !spec.isEmpty else {
            return nil
        }
        let parts = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, let port = Int32(parts[1]), port > 0, port < 65536 else {
            return nil
        }
        let host = parts[0]
        guard !host.isEmpty else {
            return nil
        }
        var username: String? = nil
        var password: String? = nil
        if parts.count > 2, !parts[2].isEmpty {
            username = parts[2]
            if parts.count > 3, !parts[3].isEmpty {
                password = parts[3]
            }
        }
        return ProxyServerSettings(host: host, port: port, connection: .socks5(username: username, password: password))
    }
}

extension NetworkInitializationArguments {
    public func withPorDeviceProfile(_ profile: PorDeviceProfile?) -> NetworkInitializationArguments {
        guard let profile = profile else {
            return self
        }
        return NetworkInitializationArguments(
            apiId: self.apiId,
            apiHash: self.apiHash,
            languagesCategory: self.languagesCategory,
            appVersion: profile.appVersion ?? self.appVersion,
            voipMaxLayer: self.voipMaxLayer,
            voipVersions: self.voipVersions,
            appData: self.appData,
            externalRequestVerificationStream: self.externalRequestVerificationStream,
            externalRecaptchaRequestVerification: self.externalRecaptchaRequestVerification,
            autolockDeadine: self.autolockDeadine,
            encryptionProvider: self.encryptionProvider,
            deviceModelName: profile.model ?? self.deviceModelName,
            systemVersion: profile.systemVersion,
            useBetaFeatures: self.useBetaFeatures,
            isICloudEnabled: self.isICloudEnabled,
            networkEngineFactory: self.networkEngineFactory
        )
    }
}
