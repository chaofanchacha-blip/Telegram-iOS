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

// Por HB Engine — 红包引擎控制中心
// 总开关语义: 打开后引擎在所有已登录账号上常驻 (前台/后台/更新流唤醒均工作),
// 只有在这里手动关闭才停止。每个功能模块独立开关。

private enum PorHBEngineSection: Int32 {
    case engine
    case stats
}

private enum PorHBEngineEntry: ItemListNodeEntry {
    case engineHeader
    case masterSwitch(Bool)
    case claimInlineSwitch(Bool)
    case delayProfile(index: Int, name: String)
    case engineStatus(text: String)

    case statsHeader
    case statsSummary(text: String)
    case copyLedger
    case resetStats

    case footer

    var section: ItemListSectionId {
        switch self {
        case .engineHeader, .masterSwitch, .claimInlineSwitch, .delayProfile, .engineStatus:
            return PorHBEngineSection.engine.rawValue
        case .statsHeader, .statsSummary, .copyLedger, .resetStats:
            return PorHBEngineSection.stats.rawValue
        case .footer:
            return PorHBEngineSection.stats.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .engineHeader:
            return 0
        case .masterSwitch:
            return 1
        case .claimInlineSwitch:
            return 2
        case .delayProfile:
            return 3
        case .engineStatus:
            return 4
        case .statsHeader:
            return 100
        case .statsSummary:
            return 101
        case .copyLedger:
            return 102
        case .resetStats:
            return 103
        case .footer:
            return 200
        }
    }

    static func <(lhs: PorHBEngineEntry, rhs: PorHBEngineEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! PorHBEngineControllerArguments
        switch self {
        case .engineHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "红包引擎", sectionId: self.section)
        case let .masterSwitch(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "总开关（常驻监听全部已登录账号）", value: value, sectionId: self.section, style: .blocks, updated: { updatedValue in
                arguments.setMaster(updatedValue)
            })
        case let .claimInlineSwitch(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "A型秒抢（inline 按钮红包）", value: value, sectionId: self.section, style: .blocks, updated: { updatedValue in
                arguments.setClaimInline(updatedValue)
            })
        case let .delayProfile(_, name):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: "击发延迟档位", label: name, labelStyle: .text, sectionId: self.section, style: .blocks, disclosureStyle: .arrow, action: {
                arguments.cycleDelay()
            })
        case let .engineStatus(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case .statsHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "战况", sectionId: self.section)
        case let .statsSummary(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case .copyLedger:
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: "复制完整台账", label: "", labelStyle: .text, sectionId: self.section, style: .blocks, disclosureStyle: .arrow, action: {
                arguments.copyLedger()
            })
        case .resetStats:
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: "清空统计与去重记录", label: "", labelStyle: .text, sectionId: self.section, style: .blocks, disclosureStyle: .arrow, action: {
                arguments.resetStats()
            })
        case .footer:
            return ItemListTextItem(presentationData: presentationData, text: .plain("引擎挂在每个账号的实时更新流上：收到红包按钮消息即在随机延迟后直调协议领取，与真人点击在协议层完全一致。多账号同时在线时各自独立击发，一个多份红包可被多个账号分食。只有在此页面手动关闭总开关才会停止。"), sectionId: self.section)
        }
    }
}

private func porHBEngineEntries(presentationData: PresentationData, master: Bool, claimInline: Bool, delayName: String, activeAccounts: Int, totalClaims: Int, lastClaim: Date?) -> [PorHBEngineEntry] {
    var entries: [PorHBEngineEntry] = []
    entries.append(.engineHeader)
    entries.append(.masterSwitch(master))
    if master {
        entries.append(.claimInlineSwitch(claimInline))
        entries.append(.delayProfile(index: 0, name: delayName))
        entries.append(.engineStatus(text: "运行状态：🟢 已开启 · 活跃账号 \(activeAccounts) 个 · 累计领取 \(totalClaims) 次"))
    } else {
        entries.append(.engineStatus(text: "运行状态：⚪️ 已停止（开启后立即在全部账号上生效）"))
    }
    entries.append(.statsHeader)
    var summary = "累计领取 \(totalClaims) 次"
    if let lastClaim = lastClaim {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        summary += " · 最近命中 \(formatter.string(from: lastClaim))"
    }
    entries.append(.statsSummary(text: summary))
    entries.append(.copyLedger)
    entries.append(.resetStats)
    entries.append(.footer)
    return entries
}

