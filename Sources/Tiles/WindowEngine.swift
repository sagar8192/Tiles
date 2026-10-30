import Foundation
import AppKit
import CoreGraphics
import ApplicationServices

// Private symbol to bridge AXUIElement to its exact CGWindowID when available
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

public enum WindowEngine {

    /// Checks whether Accessibility permissions are granted.
    /// Only triggers the macOS permission prompt if `prompt == true` AND permission is not already granted.
    public static func isAccessibilityTrusted(prompt: Bool = false) -> Bool {
        // First check silently without triggering any macOS dialog!
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

        // Collect live AX window metadata (real titles + real AXWindow frames + CGWindowIDs)
        // when Accessibility is trusted.
        let liveAXByWindowID = collectLiveAXMap()

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

        guard let windowList = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return MacSnapshot(topologyKey: topologyKey, displays: Array(displayDict.values))
        }

        var appWindowCounts: [Int32: Int] = [:]
        let myPID = ProcessInfo.processInfo.processIdentifier

        for win in windowList {
            // Only capture standard application windows (Layer == 0) belonging to regular GUI apps
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

            // Filter out tiny helper/toolbar overlay strips (like Chrome's 115px-139px fullscreen tab bar overlay)
            if w < 220 || h < 180 { continue }

            let alpha = (win[kCGWindowAlpha as String] as? Double) ?? 1.0
            if alpha <= 0.01 { continue }

            // Find which Space(s) this window belongs to
            let winSpaceIDs = SpaceBridge.spaceIDs(forWindowID: UInt32(windowNumber))
            guard !winSpaceIDs.isEmpty else {
                continue
            }

            let primarySpaceID = winSpaceIDs[0]

            guard let spaceMeta = spaceMap.spaceInfoByID[primarySpaceID],
                  displayDict[spaceMeta.displayUUID] != nil else {
                continue
            }

            // Prefer exact AXWindow frame and AXTitle if available for this CGWindowID
            let axInfo = liveAXByWindowID[CGWindowID(windowNumber)]
            let winRect = axInfo?.frame ?? CGRect(x: x, y: y, width: w, height: h)
            let cgTitle = (win[kCGWindowName as String] as? String) ?? ""
            let winTitle = (axInfo?.title.isEmpty == false) ? axInfo!.title : cgTitle
            let isFS = spaceMeta.isFullscreen || (axInfo?.isFullscreen == true)

            let targetDisplayUUID = spaceMeta.displayUUID
            let matchedSpaceIndex = spaceMeta.index
            guard var targetDisplay = displayDict[targetDisplayUUID] else {
                continue
            }

            let idxInApp = appWindowCounts[ownerPID, default: 0]
            appWindowCounts[ownerPID] = idxInApp + 1

            let dispFrame = targetDisplay.frame.cgRect
            let relX = dispFrame.width > 0 ? (winRect.minX - dispFrame.minX) / dispFrame.width : 0
            let relY = dispFrame.height > 0 ? (winRect.minY - dispFrame.minY) / dispFrame.height : 0
            let relW = dispFrame.width > 0 ? winRect.width / dispFrame.width : 1
            let relH = dispFrame.height > 0 ? winRect.height / dispFrame.height : 1

            let winSnapshot = WindowSnapshotInfo(
                windowNumber: windowNumber,
                ownerPID: ownerPID,
                ownerName: ownerName,
                bundleIdentifier: bundleByPID[ownerPID],
                windowTitle: winTitle,
                windowIndexInApp: idxInApp,
                frame: CGRectCodable(winRect),
                relativeFrame: CGRectCodable(x: relX, y: relY, width: relW, height: relH),
                displayUUID: targetDisplayUUID,
                spaceID: primarySpaceID,
                spaceIndex: matchedSpaceIndex,
                isFullscreen: isFS
            )

            if let sIdx = targetDisplay.spaces.firstIndex(where: { $0.spaceID == primarySpaceID }) {
                targetDisplay.spaces[sIdx].windows.append(winSnapshot)
            } else if !targetDisplay.spaces.isEmpty {
                targetDisplay.spaces[0].windows.append(winSnapshot)
            }
            displayDict[targetDisplayUUID] = targetDisplay
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

    public struct RestoreReport {
        public var restoredCount: Int = 0
        public var skippedMissingCount: Int = 0
        public var details: [String] = []
    }

    /// Restores windows from a `MacSnapshot` across all currently connected displays.
    /// Handles un-fullscreening windows that were fullscreened on a laptop when restoring onto an external monitor,
    /// and re-fullscreening windows that were fullscreened in the target snapshot.
    public static func restore(
        snapshot: MacSnapshot,
        onlyCurrentSpaces: Bool = false,
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

        let liveSpaceMap = SpaceBridge.queryAllDisplaySpaces()

        // Collect all target WindowSnapshotInfo entries to restore
        var targetWindows: [WindowSnapshotInfo] = []
        for disp in snapshot.displays {
            guard liveDisplayFramesByUUID[disp.uuid] != nil else { continue }

            let liveSpacesForDisplay = liveSpaceMap.spacesByDisplayUUID[disp.uuid] ?? []
            let currentLiveSpaceIndex = liveSpacesForDisplay.first(where: { $0.isCurrent })?.index

            for sp in disp.spaces {
                // Skip restoring native fullscreen spaces that were ALREADY fullscreen in the snapshot
                // UNLESS the window inside it is currently NOT fullscreen and needs to be restored
                if onlyCurrentSpaces, let currIdx = currentLiveSpaceIndex, sp.spaceIndex != currIdx {
                    continue
                }
                targetWindows.append(contentsOf: sp.windows)
            }
        }

        // Order target windows so:
        // 1. Non-fullscreen Desktop windows on external monitors (like the 49-inch ultrawide) are matched FIRST!
        // 2. Non-fullscreen Desktop windows on built-in display are matched second.
        // 3. Fullscreen Space windows are matched last (and if already fullscreen, left undisturbed!).
        let builtInUUIDs = Set(snapshot.displays.filter { $0.isBuiltIn }.map { $0.uuid })
        targetWindows.sort { a, b in
            if a.isFullscreen != b.isFullscreen {
                return !a.isFullscreen // Non-fullscreen Desktop windows first!
            }
            let aBuiltIn = builtInUUIDs.contains(a.displayUUID)
            let bBuiltIn = builtInUUIDs.contains(b.displayUUID)
            if aBuiltIn != bBuiltIn {
                return !aBuiltIn // External display windows first!
            }
            return (a.frame.width * a.frame.height) > (b.frame.width * b.frame.height)
        }

        let liveAXWindows = collectLiveAXWindows()
        logger?("Starting restore for topology [\(snapshot.topologyKey)]: \(targetWindows.count) saved windows vs \(liveAXWindows.count) live AX windows.")
        var usedAXWindowIndices: Set<Int> = []

        // First Pass: Match windows that are ALREADY in their exact fullscreen state so they aren't disturbed
        for savedWin in targetWindows where savedWin.isFullscreen {
            if let exactIdx = liveAXWindows.indices.first(where: { idx in
                !usedAXWindowIndices.contains(idx) &&
                liveAXWindows[idx].cgWindowID != 0 &&
                Int(liveAXWindows[idx].cgWindowID) == savedWin.windowNumber &&
                liveAXWindows[idx].isFullscreen
            }) {
                usedAXWindowIndices.insert(exactIdx)
                report.restoredCount += 1
            }
        }

        for savedWin in targetWindows {
            // Skip if already handled in first pass
            if savedWin.isFullscreen,
               liveAXWindows.indices.contains(where: { usedAXWindowIndices.contains($0) && Int(liveAXWindows[$0].cgWindowID) == savedWin.windowNumber }) {
                continue
            }

            let targetRect: CGRect
            if let liveDispFrame = liveDisplayFramesByUUID[savedWin.displayUUID] {
                if liveDispFrame == snapshot.displays.first(where: { $0.uuid == savedWin.displayUUID })?.frame.cgRect {
                    targetRect = savedWin.frame.cgRect
                } else {
                    let rel = savedWin.relativeFrame
                    targetRect = CGRect(
                        x: liveDispFrame.minX + CGFloat(rel.x) * liveDispFrame.width,
                        y: liveDispFrame.minY + CGFloat(rel.y) * liveDispFrame.height,
                        width: CGFloat(rel.width) * liveDispFrame.width,
                        height: CGFloat(rel.height) * liveDispFrame.height
                    )
                }
            } else {
                targetRect = savedWin.frame.cgRect
            }

            if let matchIdx = findBestMatchingLiveWindow(
                for: savedWin,
                targetRect: targetRect,
                among: liveAXWindows,
                excluding: usedAXWindowIndices
            ) {
                usedAXWindowIndices.insert(matchIdx)
                let matched = liveAXWindows[matchIdx]

                // Case A: The snapshot wants this window as a normal Desktop window (e.g. on the 49-inch monitor),
                //         but right now the user had it in macOS native Fullscreen (`matched.isFullscreen == true`) while on Laptop-Only!
                if !savedWin.isFullscreen && matched.isFullscreen {
                    logger?("Un-fullscreening '\(savedWin.ownerName)' (id=\(matched.cgWindowID)) and moving to (\(Int(targetRect.minX)), \(Int(targetRect.minY)), \(Int(targetRect.width))×\(Int(targetRect.height)))")
                    _ = AXUIElementSetAttributeValue(matched.axElement, "AXFullScreen" as CFString, kCFBooleanFalse)
                    let axEl = matched.axElement
                    // Wait for macOS 0.9s fullscreen exit animation to complete, then apply the exact 49-inch frame!
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        _ = setAXWindowFrame(axEl, to: targetRect)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                        _ = setAXWindowFrame(axEl, to: targetRect)
                    }
                    report.restoredCount += 1
                    continue
                }

                // Case B: The snapshot wants this window in native Fullscreen (e.g. restoring Laptop-Only configuration),
                //         and right now it is a normal non-fullscreen window!
                if savedWin.isFullscreen && !matched.isFullscreen {
                    logger?("Restoring '\(savedWin.ownerName)' (id=\(matched.cgWindowID)) into native Fullscreen on target display")
                    // Move onto target display first, then enter fullscreen
                    _ = setAXWindowFrame(matched.axElement, to: targetRect)
                    let axEl = matched.axElement
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        _ = AXUIElementSetAttributeValue(axEl, "AXFullScreen" as CFString, kCFBooleanTrue)
                    }
                    report.restoredCount += 1
                    continue
                }

                // Case C: Standard Desktop window -> move & resize immediately
                let ok = setAXWindowFrame(matched.axElement, to: targetRect)
                if ok {
                    report.restoredCount += 1
                    let msg = "✓ Restored '\(savedWin.ownerName)' (savedID=\(savedWin.windowNumber) -> liveID=\(matched.cgWindowID)) to (\(Int(targetRect.minX)), \(Int(targetRect.minY)), \(Int(targetRect.width))×\(Int(targetRect.height)))"
                    report.details.append(msg)
                    logger?(msg)
                } else {
                    let msg = "✕ AX setFrame failed for '\(savedWin.ownerName)' (liveID=\(matched.cgWindowID))"
                    report.details.append(msg)
                    logger?(msg)
                }
            } else {
                report.skippedMissingCount += 1
                let msg = "○ Skipped missing window '\(savedWin.ownerName)' (savedID=\(savedWin.windowNumber)) — left space empty"
                report.details.append(msg)
                logger?(msg)
            }
        }

