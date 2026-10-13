import Foundation

public struct PorDeviceProfile: Codable, Equatable {
    public var name: String
    public var model: String?
    public var systemVersion: String?
    public var appVersion: String?
    public var proxySpec: String?
    
    public init(name: String, model: String?, systemVersion: String?, appVersion: String?, proxySpec: String?) {
        self.name = name
        self.model = model
        self.systemVersion = systemVersion
        self.appVersion = appVersion
        self.proxySpec = proxySpec
    }
}

public final class PorDeviceProfileStore {
    public static let shared = PorDeviceProfileStore()
    
    private let key = "porDeviceProfiles.v1"
    
    private init() {
    }
    
    public static let presets: [PorDeviceProfile] = [
        PorDeviceProfile(name: "iPhone 17 Pro Max", model: "iPhone 17 Pro Max", systemVersion: "26.1", appVersion: "12.8.1 (33181)", proxySpec: nil),
        PorDeviceProfile(name: "iPhone 16 Pro", model: "iPhone 16 Pro", systemVersion: "26.0.3", appVersion: "12.8.1 (33181)", proxySpec: nil),
        PorDeviceProfile(name: "iPhone 15", model: "iPhone 15", systemVersion: "26.0.2", appVersion: "12.8.1 (33181)", proxySpec: nil),
        PorDeviceProfile(name: "iPad Pro", model: "iPad Pro", systemVersion: "26.1", appVersion: "12.8.1 (33181)", proxySpec: nil)
    ]
    
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
