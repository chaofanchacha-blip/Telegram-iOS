import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext
import UndoUI

private struct PorExportPayload: Codable {
    var v: Int
    var phone: String?
    var profile: PorDeviceProfile?
}

private final class PorDeviceEnvironmentControllerArguments {
    let selectModel: (String) -> Void
    let selectRealDevice: () -> Void
    let shuffleDevice: () -> Void
    let updateProxyPool: (String) -> Void
    let settleProxyPool: () -> Void
    let updateProxyField: (PorProxyFieldKind, String) -> Void
    let settleProxyFields: () -> Void
    let shuffleProxy: () -> Void
    let checkPool: () -> Void
    let exportConfig: () -> Void
    let updateImportText: (String) -> Void
    let importConfig: () -> Void
    
    init(
        selectModel: @escaping (String) -> Void,
        selectRealDevice: @escaping () -> Void,
        shuffleDevice: @escaping () -> Void,
        updateProxyPool: @escaping (String) -> Void,
        settleProxyPool: @escaping () -> Void,
        updateProxyField: @escaping (PorProxyFieldKind, String) -> Void,
        settleProxyFields: @escaping () -> Void,
        shuffleProxy: @escaping () -> Void,
        checkPool: @escaping () -> Void,
        exportConfig: @escaping () -> Void,
        updateImportText: @escaping (String) -> Void,
        importConfig: @escaping () -> Void
    ) {
        self.selectModel = selectModel
        self.selectRealDevice = selectRealDevice
        self.shuffleDevice = shuffleDevice
        self.updateProxyPool = updateProxyPool
        self.settleProxyPool = settleProxyPool
        self.updateProxyField = updateProxyField
        self.settleProxyFields = settleProxyFields
        self.shuffleProxy = shuffleProxy
        self.checkPool = checkPool
        self.exportConfig = exportConfig
        self.updateImportText = updateImportText
        self.importConfig = importConfig
    }
}

private enum PorProxyFieldKind {
    case host
    case port
    case user
    case pass
}

private enum PorDeviceEnvironmentSection: Int32 {
    case fingerprint
    case proxy
    case backup
}

private enum PorDeviceEnvironmentEntry: ItemListNodeEntry {
    case fingerprintHeader
    case shuffleDevice
    case fingerprintReal(Bool)
    case fingerprintModel(index: Int, name: String, checked: Bool)
    case fingerprintFooter
    
    case proxyHeader
    case proxyInfo(String)
    case proxyHostField(text: String)
    case proxyPortField(text: String)
    case proxyUserField(text: String)
    case proxyPassField(text: String)
    case proxyPoolInput(text: String)
    case proxyHealthRow(index: Int, spec: String, status: PorProxyHealthStatus)
    case checkPool
    case shuffleProxy
    case proxyFooter
    
    case backupHeader
    case exportConfig
    case importInput(text: String)
    case importConfig
    case backupFooter
    
    var section: ItemListSectionId {
        switch self {
        case .fingerprintHeader, .shuffleDevice, .fingerprintReal, .fingerprintModel, .fingerprintFooter:
            return PorDeviceEnvironmentSection.fingerprint.rawValue
        case .proxyHeader, .proxyInfo, .proxyHostField, .proxyPortField, .proxyUserField, .proxyPassField, .proxyPoolInput, .proxyHealthRow, .checkPool, .shuffleProxy, .proxyFooter:
            return PorDeviceEnvironmentSection.proxy.rawValue
        case .backupHeader, .exportConfig, .importInput, .importConfig, .backupFooter:
            return PorDeviceEnvironmentSection.backup.rawValue
        }
    }
    