        return report
    }

    private struct LiveAXWindow {
        let axElement: AXUIElement
        let cgWindowID: CGWindowID
        let pid: Int32
        let appName: String
        let bundleID: String?
        let title: String
        let frame: CGRect
        let indexInApp: Int
        let isFullscreen: Bool
    }

    private static func collectLiveAXMap() -> [CGWindowID: LiveAXWindow] {
        guard isAccessibilityTrusted(prompt: false) else { return [:] }
        var map: [CGWindowID: LiveAXWindow] = [:]
        for w in collectLiveAXWindows() where w.cgWindowID != 0 {
            map[w.cgWindowID] = w
        }
        return map
    }

    private static func collectLiveAXWindows() -> [LiveAXWindow] {
        var results: [LiveAXWindow] = []
        let myPID = ProcessInfo.processInfo.processIdentifier

        // Build a lookup of all live CGWindowIDs from CGWindowListCopyWindowInfo (which sees across ALL Spaces!)
        var cgWindowMeta: [CGWindowID: (pid: Int32, ownerName: String, bounds: CGRect, spaceIDs: [UInt64])] = [:]
        if let winList = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for w in winList {
                guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
                      let wid = w[kCGWindowNumber as String] as? UInt32,
                      let pid = w[kCGWindowOwnerPID as String] as? Int32,
                      let owner = w[kCGWindowOwnerName as String] as? String,
                      let b = w[kCGWindowBounds as String] as? [String: Any],
                      let x = b["X"] as? Double, let y = b["Y"] as? Double,
                      let width = b["Width"] as? Double, let height = b["Height"] as? Double,
                      width >= 220, height >= 180 else { continue }
                let spaces = SpaceBridge.spaceIDs(forWindowID: wid)
                cgWindowMeta[wid] = (pid, owner, CGRect(x: x, y: y, width: width, height: height), spaces)
            }
        }

        let spaceMap = SpaceBridge.queryAllDisplaySpaces()

        for app in NSWorkspace.shared.runningApplications {
            let pid = app.processIdentifier
            guard pid != myPID, app.activationPolicy == .regular else { continue }

            let appAX = AXUIElementCreateApplication(pid)
            // Wake up Electron/Chromium accessibility tree so Claude and Chrome return their windows in kAXWindowsAttribute!
            _ = AXUIElementSetAttributeValue(appAX, "AXManualAccessibility" as CFString, kCFBooleanTrue)

            var windowsRef: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(appAX, kAXWindowsAttribute as CFString, &windowsRef)
            var axWindows = (err == .success ? (windowsRef as? [AXUIElement]) : nil) ?? []

            // Also include kAXMainWindowAttribute and kAXFocusedWindowAttribute in case kAXWindowsAttribute omitted them
            var mainWinRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(appAX, kAXMainWindowAttribute as CFString, &mainWinRef) == .success,
               let mainWin = mainWinRef {
                axWindows.append(mainWin as! AXUIElement)
            }

            let appName = app.localizedName ?? ""
            let bundleID = app.bundleIdentifier
            var seenWinIDs: Set<CGWindowID> = []

            for (idx, winAX) in axWindows.enumerated() {
                var winID: CGWindowID = 0
                _ = _AXUIElementGetWindow(winAX, &winID)
                if winID != 0 {
                    if seenWinIDs.contains(winID) { continue }
                    seenWinIDs.insert(winID)
                }

                var subroleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(winAX, kAXSubroleAttribute as CFString, &subroleRef)
                if let subrole = subroleRef as? String,
                   subrole != (kAXStandardWindowSubrole as String) && subrole != "AXDialog" {
                    continue
                }

                var minRef: CFTypeRef?
                AXUIElementCopyAttributeValue(winAX, kAXMinimizedAttribute as CFString, &minRef)
                if let isMin = minRef as? Bool, isMin {
                    continue
                }

                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(winAX, kAXTitleAttribute as CFString, &titleRef)
                let title = (titleRef as? String) ?? ""

                var fsRef: CFTypeRef?
                AXUIElementCopyAttributeValue(winAX, "AXFullScreen" as CFString, &fsRef)
                var isFS = (fsRef as? Bool) ?? false
                if let cgMeta = cgWindowMeta[winID],
                   let firstSpace = cgMeta.spaceIDs.first,
                   spaceMap.spaceInfoByID[firstSpace]?.isFullscreen == true {
                    isFS = true
                }

                var posRef: CFTypeRef?
                var sizeRef: CFTypeRef?
                AXUIElementCopyAttributeValue(winAX, kAXPositionAttribute as CFString, &posRef)
                AXUIElementCopyAttributeValue(winAX, kAXSizeAttribute as CFString, &sizeRef)
                var pt = CGPoint.zero
                var sz = CGSize.zero
                if let p = posRef { AXValueGetValue(p as! AXValue, .cgPoint, &pt) }
                if let s = sizeRef { AXValueGetValue(s as! AXValue, .cgSize, &sz) }

                results.append(LiveAXWindow(
                    axElement: winAX,
                    cgWindowID: winID,
                    pid: pid,
                    appName: appName,
                    bundleID: bundleID,
                    title: title,
                    frame: CGRect(origin: pt, size: sz),
                    indexInApp: idx,
                    isFullscreen: isFS
                ))
            }
        }

        return results
    }

    /// Finds the best matching currently open window for a saved `WindowSnapshotInfo`.
    /// Returns `nil` if the window/app is no longer open so its space stays empty.
    private static func findBestMatchingLiveWindow(
        for saved: WindowSnapshotInfo,
        targetRect: CGRect,
        among candidates: [LiveAXWindow],
        excluding used: Set<Int>
    ) -> Int? {
        // 1. Exact CGWindowID match (works even if the window was fullscreened or un-fullscreened across configurations!)
        if saved.windowNumber > 0 {
            for (i, cand) in candidates.enumerated() where !used.contains(i) {
                if cand.cgWindowID != 0 && Int(cand.cgWindowID) == saved.windowNumber {
                    return i
                }
            }
        }

        // Filter candidates belonging to the same app (by bundleIdentifier or ownerName)
        let allSameAppIndices = candidates.indices.filter { i in
            guard !used.contains(i) else { return false }
            let c = candidates[i]
            if let sBid = saved.bundleIdentifier, let cBid = c.bundleID, !sBid.isEmpty {
                return sBid == cBid
            }
            return c.appName.caseInsensitiveCompare(saved.ownerName) == .orderedSame
        }

        guard !allSameAppIndices.isEmpty else {
            return nil
        }

        // Prefer candidates with matching fullscreen state first, falling back to any candidate of the same app
        // (e.g., if Claude was fullscreened while on Laptop-Only, we STILL want to match it so we can un-fullscreen it onto the 49" monitor!)
        let preferredIndices = allSameAppIndices.filter { candidates[$0].isFullscreen == saved.isFullscreen }
        let searchPool = preferredIndices.isEmpty ? allSameAppIndices : preferredIndices

        // 2. Exact window title match within searchPool
        if !saved.windowTitle.isEmpty {
            if let exactTitleIdx = searchPool.first(where: {
                candidates[$0].title.caseInsensitiveCompare(saved.windowTitle) == .orderedSame
            }) {
                return exactTitleIdx
            }

            // 3. Substring / keyword match
            if let partialIdx = searchPool.first(where: {
                let liveTitle = candidates[$0].title
                guard !liveTitle.isEmpty else { return false }
                return liveTitle.localizedCaseInsensitiveContains(saved.windowTitle)
                    || saved.windowTitle.localizedCaseInsensitiveContains(liveTitle)
            }) {
                return partialIdx
            }
        }

        // 4. Closest frame / size similarity among remaining windows of the same app
        let sortedBySimilarity = searchPool.sorted { a, b in
            let fa = candidates[a].frame
            let fb = candidates[b].frame
            let distA = hypot(fa.midX - targetRect.midX, fa.midY - targetRect.midY)
                + hypot(fa.width - targetRect.width, fa.height - targetRect.height)
            let distB = hypot(fb.midX - targetRect.midX, fb.midY - targetRect.midY)
                + hypot(fb.width - targetRect.width, fb.height - targetRect.height)
            return distA < distB
        }

        return sortedBySimilarity.first
    }

    /// Uses macOS Accessibility (`AXUIElement`) to move and resize a window to `rect`.
    @discardableResult
    private static func setAXWindowFrame(_ axWindow: AXUIElement, to rect: CGRect) -> Bool {
        var pt = CGPoint(x: rect.origin.x, y: rect.origin.y)
        var sz = CGSize(width: rect.size.width, height: rect.size.height)

        guard let posVal = AXValueCreate(.cgPoint, &pt),
              let sizeVal = AXValueCreate(.cgSize, &sz) else {
            return false
        }

        // Step 1: Set AXManualAccessibility on the parent app so Electron (Claude) & Chromium (Chrome)
        // expose all windows to AXUIElement, and disable AXEnhancedUserInterface to avoid width clamping.
        var pid: pid_t = 0
        AXUIElementGetPid(axWindow, &pid)
        let appAX = pid != 0 ? AXUIElementCreateApplication(pid) : nil
        if let appAX = appAX {
            _ = AXUIElementSetAttributeValue(appAX, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            _ = AXUIElementSetAttributeValue(appAX, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
        }

        _ = AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, posVal)
        let sizeErr1 = AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeVal)
        let posErr2 = AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, posVal)
        let sizeErr2 = AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeVal)

        return (posErr2 == .success || sizeErr1 == .success || sizeErr2 == .success)
    }
}
