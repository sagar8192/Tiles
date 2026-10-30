import XCTest
@testable import Tiles

final class TilesTests: XCTestCase {

    func testRolling10SnapshotsPruning() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TilesTests_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = SnapshotStore(baseDirectory: tempDir, maxSnapshotsPerTopology: 10)
        let topology = "INT-MACBOOK__EXT-49-ULTRAWIDE"

        // Save 14 snapshots spaced 60 seconds apart
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 1...14 {
            let snap = MacSnapshot(
                id: "snap-\(i)",
                capturedAt: baseDate.addingTimeInterval(Double(i * 60)),
                topologyKey: topology,
                displays: [
                    DisplaySnapshotInfo(
                        uuid: "EXT-49-ULTRAWIDE",
                        cgDisplayID: 2,
                        systemName: "Odyssey G9",
                        customName: "Home 49\" Monitor",
                        isBuiltIn: false,
                        frame: CGRectCodable(x: 0, y: 0, width: 5120, height: 1440),
                        spaces: [
                            SpaceSnapshotInfo(
                                spaceID: 101,
                                spaceIndex: 1,
                                isCurrentSpace: true,
                                windows: [
                                    WindowSnapshotInfo(
                                        windowNumber: 1000 + i,
                                        ownerPID: 555,
                                        ownerName: "Claude",
                                        bundleIdentifier: "com.anthropic.claudefordesktop",
                                        windowTitle: "Claude",
                                        windowIndexInApp: 0,
                                        frame: CGRectCodable(x: 1700, y: 40, width: 1700, height: 1380),
                                        relativeFrame: CGRectCodable(x: 0.33, y: 0.02, width: 0.33, height: 0.95),
                                        displayUUID: "EXT-49-ULTRAWIDE",
                                        spaceID: 101,
                                        spaceIndex: 1
                                    )
                                ]
                            )
                        ]
                    )
                ]
            )
            try store.saveSnapshot(snap)
        }

        let loaded = store.loadSnapshots(forTopology: topology)
        // Must strictly keep the 10 most recent snapshots (#14 down to #5)
        XCTAssertEqual(loaded.count, 10)
        XCTAssertEqual(loaded.first?.id, "snap-14")
        XCTAssertEqual(loaded.last?.id, "snap-5")
    }

    func testCustomDisplayNamePersistence() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TilesDisplayNames_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = SnapshotStore(baseDirectory: tempDir)
        store.saveCustomDisplayName("Home 49-inch Ultrawide", forDisplayUUID: "UUID-49-G9")
        store.saveCustomDisplayName("MacBook Built-in", forDisplayUUID: "UUID-MBP-16")

        let names = store.loadCustomDisplayNames()
        XCTAssertEqual(names["UUID-49-G9"], "Home 49-inch Ultrawide")
        XCTAssertEqual(names["UUID-MBP-16"], "MacBook Built-in")
    }
}
