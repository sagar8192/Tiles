import Foundation
import AppKit
import Combine

@MainActor
public final class TilesCoordinator: ObservableObject {
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
    @Published public var selectedSnapshotID: String?
    @Published public var secondsUntilNextSnapshot: Int = 60
    @Published public var isAutoSnapshotEnabled: Bool = true
    @Published public var isAccessibilityGranted: Bool = false
    @Published public var lastStatusMessage: String = "Ready"
    @Published public var isTransitioningDisplays: Bool = false
    @Published public var selectedSpaceByDisplay: [String: Int] = [:]
    @Published public var editingDisplayNames: [String: String] = [:]

    public let snapshotIntervalSeconds: Int = 60
    public let store: SnapshotStore

    private var countdownTimer: Timer?
    private var displaySettleWorkItem: DispatchWorkItem?
    private var spaceChangeWorkItem: DispatchWorkItem?
    private var previousTopologyKey: String = ""

    public init(store: SnapshotStore = SnapshotStore(maxSnapshotsPerTopology: 10)) {
        self.store = store
        self.customDisplayNames = store.loadCustomDisplayNames()
        self.isAccessibilityGranted = WindowEngine.isAccessibilityTrusted(prompt: false)

        refreshDisplayList()
        self.previousTopologyKey = currentTopologyKey
        self.viewingTopologyKey = currentTopologyKey
        reloadSnapshotsFromDisk()

        // Take an initial snapshot on launch ONLY if none exist yet for this display configuration
        if recentSnapshots.isEmpty {
            takeSnapshotNow(reason: "Initial startup snapshot")
        }

        startBackgroundTimersAndObservers()
    }

