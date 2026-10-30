import Testing
import Foundation
import CoreGraphics
@testable import Tiles

@Suite("Tiles Tests")
struct TilesTests {

    private func makeWindow(
        windowNumber: Int = 100,
        ownerPID: Int32 = 500,
        ownerName: String = "Google Chrome",
        bundleIdentifier: String? = "com.google.Chrome",
        windowTitle: String = "Docs",
        windowIndexInApp: Int = 0,
        frame: CGRect = CGRect(x: 0, y: 0, width: 1200, height: 800),
        relativeFrame: CGRect = CGRect(x: 0, y: 0, width: 0.5, height: 0.8),
        displayUUID: String = "EXT-49",
        spaceID: UInt64 = 10,
        spaceIndex: Int = 1,
        isFullscreen: Bool = false
    ) -> WindowSnapshotInfo {
        WindowSnapshotInfo(
            windowNumber: windowNumber,
            ownerPID: ownerPID,
            ownerName: ownerName,
            bundleIdentifier: bundleIdentifier,
            windowTitle: windowTitle,
            windowIndexInApp: windowIndexInApp,
            frame: CGRectCodable(frame),
            relativeFrame: CGRectCodable(relativeFrame),
            displayUUID: displayUUID,
            spaceID: spaceID,
            spaceIndex: spaceIndex,
            isFullscreen: isFullscreen
        )
    }

    @Test("Rolling 10 snapshots pruning")
    func rolling10SnapshotsPruning() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TilesTests_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = SnapshotStore(baseDirectory: tempDir, maxSnapshotsPerTopology: 10)
        let topology = "INT-MACBOOK__EXT-49-ULTRAWIDE"

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
                                    makeWindow(
                                        windowNumber: 1000 + i,
                                        ownerPID: 555,
                                        ownerName: "Claude",
                                        bundleIdentifier: "com.anthropic.claudefordesktop",
                                        windowTitle: "Claude \(i)",
                                        frame: CGRect(x: Double(i * 40), y: 40, width: 1700, height: 1380),
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
        #expect(loaded.count == 10)
        #expect(loaded.first?.id == "snap-14")
        #expect(loaded.last?.id == "snap-5")
    }

    @Test("Custom display name persistence")
    func customDisplayNamePersistence() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TilesDisplayNames_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = SnapshotStore(baseDirectory: tempDir)
        store.saveCustomDisplayName("Home 49-inch Ultrawide", forDisplayUUID: "UUID-49-G9")
        store.saveCustomDisplayName("MacBook Built-in", forDisplayUUID: "UUID-MBP-16")

