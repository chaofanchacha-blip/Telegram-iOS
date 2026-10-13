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

private final class PorDeviceEnvironmentControllerArguments {
    let selectModel: (String) -> Void
    let selectRealDevice: () -> Void
    let shuffleDevice: () -> Void
    let updateProxyPool: (String) -> Void
    let shuffleProxy: () -> Void
    
    init(
        selectModel: @escaping (String) -> Void,
        selectRealDevice: @escaping () -> Void,
        shuffleDevice: @escaping () -> Void,
        updateProxyPool: @escaping (String) -> Void,
        shuffleProxy: @escaping () -> Void
    ) {
        self.selectModel = selectModel
        self.selectRealDevice = selectRealDevice
        self.shuffleDevice = shuffleDevice
        self.updateProxyPool = updateProxyPool
        self.shuffleProxy = shuffleProxy
    }
}

private enum PorDeviceEnvironmentSection: Int32 {
    case fingerprint
    case proxy
}

private enum PorDeviceEnvironmentEntry: ItemListNodeEntry {
    case fingerprintHeader
    case shuffleDevice
    case fingerprintReal(Bool)
    case fingerprintModel(index: Int, name: String, checked: Bool)
    case fingerprintFooter
    
    case proxyHeader
    case proxyInfo(String)
    case proxyPoolInput(text: String)
    case shuffleProxy
    case proxyFooter
    
    var section: ItemListSectionId {
        switch self {
        case .fingerprintHeader, .shuffleDevice, .fingerprintReal, .fingerprintModel, .fingerprintFooter:
            return PorDeviceEnvironmentSection.fingerprint.rawValue
        case .proxyHeader, .proxyInfo, .proxyPoolInput, .shuffleProxy, .proxyFooter:
            return PorDeviceEnvironmentSection.proxy.rawValue
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
        case .proxyPoolInput:
            return 203
        case .shuffleProxy:
            return 204
        case .proxyFooter:
            return 205
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
            return ItemListActionItem(presentationData: presentationData, title: "🎲 一键更换机型（随机）", kind: .generic, alignment: .center, sectionId: self.section, style: .blocks, action: {
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
            return ItemListTextItem(presentationData: presentationData, text: .plain("选择此账号对外显示的设备身份（机型、系统、版本）。重启 App 后生效。"), sectionId: self.section)
        case .proxyHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "代理出口 (SOCKS5)", sectionId: self.section)
        case let .proxyInfo(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain("当前出口：\(text)"), sectionId: self.section)
        case let .proxyPoolInput(text):
            return ItemListSingleLineInputItem(presentationData: presentationData, title: NSAttributedString(string: "代理池"), text: text, placeholder: "host:port:用户:密码，多条用 ; 分隔", type: .regular(capitalization: false, autocorrection: false), sectionId: self.section, textUpdated: { value in
                arguments.updateProxyPool(value)
            }, action: {})
        case .shuffleProxy:
            return ItemListActionItem(presentationData: presentationData, title: "🎲 一键更换出口 IP（轮换）", kind: .generic, alignment: .center, sectionId: self.section, style: .blocks, action: {
                arguments.shuffleProxy()
            })
        case .proxyFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain("住宅或移动代理可让此账号的会话位置与指纹自洽。填写多条后可一键轮换；留空则跟随全局代理设置。"), sectionId: self.section)
        }
    }
}

private func porDeviceEnvironmentEntries(presentationData: PresentationData, profile: PorDeviceProfile?) -> [PorDeviceEnvironmentEntry] {
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
    entries.append(.proxyPoolInput(text: poolText))
    entries.append(.shuffleProxy)
    entries.append(.proxyFooter)
    return entries
}