    var stableId: Int32 {
        switch self {
        case .fingerprintHeader:
            return 0
        case .shuffleDevice:
            return 1
        case .fingerprintReal:
            return 2
        case let .fingerprintModel(index, _, _):
            return 10 + Int32(index)
        case .fingerprintFooter:
            return 200
        case .proxyHeader:
            return 201
        case .proxyInfo:
            return 202
        case .proxyHostField:
            return 203
        case .proxyPortField:
            return 204
        case .proxyUserField:
            return 205
        case .proxyPassField:
            return 206
        case .proxyPoolInput:
            return 207
        case let .proxyHealthRow(index, _, _):
            return 210 + Int32(index)
        case .checkPool:
            return 260
        case .shuffleProxy:
            return 261
        case .proxyFooter:
            return 262
        case .backupHeader:
            return 300
        case .exportConfig:
            return 301
        case .importInput:
            return 302
        case .importConfig:
            return 303
        case .backupFooter:
            return 304
        }
    }
    
    static func <(lhs: PorDeviceEnvironmentEntry, rhs: PorDeviceEnvironmentEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }
    
    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! PorDeviceEnvironmentControllerArguments
        switch self {
        case .fingerprintHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "设备指纹", sectionId: self.section)
        case .shuffleDevice:
            return ItemListActionItem(presentationData: presentationData, title: "一键更换机型（随机）", kind: .generic, alignment: .center, sectionId: self.section, style: .blocks, action: {
                arguments.shuffleDevice()
            })
        case let .fingerprintReal(checked):
            return ItemListCheckboxItem(presentationData: presentationData, title: "真实设备", style: .right, checked: checked, zeroSeparatorInsets: false, sectionId: self.section, action: {
                arguments.selectRealDevice()
            })
        case let .fingerprintModel(_, name, checked):
            return ItemListCheckboxItem(presentationData: presentationData, title: name, style: .right, checked: checked, zeroSeparatorInsets: false, sectionId: self.section, action: {
                arguments.selectModel(name)
            })
        case .fingerprintFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain("选择此账号对外显示的设备身份（机型、系统、版本），点击即时生效无需重启。对外版本默认跟随当前客户端真实版本，与服务端功能开关保持一致。"), sectionId: self.section)
        case .proxyHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "代理出口 (SOCKS5)", sectionId: self.section)
        case let .proxyInfo(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain("当前出口：\(text)"), sectionId: self.section)
        case let .proxyHostField(text):
            return ItemListSingleLineInputItem(presentationData: presentationData, title: NSAttributedString(string: "地址"), text: text, placeholder: "SOCKS5 服务器 IP 或域名", type: .regular(capitalization: false, autocorrection: false), returnKeyType: .next, sectionId: self.section, textUpdated: { value in
                arguments.updateProxyField(.host, value)
            }, updatedFocus: { focused in
                if !focused {
                    arguments.settleProxyFields()
                }
            }, action: {})
        case let .proxyPortField(text):
            return ItemListSingleLineInputItem(presentationData: presentationData, title: NSAttributedString(string: "端口"), text: text, placeholder: "1-65535", type: .number, sectionId: self.section, textUpdated: { value in
                arguments.updateProxyField(.port, value)
            }, updatedFocus: { focused in
                if !focused {
                    arguments.settleProxyFields()
                }
            }, action: {})
        case let .proxyUserField(text):
            return ItemListSingleLineInputItem(presentationData: presentationData, title: NSAttributedString(string: "账号"), text: text, placeholder: "可为空", type: .regular(capitalization: false, autocorrection: false), returnKeyType: .next, sectionId: self.section, textUpdated: { value in
                arguments.updateProxyField(.user, value)
            }, updatedFocus: { focused in
                if !focused {
                    arguments.settleProxyFields()
                }
            }, action: {})
        case let .proxyPassField(text):
            return ItemListSingleLineInputItem(presentationData: presentationData, title: NSAttributedString(string: "密码"), text: text, placeholder: "可为空", type: .password, sectionId: self.section, textUpdated: { value in
                arguments.updateProxyField(.pass, value)
            }, updatedFocus: { focused in
                if !focused {
                    arguments.settleProxyFields()
                }
            }, action: {})
        case let .proxyPoolInput(text):
            return ItemListSingleLineInputItem(presentationData: presentationData, title: NSAttributedString(string: "代理池(批量)"), text: text, placeholder: "批量出口 host:port:用户:密码，分号分隔（可选，轮换用）", type: .regular(capitalization: false, autocorrection: false), sectionId: self.section, textUpdated: { value in
                arguments.updateProxyPool(value)
            }, updatedFocus: { focused in
                if !focused {
                    arguments.settleProxyPool()
                }
            }, action: {})
        case let .proxyHealthRow(_, spec, status):
            let statusText: String
            switch status {
            case .unknown:
                statusText = "未检测"
            case .checking:
                statusText = "检测中"
            case .alive:
                statusText = "正常"
            case .dead:
                statusText = "失联"
            }
            return ItemListTextItem(presentationData: presentationData, text: .plain("\(spec) — \(statusText)"), sectionId: self.section)
        case .checkPool:
            return ItemListActionItem(presentationData: presentationData, title: "检测代理池连通性", kind: .generic, alignment: .center, sectionId: self.section, style: .blocks, action: {
                arguments.checkPool()
            })
        case .shuffleProxy:
            return ItemListActionItem(presentationData: presentationData, title: "一键更换出口 IP（轮换）", kind: .generic, alignment: .center, sectionId: self.section, style: .blocks, action: {
                arguments.shuffleProxy()
            })
        case .proxyFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain("住宅或移动代理可让此账号的会话位置与指纹自洽。轮换时会自动跳过失联出口；后台看门狗也会周期巡检，失联自动切换。留空则跟随全局代理设置。"), sectionId: self.section)
        case .backupHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "配置备份", sectionId: self.section)
        case .exportConfig:
            return ItemListActionItem(presentationData: presentationData, title: "导出配置（复制到剪贴板）", kind: .generic, alignment: .center, sectionId: self.section, style: .blocks, action: {
                arguments.exportConfig()
            })
        case let .importInput(text):
            return ItemListSingleLineInputItem(presentationData: presentationData, title: NSAttributedString(string: "导入"), text: text, placeholder: "粘贴导出的配置文本", type: .regular(capitalization: false, autocorrection: false), sectionId: self.section, textUpdated: { value in
                arguments.updateImportText(value)
            }, updatedFocus: { _ in
            }, action: {})
        case .importConfig:
            return ItemListActionItem(presentationData: presentationData, title: "导入并应用到当前账号", kind: .generic, alignment: .center, sectionId: self.section, style: .blocks, action: {
                arguments.importConfig()
            })
        case .backupFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain("配置包含机型指纹与代理池。换机或重装后，在目标账号的此页面粘贴导入即可恢复；导入会覆盖该账号现有配置。"), sectionId: self.section)
        }
    }
}