        let names = store.loadCustomDisplayNames()
        #expect(names["UUID-49-G9"] == "Home 49-inch Ultrawide")
        #expect(names["UUID-MBP-16"] == "MacBook Built-in")
    }

    @Test("classifyUnmatched waits for live hidden desktop, detects alreadyInPlace, and handles closed windows")
    func classifyUnmatchedBehavior() {
        let currentSpaces: Set<SpaceRef> = [
            SpaceRef(displayUUID: "EXT-49", spaceIndex: 1),
            SpaceRef(displayUUID: "LAPTOP", spaceIndex: 1)
        ]
        let isCurrent: (SpaceRef) -> Bool = { currentSpaces.contains($0) }

        // Real failure case: Chrome saved on ultrawide showing desktop 1, live on hidden fullscreen laptop desktop 3
        let chromeOnUltrawide = makeWindow(
            windowNumber: 13783,
            ownerName: "Google Chrome",
            displayUUID: "EXT-49",
            spaceIndex: 1,
            isFullscreen: false
        )
        let laptopDesk3 = SpaceRef(displayUUID: "LAPTOP", spaceIndex: 3)
        #expect(
            WindowEngine.classifyUnmatched(
                chromeOnUltrawide,
                liveLocation: laptopDesk3,
                liveOnFullscreenDesktop: true,
                isCurrent: isCurrent
            ) == .waitFor(laptopDesk3)
        )

        // Fullscreen window already on its saved display -> alreadyInPlace
        let savedFullscreenOnLaptop = makeWindow(
            windowNumber: 2222,
            ownerName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            displayUUID: "LAPTOP",
            spaceIndex: 3,
            isFullscreen: true
        )
        #expect(
            WindowEngine.classifyUnmatched(
                savedFullscreenOnLaptop,
                liveLocation: laptopDesk3,
                liveOnFullscreenDesktop: true,
                isCurrent: isCurrent
            ) == .alreadyInPlace
        )

        // Closed window fallback: when liveLocation is nil, missing if saved desktop is showing, waitFor if saved desktop is hidden
        #expect(
            WindowEngine.classifyUnmatched(
                chromeOnUltrawide,
                liveLocation: nil,
                liveOnFullscreenDesktop: false,
                isCurrent: isCurrent
            ) == .missing
        )

        let savedHiddenDesk = makeWindow(
            windowNumber: 3333,
            displayUUID: "EXT-49",
            spaceIndex: 2,
            isFullscreen: false
        )
        #expect(
            WindowEngine.classifyUnmatched(
                savedHiddenDesk,
                liveLocation: nil,
                liveOnFullscreenDesktop: false,
                isCurrent: isCurrent
            ) == .waitFor(SpaceRef(displayUUID: "EXT-49", spaceIndex: 2))
        )
    }

    @Test("keeping(intended:) substitutes waiting window records without touching other windows")
    func keepingIntendedBehavior() {
        let chromePlacedOnExt = makeWindow(
            windowNumber: 101,
            ownerName: "Google Chrome",
            frame: CGRect(x: 0, y: -1440, width: 2560, height: 1440),
            displayUUID: "EXT-49",
            spaceID: 201,
            spaceIndex: 1,
            isFullscreen: false
        )
        let geminiStuckOnLaptop = makeWindow(
            windowNumber: 202,
            ownerName: "Gemini",
            bundleIdentifier: "com.google.GeminiMacOS",
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            displayUUID: "LAPTOP",
            spaceID: 303,
            spaceIndex: 3,
            isFullscreen: true
        )
        let geminiIntendedOnExt = makeWindow(
            windowNumber: 202,
            ownerName: "Gemini",
            bundleIdentifier: "com.google.GeminiMacOS",
            frame: CGRect(x: 2560, y: -1440, width: 2560, height: 1440),
            displayUUID: "EXT-49",
            spaceID: 201,
            spaceIndex: 1,
            isFullscreen: false
        )

        let halfRestored = MacSnapshot(
            id: "snap-half",
            topologyKey: "EXT-49__LAPTOP",
            displays: [
                DisplaySnapshotInfo(
                    uuid: "LAPTOP",
                    cgDisplayID: 1,
                    systemName: "Built-in",
                    customName: "Built-in",
                    isBuiltIn: true,
                    frame: CGRectCodable(x: 0, y: 0, width: 1512, height: 982),
                    spaces: [
                        SpaceSnapshotInfo(spaceID: 301, spaceIndex: 1, isCurrentSpace: true, windows: []),
                        SpaceSnapshotInfo(spaceID: 303, spaceIndex: 3, isCurrentSpace: false, isFullscreenSpace: true, windows: [geminiStuckOnLaptop])
                    ]
                ),
                DisplaySnapshotInfo(
                    uuid: "EXT-49",
                    cgDisplayID: 2,
                    systemName: "DGVIEW495K",
                    customName: "Ultrawide",
                    isBuiltIn: false,
                    frame: CGRectCodable(x: 0, y: -1440, width: 5120, height: 1440),
                    spaces: [
                        SpaceSnapshotInfo(spaceID: 201, spaceIndex: 1, isCurrentSpace: true, windows: [chromePlacedOnExt])
                    ]
                )
            ]
        )

        // Empty list returns snapshot unchanged
        #expect(halfRestored.keeping(intended: []) == halfRestored)

        // Substituting Gemini moves it from laptop fullscreen desk 3 to ultrawide desk 1, leaving Chrome untouched
        let corrected = halfRestored.keeping(intended: [geminiIntendedOnExt])
        let laptopWindows = corrected.displays.first(where: { $0.uuid == "LAPTOP" })!.spaces.flatMap(\.windows)
        let extWindows = corrected.displays.first(where: { $0.uuid == "EXT-49" })!.spaces.flatMap(\.windows)

        #expect(laptopWindows.isEmpty)
        #expect(extWindows.count == 2)
        #expect(extWindows.contains(chromePlacedOnExt))
        #expect(extWindows.contains(geminiIntendedOnExt))
    }

    @Test("Fullscreen overlay filtering keeps largest window per app, preserves Split View, leaves normal desktops untouched")
    func fullscreenOverlayFiltering() {
        let candidates: [WindowEngine.CaptureWindowCandidate] = [
            // Fullscreen Chrome (space 10): toolbar strip + omnibox popup + main window
            .init(windowNumber: 1, ownerPID: 100, appKey: "com.google.chrome", spaceID: 10, isFullscreenSpace: true, frame: CGRect(x: 0, y: 0, width: 1512, height: 124)),
            .init(windowNumber: 2, ownerPID: 100, appKey: "com.google.chrome", spaceID: 10, isFullscreenSpace: true, frame: CGRect(x: 300, y: 120, width: 897, height: 298)),
            .init(windowNumber: 3, ownerPID: 100, appKey: "com.google.chrome", spaceID: 10, isFullscreenSpace: true, frame: CGRect(x: 0, y: 121, width: 1512, height: 861)),
            // Split View on space 20: Safari + Notes
            .init(windowNumber: 4, ownerPID: 200, appKey: "com.apple.safari", spaceID: 20, isFullscreenSpace: true, frame: CGRect(x: 0, y: 0, width: 756, height: 982)),
            .init(windowNumber: 5, ownerPID: 201, appKey: "com.apple.notes", spaceID: 20, isFullscreenSpace: true, frame: CGRect(x: 756, y: 0, width: 756, height: 982)),
            // Normal desktop (space 30): two Finder windows (including a legitimately small 180×140 inspector-sized window)
            .init(windowNumber: 6, ownerPID: 300, appKey: "com.apple.finder", spaceID: 30, isFullscreenSpace: false, frame: CGRect(x: 50, y: 50, width: 800, height: 600)),
            .init(windowNumber: 7, ownerPID: 300, appKey: "com.apple.finder", spaceID: 30, isFullscreenSpace: false, frame: CGRect(x: 900, y: 50, width: 180, height: 140)),
            // Tiny helper below 150×120 minimum
            .init(windowNumber: 8, ownerPID: 300, appKey: "com.apple.finder", spaceID: 30, isFullscreenSpace: false, frame: CGRect(x: 0, y: 0, width: 100, height: 40))
        ]

        let keptIDs = WindowEngine.filterCaptureCandidates(candidates).map(\.windowNumber)
        #expect(keptIDs == [3, 4, 5, 6, 7])
    }

    @Test("WindowMatcher: window ID beats title, never crosses apps, exact title wins globally, partial/nearest/surplus/unavailable")
    func windowMatcherAllPasses() {
        let leftRect = CGRect(x: 0, y: 0, width: 1200, height: 1000)
        let rightRect = CGRect(x: 1200, y: 0, width: 1200, height: 1000)

        // 1. Window ID beats title match
        let savedID = makeWindow(windowNumber: 42, windowTitle: "Old Tab", frame: leftRect)
        let liveSameTitleWrongID = LiveWindowInfo(windowID: 99, bundleIdentifier: "com.google.Chrome", appName: "Google Chrome", title: "Old Tab", frame: leftRect, isFullscreen: false)
        let liveExactIDNewTitle = LiveWindowInfo(windowID: 42, bundleIdentifier: "com.google.Chrome", appName: "Google Chrome", title: "New Tab", frame: rightRect, isFullscreen: false)
        let idMatches = WindowMatcher.match(
            saved: [savedID],
            targets: [leftRect],
            live: [liveSameTitleWrongID, liveExactIDNewTitle]
        )
        #expect(idMatches == [.init(savedIndex: 0, liveIndex: 1, kind: .windowID)])

        // 2. Never matches across apps
        let savedChrome = makeWindow(windowNumber: 500, ownerName: "Google Chrome", bundleIdentifier: "com.google.Chrome", windowTitle: "Inbox", frame: leftRect)
        let liveSafari = LiveWindowInfo(windowID: 500, bundleIdentifier: "com.apple.Safari", appName: "Safari", title: "Inbox", frame: leftRect, isFullscreen: false)
        #expect(WindowMatcher.match(saved: [savedChrome], targets: [leftRect], live: [liveSafari]).isEmpty)

        // 3. Exact titles win globally before fallbacks:
        // Saved A is untitled at left, saved B is titled "Inbox" at right.
        // Live 0 is "Inbox" at left, live 1 is "Draft" at right.
        // B must get "Inbox" (live 0), leaving A to pair with "Draft" (live 1) via nearestFrame!
        let savedA = makeWindow(windowNumber: 1, windowTitle: "", frame: leftRect)
        let savedB = makeWindow(windowNumber: 2, windowTitle: "Inbox", frame: rightRect)
        let liveInboxLeft = LiveWindowInfo(windowID: 10, bundleIdentifier: "com.google.Chrome", appName: "Google Chrome", title: "Inbox", frame: leftRect, isFullscreen: false)
        let liveDraftRight = LiveWindowInfo(windowID: 11, bundleIdentifier: "com.google.Chrome", appName: "Google Chrome", title: "Draft", frame: rightRect, isFullscreen: false)
        let globalMatches = WindowMatcher.match(
            saved: [savedA, savedB],
            targets: [leftRect, rightRect],
            live: [liveInboxLeft, liveDraftRight]
        )
        #expect(globalMatches == [
            .init(savedIndex: 0, liveIndex: 1, kind: .nearestFrame),
            .init(savedIndex: 1, liveIndex: 0, kind: .exactTitle)
        ])

        // 4. Partial titles match ("Roost — Package.swift" vs "Roost")
        let savedEditor = makeWindow(windowNumber: 77, ownerName: "Xcode", bundleIdentifier: "com.apple.dt.Xcode", windowTitle: "Roost — Package.swift", frame: leftRect)
        let liveEditor = LiveWindowInfo(windowID: 88, bundleIdentifier: "com.apple.dt.Xcode", appName: "Xcode", title: "Roost", frame: rightRect, isFullscreen: false)
        let partialMatches = WindowMatcher.match(saved: [savedEditor], targets: [leftRect], live: [liveEditor])
        #expect(partialMatches == [.init(savedIndex: 0, liveIndex: 0, kind: .partialTitle)])

        // 5 & 6. Untitled windows pair by nearest frame, and surplus saved windows stay unmatched
        let untitledLeft = makeWindow(windowNumber: 301, windowTitle: "", frame: leftRect)
        let untitledRight = makeWindow(windowNumber: 302, windowTitle: "", frame: rightRect)
        let surplusSaved = makeWindow(windowNumber: 303, windowTitle: "", frame: CGRect(x: 2400, y: 0, width: 800, height: 800))
        let liveNearRight = LiveWindowInfo(windowID: 401, bundleIdentifier: "com.google.Chrome", appName: "Google Chrome", title: "", frame: CGRect(x: 1180, y: 10, width: 1200, height: 1000), isFullscreen: false)
        let liveNearLeft = LiveWindowInfo(windowID: 402, bundleIdentifier: "com.google.Chrome", appName: "Google Chrome", title: "", frame: CGRect(x: 15, y: 0, width: 1200, height: 1000), isFullscreen: false)
        let nearestAndSurplus = WindowMatcher.match(
            saved: [untitledLeft, untitledRight, surplusSaved],
            targets: [leftRect, rightRect, surplusSaved.frame.cgRect],
            live: [liveNearRight, liveNearLeft]
        )
        #expect(nearestAndSurplus == [
            .init(savedIndex: 0, liveIndex: 1, kind: .nearestFrame),
            .init(savedIndex: 1, liveIndex: 0, kind: .nearestFrame)
        ])

        // 7. Unavailable set is respected
        let restricted = WindowMatcher.match(
            saved: [untitledLeft],
            targets: [leftRect],
            live: [liveNearLeft, liveNearRight],
            unavailable: [0]
        )
        #expect(restricted == [.init(savedIndex: 0, liveIndex: 1, kind: .nearestFrame)])
    }

    @Test("Target frames: exact when display unchanged, proportional clamped when moved/resized, nil when display gone")
    func targetFrameCalculation() {
        let savedDispFrame = CGRect(x: 0, y: -1440, width: 5120, height: 1440)
        let savedWin = makeWindow(
            frame: CGRect(x: 1280, y: -1400, width: 2560, height: 1400),
            relativeFrame: CGRect(x: 0.25, y: 0.0277777778, width: 0.5, height: 0.9722222222),
            displayUUID: "EXT-49"
        )

        // 1. Exact frame when display frame is unchanged
        let exact = WindowEngine.targetFrame(
            for: savedWin,
            savedDisplayFrame: savedDispFrame,
            liveDisplayFramesByUUID: ["EXT-49": savedDispFrame]
        )
        #expect(exact == savedWin.frame.cgRect)

        // 2. Proportional mapping when display moved/resized, and clamped when overhanging
        let resizedDisp = CGRect(x: 1512, y: 0, width: 3840, height: 1080)
        let overhangingWin = makeWindow(
            frame: CGRect(x: 4500, y: -1440, width: 1000, height: 1500),
            relativeFrame: CGRect(x: 0.85, y: -0.05, width: 0.30, height: 1.10),
            displayUUID: "EXT-49"
        )
        let mapped = WindowEngine.targetFrame(
            for: overhangingWin,
            savedDisplayFrame: savedDispFrame,
            liveDisplayFramesByUUID: ["EXT-49": resizedDisp]
        )
        #expect(mapped != nil)
        if let mapped = mapped {
            #expect(mapped.minX >= resizedDisp.minX)
            #expect(mapped.minY >= resizedDisp.minY)
            #expect(mapped.maxX <= resizedDisp.maxX)
            #expect(mapped.maxY <= resizedDisp.maxY)
            #expect(mapped.height == resizedDisp.height)
        }

        // 3. Nil when display is gone
        let missing = WindowEngine.targetFrame(
            for: savedWin,
            savedDisplayFrame: savedDispFrame,
            liveDisplayFramesByUUID: ["LAPTOP": CGRect(x: 0, y: 0, width: 1512, height: 982)]
        )
        #expect(missing == nil)
    }

    @Test("Duplicates: auto-save within 4 pt of newest is skipped; manual save is always written")
    func duplicateAutoSnapshotsAndManualOverride() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TilesDuplicates_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = SnapshotStore(baseDirectory: tempDir, maxSnapshotsPerTopology: 10)
        let topo = "EXT-49"
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        func makeSnap(id: String, offsetSeconds: Double, x: Double, winNum: Int, isManual: Bool) -> MacSnapshot {
            MacSnapshot(
                id: id,
                capturedAt: baseDate.addingTimeInterval(offsetSeconds),
                topologyKey: topo,
                displays: [
                    DisplaySnapshotInfo(
                        uuid: "EXT-49",
                        cgDisplayID: 2,
                        systemName: "DGVIEW495K",
                        customName: "Ultrawide",
                        isBuiltIn: false,
                        frame: CGRectCodable(x: 0, y: 0, width: 5120, height: 1440),
                        spaces: [
                            SpaceSnapshotInfo(
                                spaceID: 1,
                                spaceIndex: 1,
                                isCurrentSpace: true,
                                windows: [
                                    makeWindow(
                                        windowNumber: winNum,
                                        frame: CGRect(x: x, y: 100, width: 1600, height: 1200),
                                        displayUUID: "EXT-49"
                                    )
                                ]
                            )
                        ]
                    )
                ],
                isManual: isManual
            )
        }

        let firstURL = try store.saveSnapshot(makeSnap(id: "auto-1", offsetSeconds: 0, x: 100.0, winNum: 10, isManual: false))
        #expect(firstURL != nil)

        // Sub-4 pt jitter (100.0 -> 101.4 both quantize to 25) and different windowNumber -> skipped on auto-save!
        let jitterURL = try store.saveSnapshot(makeSnap(id: "auto-2", offsetSeconds: 30, x: 101.4, winNum: 99, isManual: false))
        #expect(jitterURL == nil)
        #expect(store.loadSnapshots(forTopology: topo).count == 1)

        // Manual save with identical layout IS always written!
        let manualURL = try store.saveSnapshot(makeSnap(id: "manual-3", offsetSeconds: 60, x: 100.0, winNum: 99, isManual: true))
        #expect(manualURL != nil)
        #expect(store.loadSnapshots(forTopology: topo).map(\.id) == ["manual-3", "auto-1"])
    }

    @Test("Pruning keeps the newest N unpinned snapshots plus the pinned snapshot")
    func pruningPreservesPinnedSnapshot() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TilesPinnedPrune_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = SnapshotStore(baseDirectory: tempDir, maxSnapshotsPerTopology: 5)
        let topo = "EXT-49"
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        for i in 1...8 {
            let snap = MacSnapshot(
                id: "snap-\(i)",
                capturedAt: baseDate.addingTimeInterval(Double(i * 30)),
                topologyKey: topo,
                displays: [
                    DisplaySnapshotInfo(
                        uuid: "EXT-49",
                        cgDisplayID: 2,
                        systemName: "DGVIEW495K",
                        customName: "Ultrawide",
                        isBuiltIn: false,
                        frame: CGRectCodable(x: 0, y: 0, width: 5120, height: 1440),
                        spaces: [
                            SpaceSnapshotInfo(
                                spaceID: 1,
                                spaceIndex: 1,
                                isCurrentSpace: true,
                                windows: [
                                    makeWindow(
                                        windowNumber: 200 + i,
                                        windowTitle: "Doc \(i)",
                                        frame: CGRect(x: Double(i * 50), y: 0, width: 1600, height: 1200),
                                        displayUUID: "EXT-49"
                                    )
                                ]
                            )
                        ]
                    )
                ]
            )
            try store.saveSnapshot(snap)
            if i == 1 {
                store.pinSnapshot(id: "snap-1", forTopology: topo)
            }
        }

        let loaded = store.loadSnapshots(forTopology: topo)
        let ids = loaded.map(\.id)
        // Must keep newest 5 unpinned (snap-8..snap-4) PLUS pinned snap-1 = 6 total!
        #expect(ids == ["snap-8", "snap-7", "snap-6", "snap-5", "snap-4", "snap-1"])
        #expect(store.preferredRestoreSnapshot(forTopology: topo)?.id == "snap-1")
    }

    @Test("Legacy snapshot JSON without isFullscreen or isManual decodes cleanly")
    func legacySnapshotJSONDecodesWithDefaults() throws {
        let json = """
        {
          "capturedAt" : "2026-10-29T23:51:15Z",
          "displays" : [
            {
              "cgDisplayID" : 1,
              "customName" : "Built-in Retina Display",
              "frame" : { "height" : 982, "width" : 1512, "x" : 0, "y" : 0 },
              "isBuiltIn" : true,
              "spaces" : [
                {
                  "isCurrentSpace" : true,
                  "spaceID" : 1,
                  "spaceIndex" : 1,
                  "windows" : [
                    {
                      "bundleIdentifier" : "com.google.Chrome",
                      "displayUUID" : "37D8832A",
                      "frame" : { "height" : 800, "width" : 1200, "x" : 20, "y" : 40 },
                      "ownerName" : "Google Chrome",
                      "ownerPID" : 1186,
                      "relativeFrame" : { "height" : 0.8, "width" : 0.8, "x" : 0.01, "y" : 0.04 },
                      "spaceID" : 1,
                      "spaceIndex" : 1,
                      "windowIndexInApp" : 0,
                      "windowNumber" : 13783,
                      "windowTitle" : "Tiles"
                    }
                  ]
                }
              ],
              "systemName" : "Built-in Retina Display",
              "uuid" : "37D8832A"
            }
          ],
          "id" : "LEGACY-1234",
          "topologyKey" : "37D8832A"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(MacSnapshot.self, from: Data(json.utf8))
        #expect(decoded.id == "LEGACY-1234")
        #expect(decoded.isManual == false)
        #expect(decoded.displays[0].spaces[0].isFullscreenSpace == false)
        #expect(decoded.displays[0].spaces[0].windows[0].isFullscreen == false)
    }

    @Test("One-time legacy TilesData copy preserves legacy files and copies snapshots + display_names.json")
    func oneTimeLegacyMigrationCopiesWithoutDeleting() throws {
        let legacyDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TilesLegacy_\(UUID().uuidString)", isDirectory: true)
        let newDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TilesAppSupport_\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: legacyDir)
            try? FileManager.default.removeItem(at: newDir)
        }

        // Seed legacy folder with a snapshot and display_names.json
        let legacyStore = SnapshotStore(baseDirectory: legacyDir)
        legacyStore.saveCustomDisplayName("49-inch Studio Ultrawide", forDisplayUUID: "EXT-49")
        let legacySnap = MacSnapshot(
            id: "legacy-snap-1",
            topologyKey: "EXT-49",
            displays: [
                DisplaySnapshotInfo(
                    uuid: "EXT-49",
                    cgDisplayID: 2,
                    systemName: "DGVIEW495K",
                    customName: "49-inch Studio Ultrawide",
                    isBuiltIn: false,
                    frame: CGRectCodable(x: 0, y: 0, width: 5120, height: 1440),
                    spaces: [
                        SpaceSnapshotInfo(spaceID: 1, spaceIndex: 1, isCurrentSpace: true, windows: [makeWindow()])
                    ]
                )
            ],
            isManual: true
        )
        try legacyStore.saveSnapshot(legacySnap)

        // Initialize new store pointing at empty newDir with legacyDir candidate
        let migratedStore = SnapshotStore(baseDirectory: newDir, legacyDataDirectory: legacyDir)
        #expect(migratedStore.loadSnapshots(forTopology: "EXT-49").map(\.id) == ["legacy-snap-1"])
        #expect(migratedStore.loadCustomDisplayNames()["EXT-49"] == "49-inch Studio Ultrawide")
        #expect(migratedStore.readRecentLogLines().contains("Copied legacy data"))

        // Legacy files must still exist untouched!
        #expect(legacyStore.loadSnapshots(forTopology: "EXT-49").map(\.id) == ["legacy-snap-1"])
    }
}
