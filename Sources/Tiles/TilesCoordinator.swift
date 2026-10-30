import Foundation
import AppKit
import CoreGraphics
import Combine
import ServiceManagement

public enum DashboardTab: String, CaseIterable, Identifiable {
    case map = "Snapshot Map"
    case log = "Activity Log"
    case settings = "Settings"

    public var id: String { rawValue }
}

@MainActor
public final class TilesCoordinator: ObservableObject {
    public static let allowedIntervals: [Int] = [15, 30, 60, 120, 300]
    public static let allowedHistoryLimits: [Int] = [5, 10, 20, 50]

    private enum DefaultsKeys {
        static let autoSnapshot = "Tiles.isAutoSnapshotEnabled"
        static let autoRestore = "Tiles.isAutoRestoreEnabled"
        static let intervalSeconds = "Tiles.snapshotIntervalSeconds"
        static let historyLimit = "Tiles.historyLimit"
        static let openAtLogin = "Tiles.openAtLogin"
    }

    @Published public var customDisplayNames: [String: String] = [:]
    @Published public var connectedDisplays: [(
        uuid: String,
        cgDisplayID: CGDirectDisplayID,
        systemName: String,
        customName: String,
        isBuiltIn: Bool,
        quartzFrame: CGRect
    )] = []
    @Published public var currentTopologyKey: String = ""
    @Published public var availableTopologies: [String] = []
    @Published public var viewingTopologyKey: String = ""
    @Published public var recentSnapshots: [MacSnapshot] = []
    @Published public var pinsByTopology: [String: String] = [:]
    @Published public var selectedSnapshotID: String?
    @Published public var secondsUntilNextSnapshot: Int = 30

    @Published public var isAutoSnapshotEnabled: Bool = true {
        didSet {
            guard !isInitializing else { return }
            defaults.set(isAutoSnapshotEnabled, forKey: DefaultsKeys.autoSnapshot)
            if isAutoSnapshotEnabled {
                secondsUntilNextSnapshot = snapshotIntervalSeconds
            }
        }
    }

    @Published public var isAutoRestoreEnabled: Bool = true {
        didSet {
            guard !isInitializing else { return }
            defaults.set(isAutoRestoreEnabled, forKey: DefaultsKeys.autoRestore)
        }
    }

    @Published public var snapshotIntervalSeconds: Int = 30 {
        didSet {
            guard !isInitializing else { return }
            defaults.set(snapshotIntervalSeconds, forKey: DefaultsKeys.intervalSeconds)
            secondsUntilNextSnapshot = snapshotIntervalSeconds
        }
    }

    @Published public var historyLimit: Int = 10 {
        didSet {
            guard !isInitializing else { return }
            defaults.set(historyLimit, forKey: DefaultsKeys.historyLimit)
            store.maxSnapshotsPerTopology = historyLimit
            store.pruneAllTopologies()
            reloadSnapshotsFromDisk()
        }
    }

    @Published public var openAtLogin: Bool = false {
        didSet {
            guard !isInitializing else { return }
            defaults.set(openAtLogin, forKey: DefaultsKeys.openAtLogin)
            do {
                if openAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                store.appendLog("Open at login update failed: \(error.localizedDescription)")
                lastStatusMessage = "Login item error: \(error.localizedDescription)"
            }
        }
    }

    @Published public var isAccessibilityGranted: Bool = false
    @Published public var lastStatusMessage: String = "Ready"
    @Published public var isTransitioningDisplays: Bool = false
    @Published public var selectedSpaceByDisplay: [String: Int] = [:]
    @Published public var editingDisplayNames: [String: String] = [:]
    @Published public var selectedDashboardTab: DashboardTab = .map {
        didSet {
            if selectedDashboardTab == .log {
                refreshActivityLog()
            }
        }
    }
    @Published public var activityLogText: String = ""
    @Published public var logSearchFilter: String = ""

    public let store: SnapshotStore
    private let defaults: UserDefaults
    private var isInitializing: Bool = true

    private var countdownTimer: Timer?
    private var timerTickCount: Int = 0
    private var displaySettleWorkItem: DispatchWorkItem?
    private var wakeFreezeWorkItem: DispatchWorkItem?
    private var wakeFreezeUntil: Date = .distantPast
    private var spaceChangeWorkItem: DispatchWorkItem?
    private var previousTopologyKey: String = ""