    public var selectedSnapshot: MacSnapshot? {
        if let id = selectedSnapshotID,
           let match = recentSnapshots.first(where: { $0.id == id }) {
            return match
        }
        return recentSnapshots.first
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
            // Check saved snapshots for that topology to find the display's system/custom name
            let snaps = store.loadSnapshots(forTopology: key)
            if let disp = snaps.first?.displays.first(where: { $0.uuid == uuid }) {
                return disp.customName
            }
            return String(uuid.prefix(8))
        }
        return names.joined(separator: " + ")
    }

    public func selectViewingTopology(_ key: String) {
        viewingTopologyKey = key
        recentSnapshots = store.loadSnapshots(forTopology: key)
        selectedSnapshotID = recentSnapshots.first?.id
    }

    public func checkAccessibility(prompt: Bool) {
        isAccessibilityGranted = WindowEngine.isAccessibilityTrusted(prompt: prompt)
        if !isAccessibilityGranted && prompt {
            // Also open System Settings -> Privacy & Security -> Accessibility directly so the user can toggle it easily
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

    public func takeSnapshotNow(reason: String = "Auto-snapshot") {
        guard !isTransitioningDisplays else { return }
        refreshDisplayList()

        let snapshot = WindowEngine.captureCurrentMacSnapshot(
            customDisplayNames: customDisplayNames,
            logger: { [weak self] msg in self?.store.appendLog(msg) }
        )
        guard !snapshot.displays.isEmpty else { return }

        // Sanity Guard: If this is an automatic timer snapshot for a multi-display configuration
        // that includes an external monitor, and the external monitor currently has 0 windows
        // WHILE our newest saved snapshot for this exact configuration had windows on that external monitor,
        // do NOT overwrite the good history with an un-restored / empty external display state!
        let isManual = reason.localizedCaseInsensitiveContains("Manual") || reason.localizedCaseInsensitiveContains("Initial")
        if !isManual {
            let existing = store.loadSnapshots(forTopology: snapshot.topologyKey)
            if let latestGood = existing.first {
                for disp in snapshot.displays where !disp.isBuiltIn {
                    let newWinCountOnExt = disp.spaces.reduce(0) { $0 + $1.windows.count }
                    let prevWinCountOnExt = latestGood.displays
                        .first(where: { $0.uuid == disp.uuid })?
                        .spaces.reduce(0, { $0 + $1.windows.count }) ?? 0

                    if newWinCountOnExt == 0 && prevWinCountOnExt > 0 {
                        store.appendLog("Skipped auto-snapshot for [\(snapshot.topologyKey)]: external display '\(disp.customName)' has 0 windows while previous snapshot had \(prevWinCountOnExt) windows.")
                        secondsUntilNextSnapshot = snapshotIntervalSeconds
                        return
                    }
                }
            }
        }

        do {
            try store.saveSnapshot(snapshot)
            viewingTopologyKey = currentTopologyKey
            reloadSnapshotsFromDisk()
            selectedSnapshotID = snapshot.id
            secondsUntilNextSnapshot = snapshotIntervalSeconds

            let fmt = DateFormatter()
            fmt.timeStyle = .short
            lastStatusMessage = "\(reason) saved at \(fmt.string(from: snapshot.capturedAt)) (\(snapshot.totalWindowCount) windows)"
        } catch {
            lastStatusMessage = "Failed to write snapshot: \(error.localizedDescription)"
        }
    }

    public func restoreSnapshot(_ snapshot: MacSnapshot? = nil, onlyCurrentSpaces: Bool = false) {
        let activeTopologySnapshots = store.loadSnapshots(forTopology: currentTopologyKey)
        guard let target = snapshot ?? activeTopologySnapshots.first else {
            let msg = "No saved snapshot found for configuration: \(friendlyName(forTopologyKey: currentTopologyKey))"
            lastStatusMessage = msg
            store.appendLog(msg)
            return
        }

        // Check silently first; if TCC was just reset or not yet bound to our certificate,
        // prompt once when the user explicitly clicks Restore!
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
            onlyCurrentSpaces: onlyCurrentSpaces,
            logger: { [weak self] msg in self?.store.appendLog(msg) }
        )
        pendingSpaceRestoreSnapshot = target
        let fmt = DateFormatter()
        fmt.timeStyle = .short
        lastStatusMessage = "Restored \(report.restoredCount) windows for [\(friendlyName(forTopologyKey: target.topologyKey))] from \(fmt.string(from: target.capturedAt))"
    }

    // MARK: - Background Daemon & System Notifications

    private func startBackgroundTimersAndObservers() {
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.isAccessibilityGranted = WindowEngine.isAccessibilityTrusted(prompt: false)
                guard self.isAutoSnapshotEnabled, !self.isTransitioningDisplays else { return }

                self.secondsUntilNextSnapshot -= 1
                if self.secondsUntilNextSnapshot % 5 == 0 {
                    self.reloadSnapshotsFromDisk()
                }
                if self.secondsUntilNextSnapshot <= 0 {
                    self.takeSnapshotNow(reason: "Auto 60s snapshot")
                }
            }
        }

        // Observe ANY Display Configuration Change (External Monitor Plug/Unplug, Lid Close/Open Clamshell, etc.)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleScreenParametersChanged()
            }
        }

        // Allow CLI / Makefile to trigger an immediate restore via DistributedNotificationCenter
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.sagar.Tiles.TriggerRestore"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.store.appendLog("Received external TriggerRestore notification.")
                self?.restoreSnapshot(nil, onlyCurrentSpaces: false)
            }
        }

        // Observe Desktop (Space) Switches (`Control + Left/Right Arrow` or Mission Control swipe)
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

    private var pendingSpaceRestoreSnapshot: MacSnapshot?

    private func handleScreenParametersChanged() {
        // Freeze automatic snapshots immediately so a mid-transition state never overwrites our 10 good snapshots!
        isTransitioningDisplays = true
        secondsUntilNextSnapshot = snapshotIntervalSeconds
        lastStatusMessage = "Display configuration change detected — settling..."

        displaySettleWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let oldTopology = self.previousTopologyKey
                self.refreshDisplayList()
                let newTopology = self.currentTopologyKey
                self.previousTopologyKey = newTopology
                self.viewingTopologyKey = newTopology
                self.reloadSnapshotsFromDisk()

                self.store.appendLog("Display configuration changed: [\(oldTopology)] -> [\(newTopology)]")

                // Whenever the display configuration changes (whether adding a monitor, unplugging to laptop-only,
                // or closing the lid into external-only clamshell mode), restore the newest snapshot for `newTopology`!
                if let latestForNewConfig = self.recentSnapshots.first {
                    self.store.appendLog("Auto-restoring latest snapshot (\(latestForNewConfig.id)) for configuration [\(newTopology)]")
                    self.restoreSnapshot(latestForNewConfig, onlyCurrentSpaces: false)

                    // Wait an extra 4 seconds before allowing auto-snapshots to resume, giving any un-fullscreen
                    // animations time to finish!
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                        self.secondsUntilNextSnapshot = self.snapshotIntervalSeconds
                        self.isTransitioningDisplays = false
                    }
                } else {
                    // First time ever seeing this display configuration — record initial snapshot after settle
                    self.isTransitioningDisplays = false
                    self.takeSnapshotNow(reason: "Initial snapshot for new configuration")
                }
            }
        }
        displaySettleWorkItem = work
        // Wait 2.5 seconds for macOS display negotiation & WindowServer migration to settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    private func handleActiveSpaceChanged() {
        guard !isTransitioningDisplays else { return }
        spaceChangeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.objectWillChange.send()
                if let snap = self.pendingSpaceRestoreSnapshot ?? self.recentSnapshots.first,
                   self.isAccessibilityGranted {
                    _ = WindowEngine.restore(
                        snapshot: snap,
                        onlyCurrentSpaces: true,
                        logger: { [weak self] msg in self?.store.appendLog("[SpaceSwitch] " + msg) }
                    )
                }
            }
        }
        spaceChangeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}
