import Foundation
import AppKit
import CoreGraphics
import ApplicationServices
import Darwin

/// Plain value describing a live window, so matching is testable without AXUIElements.
/// Keep the AXUIElement in a parallel array indexed the same way.
public struct LiveWindowInfo: Equatable {
    public var windowID: CGWindowID   // 0 when unknown
    public var bundleIdentifier: String?
    public var appName: String
    public var title: String
    public var frame: CGRect
    public var isFullscreen: Bool

    public init(
        windowID: CGWindowID,
        bundleIdentifier: String?,
        appName: String,
        title: String,
        frame: CGRect,
        isFullscreen: Bool
    ) {
        self.windowID = windowID
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.title = title
        self.frame = frame
        self.isFullscreen = isFullscreen
    }

    public var appKey: String {
        ((bundleIdentifier?.isEmpty == false) ? bundleIdentifier! : appName).lowercased()
    }
}

public enum WindowMatcher {
    public enum Kind: String { case windowID, exactTitle, partialTitle, nearestFrame }

    public struct Match: Equatable {
        public var savedIndex: Int
        public var liveIndex: Int
        public var kind: Kind

        public init(savedIndex: Int, liveIndex: Int, kind: Kind) {
            self.savedIndex = savedIndex
            self.liveIndex = liveIndex
            self.kind = kind
        }
    }

    /// `targets[i]` is where `saved[i]` should go. It is used to break ties.
    public static func match(
        saved: [WindowSnapshotInfo],
        targets: [CGRect],
        live: [LiveWindowInfo],
        unavailable: Set<Int> = []
    ) -> [Match] {
        var usedSaved = Set<Int>(), usedLive = unavailable, result: [Match] = []

        func distance(_ a: CGRect, _ b: CGRect) -> Double {
            Double(hypot(a.midX - b.midX, a.midY - b.midY) + hypot(a.width - b.width, a.height - b.height))
        }
        func pass(_ kind: Kind, _ accepts: (WindowSnapshotInfo, LiveWindowInfo) -> Bool) {
            var pairs: [(s: Int, l: Int, cost: Double)] = []
            for s in saved.indices where !usedSaved.contains(s) {
                for l in live.indices where !usedLive.contains(l) {
                    let sw = saved[s], lw = live[l]
                    guard sw.appKey == lw.appKey, accepts(sw, lw) else { continue }   // never across apps
                    var cost = distance(targets[s], lw.frame)
                    if sw.isFullscreen != lw.isFullscreen { cost += 100_000 }
                    pairs.append((s, l, cost))
                }
            }
            pairs.sort { $0.cost != $1.cost ? $0.cost < $1.cost : ($0.s, $0.l) < ($1.s, $1.l) }
            for p in pairs where !usedSaved.contains(p.s) && !usedLive.contains(p.l) {
                usedSaved.insert(p.s); usedLive.insert(p.l)
                result.append(Match(savedIndex: p.s, liveIndex: p.l, kind: kind))
            }
        }

        pass(.windowID) { s, l in s.windowNumber != 0 && UInt32(s.windowNumber) == l.windowID }
        pass(.exactTitle) { s, l in !s.windowTitle.isEmpty && s.windowTitle.caseInsensitiveCompare(l.title) == .orderedSame }
        pass(.partialTitle) { s, l in
            let a = s.windowTitle, b = l.title
            guard a.count >= 3, b.count >= 3 else { return false }
            return a.localizedCaseInsensitiveContains(b) || b.localizedCaseInsensitiveContains(a)
        }
        pass(.nearestFrame) { _, _ in true }
        return result.sorted { $0.savedIndex < $1.savedIndex }
    }
}

public enum WindowEngine {

    private static let axMessagingTimeout: Float = 0.5

    private typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private typealias CreateWithRemoteTokenFn = @convention(c) (CFData) -> Unmanaged<AXUIElement>?

    private static let getWindowFn: GetWindowFn? = {
        guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(p, to: GetWindowFn.self)
    }()

    private static let createWithRemoteToken: CreateWithRemoteTokenFn? = {
        guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementCreateWithRemoteToken") else { return nil }
        return unsafeBitCast(p, to: CreateWithRemoteTokenFn.self)
    }()

    @discardableResult
    private static func getWindowID(_ element: AXUIElement, _ windowID: inout CGWindowID) -> AXError {
        guard let fn = getWindowFn else {
            windowID = 0
            return .failure
        }
        return fn(element, &windowID)
    }