    private var activeRestore: MacSnapshot?
    private var waiting: [String: SpaceRef] = [:]
    private var placedWindowIDs: Set<CGWindowID> = []
    private var consecutiveEmptyExternalSkips: Int = 0

    public init(
        store: SnapshotStore = SnapshotStore(),
        defaults: UserDefaults = .standard
    ) {
        self.store = store
        self.defaults = defaults

        let savedAutoSnap = defaults.object(forKey: DefaultsKeys.autoSnapshot) as? Bool ?? true
        let savedAutoRestore = defaults.object(forKey: DefaultsKeys.autoRestore) as? Bool ?? true
        let rawInterval = defaults.object(forKey: DefaultsKeys.intervalSeconds) as? Int ?? 30
        let validInterval = Self.allowedIntervals.contains(rawInterval) ? rawInterval : 30
        let rawLimit = defaults.object(forKey: DefaultsKeys.historyLimit) as? Int ?? 10
        let validLimit = Self.allowedHistoryLimits.contains(rawLimit) ? rawLimit : 10
        let savedLogin = (SMAppService.mainApp.status == .enabled)
            || (defaults.object(forKey: DefaultsKeys.openAtLogin) as? Bool ?? false)

        self.isAutoSnapshotEnabled = savedAutoSnap
        self.isAutoRestoreEnabled = savedAutoRestore
        self.snapshotIntervalSeconds = validInterval
        self.secondsUntilNextSnapshot = validInterval
        self.historyLimit = validLimit
        self.openAtLogin = savedLogin
        self.store.maxSnapshotsPerTopology = validLimit

        self.customDisplayNames = store.loadCustomDisplayNames()
        self.pinsByTopology = store.loadPins()
        self.isAccessibilityGranted = WindowEngine.isAccessibilityTrusted(prompt: false)

        refreshDisplayList()
        self.previousTopologyKey = currentTopologyKey
        self.viewingTopologyKey = currentTopologyKey
        reloadSnapshotsFromDisk()
        refreshActivityLog()
        self.isInitializing = false

        if recentSnapshots.isEmpty {
            takeSnapshotNow(isManual: false, reason: "Initial startup snapshot")
        }

        startBackgroundTimersAndObservers()
    }

    private func clearActiveRestoreState() {
        activeRestore = nil
        waiting.removeAll()
        placedWindowIDs.removeAll()
    }

