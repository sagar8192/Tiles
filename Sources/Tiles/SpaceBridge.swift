import Foundation
import CoreGraphics

// MARK: - Private SkyLight / CoreGraphics Space Declarations
// Used by macOS window managers (Yabai, Rectangle, Amethyst, AltTab) to inspect all Spaces
// across all connected displays and find which Space a CGWindowID lives on.

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> Int32

@_silgen_name("CGSCopyManagedDisplaySpaces")
func CGSCopyManagedDisplaySpaces(_ cid: Int32) -> CFArray?

@_silgen_name("CGSCopySpacesForWindows")
func CGSCopySpacesForWindows(_ cid: Int32, _ mask: Int32, _ windowIDs: CFArray) -> CFArray?

public struct DisplaySpacesMap {
    public struct SpaceEntry {
        public let spaceID: UInt64
        public let index: Int // 1-based index on that display
        public let isCurrent: Bool
        public let isFullscreen: Bool
    }

    /// Maps Display UUID String -> ordered list of Spaces on that display
    public var spacesByDisplayUUID: [String: [SpaceEntry]] = [:]
    /// Maps SpaceID -> (Display UUID, 1-based Space Index, isCurrent, isFullscreen)
    public var spaceInfoByID: [UInt64: (displayUUID: String, index: Int, isCurrent: Bool, isFullscreen: Bool)] = [:]
}

public enum SpaceBridge {
    private static let kCGSSpaceAll: Int32 = 7

    /// Queries macOS SkyLight for all Displays and their ordered Desktops (Spaces).
    public static func queryAllDisplaySpaces() -> DisplaySpacesMap {
        var result = DisplaySpacesMap()
        let cid = CGSMainConnectionID()
        guard cid != 0,
              let rawArray = CGSCopyManagedDisplaySpaces(cid) as? [[String: Any]] else {
            return result
        }

        for displayDict in rawArray {
            guard let displayIDStr = displayDict["Display Identifier"] as? String else { continue }
            let currentSpaceDict = displayDict["Current Space"] as? [String: Any]
            let currentSpaceID = (currentSpaceDict?["id64"] as? UInt64)
                ?? (currentSpaceDict?["ManagedSpaceID"] as? UInt64)
                ?? 0

            guard let spacesList = displayDict["Spaces"] as? [[String: Any]] else { continue }

            var entries: [DisplaySpacesMap.SpaceEntry] = []
            var userSpaceCounter = 1

            for sp in spacesList {
                // Type 0 is a standard user Desktop Space.
                // Type 4 is a macOS Native Fullscreen Space.
                let spaceType = (sp["type"] as? Int) ?? 0
                let spaceID = (sp["id64"] as? UInt64)
                    ?? (sp["ManagedSpaceID"] as? UInt64)
                    ?? 0
                guard spaceID != 0 else { continue }

                if spaceType == 0 || spaceType == 4 {
                    let isCurr = (spaceID == currentSpaceID)
                    let isFS = (spaceType == 4)
                    let entry = DisplaySpacesMap.SpaceEntry(
                        spaceID: spaceID,
                        index: userSpaceCounter,
                        isCurrent: isCurr,
                        isFullscreen: isFS
                    )
                    entries.append(entry)
                    result.spaceInfoByID[spaceID] = (displayIDStr, userSpaceCounter, isCurr, isFS)
                    userSpaceCounter += 1
                }
            }

            result.spacesByDisplayUUID[displayIDStr] = entries
        }

        return result
    }

    /// Returns the Space IDs that a given `CGWindowID` belongs to (works even for windows on inactive Desktops!).
    public static func spaceIDs(forWindowID windowID: UInt32) -> [UInt64] {
        let cid = CGSMainConnectionID()
        guard cid != 0 else { return [] }
        let winArray = [NSNumber(value: windowID)] as CFArray
        guard let spaces = CGSCopySpacesForWindows(cid, kCGSSpaceAll, winArray) as? [NSNumber] else {
            return []
        }
        return spaces.map { $0.uint64Value }
    }
}
