import Foundation

/// Manages saving and loading rolling snapshots on disk (max 10 per display topology)
/// as well as persistent custom monitor names.
public final class SnapshotStore {
    public let baseDirectory: URL
    public let maxSnapshotsPerTopology: Int

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        baseDirectory: URL? = nil,
        maxSnapshotsPerTopology: Int = 10
    ) {
        if let customDir = baseDirectory {
            self.baseDirectory = customDir
        } else {
            self.baseDirectory = URL(fileURLWithPath: "/Users/sagar/Applications/Mac Apps/Tiles/TilesData", isDirectory: true)
        }
        self.maxSnapshotsPerTopology = maxSnapshotsPerTopology

        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601

        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601

        try? FileManager.default.createDirectory(at: self.baseDirectory, withIntermediateDirectories: true)
        migrateLegacySnapshotsIfNeeded()
    }

    private func migrateLegacySnapshotsIfNeeded() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let legacyDir = appSupport.appendingPathComponent("Tiles", isDirectory: true)
        guard FileManager.default.fileExists(atPath: legacyDir.path) else { return }

        // Migrate display_names.json if not present yet
        let legacyNames = legacyDir.appendingPathComponent("display_names.json")
        if FileManager.default.fileExists(atPath: legacyNames.path) && !FileManager.default.fileExists(atPath: displayNamesFileURL.path) {
            try? FileManager.default.copyItem(at: legacyNames, to: displayNamesFileURL)
        }

        // Remove legacy snapshots that contained type-4 fullscreen Chrome windows on the MacBook
        // so fresh snapshots only contain true Desktop windows.
        try? FileManager.default.removeItem(at: legacyDir.appendingPathComponent("snapshots"))
    }

    // MARK: - Diagnostic Logging

    public var logFileURL: URL {
        baseDirectory.appendingPathComponent("tiles.log")
    }

    public func appendLog(_ message: String) {
        let fmt = ISO8601DateFormatter()
        let line = "[\(fmt.string(from: Date()))] \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFileURL.path),
               let handle = try? FileHandle(forWritingTo: logFileURL) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: logFileURL, options: .atomic)
            }
        }
    }

    // MARK: - Custom Monitor Names

    private var displayNamesFileURL: URL {
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

    // MARK: - Rolling 10 Snapshots per Topology

    public var snapshotsRootDirectory: URL {
        baseDirectory.appendingPathComponent("snapshots", isDirectory: true)
    }

    public func directory(forTopology topologyKey: String) -> URL {
        let safeName = topologyKey.replacingOccurrences(of: "/", with: "_")
        return snapshotsRootDirectory.appendingPathComponent(safeName, isDirectory: true)
    }

    /// Saves a new `MacSnapshot` to disk and prunes older snapshots so at most `maxSnapshotsPerTopology` (10) remain.
    @discardableResult
    public func saveSnapshot(_ snapshot: MacSnapshot) throws -> URL {
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

        pruneOldSnapshots(in: dir)
        return fileURL
    }

    /// Loads the up-to-10 most recent snapshots for a given topology key, sorted newest first.
    public func loadSnapshots(forTopology topologyKey: String) -> [MacSnapshot] {
        let dir = directory(forTopology: topologyKey)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let jsonFiles = files.filter { $0.pathExtension.lowercased() == "json" }
        var loaded: [MacSnapshot] = []
        for url in jsonFiles {
            if let data = try? Data(contentsOf: url),
               let snap = try? decoder.decode(MacSnapshot.self, from: data) {
                loaded.append(snap)
            }
        }

        // Sort newest first (`#1` is index 0)
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

    private func pruneOldSnapshots(in directory: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        let jsonFiles = files.filter { $0.pathExtension.lowercased() == "json" }
        guard jsonFiles.count > maxSnapshotsPerTopology else { return }

        // Decode timestamps or sort by filename descending
        var datedFiles: [(url: URL, date: Date)] = []
        for url in jsonFiles {
            if let data = try? Data(contentsOf: url),
               let snap = try? decoder.decode(MacSnapshot.self, from: data) {
                datedFiles.append((url, snap.capturedAt))
            } else {
                datedFiles.append((url, .distantPast))
            }
        }

        datedFiles.sort { $0.date > $1.date }
        let toDelete = datedFiles.dropFirst(maxSnapshotsPerTopology)
        for item in toDelete {
            try? FileManager.default.removeItem(at: item.url)
        }
    }
}