    private func resumeTransitionsRespectingWakeFreeze() {
        let remaining = wakeFreezeUntil.timeIntervalSinceNow
        if remaining > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
                guard let self = self, self.displaySettleWorkItem == nil else { return }
                self.secondsUntilNextSnapshot = self.snapshotIntervalSeconds
                self.isTransitioningDisplays = false
            }
        } else {
            secondsUntilNextSnapshot = snapshotIntervalSeconds
            isTransitioningDisplays = false
        }
    }

    public var selectedSnapshot: MacSnapshot? {
        if let id = selectedSnapshotID,
           let match = recentSnapshots.first(where: { $0.id == id }) {
            return match
        }
        return recentSnapshots.first
    }

    public func isPinned(_ snapshot: MacSnapshot) -> Bool {
        pinsByTopology[snapshot.topologyKey] == snapshot.id
    }

    public func pinSnapshot(_ snapshot: MacSnapshot) {
        store.pinSnapshot(id: snapshot.id, forTopology: snapshot.topologyKey)
        pinsByTopology = store.loadPins()
        store.appendLog("Pinned snapshot \(snapshot.id.prefix(6)) as default for [\(snapshot.topologyKey)]")
        reloadSnapshotsFromDisk()
        lastStatusMessage = "Pinned snapshot as default"
    }

    public func unpinSnapshot(_ snapshot: MacSnapshot) {
        store.unpin(forTopology: snapshot.topologyKey)
        pinsByTopology = store.loadPins()
        store.appendLog("Unpinned default snapshot for [\(snapshot.topologyKey)]")
        reloadSnapshotsFromDisk()
        lastStatusMessage = "Unpinned default snapshot"
    }

    public func deleteSnapshot(_ snapshot: MacSnapshot) {
        store.deleteSnapshot(id: snapshot.id, forTopology: snapshot.topologyKey)
        pinsByTopology = store.loadPins()
        reloadSnapshotsFromDisk()
        lastStatusMessage = "Deleted snapshot"
    }

    public func refreshActivityLog() {
        activityLogText = store.readRecentLogLines(limit: 200)
    }

    /// Returns a human-readable label for a topology key (e.g. "Built-in Retina Display + Home 49\" Odyssey G9")
    public func friendlyName(forTopologyKey key: String) -> String {
        let uuids = key.components(separatedBy: "__").filter { !$0.isEmpty }
        if uuids.isEmpty { return "Unknown Configuration" }
        let names = uuids.map { uuid -> String in
            if let custom = customDisplayNames[uuid], !custom.isEmpty {
                return custom
            }
            if let live = connectedDisplays.first(where: { $0.uuid == uuid }) {
                return live.customName
            }
            let snaps = store.loadSnapshots(forTopology: key)
            if let disp = snaps.first?.displays.first(where: { $0.uuid == uuid }) {
                return disp.customName
            }
            return String(uuid.prefix(8))
        }
        return names.joined(separator: " + ")
    }

    public struct SetupInfo: Identifiable, Equatable {
        public var id: String { topologyKey }
        public let topologyKey: String
        public let title: String
        public let subtitle: String
        public let icon: String
        public let isConnected: Bool
        public let snapshotCount: Int
        public let hasPin: Bool

        public init(
            topologyKey: String,
            title: String,
            subtitle: String,
            icon: String,
            isConnected: Bool,
            snapshotCount: Int,
            hasPin: Bool
        ) {
            self.topologyKey = topologyKey
            self.title = title
            self.subtitle = subtitle
            self.icon = icon
            self.isConnected = isConnected
            self.snapshotCount = snapshotCount
            self.hasPin = hasPin
        }
    }

    public func setupInfo(for key: String) -> SetupInfo {
        let isConnected = (key == currentTopologyKey)
        let snaps = store.loadSnapshots(forTopology: key)
        let hasPin = pinsByTopology[key] != nil

        let uuids = key.components(separatedBy: "__").filter { !$0.isEmpty }
        var dispSummaries: [(name: String, width: Int, height: Int, isBuiltIn: Bool)] = []

        for uuid in uuids {
            let custom = customDisplayNames[uuid]
            if let live = connectedDisplays.first(where: { $0.uuid == uuid }) {
                let dName = (custom?.isEmpty == false) ? custom! : live.customName
                dispSummaries.append((name: dName, width: Int(live.quartzFrame.width), height: Int(live.quartzFrame.height), isBuiltIn: live.isBuiltIn))
            } else if let savedDisp = snaps.first?.displays.first(where: { $0.uuid == uuid }) {
                let dName = (custom?.isEmpty == false) ? custom! : savedDisp.customName
                dispSummaries.append((name: dName, width: Int(savedDisp.frame.width), height: Int(savedDisp.frame.height), isBuiltIn: savedDisp.isBuiltIn))
            }
        }

        let title: String
        let subtitle: String
        let icon: String

        if dispSummaries.count == 1 {
            let d = dispSummaries[0]
            if d.isBuiltIn {
                let custom = customDisplayNames[uuids[0]]
                title = (custom?.isEmpty == false) ? custom! : "Internal Display Only"
                icon = "laptopcomputer"
            } else {
                let custom = customDisplayNames[uuids[0]]
                title = (custom?.isEmpty == false) ? custom! : (d.width >= 3840 ? "49\" Ultrawide (Clamshell)" : d.name)
                icon = "display"
            }
            subtitle = "\(d.width)×\(d.height) • 1 Screen"
        } else if dispSummaries.count >= 2 {
            let hasBuiltIn = dispSummaries.contains(where: { $0.isBuiltIn })
            let ultrawide = dispSummaries.first(where: { $0.width >= 3840 })

            if hasBuiltIn && ultrawide != nil {
                title = "Internal Display + 49\" Ultrawide"
                icon = "display.2"
                let extW = ultrawide?.width ?? 5120
                subtitle = "\(dispSummaries.count) Displays • \(extW)×\(ultrawide?.height ?? 1440) + Retina"
            } else if hasBuiltIn {
                let others = dispSummaries.filter { !$0.isBuiltIn }.map(\.name).joined(separator: " + ")
                title = "Internal Display + \(others.isEmpty ? "External" : others)"
                icon = "display.2"
                subtitle = "\(dispSummaries.count) Displays Connected"
            } else {
                title = dispSummaries.map(\.name).joined(separator: " + ")
                icon = "display.2"
                subtitle = "\(dispSummaries.count) External Displays"
            }
        } else {
            title = friendlyName(forTopologyKey: key)
            subtitle = "Saved Configuration"
            icon = "display"
        }

        return SetupInfo(
            topologyKey: key,
            title: title,
            subtitle: subtitle,
            icon: icon,
            isConnected: isConnected,
            snapshotCount: snaps.count,
            hasPin: hasPin
        )
    }

    public var allSetupInfos: [SetupInfo] {
        availableTopologies.map { setupInfo(for: $0) }
    }

    public func selectViewingTopology(_ key: String) {
        viewingTopologyKey = key
        recentSnapshots = store.loadSnapshots(forTopology: key)
        pinsByTopology = store.loadPins()
        selectedSnapshotID = recentSnapshots.first?.id
    }

    public func checkAccessibility(prompt: Bool) {
        isAccessibilityGranted = WindowEngine.isAccessibilityTrusted(prompt: prompt)
        if !isAccessibilityGranted && prompt {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    public func updateCustomName(_ newName: String, forDisplayUUID uuid: String) {
        store.saveCustomDisplayName(newName, forDisplayUUID: uuid)
        customDisplayNames = store.loadCustomDisplayNames()
        refreshDisplayList()
        lastStatusMessage = "Renamed display to \"\(newName)\""
    }

    public func refreshDisplayList() {
        connectedDisplays = DisplayHelper.currentConnectedDisplays(customNames: customDisplayNames)
        currentTopologyKey = DisplayHelper.currentTopologyKey(customNames: customDisplayNames)
        var allTopos = Set(store.availableTopologies())
        if !currentTopologyKey.isEmpty {
            allTopos.insert(currentTopologyKey)
        }
        availableTopologies = allTopos.sorted()
    }

    public func reloadSnapshotsFromDisk() {
        let targetKey = viewingTopologyKey.isEmpty ? currentTopologyKey : viewingTopologyKey
        recentSnapshots = store.loadSnapshots(forTopology: targetKey)
        pinsByTopology = store.loadPins()
        if selectedSnapshotID == nil || !recentSnapshots.contains(where: { $0.id == selectedSnapshotID }) {
            selectedSnapshotID = recentSnapshots.first?.id
        }
        var allTopos = Set(store.availableTopologies())
        if !currentTopologyKey.isEmpty {
            allTopos.insert(currentTopologyKey)
        }
        availableTopologies = allTopos.sorted()
    }

    // MARK: - Snapshot & Restore Actions

    public func takeSnapshotNow(isManual: Bool = false, reason: String = "Auto-snapshot") {
        guard !isTransitioningDisplays else { return }
        refreshDisplayList()

        if isManual {
            clearActiveRestoreState()
        }

        var snapshot = WindowEngine.captureCurrentMacSnapshot(
            customDisplayNames: customDisplayNames,
            logger: { [weak self] msg in self?.store.appendLog(msg) }
        )
        snapshot.isManual = isManual
        guard !snapshot.displays.isEmpty else { return }

        if !isManual,
           let active = activeRestore,
           active.topologyKey == snapshot.topologyKey,
           !waiting.isEmpty {
            let intended = active.displays
                .flatMap { $0.spaces.flatMap(\.windows) }
                .filter { waiting[$0.id] != nil }
            snapshot = snapshot.keeping(intended: intended)
        }

        if !isManual {
            let existing = store.loadSnapshots(forTopology: snapshot.topologyKey)
            if let latestGood = existing.first {
                var triggeredEmptyExternalGuard: (name: String, prevCount: Int)? = nil
                for disp in snapshot.displays where !disp.isBuiltIn {
                    let newWinCountOnExt = disp.spaces.reduce(0) { $0 + $1.windows.count }
                    let prevWinCountOnExt = latestGood.displays
                        .first(where: { $0.uuid == disp.uuid })?
                        .spaces.reduce(0, { $0 + $1.windows.count }) ?? 0

                    if newWinCountOnExt == 0 && prevWinCountOnExt > 0 {
                        triggeredEmptyExternalGuard = (disp.customName, prevWinCountOnExt)
                        break
                    }
                }

                if let guardHit = triggeredEmptyExternalGuard {
                    if consecutiveEmptyExternalSkips < 3 {
                        consecutiveEmptyExternalSkips += 1
                        store.appendLog("Skipped auto-snapshot (\(consecutiveEmptyExternalSkips)/3) for [\(snapshot.topologyKey)]: external display '\(guardHit.name)' has 0 windows while previous snapshot had \(guardHit.prevCount) windows.")
                        secondsUntilNextSnapshot = snapshotIntervalSeconds
                        return
                    } else {
                        store.appendLog("Accepting empty external display snapshot for [\(snapshot.topologyKey)] after 3 consecutive skips.")
                        consecutiveEmptyExternalSkips = 0
                    }
                } else {
                    consecutiveEmptyExternalSkips = 0
                }
            }
        } else {
            consecutiveEmptyExternalSkips = 0
        }

        do {
            let savedURL = try store.saveSnapshot(snapshot)
            consecutiveEmptyExternalSkips = 0
            secondsUntilNextSnapshot = snapshotIntervalSeconds

            if savedURL != nil {
                viewingTopologyKey = currentTopologyKey
                reloadSnapshotsFromDisk()
                selectedSnapshotID = snapshot.id
                let fmt = DateFormatter()
                fmt.timeStyle = .short
                lastStatusMessage = "\(reason) saved at \(fmt.string(from: snapshot.capturedAt)) (\(snapshot.totalWindowCount) windows)"
            } else {
                store.appendLog("Skipped duplicate auto-snapshot for [\(snapshot.topologyKey)] (layout unchanged).")
                lastStatusMessage = "Auto-snapshot skipped (unchanged)"
            }
            if selectedDashboardTab == .log {
                refreshActivityLog()
            }
        } catch {
            lastStatusMessage = "Failed to write snapshot: \(error.localizedDescription)"
        }
    }

    public func restoreSnapshot(_ snapshot: MacSnapshot? = nil) {
        guard let target = snapshot ?? store.preferredRestoreSnapshot(forTopology: currentTopologyKey) else {
            let msg = "No saved snapshot found for configuration: \(friendlyName(forTopologyKey: currentTopologyKey))"
            lastStatusMessage = msg
            store.appendLog(msg)
            return
        }

        isAccessibilityGranted = WindowEngine.isAccessibilityTrusted(prompt: false)
        if !isAccessibilityGranted {
            isAccessibilityGranted = WindowEngine.isAccessibilityTrusted(prompt: true)
        }
        guard isAccessibilityGranted else {
            let msg = "Restore blocked: Please enable Tiles in the Accessibility window that just opened, then click Restore again."
            lastStatusMessage = msg
            store.appendLog(msg)
            return
        }

        let report = WindowEngine.restore(
            snapshot: target,
            logger: { [weak self] msg in self?.store.appendLog(msg) }
        )
        activeRestore = target
        waiting = report.waiting
        placedWindowIDs = report.placedWindowIDs

        if selectedDashboardTab == .log {
            refreshActivityLog()
        }

        let fmt = DateFormatter()
        fmt.timeStyle = .short
        let waitSuffix = report.waiting.isEmpty ? "" : " (\(report.waiting.count) waiting)"
        lastStatusMessage = "Restored \(report.restoredCount) windows\(waitSuffix) for [\(friendlyName(forTopologyKey: target.topologyKey))] from \(fmt.string(from: target.capturedAt))"
    }

    public func restoreSnapshotMatchingPrefix(_ prefix: String) {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            restoreSnapshot(nil)
            return
        }

        let lower = trimmed.lowercased()
        let currentSnaps = store.loadSnapshots(forTopology: currentTopologyKey)
        if let match = currentSnaps.first(where: { $0.id.lowercased().hasPrefix(lower) }) {
            store.appendLog("Restoring snapshot matching prefix '\(trimmed)' -> \(match.id)")
            restoreSnapshot(match)
            return
        }

        for topo in store.availableTopologies() where topo != currentTopologyKey {
            let snaps = store.loadSnapshots(forTopology: topo)
            if let match = snaps.first(where: { $0.id.lowercased().hasPrefix(lower) }) {
                store.appendLog("Restoring snapshot matching prefix '\(trimmed)' -> \(match.id)")
                restoreSnapshot(match)
                return
            }
        }

        let msg = "No snapshot found matching ID prefix '\(trimmed)'."
        store.appendLog(msg)
        lastStatusMessage = msg
    }

    // MARK: - Background Daemon & System Notifications

    private func startBackgroundTimersAndObservers() {
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.timerTickCount += 1

                if self.timerTickCount % 2 == 0 {
                    self.isAccessibilityGranted = WindowEngine.isAccessibilityTrusted(prompt: false)
                    if self.selectedDashboardTab == .log {
                        self.refreshActivityLog()
                    }
                }

                guard self.isAutoSnapshotEnabled, !self.isTransitioningDisplays else { return }

                self.secondsUntilNextSnapshot -= 1
                if self.secondsUntilNextSnapshot <= 0 {
                    self.takeSnapshotNow(isManual: false, reason: "Auto-snapshot")
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleScreenParametersChanged()
            }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleDidWake()
            }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.sagar.Tiles.TriggerRestore"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let prefix = notification.userInfo?["snapshot"] as? String
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if let prefix = prefix, !prefix.isEmpty {
                    self.store.appendLog("Received external TriggerRestore notification (snapshot=\(prefix)).")
                    self.restoreSnapshotMatchingPrefix(prefix)
                } else {
                    self.store.appendLog("Received external TriggerRestore notification.")
                    self.restoreSnapshot(nil)
                }
            }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.sagar.Tiles.TriggerSave"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.store.appendLog("Received external TriggerSave notification.")
                self.takeSnapshotNow(isManual: true, reason: "Manual snapshot")
            }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.sagar.Tiles.Diagnose"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.store.appendLog("Received external Diagnose notification.")
                WindowEngine.diagnoseReachableWindows { [weak self] msg in
                    self?.store.appendLog(msg)
                }
                if self.selectedDashboardTab == .log {
                    self.refreshActivityLog()
                }
                self.lastStatusMessage = "Diagnostics logged to tiles.log"
            }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleActiveSpaceChanged()
            }
        }
    }

    private func handleDidWake() {
        isTransitioningDisplays = true
        secondsUntilNextSnapshot = snapshotIntervalSeconds
        wakeFreezeUntil = Date().addingTimeInterval(8.0)
        lastStatusMessage = "System woke from sleep — settling displays..."
        store.appendLog("System woke from sleep — freezing snapshots for 8s.")

        wakeFreezeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.wakeFreezeWorkItem = nil
                guard self.displaySettleWorkItem == nil else { return }
                self.secondsUntilNextSnapshot = self.snapshotIntervalSeconds
                self.isTransitioningDisplays = false
                self.lastStatusMessage = "Ready"
            }
        }
        wakeFreezeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0, execute: work)
    }

    private func handleScreenParametersChanged() {
        isTransitioningDisplays = true
        secondsUntilNextSnapshot = snapshotIntervalSeconds
        lastStatusMessage = "Display configuration change detected — settling..."

        displaySettleWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.displaySettleWorkItem = nil

                let oldTopology = self.previousTopologyKey
                self.refreshDisplayList()
                let newTopology = self.currentTopologyKey

                guard oldTopology != newTopology else {
                    self.store.appendLog("Screen parameters updated within same topology [\(newTopology)] — skipping auto-restore.")
                    self.lastStatusMessage = "Display parameters updated"
                    self.resumeTransitionsRespectingWakeFreeze()
                    return
                }

                self.previousTopologyKey = newTopology
                self.viewingTopologyKey = newTopology
                self.clearActiveRestoreState()
                self.consecutiveEmptyExternalSkips = 0
                self.reloadSnapshotsFromDisk()

                self.store.appendLog("Display configuration changed: [\(oldTopology)] -> [\(newTopology)]")

                guard self.isAutoRestoreEnabled else {
                    self.store.appendLog("Auto-restore is disabled in settings — skipping restore for [\(newTopology)].")
                    self.lastStatusMessage = "Switched to \(self.friendlyName(forTopologyKey: newTopology))"
                    self.resumeTransitionsRespectingWakeFreeze()
                    return
                }

                if let preferredForNewConfig = self.store.preferredRestoreSnapshot(forTopology: newTopology) {
                    let isPin = self.isPinned(preferredForNewConfig)
                    self.store.appendLog("Auto-restoring \(isPin ? "pinned" : "latest") snapshot (\(preferredForNewConfig.id)) for configuration [\(newTopology)]")
                    self.restoreSnapshot(preferredForNewConfig)

                    DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                        self?.resumeTransitionsRespectingWakeFreeze()
                    }
                } else {
                    self.resumeTransitionsRespectingWakeFreeze()
                    if !self.isTransitioningDisplays {
                        self.takeSnapshotNow(isManual: false, reason: "Initial snapshot for new configuration")
                    }
                }
            }
        }
        displaySettleWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    private func handleActiveSpaceChanged() {
        guard !isTransitioningDisplays else { return }
        spaceChangeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self, !self.isTransitioningDisplays else { return }
                self.objectWillChange.send()
                guard !self.waiting.isEmpty,
                      let snap = self.activeRestore,
                      self.isAccessibilityGranted else { return }

                let spaceMap = SpaceBridge.queryAllDisplaySpaces()
                var showingSpaces: Set<SpaceRef> = []
                for (dispUUID, entries) in spaceMap.spacesByDisplayUUID {
                    for entry in entries where entry.isCurrent {
                        showingSpaces.insert(SpaceRef(displayUUID: dispUUID, spaceIndex: entry.index))
                    }
                }

                let dueEntries = self.waiting.filter { showingSpaces.contains($0.value) }
                guard !dueEntries.isEmpty else { return }

                let dueIDs = Set(dueEntries.keys)
                for id in dueIDs {
                    self.waiting.removeValue(forKey: id)
                }

                let report = WindowEngine.restore(
                    snapshot: snap,
                    onlySavedWindowIDs: dueIDs,
                    excludingLiveWindowIDs: self.placedWindowIDs,
                    logger: { [weak self] msg in self?.store.appendLog("[SpaceSwitch] " + msg) }
                )
                self.placedWindowIDs.formUnion(report.placedWindowIDs)

                for (id, newRef) in report.waiting {
                    if let oldRef = dueEntries[id], newRef != oldRef {
                        self.waiting[id] = newRef
                    }
                }
            }
        }
        spaceChangeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    public func restoreSnapshotAtIndex(_ index: Int) {
        guard index >= 0 && index < recentSnapshots.count else { return }
        restoreSnapshot(recentSnapshots[index])
    }

    /// Short 2-3 character profile abbreviation for the narrow navigation rail (e.g. "2D", "1D", "49")
    public func topologyNickname(for key: String) -> String {
        let uuids = key.components(separatedBy: "__").filter { !$0.isEmpty }
        if uuids.count > 1 {
            let snaps = store.loadSnapshots(forTopology: key)
            if snaps.first?.displays.contains(where: { $0.frame.width >= 3840 }) == true {
                return "49"
            }
            if connectedDisplays.contains(where: { $0.quartzFrame.width >= 3840 }) {
                return "49"
            }
            return "\(uuids.count)D"
        } else if uuids.count == 1 {
            return "1D"
        }
        return "ALL"
    }

    /// Extracts up to `limit` distinct app names from a snapshot for pastel pill tags
    public func topApps(for snapshot: MacSnapshot, limit: Int = 3) -> [String] {
        var seen = Set<String>()
        var apps: [String] = []
        for d in snapshot.displays {
            for s in d.spaces {
                for w in s.windows {
                    let name = w.ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty, !seen.contains(name.lowercased()) else { continue }
                    seen.insert(name.lowercased())
                    apps.append(name)
                    if apps.count >= limit { return apps }
                }
            }
        }
        return apps
    }

    /// Computes how many windows have moved live compared to this saved snapshot
    public func driftSummary(for snapshot: MacSnapshot) -> (driftCount: Int, label: String) {
        guard let latest = recentSnapshots.first else {
            return (0, "Live match")
        }
        if snapshot.id == latest.id {
            return (0, "Live match")
        }
        let latestWindows = latest.displays.flatMap { $0.spaces.flatMap(\.windows) }
        var latestMap: [String: WindowSnapshotInfo] = [:]
        for w in latestWindows {
            latestMap["\(w.appKey)|\(w.windowTitle)"] = w
        }

        var moved = 0
        let currentWindows = snapshot.displays.flatMap { $0.spaces.flatMap(\.windows) }
        for w in currentWindows {
            if let match = latestMap["\(w.appKey)|\(w.windowTitle)"] {
                let dx = abs(w.frame.x - match.frame.x)
                let dy = abs(w.frame.y - match.frame.y)
                let dw = abs(w.frame.width - match.frame.width)
                let dh = abs(w.frame.height - match.frame.height)
                if dx > 15 || dy > 15 || dw > 15 || dh > 15 {
                    moved += 1
                }
            }
        }

        if moved == 0 {
            return (0, "Matches live layout")
        } else {
            return (moved, "\(moved) moved live")
        }
    }
}
