import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext

private final class PorDeviceEnvironmentControllerArguments {
    let selectProfile: (PorDeviceProfile?) -> Void
    let updateProxySpec: (String) -> Void
    
    init(
        selectProfile: @escaping (PorDeviceProfile?) -> Void,
        updateProxySpec: @escaping (String) -> Void
    ) {
        self.selectProfile = selectProfile
        self.updateProxySpec = updateProxySpec
    }
}

private enum PorDeviceEnvironmentSection: Int32 {
    case fingerprint
    case proxy
}

private enum PorDeviceEnvironmentEntry: ItemListNodeEntry {
    case fingerprintHeader
    case fingerprintReal(Bool)
    case fingerprintPreset(index: Int, name: String, checked: Bool)
    case fingerprintFooter
    
    case proxyHeader
    case proxyValue(text: String)
    case proxyFooter
    
    var section: ItemListSectionId {
        switch self {
        case .fingerprintHeader, .fingerprintReal, .fingerprintPreset, .fingerprintFooter:
            return PorDeviceEnvironmentSection.fingerprint.rawValue
        case .proxyHeader, .proxyValue, .proxyFooter:
            return PorDeviceEnvironmentSection.proxy.rawValue
        }
    }
    
    var stableId: Int32 {
        switch self {
        case .fingerprintHeader:
            return 0
        case .fingerprintReal:
            return 1
        case let .fingerprintPreset(index, _, _):
            return 2 + Int32(index)
        case .fingerprintFooter:
            return 100
        case .proxyHeader:
            return 101
        case .proxyValue:
            return 102
        case .proxyFooter:
            return 103
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
        case let .fingerprintReal(checked):
            return ItemListCheckboxItem(presentationData: presentationData, title: "真实设备", style: .right, checked: checked, zeroSeparatorInsets: false, sectionId: self.section, action: {
                arguments.selectProfile(nil)
            })
        case let .fingerprintPreset(_, name, checked):
            return ItemListCheckboxItem(presentationData: presentationData, title: name, style: .right, checked: checked, zeroSeparatorInsets: false, sectionId: self.section, action: {
                if let preset = PorDeviceProfileStore.presets.first(where: { $0.name == name }) {
                    arguments.selectProfile(preset)
                }
            })
        case .fingerprintFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain("选择此账号对外显示的设备身份（机型、系统、版本）。重启 App 后生效。"), sectionId: self.section)
        case .proxyHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "账号代理 (SOCKS5)", sectionId: self.section)
        case let .proxyValue(text):
            return ItemListSingleLineInputItem(presentationData: presentationData, title: NSAttributedString(string: "代理"), text: text, placeholder: "host:port:用户名:密码", type: .regular(capitalization: false, autocorrection: false), sectionId: self.section, textUpdated: { value in
                arguments.updateProxySpec(value)
            }, action: {})
        case .proxyFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain("住宅或移动代理可让此账号的会话位置与指纹自洽。留空则跟随全局代理设置。"), sectionId: self.section)
        }
    }
}

private func porDeviceEnvironmentEntries(presentationData: PresentationData, profile: PorDeviceProfile?) -> [PorDeviceEnvironmentEntry] {
    var entries: [PorDeviceEnvironmentEntry] = []
    entries.append(.fingerprintHeader)
    entries.append(.fingerprintReal(profile?.model == nil))
    for (index, preset) in PorDeviceProfileStore.presets.enumerated() {
        entries.append(.fingerprintPreset(index: index, name: preset.name, checked: profile?.model == preset.model))
    }
    entries.append(.fingerprintFooter)
    entries.append(.proxyHeader)
    entries.append(.proxyValue(text: profile?.proxySpec ?? ""))
    entries.append(.proxyFooter)
    return entries
}

public func porDeviceEnvironmentController(context: AccountContext) -> ViewController {
    let accountId = context.account.id
    
    var currentProfile = PorDeviceProfileStore.shared.profile(accountId: accountId)
    
    let selectionPromise = ValuePromise<PorDeviceProfile?>(currentProfile)
    
    let arguments = PorDeviceEnvironmentControllerArguments(
        selectProfile: { profile in
            currentProfile = profile
            PorDeviceProfileStore.shared.setProfile(profile, accountId: accountId)
            selectionPromise.set(profile)
        },
        updateProxySpec: { value in
            var spec: String? = nil
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                spec = trimmed
            }
            var profile = currentProfile ?? PorDeviceProfile(name: "自定义", model: nil, systemVersion: nil, appVersion: nil, proxySpec: nil)
            profile.proxySpec = spec
            currentProfile = profile
            PorDeviceProfileStore.shared.setProfile(profile, accountId: accountId)
            selectionPromise.set(profile)
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
    
    return controller
}