public func porDeviceEnvironmentController(context: AccountContext) -> ViewController {
    let accountId = context.account.id
    
    var currentProfile = PorDeviceProfileStore.shared.profile(accountId: accountId)
    
    let selectionPromise = ValuePromise<PorDeviceProfile?>(currentProfile)
    
    var presentUndoImpl: ((UndoOverlayContent) -> Void)?
    
    let commit = { (profile: PorDeviceProfile?) in
        currentProfile = profile
        PorDeviceProfileStore.shared.setProfile(profile, accountId: accountId)
        selectionPromise.set(profile)
    }
    
    let arguments = PorDeviceEnvironmentControllerArguments(
        selectModel: { name in
            guard let preset = PorDeviceProfileStore.catalog.first(where: { $0.name == name }) else {
                return
            }
            var profile = preset
            if let cur = currentProfile {
                profile.proxySpec = cur.proxySpec
                profile.proxyPool = cur.proxyPool
            }
            commit(profile)
            presentUndoImpl?(.universal(animation: "anim_infotip", scale: 1.0, colors: [:], title: nil, text: "已选 \(preset.model ?? preset.name)，重启 App 后生效", customUndoText: nil, timeout: 5))
        },
        selectRealDevice: {
            if let cur = currentProfile, cur.model == nil {
                presentUndoImpl?(.universal(animation: "anim_infotip", scale: 1.0, colors: [:], title: nil, text: "当前已是真实设备指纹", customUndoText: nil, timeout: 5))
                return
            }
            var profile: PorDeviceProfile? = nil
            if let cur = currentProfile {
                profile = PorDeviceProfile(name: "真实设备（保留代理）", model: nil, systemVersion: nil, appVersion: nil, proxySpec: cur.proxySpec, proxyPool: cur.proxyPool)
            }
            commit(profile)
            presentUndoImpl?(.universal(animation: "anim_infotip", scale: 1.0, colors: [:], title: nil, text: "已恢复真实设备指纹，重启 App 后生效", customUndoText: nil, timeout: 5))
        },
        shuffleDevice: {
            let next = PorDeviceProfileStore.randomProfile(excludingModel: currentProfile?.model)
            var profile = next
            if let cur = currentProfile {
                profile.proxySpec = cur.proxySpec
                profile.proxyPool = cur.proxyPool
            }
            commit(profile)
            presentUndoImpl?(.universal(animation: "anim_infotip", scale: 1.0, colors: [:], title: nil, text: "已随机更换为 \(next.model ?? next.name)，重启 App 后生效", customUndoText: nil, timeout: 5))
        },
        updateProxyPool: { value in
            let pool = PorDeviceProfileStore.parseProxyPool(value)
            var profile = currentProfile ?? PorDeviceProfile(name: "自定义", model: nil, systemVersion: nil, appVersion: nil, proxySpec: nil)
            profile.proxyPool = pool.isEmpty ? nil : pool
            if let spec = profile.proxySpec, !pool.isEmpty && !pool.contains(spec) {
                profile.proxySpec = pool.first
            }
            if profile.proxySpec == nil && !pool.isEmpty {
                profile.proxySpec = pool.first
            }
            currentProfile = profile
            PorDeviceProfileStore.shared.setProfile(profile, accountId: accountId)
        },
        shuffleProxy: {
            guard let cur = currentProfile else {
                presentUndoImpl?(.universal(animation: "anim_infotip", scale: 1.0, colors: [:], title: nil, text: "请先在下方填写代理池", customUndoText: nil, timeout: 5))
                return
            }
            let pool = cur.proxyPool ?? (cur.proxySpec != nil ? [cur.proxySpec!] : [])
            guard !pool.isEmpty else {
                presentUndoImpl?(.universal(animation: "anim_infotip", scale: 1.0, colors: [:], title: nil, text: "代理池为空，请先填写代理", customUndoText: nil, timeout: 5))
                return
            }
            guard pool.count > 1 else {
                presentUndoImpl?(.universal(animation: "anim_infotip", scale: 1.0, colors: [:], title: nil, text: "代理池只有一条，无备选可切换", customUndoText: nil, timeout: 5))
                return
            }
            let currentIndex = pool.firstIndex(of: cur.proxySpec ?? "") ?? -1
            let nextIndex = (currentIndex + 1) % pool.count
            var profile = cur
            profile.proxySpec = pool[nextIndex]
            commit(profile)
            presentUndoImpl?(.universal(animation: "anim_infotip", scale: 1.0, colors: [:], title: nil, text: "已切换出口：\(pool[nextIndex])，重启 App 后生效", customUndoText: nil, timeout: 5))
        }
    )
    
    let signal = combineLatest(queue: .mainQueue(),
        context.sharedContext.presentationData,
        selectionPromise.get()
    )
    |> deliverOnMainQueue
    |> map { presentationData, profile -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("设备环境"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: porDeviceEnvironmentEntries(presentationData: presentationData, profile: profile), style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }
    
    let controller = ItemListController(context: context, state: signal)
    controller.navigationPresentation = .modal
    
    presentUndoImpl = { [weak controller] content in
        guard let controller else {
            return
        }
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        controller.present(UndoOverlayController(presentationData: presentationData, content: content, elevatedLayout: false, action: { _ in
            return false
        }), in: .current)
    }
    
    return controller
}