    /// Builds AX elements for an app's windows by element ID. This reaches windows on desktops
    /// that are not showing. Stops when every wanted window is found, after 2,000 IDs, or after 0.4 s.
    static func axElementsByRemoteToken(pid: pid_t, windowIDs wanted: Set<CGWindowID>) -> [AXUIElement] {
        guard let create = createWithRemoteToken, getWindowFn != nil else { return [] }
        // Token layout: pid (4 bytes), 0 (4), "coco" magic (4), element ID (8).
        var token = Data(count: 20)
        token.replaceSubrange(0..<4, with: withUnsafeBytes(of: Int32(pid)) { Data($0) })
        token.replaceSubrange(4..<8, with: withUnsafeBytes(of: Int32(0)) { Data($0) })
        token.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f_636f)) { Data($0) })

        var found: [AXUIElement] = []
        var remaining = wanted
        let deadline = Date().addingTimeInterval(0.4)
        for elementID in UInt64(0)..<2000 {
            if remaining.isEmpty || Date() > deadline { break }
            token.replaceSubrange(12..<20, with: withUnsafeBytes(of: elementID) { Data($0) })
            guard let el = create(token as CFData)?.takeRetainedValue() else { continue }
            AXUIElementSetMessagingTimeout(el, axMessagingTimeout)
            var wid: CGWindowID = 0
            guard getWindowID(el, &wid) == .success, wid != 0, remaining.contains(wid) else { continue }
            remaining.remove(wid)
            found.append(el)
        }
        return found
    }

    /// Plain candidate value used to filter out small helper strips and fullscreen overlays.
    public struct CaptureWindowCandidate: Equatable {
        public var windowNumber: Int
        public var ownerPID: Int32
        public var appKey: String
        public var spaceID: UInt64
        public var isFullscreenSpace: Bool
        public var frame: CGRect

        public init(
            windowNumber: Int,
            ownerPID: Int32,
            appKey: String,
            spaceID: UInt64,
            isFullscreenSpace: Bool,
            frame: CGRect
        ) {
            self.windowNumber = windowNumber
            self.ownerPID = ownerPID
            self.appKey = appKey
            self.spaceID = spaceID
            self.isFullscreenSpace = isFullscreenSpace
            self.frame = frame
        }
    }

    /// Filters candidate windows by minimum size (150×120) and, on fullscreen desktops,
    /// keeps only the largest window per app on each fullscreen space (preserving Split View apps).
    public static func filterCaptureCandidates(_ candidates: [CaptureWindowCandidate]) -> [CaptureWindowCandidate] {
        let sizeFiltered = candidates.filter { $0.frame.width >= 150 && $0.frame.height >= 120 }

        struct FullscreenAppGroup: Hashable {
            let spaceID: UInt64
            let appKey: String
        }

        var bestByGroup: [FullscreenAppGroup: (windowNumber: Int, area: CGFloat)] = [:]
        for c in sizeFiltered where c.isFullscreenSpace {
            let key = FullscreenAppGroup(spaceID: c.spaceID, appKey: c.appKey)
            let area = c.frame.width * c.frame.height
            if let existing = bestByGroup[key] {
                if area > existing.area {
                    bestByGroup[key] = (c.windowNumber, area)
                }
            } else {
                bestByGroup[key] = (c.windowNumber, area)
            }
        }

        return sizeFiltered.filter { c in
            guard c.isFullscreenSpace else { return true }
            let key = FullscreenAppGroup(spaceID: c.spaceID, appKey: c.appKey)
            return bestByGroup[key]?.windowNumber == c.windowNumber
        }
    }

    /// Computes the target Quartz frame for a saved window on the currently connected displays.
    /// Returns `nil` when the saved window's display is not connected.
    /// Returns the exact saved frame when the display's frame is unchanged, or proportionally maps
    /// and clamps to the display bounds when the display moved or changed resolution.
    public static func targetFrame(
        for saved: WindowSnapshotInfo,
        savedDisplayFrame: CGRect?,
        liveDisplayFramesByUUID: [String: CGRect]
    ) -> CGRect? {
        guard let liveDispFrame = liveDisplayFramesByUUID[saved.displayUUID] else {
            return nil
        }
        if let savedDispFrame = savedDisplayFrame, liveDispFrame == savedDispFrame {
            return saved.frame.cgRect
        }

        let rel = saved.relativeFrame
        let minW = min(CGFloat(150), liveDispFrame.width)
        let minH = min(CGFloat(120), liveDispFrame.height)
        let w = min(max(CGFloat(rel.width) * liveDispFrame.width, minW), liveDispFrame.width)
        let h = min(max(CGFloat(rel.height) * liveDispFrame.height, minH), liveDispFrame.height)
        var x = liveDispFrame.minX + CGFloat(rel.x) * liveDispFrame.width
        var y = liveDispFrame.minY + CGFloat(rel.y) * liveDispFrame.height
        x = min(max(x, liveDispFrame.minX), liveDispFrame.maxX - w)
        y = min(max(y, liveDispFrame.minY), liveDispFrame.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Checks whether Accessibility permissions are granted.
    /// Only triggers the macOS permission prompt if `prompt == true` AND permission is not already granted.
    public static func isAccessibilityTrusted(prompt: Bool = false) -> Bool {
        if AXIsProcessTrusted() {
            return true
        }
        guard prompt else {
            return false
        }
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Captures a complete Mac-wide snapshot across all connected displays (internal + external)
    /// and all Desktops (Spaces) on each display.
    public static func captureCurrentMacSnapshot(
        customDisplayNames: [String: String],
        logger: ((String) -> Void)? = nil
    ) -> MacSnapshot {
        let connected = DisplayHelper.currentConnectedDisplays(customNames: customDisplayNames)
        let topologyKey = connected.isEmpty
            ? "headless"
            : connected.map { $0.uuid }.sorted().joined(separator: "__")

        let spaceMap = SpaceBridge.queryAllDisplaySpaces()
        let hasDesktopInfo = !spaceMap.spaceInfoByID.isEmpty

        // Map PID -> Bundle Identifier & Regular App status using NSWorkspace
        var bundleByPID: [Int32: String] = [:]
        var regularPIDs: Set<Int32> = []
        for app in NSWorkspace.shared.runningApplications {
            if let bid = app.bundleIdentifier {
                bundleByPID[app.processIdentifier] = bid
            }
            if app.activationPolicy == .regular {
                regularPIDs.insert(app.processIdentifier)
            }
        }

        // Collect live AX window metadata on showing desktops without remote-token probing (cheap).
        let (liveAXByWindowID, axWindowIDsByPID) = collectLiveAXInfoForCapture()

        // Initialize DisplaySnapshotInfo structures with their known Spaces
        var displayDict: [String: DisplaySnapshotInfo] = [:]
        for disp in connected {
            let rawSpaces = spaceMap.spacesByDisplayUUID[disp.uuid]
                ?? (connected.count == 1 ? spaceMap.spacesByDisplayUUID.values.first : nil)
                ?? [DisplaySpacesMap.SpaceEntry(spaceID: 1, index: 1, isCurrent: true, isFullscreen: false)]

            let spaceInfos = rawSpaces.map { sp in
                SpaceSnapshotInfo(
                    spaceID: sp.spaceID,
                    spaceIndex: sp.index,
                    isCurrentSpace: sp.isCurrent,
                    isFullscreenSpace: sp.isFullscreen,
                    windows: []
                )
            }

            displayDict[disp.uuid] = DisplaySnapshotInfo(
                uuid: disp.uuid,
                cgDisplayID: disp.cgDisplayID,
                systemName: disp.systemName,
                customName: disp.customName,
                isBuiltIn: disp.isBuiltIn,
                frame: CGRectCodable(disp.quartzFrame),
                spaces: spaceInfos
            )
        }

        let cgListOptions: CGWindowListOption = hasDesktopInfo
            ? [.optionAll, .excludeDesktopElements]
            : [.optionOnScreenOnly, .excludeDesktopElements]

        guard let windowList = CGWindowListCopyWindowInfo(cgListOptions, kCGNullWindowID) as? [[String: Any]] else {
            return MacSnapshot(topologyKey: topologyKey, displays: Array(displayDict.values))
        }

        struct PendingCapturedWindow {
            let candidate: CaptureWindowCandidate
            let ownerPID: Int32
            let ownerName: String
            let bundleID: String?
            let winTitle: String
            let winRect: CGRect
            let targetDisplayUUID: String
            let primarySpaceID: UInt64
            let matchedSpaceIndex: Int
            let isFS: Bool
        }

        var pendingWindows: [PendingCapturedWindow] = []
        let myPID = ProcessInfo.processInfo.processIdentifier
        let connectedFrames = connected.map { (uuid: $0.uuid, frame: $0.quartzFrame) }

        for win in windowList {
            guard let layer = win[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let ownerPID = win[kCGWindowOwnerPID as String] as? Int32,
                  ownerPID != myPID,
                  regularPIDs.contains(ownerPID) else { continue }
            guard let windowNumber = win[kCGWindowNumber as String] as? Int else { continue }
            guard let ownerName = win[kCGWindowOwnerName as String] as? String else { continue }

            guard let boundsDict = win[kCGWindowBounds as String] as? [String: Any],
                  let x = boundsDict["X"] as? Double,
                  let y = boundsDict["Y"] as? Double,
                  let w = boundsDict["Width"] as? Double,
                  let h = boundsDict["Height"] as? Double else { continue }

            let alpha = (win[kCGWindowAlpha as String] as? Double) ?? 1.0
            if alpha <= 0.01 { continue }

            let axInfo = liveAXByWindowID[CGWindowID(windowNumber)]
            let winRect = axInfo?.frame ?? CGRect(x: x, y: y, width: w, height: h)

            let targetDisplayUUID: String
            let primarySpaceID: UInt64
            let matchedSpaceIndex: Int
            let isCurrentSpace: Bool
            let isFullscreenSpace: Bool

            if hasDesktopInfo {
                let winSpaceIDs = SpaceBridge.spaceIDs(forWindowID: UInt32(windowNumber))
                guard let firstSpaceID = winSpaceIDs.first,
                      let spaceMeta = spaceMap.spaceInfoByID[firstSpaceID],
                      displayDict[spaceMeta.displayUUID] != nil else {
                    continue
                }
                targetDisplayUUID = spaceMeta.displayUUID
                primarySpaceID = firstSpaceID
                matchedSpaceIndex = spaceMeta.index
                isCurrentSpace = spaceMeta.isCurrent
                isFullscreenSpace = spaceMeta.isFullscreen
            } else {
                guard let bestUUID = bestDisplayUUID(for: winRect, displays: connectedFrames),
                      displayDict[bestUUID] != nil else {
                    continue
                }
                targetDisplayUUID = bestUUID
                primarySpaceID = 1
                matchedSpaceIndex = 1
                isCurrentSpace = true
                isFullscreenSpace = false
            }

            // On a showing desktop, when an app exposes window IDs via Accessibility,
            // skip CGWindowList entries for that app that Accessibility does not list.
            if isCurrentSpace,
               let knownAXIDs = axWindowIDsByPID[ownerPID],
               !knownAXIDs.isEmpty,
               !knownAXIDs.contains(CGWindowID(windowNumber)) {
                continue
            }

            let cgTitle = (win[kCGWindowName as String] as? String) ?? ""
            let winTitle = (axInfo?.title.isEmpty == false) ? axInfo!.title : cgTitle
            let isFS = isFullscreenSpace || (axInfo?.isFullscreen == true)
            let bundleID = bundleByPID[ownerPID]
            let appKey = ((bundleID?.isEmpty == false) ? bundleID! : ownerName).lowercased()

            let candidate = CaptureWindowCandidate(
                windowNumber: windowNumber,
                ownerPID: ownerPID,
                appKey: appKey,
                spaceID: primarySpaceID,
                isFullscreenSpace: isFullscreenSpace,
                frame: winRect
            )

            pendingWindows.append(PendingCapturedWindow(
                candidate: candidate,
                ownerPID: ownerPID,
                ownerName: ownerName,
                bundleID: bundleID,
                winTitle: winTitle,
                winRect: winRect,
                targetDisplayUUID: targetDisplayUUID,
                primarySpaceID: primarySpaceID,
                matchedSpaceIndex: matchedSpaceIndex,
                isFS: isFS
            ))
        }

        let keptWindowNumbers = Set(filterCaptureCandidates(pendingWindows.map(\.candidate)).map(\.windowNumber))
        var appWindowCounts: [Int32: Int] = [:]

        for item in pendingWindows where keptWindowNumbers.contains(item.candidate.windowNumber) {
            guard var targetDisplay = displayDict[item.targetDisplayUUID] else { continue }

            let idxInApp = appWindowCounts[item.ownerPID, default: 0]
            appWindowCounts[item.ownerPID] = idxInApp + 1

            let dispFrame = targetDisplay.frame.cgRect
            let relX = dispFrame.width > 0 ? (item.winRect.minX - dispFrame.minX) / dispFrame.width : 0
            let relY = dispFrame.height > 0 ? (item.winRect.minY - dispFrame.minY) / dispFrame.height : 0
            let relW = dispFrame.width > 0 ? item.winRect.width / dispFrame.width : 1
            let relH = dispFrame.height > 0 ? item.winRect.height / dispFrame.height : 1

            let winSnapshot = WindowSnapshotInfo(
                windowNumber: item.candidate.windowNumber,
                ownerPID: item.ownerPID,
                ownerName: item.ownerName,
                bundleIdentifier: item.bundleID,
                windowTitle: item.winTitle,
                windowIndexInApp: idxInApp,
                frame: CGRectCodable(item.winRect),
                relativeFrame: CGRectCodable(x: relX, y: relY, width: relW, height: relH),
                displayUUID: item.targetDisplayUUID,
                spaceID: item.primarySpaceID,
                spaceIndex: item.matchedSpaceIndex,
                isFullscreen: item.isFS
            )

            if let sIdx = targetDisplay.spaces.firstIndex(where: { $0.spaceID == item.primarySpaceID }) {
                targetDisplay.spaces[sIdx].windows.append(winSnapshot)
            } else if !targetDisplay.spaces.isEmpty {
                targetDisplay.spaces[0].windows.append(winSnapshot)
            }
            displayDict[item.targetDisplayUUID] = targetDisplay
        }

        let orderedDisplays = connected.compactMap { displayDict[$0.uuid] }
        let snap = MacSnapshot(
            capturedAt: Date(),
            topologyKey: topologyKey,
            displays: orderedDisplays
        )
        logger?("Captured snapshot [\(topologyKey)]: \(snap.displays.count) displays, \(snap.totalDesktopCount) desktops, \(snap.totalWindowCount) windows")
        return snap
    }

    /// Finds the display UUID whose frame has the largest overlap (or closest center) to `rect`.
    public static func bestDisplayUUID(for rect: CGRect, displays: [(uuid: String, frame: CGRect)]) -> String? {
        guard !displays.isEmpty else { return nil }
        var bestUUID = displays[0].uuid
        var bestArea: CGFloat = -1

        for d in displays {
            let inter = rect.intersection(d.frame)
            let area = inter.isNull ? 0 : (inter.width * inter.height)
            if area > bestArea {
                bestArea = area
                bestUUID = d.uuid
            }
        }
        return bestUUID
    }

    // MARK: - Window Restoration Engine

    public enum Unmatched: Equatable {
        /// Already how the snapshot wants it, for example fullscreen on the right display.
        case alreadyInPlace
        /// Out of reach for now. Place it when this desktop is showing.
        case waitFor(SpaceRef)
        /// Gone (app closed), or on a showing desktop and still unreachable.
        case missing
    }

    /// What matters is where the window is now, not where it is going: a window headed for the
    /// ultrawide may be sitting in a fullscreen desktop on the laptop. When the window still
    /// exists, wait for the desktop it is on. When its ID is gone, fall back to its saved desktop.
    public static func classifyUnmatched(
        _ w: WindowSnapshotInfo, liveLocation: SpaceRef?, liveOnFullscreenDesktop: Bool,
        isCurrent: (SpaceRef) -> Bool
    ) -> Unmatched {
        if let loc = liveLocation {
            if w.isFullscreen && liveOnFullscreenDesktop && loc.displayUUID == w.displayUUID { return .alreadyInPlace }
            return isCurrent(loc) ? .missing : .waitFor(loc)
        }
        let saved = SpaceRef(displayUUID: w.displayUUID, spaceIndex: w.spaceIndex)
        if w.spaceIndex > 0 && !isCurrent(saved) { return .waitFor(saved) }
        return .missing
    }

    public struct RestoreReport {
        public var restoredCount: Int = 0
        public var skippedMissingCount: Int = 0
        public var waiting: [String: SpaceRef] = [:]
        public var placedWindowIDs: Set<CGWindowID> = []
        public var details: [String] = []
    }

    /// Restores windows from a `MacSnapshot` across all currently connected displays using global multi-pass matching.
    public static func restore(
        snapshot: MacSnapshot,
        onlySavedWindowIDs: Set<String>? = nil,
        excludingLiveWindowIDs: Set<CGWindowID> = [],
        logger: ((String) -> Void)? = nil
    ) -> RestoreReport {
        var report = RestoreReport()
        guard isAccessibilityTrusted(prompt: false) else {
            let msg = "Restore aborted: Accessibility permission is not granted."
            report.details.append(msg)
            logger?(msg)
            return report
        }

        let liveDisplays = DisplayHelper.currentConnectedDisplays(customNames: [:])
        var liveDisplayFramesByUUID: [String: CGRect] = [:]
        for d in liveDisplays {
            liveDisplayFramesByUUID[d.uuid] = d.quartzFrame
        }

        var savedDisplayFramesByUUID: [String: CGRect] = [:]
        for disp in snapshot.displays {
            savedDisplayFramesByUUID[disp.uuid] = disp.frame.cgRect
        }

        let liveSpaceMap = SpaceBridge.queryAllDisplaySpaces()

        var targetWindows: [WindowSnapshotInfo] = []
        var targetRects: [CGRect] = []
        for disp in snapshot.displays {
            for sp in disp.spaces {
                for w in sp.windows {
                    if let onlyIDs = onlySavedWindowIDs, !onlyIDs.contains(w.id) {
                        continue
                    }
                    guard let rect = targetFrame(
                        for: w,
                        savedDisplayFrame: savedDisplayFramesByUUID[w.displayUUID],
                        liveDisplayFramesByUUID: liveDisplayFramesByUUID
                    ) else {
                        continue
                    }
                    targetWindows.append(w)
                    targetRects.append(rect)
                }
            }
        }

        let wantedIDs = Set(targetWindows.compactMap { $0.windowNumber > 0 ? CGWindowID($0.windowNumber) : nil })
        let liveAXWindows = collectLiveAXWindows(alsoFind: wantedIDs)
        let liveInfos = liveAXWindows.map { w in
            LiveWindowInfo(
                windowID: w.cgWindowID,
                bundleIdentifier: w.bundleID,
                appName: w.appName,
                title: w.title,
                frame: w.frame,
                isFullscreen: w.isFullscreen
            )
        }

        logger?("Starting restore for topology [\(snapshot.topologyKey)]: \(targetWindows.count) saved windows vs \(liveAXWindows.count) live AX windows.")

        var unavailableIndices: Set<Int> = []
        for (idx, w) in liveAXWindows.enumerated() {
            if w.cgWindowID != 0 && excludingLiveWindowIDs.contains(w.cgWindowID) {
                unavailableIndices.insert(idx)
            }
        }

        let matches = WindowMatcher.match(
            saved: targetWindows,
            targets: targetRects,
            live: liveInfos,
            unavailable: unavailableIndices
        )
        var matchBySavedIndex: [Int: WindowMatcher.Match] = [:]
        for m in matches {
            matchBySavedIndex[m.savedIndex] = m
        }

        let isCurrentSpace: (SpaceRef) -> Bool = { ref in
            liveSpaceMap.spacesByDisplayUUID[ref.displayUUID]?.contains(where: {
                $0.index == ref.spaceIndex && $0.isCurrent
            }) == true
        }

        for sIdx in targetWindows.indices {
            let savedWin = targetWindows[sIdx]
            let targetRect = targetRects[sIdx]

            if let match = matchBySavedIndex[sIdx] {
                let matched = liveAXWindows[match.liveIndex]
                if matched.cgWindowID != 0 {
                    report.placedWindowIDs.insert(matched.cgWindowID)
                }
                let winTag = matched.isOnOtherDesktop
                    ? "[\(matched.cgWindowID), other desktop]"
                    : "[\(matched.cgWindowID)]"
                let kindTag = "match=\(match.kind.rawValue)"

                // Saved: Not fullscreen | Live: Fullscreen -> Exit fullscreen, then set the frame (1.0s, 1.8s, 3.0s)
                if !savedWin.isFullscreen && matched.isFullscreen {
                    let msg = "✓ Un-fullscreening '\(savedWin.ownerName)' \(winTag) (\(kindTag)) and moving to (\(Int(targetRect.minX)), \(Int(targetRect.minY)), \(Int(targetRect.width))×\(Int(targetRect.height)))"
                    report.details.append(msg)
                    logger?(msg)
                    AXUIElementSetMessagingTimeout(matched.axElement, axMessagingTimeout)
                    _ = AXUIElementSetAttributeValue(matched.axElement, "AXFullScreen" as CFString, kCFBooleanFalse)
                    let axEl = matched.axElement
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        _ = setAXWindowFrame(axEl, to: targetRect, allowRetry: false)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                        _ = setAXWindowFrame(axEl, to: targetRect, allowRetry: false)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                        _ = setAXWindowFrame(axEl, to: targetRect, allowRetry: true)
                    }
                    report.restoredCount += 1
                    continue
                }

                // Saved: Fullscreen | Live: Not fullscreen -> Set the frame, then enter fullscreen
                if savedWin.isFullscreen && !matched.isFullscreen {
                    let msg = "✓ Restoring '\(savedWin.ownerName)' \(winTag) (\(kindTag)) into native Fullscreen on target display"
                    report.details.append(msg)
                    logger?(msg)
                    _ = setAXWindowFrame(matched.axElement, to: targetRect, allowRetry: false)
                    let axEl = matched.axElement
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        AXUIElementSetMessagingTimeout(axEl, axMessagingTimeout)
                        _ = AXUIElementSetAttributeValue(axEl, "AXFullScreen" as CFString, kCFBooleanTrue)
                    }
                    report.restoredCount += 1
                    continue
                }

                // Saved: Fullscreen | Live: Fullscreen -> Leave it alone
                if savedWin.isFullscreen && matched.isFullscreen {
                    let msg = "✓ Already fullscreen '\(savedWin.ownerName)' \(winTag) (\(kindTag))"
                    report.details.append(msg)
                    logger?(msg)
                    report.restoredCount += 1
                    continue
                }

                // Saved: Not fullscreen | Live: Not fullscreen -> Set the frame
                let ok = setAXWindowFrame(matched.axElement, to: targetRect, allowRetry: true)
                if ok {
                    report.restoredCount += 1
                    let msg = "✓ Restored '\(savedWin.ownerName)' \(winTag) (\(kindTag), savedID=\(savedWin.windowNumber)) to (\(Int(targetRect.minX)), \(Int(targetRect.minY)), \(Int(targetRect.width))×\(Int(targetRect.height)))"
                    report.details.append(msg)
                    logger?(msg)
                } else {
                    let msg = "✕ AX setFrame failed for '\(savedWin.ownerName)' \(winTag) (\(kindTag))"
                    report.details.append(msg)
                    logger?(msg)
                }
            } else {
                var liveLocation: SpaceRef? = nil
                var liveOnFullscreenDesktop = false
                if savedWin.windowNumber > 0,
                   let firstSpaceID = SpaceBridge.spaceIDs(forWindowID: UInt32(savedWin.windowNumber)).first,
                   let spaceInfo = liveSpaceMap.spaceInfoByID[firstSpaceID] {
                    liveLocation = SpaceRef(displayUUID: spaceInfo.displayUUID, spaceIndex: spaceInfo.index)
                    liveOnFullscreenDesktop = spaceInfo.isFullscreen
                }

                switch classifyUnmatched(
                    savedWin,
                    liveLocation: liveLocation,
                    liveOnFullscreenDesktop: liveOnFullscreenDesktop,
                    isCurrent: isCurrentSpace
                ) {
                case .alreadyInPlace:
                    report.restoredCount += 1
                    if savedWin.windowNumber > 0 {
                        report.placedWindowIDs.insert(CGWindowID(savedWin.windowNumber))
                    }
                    let msg = "✓ Already in place '\(savedWin.ownerName)' [\(savedWin.windowNumber)] (fullscreen on saved display)"
                    report.details.append(msg)
                    logger?(msg)
                case .waitFor(let spaceRef):
                    report.waiting[savedWin.id] = spaceRef
                    let msg = "⏳ Waiting for '\(savedWin.ownerName)' [\(savedWin.windowNumber)] on desktop \(spaceRef.spaceIndex) (\(spaceRef.displayUUID.prefix(8)))"
                    report.details.append(msg)
                    logger?(msg)
                case .missing:
                    report.skippedMissingCount += 1
                    let msg = "○ Skipped missing window '\(savedWin.ownerName)' (savedID=\(savedWin.windowNumber)) — left space empty"
                    report.details.append(msg)
                    logger?(msg)
                }
            }
        }

        return report
    }

    internal struct LiveAXWindow {
        let axElement: AXUIElement
        let cgWindowID: CGWindowID
        let pid: Int32
        let appName: String
        let bundleID: String?
        let title: String
        let frame: CGRect
        let indexInApp: Int
        let isFullscreen: Bool
        let isOnOtherDesktop: Bool
    }

    private static func collectLiveAXInfoForCapture() -> (
        byWindowID: [CGWindowID: LiveAXWindow],
        axWindowIDsByPID: [Int32: Set<CGWindowID>]
    ) {
        guard isAccessibilityTrusted(prompt: false) else { return ([:], [:]) }
        var map: [CGWindowID: LiveAXWindow] = [:]
        var idsByPID: [Int32: Set<CGWindowID>] = [:]
        for w in collectLiveAXWindows() where w.cgWindowID != 0 {
            map[w.cgWindowID] = w
            idsByPID[w.pid, default: []].insert(w.cgWindowID)
        }
        return (map, idsByPID)
    }

    internal static func collectLiveAXWindows(alsoFind wanted: Set<CGWindowID> = []) -> [LiveAXWindow] {
        var results: [LiveAXWindow] = []
        let myPID = ProcessInfo.processInfo.processIdentifier

        var cgWindowMeta: [CGWindowID: (pid: Int32, ownerName: String, title: String, bounds: CGRect, spaceIDs: [UInt64])] = [:]
        var ownerPIDByWindowID: [CGWindowID: Int32] = [:]
        if let winList = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for w in winList {
                guard let wid = w[kCGWindowNumber as String] as? UInt32,
                      let pid = w[kCGWindowOwnerPID as String] as? Int32 else { continue }
                ownerPIDByWindowID[wid] = pid

                guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
                      let owner = w[kCGWindowOwnerName as String] as? String,
                      let b = w[kCGWindowBounds as String] as? [String: Any],
                      let x = b["X"] as? Double, let y = b["Y"] as? Double,
                      let width = b["Width"] as? Double, let height = b["Height"] as? Double,
                      width >= 150, height >= 120 else { continue }
                let cgTitle = (w[kCGWindowName as String] as? String) ?? ""
                let spaces = SpaceBridge.spaceIDs(forWindowID: wid)
                cgWindowMeta[wid] = (pid, owner, cgTitle, CGRect(x: x, y: y, width: width, height: height), spaces)
            }
        }

        let spaceMap = SpaceBridge.queryAllDisplaySpaces()
        var runningAppsByPID: [Int32: NSRunningApplication] = [:]
        var seenGlobalWinIDs: Set<CGWindowID> = []

        func buildLiveAXWindow(
            winAX: AXUIElement,
            pid: Int32,
            appName: String,
            bundleID: String?,
            indexInApp: Int,
            isOnOtherDesktop: Bool,
            seenForApp: inout Set<CGWindowID>
        ) -> LiveAXWindow? {
            AXUIElementSetMessagingTimeout(winAX, axMessagingTimeout)

            var winID: CGWindowID = 0
            _ = getWindowID(winAX, &winID)
            if winID != 0 {
                if seenForApp.contains(winID) { return nil }
                seenForApp.insert(winID)
                seenGlobalWinIDs.insert(winID)
            }

            // Accept only AXStandardWindow, drop AXDialog; if no subrole, require non-zero winID (drops Finder desktop).
            var subroleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(winAX, kAXSubroleAttribute as CFString, &subroleRef)
            if let subrole = subroleRef as? String, !subrole.isEmpty {
                guard subrole == (kAXStandardWindowSubrole as String) else { return nil }
            } else {
                guard winID != 0 else { return nil }
            }

            var minRef: CFTypeRef?
            AXUIElementCopyAttributeValue(winAX, kAXMinimizedAttribute as CFString, &minRef)
            if let isMin = minRef as? Bool, isMin {
                return nil
            }

            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(winAX, kAXTitleAttribute as CFString, &titleRef)
            let axTitle = (titleRef as? String) ?? ""
            let title = !axTitle.isEmpty ? axTitle : (cgWindowMeta[winID]?.title ?? "")

            var fsRef: CFTypeRef?
            AXUIElementCopyAttributeValue(winAX, "AXFullScreen" as CFString, &fsRef)
            var isFS = (fsRef as? Bool) ?? false
            if let cgMeta = cgWindowMeta[winID],
               let firstSpace = cgMeta.spaceIDs.first,
               spaceMap.spaceInfoByID[firstSpace]?.isFullscreen == true {
                isFS = true
            }

            var rect = readAXWindowFrame(winAX) ?? .zero
            if rect.width <= 0 || rect.height <= 0, let cgBounds = cgWindowMeta[winID]?.bounds {
                rect = cgBounds
            }

            return LiveAXWindow(
                axElement: winAX,
                cgWindowID: winID,
                pid: pid,
                appName: appName,
                bundleID: bundleID,
                title: title,
                frame: rect,
                indexInApp: indexInApp,
                isFullscreen: isFS,
                isOnOtherDesktop: isOnOtherDesktop
            )
        }

        for app in NSWorkspace.shared.runningApplications {
            let pid = app.processIdentifier
            guard pid != myPID, app.activationPolicy == .regular else { continue }
            runningAppsByPID[pid] = app

            let appAX = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appAX, axMessagingTimeout)
            _ = AXUIElementSetAttributeValue(appAX, "AXManualAccessibility" as CFString, kCFBooleanTrue)

            var windowsRef: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(appAX, kAXWindowsAttribute as CFString, &windowsRef)
            var axWindows = (err == .success ? (windowsRef as? [AXUIElement]) : nil) ?? []

            var mainWinRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(appAX, kAXMainWindowAttribute as CFString, &mainWinRef) == .success,
               let mainWin = mainWinRef {
                axWindows.append(mainWin as! AXUIElement)
            }

            let appName = app.localizedName ?? ""
            let bundleID = app.bundleIdentifier
            var seenWinIDs: Set<CGWindowID> = []

            for (idx, winAX) in axWindows.enumerated() {
                if let built = buildLiveAXWindow(
                    winAX: winAX,
                    pid: pid,
                    appName: appName,
                    bundleID: bundleID,
                    indexInApp: idx,
                    isOnOtherDesktop: false,
                    seenForApp: &seenWinIDs
                ) {
                    results.append(built)
                }
            }
        }

        // Probe hidden desktops for wanted window IDs that were not seen via kAXWindowsAttribute
        if !wanted.isEmpty {
            let missingWanted = wanted.subtracting(seenGlobalWinIDs)
            var missingByPID: [Int32: Set<CGWindowID>] = [:]
            for wid in missingWanted {
                guard let pid = ownerPIDByWindowID[wid], pid != myPID else { continue }
                missingByPID[pid, default: []].insert(wid)
            }

            for (pid, pidWantedIDs) in missingByPID {
                let remoteElements = axElementsByRemoteToken(pid: pid, windowIDs: pidWantedIDs)
                guard !remoteElements.isEmpty else { continue }

                let app = runningAppsByPID[pid] ?? NSRunningApplication(processIdentifier: pid)
                let appName = app?.localizedName ?? cgWindowMeta[pidWantedIDs.first!]?.ownerName ?? ""
                let bundleID = app?.bundleIdentifier
                var seenRemoteIDs: Set<CGWindowID> = seenGlobalWinIDs

                for (offset, winAX) in remoteElements.enumerated() {
                    if let built = buildLiveAXWindow(
                        winAX: winAX,
                        pid: pid,
                        appName: appName,
                        bundleID: bundleID,
                        indexInApp: 1000 + offset,
                        isOnOtherDesktop: true,
                        seenForApp: &seenRemoteIDs
                    ) {
                        results.append(built)
                    }
                }
            }
        }

        return results
    }

    /// Diagnostic helper invoked by `com.sagar.Tiles.Diagnose`: queries all window-server IDs,
    /// passes them all as `alsoFind`, and logs every reachable window with app, ID, desktop state,
    /// fullscreen state, frame, title, total count, and elapsed time.
    public static func diagnoseReachableWindows(logger: (String) -> Void) {
        let start = Date()
        guard isAccessibilityTrusted(prompt: false) else {
            logger("[Diagnose] Aborted: Accessibility permission is not granted.")
            return
        }

        let myPID = ProcessInfo.processInfo.processIdentifier
        let regularPIDs = Set(
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .map(\.processIdentifier)
        )

        var allServerIDs: Set<CGWindowID> = []
        if let winList = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for w in winList {
                guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
                      let pid = w[kCGWindowOwnerPID as String] as? Int32,
                      pid != myPID, regularPIDs.contains(pid),
                      let wid = w[kCGWindowNumber as String] as? UInt32, wid != 0 else {
                    continue
                }
                allServerIDs.insert(wid)
            }
        }

        let reachable = collectLiveAXWindows(alsoFind: allServerIDs)
        let elapsed = Date().timeIntervalSince(start)
        logger("[Diagnose] Probed \(allServerIDs.count) server window IDs -> \(reachable.count) reachable AX windows in \(String(format: "%.3f", elapsed)) s")

        for w in reachable {
            let desktopState = w.isOnOtherDesktop ? "other desktop" : "showing"
            let fsState = w.isFullscreen ? "fullscreen" : "windowed"
            let frameStr = "(\(Int(w.frame.minX)), \(Int(w.frame.minY)), \(Int(w.frame.width))×\(Int(w.frame.height)))"
            logger("[Diagnose] app='\(w.appName)' id=\(w.cgWindowID) desktop=\(desktopState) state=\(fsState) frame=\(frameStr) title='\(w.title)'")
        }
        logger("[Diagnose] Total reachable windows: \(reachable.count) (time: \(String(format: "%.3f", elapsed)) s)")
    }

    private static func readAXWindowFrame(_ axWindow: AXUIElement) -> CGRect? {
        AXUIElementSetMessagingTimeout(axWindow, axMessagingTimeout)
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        let posErr = AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posRef)
        let sizeErr = AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef)
        guard posErr == .success, sizeErr == .success,
              let p = posRef, let s = sizeRef else {
            return nil
        }
        var pt = CGPoint.zero
        var sz = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &pt)
        AXValueGetValue(s as! AXValue, .cgSize, &sz)
        return CGRect(origin: pt, size: sz)
    }

    /// Uses macOS Accessibility (`AXUIElement`) to move and resize a window to `rect`.
    /// Sets size -> position -> size, restores `AXEnhancedUserInterface` if it was enabled,
    /// and retries once 0.35 s later if the resulting frame is more than 4 pt off.
    @discardableResult
    private static func setAXWindowFrame(_ axWindow: AXUIElement, to rect: CGRect, allowRetry: Bool = true) -> Bool {
        AXUIElementSetMessagingTimeout(axWindow, axMessagingTimeout)

        var pt = CGPoint(x: rect.origin.x, y: rect.origin.y)
        var sz = CGSize(width: rect.size.width, height: rect.size.height)

        guard let posVal = AXValueCreate(.cgPoint, &pt),
              let sizeVal = AXValueCreate(.cgSize, &sz) else {
            return false
        }

        var pid: pid_t = 0
        AXUIElementGetPid(axWindow, &pid)
        let appAX = pid != 0 ? AXUIElementCreateApplication(pid) : nil
        var wasEnhancedUI = false

        if let appAX = appAX {
            AXUIElementSetMessagingTimeout(appAX, axMessagingTimeout)
            _ = AXUIElementSetAttributeValue(appAX, "AXManualAccessibility" as CFString, kCFBooleanTrue)

            var enhancedRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(appAX, "AXEnhancedUserInterface" as CFString, &enhancedRef) == .success,
               let isEnhanced = enhancedRef as? Bool, isEnhanced {
                wasEnhancedUI = true
                _ = AXUIElementSetAttributeValue(appAX, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
            }
        }
        defer {
            if wasEnhancedUI, let appAX = appAX {
                _ = AXUIElementSetAttributeValue(appAX, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            }
        }

        // Order of operations: size, then position, then size again.
        let sizeErr1 = AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeVal)
        let posErr = AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, posVal)
        let sizeErr2 = AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeVal)

        let succeeded = (posErr == .success || sizeErr1 == .success || sizeErr2 == .success)

        if allowRetry {
            let needsRetry: Bool
            if let actual = readAXWindowFrame(axWindow) {
                needsRetry = abs(actual.minX - rect.minX) > 4
                    || abs(actual.minY - rect.minY) > 4
                    || abs(actual.width - rect.width) > 4
                    || abs(actual.height - rect.height) > 4
            } else {
                needsRetry = true
            }

            if needsRetry {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    _ = setAXWindowFrame(axWindow, to: rect, allowRetry: false)
                }
            }
        }

        return succeeded
    }
}
