import Foundation

/// Manages saving and loading rolling snapshots on disk (configurable history limit per display topology),
/// pinned default layouts (`pins.json`), custom monitor names, and rotated diagnostic logs.
public final class SnapshotStore {
    public static let allowedHistoryLimits: [Int] = [5, 10, 20, 50]
    private static let maxLogBytes: Int = 1_048_576 // 1 MB

    public let baseDirectory: URL
    public var maxSnapshotsPerTopology: Int

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        baseDirectory: URL? = nil,
        maxSnapshotsPerTopology: Int = 10,
        legacyDataDirectory: URL? = nil
    ) {
        let shouldAttemptLegacyCopy: Bool
        if let customDir = baseDirectory {
            self.baseDirectory = customDir
            shouldAttemptLegacyCopy = (legacyDataDirectory != nil)
        } else if let envPath = ProcessInfo.processInfo.environment["TILES_DATA_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !envPath.isEmpty {
            let expanded = (envPath as NSString).expandingTildeInPath
            self.baseDirectory = URL(fileURLWithPath: expanded, isDirectory: true)
            shouldAttemptLegacyCopy = (legacyDataDirectory != nil)
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.baseDirectory = appSupport.appendingPathComponent("Tiles", isDirectory: true)
            shouldAttemptLegacyCopy = true
        }
        self.maxSnapshotsPerTopology = max(1, maxSnapshotsPerTopology)

        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601

        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601

        try? FileManager.default.createDirectory(at: self.baseDirectory, withIntermediateDirectories: true)

        if shouldAttemptLegacyCopy {
            copyLegacyDataIfNeeded(explicitCandidate: legacyDataDirectory)
        }
        seedAppPlacementsIfNeeded()
    }

    /// One-time non-destructive copy from the legacy `TilesData` folder into the new data folder
    /// when the new folder has no snapshots yet. Never deletes or moves legacy files.
    private func copyLegacyDataIfNeeded(explicitCandidate: URL?) {
        let hasExistingSnapshots = availableTopologies().contains { !loadSnapshots(forTopology: $0).isEmpty }
        guard !hasExistingSnapshots else { return }

        var candidates: [URL] = []
        if let explicit = explicitCandidate {
            candidates.append(explicit)
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            candidates.append(home.appendingPathComponent("Applications/Mac Apps/Tiles/TilesData", isDirectory: true))
            candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true).appendingPathComponent("TilesData", isDirectory: true))
            let bundleParent = Bundle.main.bundleURL.deletingLastPathComponent()
            candidates.append(bundleParent.appendingPathComponent("TilesData", isDirectory: true))
            candidates.append(bundleParent.deletingLastPathComponent().appendingPathComponent("TilesData", isDirectory: true))
        }

        let fm = FileManager.default
        let targetStd = baseDirectory.standardizedFileURL

        for legacyDir in candidates {
            let legacyStd = legacyDir.standardizedFileURL
            guard legacyStd != targetStd, fm.fileExists(atPath: legacyDir.path) else { continue }

            let legacySnapshots = legacyDir.appendingPathComponent("snapshots", isDirectory: true)
            let legacyDisplayNames = legacyDir.appendingPathComponent("display_names.json")
            var copiedAnything = false

            if fm.fileExists(atPath: legacySnapshots.path),
               let subdirs = try? fm.contentsOfDirectory(at: legacySnapshots, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]),
               !subdirs.isEmpty {
                try? fm.createDirectory(at: snapshotsRootDirectory, withIntermediateDirectories: true)
                for item in subdirs {
                    let dest = snapshotsRootDirectory.appendingPathComponent(item.lastPathComponent)
                    if !fm.fileExists(atPath: dest.path) {
                        if (try? fm.copyItem(at: item, to: dest)) != nil {
                            copiedAnything = true
                        }
                    }
                }
            }

            if fm.fileExists(atPath: legacyDisplayNames.path),
               !fm.fileExists(atPath: displayNamesFileURL.path) {
                if (try? fm.copyItem(at: legacyDisplayNames, to: displayNamesFileURL)) != nil {
                    copiedAnything = true
                }
            }

            if copiedAnything {
                appendLog("Copied legacy data from '\(legacyDir.path)' into '\(baseDirectory.path)'.")
                break
            }
        }
    }

    // MARK: - Diagnostic Logging & Rotation

    public var logFileURL: URL {
        baseDirectory.appendingPathComponent("tiles.log")
    }

    public func appendLog(_ message: String) {
        let fmt = ISO8601DateFormatter()
        let line = "[\(fmt.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: logFileURL.path),
           let handle = try? FileHandle(forWritingTo: logFileURL) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: logFileURL, options: .atomic)
        }

        rotateLogIfNeeded()
    }

    private func rotateLogIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
              let fileSize = attrs[.size] as? Int,
              fileSize > Self.maxLogBytes,
              let fullData = try? Data(contentsOf: logFileURL) else {
            return
        }

        let halfStart = fullData.count / 2
        var cutIndex = halfStart
        if let newlineIdx = fullData[halfStart...].firstIndex(of: 0x0A),
           newlineIdx + 1 < fullData.endIndex {
            cutIndex = newlineIdx + 1
        }
        let newestHalf = Data(fullData[cutIndex...])
        try? newestHalf.write(to: logFileURL, options: .atomic)
    }

    public func readRecentLogLines(limit: Int = 200) -> String {
        guard let content = try? String(contentsOf: logFileURL, encoding: .utf8),
              !content.isEmpty else {
            return ""
        }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
            .dropLast(content.hasSuffix("\n") ? 1 : 0)
        return lines.suffix(limit).joined(separator: "\n")
    }

    // MARK: - Custom Monitor Names

    public var displayNamesFileURL: URL {
        baseDirectory.appendingPathComponent("display_names.json")
    }

    public func loadCustomDisplayNames() -> [String: String] {
        guard let data = try? Data(contentsOf: displayNamesFileURL),
              let dict = try? decoder.decode([String: String].self, from: data) else {
            return [:]
        }
        return dict
    }

    public func saveCustomDisplayName(_ name: String, forDisplayUUID uuid: String) {
        var current = loadCustomDisplayNames()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            current.removeValue(forKey: uuid)
        } else {
            current[uuid] = trimmed
        }
        if let data = try? encoder.encode(current) {
            try? data.write(to: displayNamesFileURL, options: .atomic)
        }
    }

    // MARK: - Pinned Layouts per Topology (pins.json)

    public var pinsFileURL: URL {
        baseDirectory.appendingPathComponent("pins.json")
    }

    public func loadPins() -> [String: String] {
        guard let data = try? Data(contentsOf: pinsFileURL),
              let dict = try? decoder.decode([String: String].self, from: data) else {
            return [:]
        }
        return dict
    }

    public func pinnedSnapshotID(forTopology topologyKey: String) -> String? {
        loadPins()[topologyKey]
    }

    public func pinSnapshot(id snapshotID: String, forTopology topologyKey: String) {
        var pins = loadPins()
        pins[topologyKey] = snapshotID
        if let data = try? encoder.encode(pins) {
            try? data.write(to: pinsFileURL, options: .atomic)
        }
    }

    public func unpin(forTopology topologyKey: String) {
        var pins = loadPins()
        pins.removeValue(forKey: topologyKey)
        if let data = try? encoder.encode(pins) {
            try? data.write(to: pinsFileURL, options: .atomic)
        }
        pruneOldSnapshots(forTopology: topologyKey)
    }

    /// Returns the pinned snapshot if one exists on disk for `topologyKey`, otherwise the newest snapshot.
    public func preferredRestoreSnapshot(forTopology topologyKey: String) -> MacSnapshot? {
        let all = loadSnapshots(forTopology: topologyKey)
        if let pinID = pinnedSnapshotID(forTopology: topologyKey),
           let pinned = all.first(where: { $0.id == pinID }) {
            return pinned
        }
        return all.first
    }

    // MARK: - Last Known App Placements per Topology (app_placements.json)

    /// topologyKey -> appKey -> that app's windows the last time a saved snapshot of that setup
    /// included it. Outlives the rolling history, so an app that was not running when a setup's
    /// newest snapshot was taken can still be put back where it last was on that setup.
    public typealias AppPlacements = [String: [String: [WindowSnapshotInfo]]]

    public var appPlacementsFileURL: URL {
        baseDirectory.appendingPathComponent("app_placements.json")
    }

    public func loadAppPlacements() -> AppPlacements {
        guard let data = try? Data(contentsOf: appPlacementsFileURL),
              let dict = try? decoder.decode(AppPlacements.self, from: data) else {
            return [:]
        }
        return dict
    }

    /// Records every app in `snapshot` as its latest placement for the snapshot's setup.
    /// Apps absent from `snapshot` keep their previous placement.
    public func recordAppPlacements(from snapshot: MacSnapshot) {
        var all = loadAppPlacements()
        Self.merge(snapshot, into: &all)
        if let data = try? encoder.encode(all) {
            try? data.write(to: appPlacementsFileURL, options: .atomic)
        }
    }

    /// Last known windows on `topologyKey` for each of `apps` that has a recorded placement.
    public func lastKnownWindows(forTopology topologyKey: String, apps: Set<String>) -> [WindowSnapshotInfo] {
        let forTopology = loadAppPlacements()[topologyKey] ?? [:]
        return apps.sorted().flatMap { forTopology[$0] ?? [] }
    }

    private static func merge(_ snapshot: MacSnapshot, into all: inout AppPlacements) {
        let windows = snapshot.displays.flatMap { $0.spaces.flatMap(\.windows) }
        guard !windows.isEmpty else { return }
        var forTopology = all[snapshot.topologyKey] ?? [:]
        for (appKey, appWindows) in Dictionary(grouping: windows, by: \.appKey) {
            forTopology[appKey] = appWindows
        }
        all[snapshot.topologyKey] = forTopology
    }

    /// First run with this feature: build placements from the existing history, oldest first,
    /// so the newest snapshot that included each app wins.
    private func seedAppPlacementsIfNeeded() {
        guard !FileManager.default.fileExists(atPath: appPlacementsFileURL.path) else { return }
        var all: AppPlacements = [:]
        for topo in availableTopologies() {
            for snap in loadSnapshots(forTopology: topo).reversed() {
                Self.merge(snap, into: &all)
            }
        }
        guard !all.isEmpty, let data = try? encoder.encode(all) else { return }
        try? data.write(to: appPlacementsFileURL, options: .atomic)
    }

    // MARK: - Rolling History Snapshots per Topology

    public var snapshotsRootDirectory: URL {
        baseDirectory.appendingPathComponent("snapshots", isDirectory: true)
    }

    public func directory(forTopology topologyKey: String) -> URL {
        let safeName = topologyKey.replacingOccurrences(of: "/", with: "_")
        return snapshotsRootDirectory.appendingPathComponent(safeName, isDirectory: true)
    }

    /// Saves a `MacSnapshot` to disk unless it is an automatic snapshot equivalent to the newest stored snapshot.
    /// Returns the written file URL, or `nil` when skipped as a duplicate.
    @discardableResult
    public func saveSnapshot(_ snapshot: MacSnapshot) throws -> URL? {
        if !snapshot.isManual,
           let newest = loadSnapshots(forTopology: snapshot.topologyKey).first,
           snapshot.isEquivalent(to: newest) {
            return nil
        }

        let dir = directory(forTopology: snapshot.topologyKey)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withFullDate, .withTime]
        let timestampStr = formatter.string(from: snapshot.capturedAt)
            .replacingOccurrences(of: ":", with: "-")
        let filename = "snapshot_\(timestampStr)_\(snapshot.id.prefix(6)).json"
        let fileURL = dir.appendingPathComponent(filename)

        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)

        recordAppPlacements(from: snapshot)
        pruneOldSnapshots(forTopology: snapshot.topologyKey)
        return fileURL
    }

    /// Deletes a specific snapshot by ID for a topology, unpinning if it was pinned.
    public func deleteSnapshot(id snapshotID: String, forTopology topologyKey: String) {
        let dir = directory(forTopology: topologyKey)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for url in files where url.pathExtension.lowercased() == "json" {
            if let data = try? Data(contentsOf: url),
               let snap = try? decoder.decode(MacSnapshot.self, from: data),
               snap.id == snapshotID {
                try? FileManager.default.removeItem(at: url)
            }
        }
        if pinnedSnapshotID(forTopology: topologyKey) == snapshotID {
            unpin(forTopology: topologyKey)
        }
    }

    /// Loads saved snapshots for a given topology key, sorted newest first.
    public func loadSnapshots(forTopology topologyKey: String) -> [MacSnapshot] {
        let dir = directory(forTopology: topologyKey)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let jsonFiles = files.filter { $0.pathExtension.lowercased() == "json" }
        var loaded: [MacSnapshot] = []
        for url in jsonFiles {
            if let data = try? Data(contentsOf: url),
               let snap = try? decoder.decode(MacSnapshot.self, from: data) {
                loaded.append(snap)
            }
        }

        return loaded.sorted { $0.capturedAt > $1.capturedAt }
    }

    /// Lists all saved topology keys that have snapshots on disk.
    public func availableTopologies() -> [String] {
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: snapshotsRootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return dirs.map { $0.lastPathComponent }.sorted()
    }

    public func pruneAllTopologies() {
        for topo in availableTopologies() {
            pruneOldSnapshots(forTopology: topo)
        }
    }

    /// Keeps the newest `maxSnapshotsPerTopology` unpinned auto snapshots, the newest
    /// `maxSnapshotsPerTopology` unpinned manual snapshots, plus the pinned snapshot (if any).
    /// Manual and auto snapshots are capped separately so frequent auto-saves never evict a manual save.
    public func pruneOldSnapshots(forTopology topologyKey: String) {
        let directory = directory(forTopology: topologyKey)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        let pinnedID = pinnedSnapshotID(forTopology: topologyKey)
        let jsonFiles = files.filter { $0.pathExtension.lowercased() == "json" }

        var autoFiles: [(url: URL, date: Date)] = []
        var manualFiles: [(url: URL, date: Date)] = []
        for url in jsonFiles {
            if let data = try? Data(contentsOf: url),
               let snap = try? decoder.decode(MacSnapshot.self, from: data) {
                if let pinnedID = pinnedID, snap.id == pinnedID {
                    continue
                }
                if snap.isManual {
                    manualFiles.append((url, snap.capturedAt))
                } else {
                    autoFiles.append((url, snap.capturedAt))
                }
            } else {
                autoFiles.append((url, .distantPast))
            }
        }

        for var group in [autoFiles, manualFiles] where group.count > maxSnapshotsPerTopology {
            group.sort { $0.date > $1.date }
            for item in group.dropFirst(maxSnapshotsPerTopology) {
                try? FileManager.default.removeItem(at: item.url)
            }
        }
    }
}