private func porDeviceEnvironmentEntries(presentationData: PresentationData, profile: PorDeviceProfile?, health: [String: PorProxyHealthStatus], importText: String, draftHost: String, draftPort: String, draftUser: String, draftPass: String) -> [PorDeviceEnvironmentEntry] {
    var entries: [PorDeviceEnvironmentEntry] = []
    entries.append(.fingerprintHeader)
    entries.append(.shuffleDevice)
    entries.append(.fingerprintReal(profile?.model == nil))
    for (index, preset) in PorDeviceProfileStore.catalog.enumerated() {
        entries.append(.fingerprintModel(index: index, name: preset.name, checked: profile?.model == preset.model))
    }
    entries.append(.fingerprintFooter)
    entries.append(.proxyHeader)
    let poolText = profile?.proxyPool?.joined(separator: ";") ?? profile?.proxySpec ?? ""
    entries.append(.proxyInfo(profile?.proxySpec ?? "未设置（跟随全局）"))
    entries.append(.proxyHostField(text: draftHost))
    entries.append(.proxyPortField(text: draftPort))
    entries.append(.proxyUserField(text: draftUser))
    entries.append(.proxyPassField(text: draftPass))
    entries.append(.proxyPoolInput(text: poolText))
    var healthSpecs: [String] = profile?.proxyPool ?? []
    if healthSpecs.isEmpty, let spec = profile?.proxySpec {
        healthSpecs = [spec]
    }
    for (index, spec) in healthSpecs.enumerated() {
        if index < 30 {
            entries.append(.proxyHealthRow(index: index, spec: spec, status: health[spec] ?? .unknown))
        }
    }
    entries.append(.checkPool)
    entries.append(.shuffleProxy)
    entries.append(.proxyFooter)
    entries.append(.backupHeader)
    entries.append(.exportConfig)
    entries.append(.importInput(text: importText))
    entries.append(.importConfig)
    entries.append(.backupFooter)
    return entries
}

