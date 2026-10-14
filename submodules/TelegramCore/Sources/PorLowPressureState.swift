import Foundation
import SwiftSignalKit
import Postbox

/// POR18: 减压文件夹 (low-pressure folder) support.
///
/// Chats inside folders flagged as "low pressure" never fetch media automatically:
/// the fetch manager blocks every non-user-initiated media fetch (display prefetch,
/// background prefetch, automatic download) for those peers. Manual, user-initiated
/// fetches (tapping media, opening the gallery, saving a file) still go through.

public struct PorLowPressureFlagsEntry: Codable, Equatable {
    public var enabledFolderIds: [Int32]

    public init(enabledFolderIds: [Int32]) {
        self.enabledFolderIds = enabledFolderIds
    }
}

public let porLowPressurePreferencesKey: ValueBoxKey = {
    let key = ValueBoxKey(length: 4)
    key.setInt32(0, value: 0x504F5250) // "PORP"
    return key
}()

/// Thread-safe snapshot of the low-pressure peer set. Updated from the postbox queue,
/// queried from the fetch manager queue.
public final class PorLowPressureState {
    private let lock = NSLock()
    private var enabledFolderIds: Set<Int32> = []
    private var exactPeers: Set<PeerId> = []
    private var includeChannels = false
    private var includeGroups = false

    public init() {
    }

    public func isEnabled(folderId: Int32) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.enabledFolderIds.contains(folderId)
    }

    /// Whether automatic media fetches are blocked for this peer.
    /// Only peer id namespaces are inspected here (no postbox access on the hot path):
    /// explicitly included peers always match; "all channels" / "all groups" folder
    /// categories match by namespace. Contact/bot categories are not resolvable from
    /// the id alone and are intentionally not enforced.
    public func isLowPressure(peerId: PeerId) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        if self.exactPeers.contains(peerId) {
            return true
        }
        if self.includeChannels && peerId.namespace == Namespaces.Peer.CloudChannel {
            return true
        }
        if self.includeGroups && peerId.namespace == Namespaces.Peer.CloudGroup {
            return true
        }
        return false
    }

    fileprivate func update(enabledFolderIds: Set<Int32>, filters: [ChatListFilter]) {
        var exactPeers = Set<PeerId>()
        var includeChannels = false
        var includeGroups = false
        for filter in filters {
            guard enabledFolderIds.contains(filter.id) else {
                continue
            }
            if case let .filter(_, _, _, data) = filter {
                for peerId in data.includePeers.peers {
                    if !data.excludePeers.contains(peerId) {
                        exactPeers.insert(peerId)
                    }
                }
                for peerId in data.includePeers.pinnedPeers {
                    if !data.excludePeers.contains(peerId) {
                        exactPeers.insert(peerId)
                    }
                }
                if data.categories.contains(.channels) {
                    includeChannels = true
                }
                if data.categories.contains(.groups) {
                    includeGroups = true
                }
            }
        }
        self.lock.lock()
        self.enabledFolderIds = enabledFolderIds
        self.exactPeers = exactPeers
        self.includeChannels = includeChannels
        self.includeGroups = includeGroups
        self.lock.unlock()
    }
}

/// Creates and wires a PorLowPressureState that tracks the account's chat-list filters
/// plus the por low-pressure folder flags. The returned disposable must be retained.
public func startPorLowPressureState(postbox: Postbox) -> (PorLowPressureState, Disposable) {
    let state = PorLowPressureState()
    let disposable = postbox.preferencesView(keys: [PreferencesKeys.chatListFilters, porLowPressurePreferencesKey]).start(next: { view in
        let filtersState = view.values[PreferencesKeys.chatListFilters]?.get(ChatListFiltersState.self) ?? ChatListFiltersState.default
        let enabledIds = view.values[porLowPressurePreferencesKey]?.get(PorLowPressureFlagsEntry.self)?.enabledFolderIds ?? []
        state.update(enabledFolderIds: Set(enabledIds), filters: filtersState.filters)
    })
    return (state, disposable)
}

/// Enables or disables low-pressure mode for a chat-list folder (by folder id).
public func setPorLowPressureFolderEnabled(account: Account, folderId: Int32, enabled: Bool) -> Signal<Void, NoError> {
    let postbox = account.postbox
    return postbox.transaction { transaction -> Void in
        transaction.updatePreferencesEntry(key: porLowPressurePreferencesKey, { current in
            var entry = current?.get(PorLowPressureFlagsEntry.self) ?? PorLowPressureFlagsEntry(enabledFolderIds: [])
            if enabled {
                if !entry.enabledFolderIds.contains(folderId) {
                    entry.enabledFolderIds.append(folderId)
                }
            } else {
                entry.enabledFolderIds.removeAll { $0 == folderId }
            }
            return PreferencesEntry(entry)
        })
    }
}
