import Foundation
import CoreGraphics
import Darwin

// MARK: - Private SkyLight / CoreGraphics Space Declarations (Runtime Loaded via dlsym)
// Loaded dynamically so Tiles degrades gracefully rather than crashing at launch if a future macOS removes a symbol.

private func privateSymbol<T>(_ name: String, as _: T.Type) -> T? {
    guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil } // RTLD_DEFAULT
    return unsafeBitCast(p, to: T.self)
}

private typealias MainConnectionFn = @convention(c) () -> Int32
private typealias CopyDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
private typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

public struct DisplaySpacesMap {
    public struct SpaceEntry {
        public let spaceID: UInt64
        public let index: Int // 1-based index on that display
        public let isCurrent: Bool
        public let isFullscreen: Bool

        public init(spaceID: UInt64, index: Int, isCurrent: Bool, isFullscreen: Bool) {
            self.spaceID = spaceID
            self.index = index
            self.isCurrent = isCurrent
            self.isFullscreen = isFullscreen
        }
    }

    /// Maps Display UUID String -> ordered list of Spaces on that display
    public var spacesByDisplayUUID: [String: [SpaceEntry]] = [:]
    /// Maps SpaceID -> (Display UUID, 1-based Space Index, isCurrent, isFullscreen)
    public var spaceInfoByID: [UInt64: (displayUUID: String, index: Int, isCurrent: Bool, isFullscreen: Bool)] = [:]

    public init() {}
}

public enum SpaceBridge {
    private static let kCGSSpaceAll: Int32 = 7
    private static let mainConnectionIDFn = privateSymbol("CGSMainConnectionID", as: MainConnectionFn.self)
    private static let copyManagedDisplaySpacesFn = privateSymbol("CGSCopyManagedDisplaySpaces", as: CopyDisplaySpacesFn.self)
    private static let copySpacesForWindowsFn = privateSymbol("CGSCopySpacesForWindows", as: CopySpacesForWindowsFn.self)

    public static var isAvailable: Bool {
        guard let mainConn = mainConnectionIDFn,
              copyManagedDisplaySpacesFn != nil,
              copySpacesForWindowsFn != nil else {
            return false
        }
        return mainConn() != 0
    }

    /// Queries macOS SkyLight for all Displays and their ordered Desktops (Spaces).
    public static func queryAllDisplaySpaces() -> DisplaySpacesMap {
        var result = DisplaySpacesMap()
        guard let mainConn = mainConnectionIDFn,
              let copyDisplaySpaces = copyManagedDisplaySpacesFn else {
            return result
        }
        let cid = mainConn()
        guard cid != 0,
              let cfArr = copyDisplaySpaces(cid)?.takeRetainedValue(),
              let rawArray = cfArr as? [[String: Any]] else {
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
        guard let mainConn = mainConnectionIDFn,
              let copySpaces = copySpacesForWindowsFn else {
            return []
        }
        let cid = mainConn()
        guard cid != 0 else { return [] }
        let winArray = [NSNumber(value: windowID)] as CFArray
        guard let cfSpaces = copySpaces(cid, kCGSSpaceAll, winArray)?.takeRetainedValue(),
              let spaces = cfSpaces as? [NSNumber] else {
            return []
        }
        return spaces.map { $0.uint64Value }
    }
}