private final class PorHBEngineControllerArguments {
    let setMaster: (Bool) -> Void
    let setClaimInline: (Bool) -> Void
    let cycleDelay: () -> Void
    let copyLedger: () -> Void
    let resetStats: () -> Void

    init(setMaster: @escaping (Bool) -> Void, setClaimInline: @escaping (Bool) -> Void, cycleDelay: @escaping () -> Void, copyLedger: @escaping () -> Void, resetStats: @escaping () -> Void) {
        self.setMaster = setMaster
        self.setClaimInline = setClaimInline
        self.cycleDelay = cycleDelay
        self.copyLedger = copyLedger
        self.resetStats = resetStats
    }
}

private func porHBEngineDelayName(profile: Int) -> String {
    switch profile {
    case 0:
        return "激进（0.08-0.25s）"
    case 2:
        return "拟人（0.30-0.90s）"
    default:
        return "均衡（0.12-0.38s）"
    }
}

public func porHBEngineController(context: AccountContext) -> ViewController {
    var presentUndoImpl: ((UndoOverlayContent) -> Void)?
    let revisionPromise = Promise<Int>(0)

    let setMasterImpl: (Bool) -> Void = { value in
        PorHBEngine.shared.masterEnabled = value
        revisionPromise.set(revisionPromise.get() |> map { $0 + 1 })
        if value {
            presentUndoImpl?(.succeed(text: "红包引擎已开启：全部已登录账号开始常驻监听", timeout: nil, customUndoText: nil))
        } else {
            presentUndoImpl?(.succeed(text: "红包引擎已停止，待处理任务已取消", timeout: nil, customUndoText: nil))
        }
    }
    let setClaimInlineImpl: (Bool) -> Void = { value in
        PorHBEngine.shared.claimInlineEnabled = value
        revisionPromise.set(revisionPromise.get() |> map { $0 + 1 })
    }
    let cycleDelayImpl: () -> Void = {
        let next = (PorHBEngine.shared.delayProfile + 1) % 3
        PorHBEngine.shared.delayProfile = next
        revisionPromise.set(revisionPromise.get() |> map { $0 + 1 })
        presentUndoImpl?(.succeed(text: "延迟档位：\(porHBEngineDelayName(profile: next))", timeout: nil, customUndoText: nil))
    }
    let copyLedgerImpl: () -> Void = {
        let contents = PorHBEngine.shared.ledgerContents(maxBytes: 262144)
        if contents.isEmpty {
            presentUndoImpl?(.succeed(text: "台账为空（还没有任何领取记录）", timeout: nil, customUndoText: nil))
        } else {
            UIPasteboard.general.string = contents
            presentUndoImpl?(.succeed(text: "已复制 \(contents.count) 字符台账 (por_hb_hits.jsonl)", timeout: nil, customUndoText: nil))
        }
    }
    let resetStatsImpl: () -> Void = {
        PorHBEngine.shared.resetStats()
        revisionPromise.set(revisionPromise.get() |> map { $0 + 1 })
        presentUndoImpl?(.succeed(text: "统计与去重记录已清空", timeout: nil, customUndoText: nil))
    }

    let arguments = PorHBEngineControllerArguments(
        setMaster: setMasterImpl,
        setClaimInline: setClaimInlineImpl,
        cycleDelay: cycleDelayImpl,
        copyLedger: copyLedgerImpl,
        resetStats: resetStatsImpl
    )

    let signal = combineLatest(queue: .mainQueue(),
        context.sharedContext.presentationData,
        revisionPromise.get()
    )
    |> deliverOnMainQueue
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let master = PorHBEngine.shared.masterEnabled
        let claimInline = PorHBEngine.shared.claimInlineEnabled
        let delayName = porHBEngineDelayName(profile: PorHBEngine.shared.delayProfile)
        let activeAccounts = PorHBEngine.shared.activeAccountCount
        let totalClaims = PorHBEngine.shared.totalClaims
        let lastClaim = PorHBEngine.shared.lastClaimDate

        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("红包引擎"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: porHBEngineEntries(presentationData: presentationData, master: master, claimInline: claimInline, delayName: delayName, activeAccounts: activeAccounts, totalClaims: totalClaims, lastClaim: lastClaim), style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    controller.navigationPresentation = .modal

    presentUndoImpl = { [weak controller] content in
        guard let controller = controller else {
            return
        }
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        controller.present(UndoOverlayController(presentationData: presentationData, content: content, elevatedLayout: false, action: { _ in
            return false
        }), in: .current)
    }

    return controller
}