private func porCheckNext(_ candidates: [String], index: Int, dead: [String], completion: @escaping (String?, [String]) -> Void) {
    if index >= candidates.count {
        completion(nil, dead)
        return
    }
    let spec = candidates[index]
    PorProxyHealth.shared.check(spec: spec) { checkedSpec, alive in
        PorProxyHealth.shared.record(spec: checkedSpec, status: alive ? .alive : .dead, persist: true)
        if alive {
            completion(spec, dead)
        } else {
            porCheckNext(candidates, index: index + 1, dead: dead + [checkedSpec], completion: completion)
        }
    }
}

public func porDeviceEnvironmentController(context: AccountContext) -> ViewController {
    let accountId = context.account.id
    
    var currentProfile = PorDeviceProfileStore.shared.profile(accountId: accountId)
    var importText: String = ""
    
    var proxyDraftHost: String = ""
    var proxyDraftPort: String = ""
    var proxyDraftUser: String = ""
    var proxyDraftPass: String = ""
    func syncProxyDraftsFromProfile() {
        guard let spec = currentProfile?.proxySpec, !spec.isEmpty else {
            return
        }
        let parts = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else {
            return
        }
        proxyDraftHost = parts[0]
        proxyDraftPort = parts[1]
        proxyDraftUser = parts.count > 2 ? parts[2] : ""
        proxyDraftPass = parts.count > 3 ? parts[3] : ""
    }
    syncProxyDraftsFromProfile()
    
    let selectionPromise = ValuePromise<PorDeviceProfile?>(currentProfile)
    let importTextPromise = ValuePromise<String>("")
    
    var presentUndoImpl: ((UndoOverlayContent) -> Void)?
    
    func showToast(_ text: String) {
        presentUndoImpl?(.universal(animation: "anim_infotip", scale: 1.0, colors: [:], title: nil, text: text, customUndoText: nil, timeout: 5))
    }
    
    let bundleAppVersion: String = {
        let short = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""
        let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? ""
        if short.isEmpty {
            return ""
        }
        return "\(short) (\(build))"
    }()
    
    let applyDeviceLive = { (profile: PorDeviceProfile?) in
        let network = context.account.network
        let env = network.context.apiEnvironment
        var model: String? = nil
        var sys: String? = nil
        var app: String? = bundleAppVersion
        if let p = profile {
            model = p.model
            sys = p.systemVersion
            if let av = p.appVersion {
                app = av
            }
        }
        let newEnv = env.por(withUpdatedDeviceModel: model, systemVersion: sys, appVersion: app)
        network.context.updateApiEnvironment { _ in return newEnv }
    }
    
    let applyProxyLive = {
        let network = context.account.network
        let _ = (context.sharedContext.accountManager.sharedData(keys: [SharedDataKeys.proxySettings])
        |> take(1)
        |> deliverOnMainQueue).start(next: { sharedData in
            let shared = sharedData.entries[SharedDataKeys.proxySettings]?.get(ProxySettings.self)
            let resolved = PorDeviceProfileStore.shared.resolveProxy(accountId: accountId, shared: shared)
            network.updateProxySettings(resolved?.effectiveActiveServer)
        })
    }
    
    let commit = { (profile: PorDeviceProfile?) in
        currentProfile = profile
        PorDeviceProfileStore.shared.setProfile(profile, accountId: accountId)
        selectionPromise.set(profile)
        applyDeviceLive(profile)
        applyProxyLive()
    }
    
    let selectModelImpl: (String) -> Void = { name in
            guard let preset = PorDeviceProfileStore.catalog.first(where: { $0.name == name }) else {
                return
            }
            var profile = preset
            if let cur = currentProfile {
                profile.proxySpec = cur.proxySpec
                profile.proxyPool = cur.proxyPool
            }
            commit(profile)
            let pairingNote = profile.proxySpec != nil ? "（出口未变，请确认与常用登录环境自洽）" : ""
            showToast("已选 \(preset.model ?? preset.name)，已即时生效\(pairingNote)")
        }
    let selectRealDeviceImpl: () -> Void = {
            if let cur = currentProfile, cur.model == nil {
                showToast("当前已是真实设备指纹")
                return
            }
            var profile: PorDeviceProfile? = nil
            if let cur = currentProfile {
                profile = PorDeviceProfile(name: "真实设备（保留代理）", model: nil, systemVersion: nil, appVersion: nil, proxySpec: cur.proxySpec, proxyPool: cur.proxyPool)
            }
            commit(profile)
            let pairingNote = (profile?.proxySpec) != nil ? "（出口未变，请确认与常用登录环境自洽）" : ""
            showToast("已恢复真实设备指纹，已即时生效\(pairingNote)")
        }
    let shuffleDeviceImpl: () -> Void = {
            let next = PorDeviceProfileStore.randomProfile(excludingModel: currentProfile?.model)
            var profile = next
            if let cur = currentProfile {
                profile.proxySpec = cur.proxySpec
                profile.proxyPool = cur.proxyPool
            }
            commit(profile)
            let pairingNote = profile.proxySpec != nil ? "（出口未变，请确认与常用登录环境自洽）" : ""
            showToast("已随机更换为 \(next.model ?? next.name)，已即时生效\(pairingNote)")
        }
    let updateProxyPoolImpl: (String) -> Void = { value in
            let pool = PorDeviceProfileStore.parseProxyPool(value)
            var profile = currentProfile ?? PorDeviceProfile(name: "自定义", model: nil, systemVersion: nil, appVersion: nil, proxySpec: nil)
            profile.proxyPool = pool.isEmpty ? nil : pool
            currentProfile = profile
            PorDeviceProfileStore.shared.setProfile(profile, accountId: accountId)
        }
    let settleProxyPoolImpl: () -> Void = {
            guard var profile = currentProfile else {
                return
            }
            let pool = profile.proxyPool ?? []
            var changed = false
            if let spec = profile.proxySpec, !pool.isEmpty && !pool.contains(spec) {
                profile.proxySpec = pool.first
                changed = true
            } else if profile.proxySpec == nil && !pool.isEmpty {
                profile.proxySpec = pool.first
                changed = true
            }
            if changed {
                currentProfile = profile
                PorDeviceProfileStore.shared.setProfile(profile, accountId: accountId)
                selectionPromise.set(profile)
                applyProxyLive()
                syncProxyDraftsFromProfile()
            }
        }
    let updateProxyFieldImpl: (PorProxyFieldKind, String) -> Void = { kind, value in
        switch kind {
        case .host:
            proxyDraftHost = value
        case .port:
            proxyDraftPort = value
        case .user:
            proxyDraftUser = value
        case .pass:
            proxyDraftPass = value
        }
    }
    let settleProxyFieldsImpl: () -> Void = {
        let host = proxyDraftHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let portText = proxyDraftPort.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = proxyDraftUser.trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = proxyDraftPass.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.isEmpty && portText.isEmpty && user.isEmpty && pass.isEmpty {
            if let cur = currentProfile, cur.proxySpec != nil {
                var profile = cur
                profile.proxySpec = nil
                commit(profile)
                showToast("已清除出口，改为跟随全局代理设置")
            }
            return
        }
        guard !host.isEmpty, let port = Int32(portText), port > 0, port < 65536 else {
            showToast("格式有误：地址必填，端口需为 1-65535")
            return
        }
        var spec = "\(host):\(port)"
        if !user.isEmpty {
            spec += ":\(user)"
            if !pass.isEmpty {
                spec += ":\(pass)"
            }
        }
        var profile = currentProfile ?? PorDeviceProfile(name: "自定义", model: nil, systemVersion: nil, appVersion: nil, proxySpec: nil)
        if profile.proxySpec == spec, let pool = profile.proxyPool, pool.contains(spec) {
            return
        }
        profile.proxySpec = spec
        var pool = profile.proxyPool ?? []
        if !pool.contains(spec) {
            pool.insert(spec, at: 0)
        }
        profile.proxyPool = pool.isEmpty ? nil : pool
        commit(profile)
        showToast("出口已更新并即时生效：\(spec)")
    }
    let shuffleProxyImpl: () -> Void = {
            guard let cur = currentProfile else {
                showToast("请先填写代理池")
                return
            }
            let pool = cur.proxyPool ?? (cur.proxySpec != nil ? [cur.proxySpec!] : [])
            guard !pool.isEmpty else {
                showToast("代理池为空，请先填写代理")
                return
            }
            guard pool.count > 1 else {
                let single = pool[0]
                PorProxyHealth.shared.record(spec: single, status: .checking, persist: false)
                PorProxyHealth.shared.check(spec: single) { spec, alive in
                    PorProxyHealth.shared.record(spec: spec, status: alive ? .alive : .dead, persist: true)
                    if alive {
                        showToast("仅一条出口，当前连通正常")
                    } else {
                        showToast("仅一条出口，且已失联，请检查代理或补充池子")
                    }
                }
                return
            }
            let currentIndex = pool.firstIndex(of: cur.proxySpec ?? "") ?? -1
            var candidates: [String] = []
            for offset in 1..<pool.count {
                candidates.append(pool[(currentIndex + offset) % pool.count])
            }
            for spec in candidates {
                PorProxyHealth.shared.record(spec: spec, status: .checking, persist: false)
            }
            porCheckNext(candidates, index: 0, dead: []) { chosen, deadList in
                guard let chosen = chosen else {
                    showToast("代理池内出口全部失联，已保留当前：\(cur.proxySpec ?? "无")")
                    return
                }
                var profile = cur
                profile.proxySpec = chosen
                commit(profile)
                syncProxyDraftsFromProfile()
                let skippedText = deadList.isEmpty ? "" : "（已自动跳过 \(deadList.count) 条失联出口）"
                showToast("已切换出口：\(chosen)，已即时生效\(skippedText)")
            }
        }
    let checkPoolImpl: () -> Void = {
            guard let profile = currentProfile else {
                showToast("请先填写代理池")
                return
            }
            var specs = profile.proxyPool ?? []
            if specs.isEmpty, let spec = profile.proxySpec {
                specs = [spec]
            }
            guard !specs.isEmpty else {
                showToast("代理池为空，请先填写代理")
                return
            }
            for spec in specs {
                PorProxyHealth.shared.record(spec: spec, status: .checking, persist: false)
                PorProxyHealth.shared.check(spec: spec) { checkedSpec, alive in
                    PorProxyHealth.shared.record(spec: checkedSpec, status: alive ? .alive : .dead, persist: true)
                }
            }
        }
    let exportConfigImpl: () -> Void = {
            guard let profile = currentProfile else {
                showToast("当前没有可导出的配置")
                return
            }
            let peerSignal: Signal<EnginePeer?, NoError> = context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: context.account.peerId))
            |> take(1)
            |> deliverOnMainQueue
            let _ = peerSignal.start(next: { peer in
                var phone: String? = nil
                if let peer = peer, case let .user(user) = peer {
                    phone = user.phone
                }
                let payload = PorExportPayload(v: 1, phone: phone, profile: profile)
                if let data = try? JSONEncoder().encode(payload) {
                    let encoded = data.base64EncodedString()
                    UIPasteboard.general.string = encoded
                    showToast("配置已复制到剪贴板（\(encoded.count) 字符），在另一台设备的设备环境页面导入即可")
                } else {
                    showToast("导出失败，请重试")
                }
            })
        }
    let updateImportTextImpl: (String) -> Void = { value in
            importText = value
            importTextPromise.set(value)
        }
    let importConfigImpl: () -> Void = {
            let trimmed = importText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                showToast("请先粘贴要导入的配置文本")
                return
            }
            let cleaned = trimmed.components(separatedBy: .whitespacesAndNewlines).joined()
            guard let data = Data(base64Encoded: cleaned), let payload = try? JSONDecoder().decode(PorExportPayload.self, from: data) else {
                showToast("导入失败：配置文本格式不正确")
                return
            }
            guard payload.v == 1, let profile = payload.profile else {
                showToast("导入失败：配置内容不完整")
                return
            }
            commit(profile)
            syncProxyDraftsFromProfile()
            let fromText = payload.phone != nil ? "（来自 \(payload.phone!)）" : ""
            showToast("已导入并应用\(fromText)，已即时生效")
            importText = ""
            importTextPromise.set("")
        }

    let arguments = PorDeviceEnvironmentControllerArguments(
        selectModel: selectModelImpl,
        selectRealDevice: selectRealDeviceImpl,
        shuffleDevice: shuffleDeviceImpl,
        updateProxyPool: updateProxyPoolImpl,
        settleProxyPool: settleProxyPoolImpl,
        updateProxyField: updateProxyFieldImpl,
        settleProxyFields: settleProxyFieldsImpl,
        shuffleProxy: shuffleProxyImpl,
        checkPool: checkPoolImpl,
        exportConfig: exportConfigImpl,
        updateImportText: updateImportTextImpl,
        importConfig: importConfigImpl
    )
    
    let signal = combineLatest(queue: .mainQueue(),
        context.sharedContext.presentationData,
        selectionPromise.get(),
        PorProxyHealth.shared.statusesValue.get(),
        importTextPromise.get()
    )
    |> deliverOnMainQueue
    |> map { presentationData, profile, health, importText -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("设备环境"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: porDeviceEnvironmentEntries(presentationData: presentationData, profile: profile, health: health, importText: importText, draftHost: proxyDraftHost, draftPort: proxyDraftPort, draftUser: proxyDraftUser, draftPass: proxyDraftPass), style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }
    
    let controller = ItemListController(context: context, state: signal)
    controller.navigationPresentation = .modal
    
    let porDismissKeyboardTap = UITapGestureRecognizer(target: controller.view, action: #selector(UIView.endEditing(_:)))
    porDismissKeyboardTap.cancelsTouchesInView = false
    controller.view.addGestureRecognizer(porDismissKeyboardTap)
    
    presentUndoImpl = { [weak controller] content in
        guard let controller else {
            return
        }
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        controller.present(UndoOverlayController(presentationData: presentationData, content: content, elevatedLayout: false, action: { _ in
            return false
        }), in: .current)
    }
    
    let accountKey = String(accountId.int64)
    let _ = (PorProxyWatchdog.shared.rotationsValue.get()
    |> deliverOnMainQueue).startStandalone(next: { rotations in
        if let newSpec = rotations[accountKey] {
            PorProxyWatchdog.shared.consumeRotation(accountId: accountId)
            showToast("当前出口失联，看门狗已自动切换为：\(newSpec)")
        }
    })
    
    PorProxyWatchdog.shared.runCheck()
    
    return controller
}
