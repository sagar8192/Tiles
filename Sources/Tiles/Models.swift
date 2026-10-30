import Foundation
import CoreGraphics

/// Represents a physical or built-in display captured during a snapshot.
public struct DisplaySnapshotInfo: Codable, Identifiable, Equatable {
    public var id: String { uuid }
    public let uuid: String
    public let cgDisplayID: UInt32
    public let systemName: String
    public var customName: String
    public let isBuiltIn: Bool
    public let frame: CGRectCodable
    public var spaces: [SpaceSnapshotInfo]

    public init(
        uuid: String,
        cgDisplayID: UInt32,
        systemName: String,
        customName: String,
        isBuiltIn: Bool,
        frame: CGRectCodable,
        spaces: [SpaceSnapshotInfo]
    ) {
        self.uuid = uuid
        self.cgDisplayID = cgDisplayID
        self.systemName = systemName
        self.customName = customName
        self.isBuiltIn = isBuiltIn
        self.frame = frame
        self.spaces = spaces
    }
}

/// Represents a macOS Desktop (Space) belonging to a specific Display.
public struct SpaceSnapshotInfo: Codable, Identifiable, Equatable {
    public var id: UInt64 { spaceID }
    public let spaceID: UInt64
    public let spaceIndex: Int // 1-based Desktop number on this display (e.g. Desktop 1, Desktop 2)
    public let isCurrentSpace: Bool
    public let isFullscreenSpace: Bool
    public var windows: [WindowSnapshotInfo]

    public init(
        spaceID: UInt64,
        spaceIndex: Int,
        isCurrentSpace: Bool,
        isFullscreenSpace: Bool = false,
        windows: [WindowSnapshotInfo]
    ) {
        self.spaceID = spaceID
        self.spaceIndex = spaceIndex
        self.isCurrentSpace = isCurrentSpace
        self.isFullscreenSpace = isFullscreenSpace
        self.windows = windows
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.spaceID = try container.decode(UInt64.self, forKey: .spaceID)
        self.spaceIndex = try container.decode(Int.self, forKey: .spaceIndex)
        self.isCurrentSpace = try container.decode(Bool.self, forKey: .isCurrentSpace)
        self.isFullscreenSpace = (try? container.decode(Bool.self, forKey: .isFullscreenSpace)) ?? false
        self.windows = try container.decode([WindowSnapshotInfo].self, forKey: .windows)
    }
}

/// Represents an individual window's exact coordinates and identity at snapshot time.
public struct WindowSnapshotInfo: Codable, Identifiable, Equatable {
    public var id: String { "\(bundleIdentifier ?? ownerName)-\(windowNumber)" }
    public let windowNumber: Int
    public let ownerPID: Int32
    public let ownerName: String
    public let bundleIdentifier: String?
    public let windowTitle: String
    public let windowIndexInApp: Int
    public let frame: CGRectCodable // Global Quartz coordinates (origin top-left of primary screen)
    public let relativeFrame: CGRectCodable // Normalized 0.0...1.0 relative to its display frame
    public let displayUUID: String
    public let spaceID: UInt64
    public let spaceIndex: Int
    public let isFullscreen: Bool

    public var appKey: String {
        ((bundleIdentifier?.isEmpty == false) ? bundleIdentifier! : ownerName).lowercased()
    }

    public init(
        windowNumber: Int,
        ownerPID: Int32,
        ownerName: String,
        bundleIdentifier: String?,
        windowTitle: String,
        windowIndexInApp: Int,
        frame: CGRectCodable,
        relativeFrame: CGRectCodable,
        displayUUID: String,
        spaceID: UInt64,
        spaceIndex: Int,
        isFullscreen: Bool = false
    ) {
        self.windowNumber = windowNumber
        self.ownerPID = ownerPID
        self.ownerName = ownerName
        self.bundleIdentifier = bundleIdentifier
        self.windowTitle = windowTitle
        self.windowIndexInApp = windowIndexInApp
        self.frame = frame
        self.relativeFrame = relativeFrame
        self.displayUUID = displayUUID
        self.spaceID = spaceID
        self.spaceIndex = spaceIndex
        self.isFullscreen = isFullscreen
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.windowNumber = try container.decode(Int.self, forKey: .windowNumber)
        self.ownerPID = try container.decode(Int32.self, forKey: .ownerPID)
        self.ownerName = try container.decode(String.self, forKey: .ownerName)
        self.bundleIdentifier = try? container.decode(String.self, forKey: .bundleIdentifier)
        self.windowTitle = try container.decode(String.self, forKey: .windowTitle)
        self.windowIndexInApp = try container.decode(Int.self, forKey: .windowIndexInApp)
        self.frame = try container.decode(CGRectCodable.self, forKey: .frame)
        self.relativeFrame = try container.decode(CGRectCodable.self, forKey: .relativeFrame)
        self.displayUUID = try container.decode(String.self, forKey: .displayUUID)
        self.spaceID = try container.decode(UInt64.self, forKey: .spaceID)
        self.spaceIndex = try container.decode(Int.self, forKey: .spaceIndex)
        self.isFullscreen = (try? container.decode(Bool.self, forKey: .isFullscreen)) ?? false
    }
}

/// Codable wrapper around CGRect for clean JSON serialization.
public struct CGRectCodable: Codable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(_ rect: CGRect) {
        self.x = Double(rect.origin.x)
        self.y = Double(rect.origin.y)
        self.width = Double(rect.size.width)
        self.height = Double(rect.size.height)
    }

    public var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

/// Identifies a specific Desktop (Space) on a specific Display by 1-based index.
public struct SpaceRef: Hashable, Codable, Equatable, Sendable {
    public var displayUUID: String
    public var spaceIndex: Int

    public init(displayUUID: String, spaceIndex: Int) {
        self.displayUUID = displayUUID
        self.spaceIndex = spaceIndex
    }
}

/// A complete Mac-wide snapshot taken at a point in time across all displays and desktops.
public struct MacSnapshot: Codable, Identifiable, Equatable {
    public let id: String
    public let capturedAt: Date
    public let topologyKey: String
    public var displays: [DisplaySnapshotInfo]
    public var isManual: Bool

    public init(
        id: String = UUID().uuidString,
        capturedAt: Date = Date(),
        topologyKey: String,
        displays: [DisplaySnapshotInfo],
        isManual: Bool = false
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.topologyKey = topologyKey
        self.displays = displays
        self.isManual = isManual
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.capturedAt = try container.decode(Date.self, forKey: .capturedAt)
        self.topologyKey = try container.decode(String.self, forKey: .topologyKey)
        self.displays = try container.decode([DisplaySnapshotInfo].self, forKey: .displays)
        self.isManual = (try? container.decode(Bool.self, forKey: .isManual)) ?? false
    }

    public var totalDesktopCount: Int {
        displays.reduce(0) { $0 + $1.spaces.count }
    }

    public var totalWindowCount: Int {
        displays.reduce(0) { acc, disp in
            acc + disp.spaces.reduce(0) { $0 + $1.windows.count }
        }
    }

    /// Same apps with windows in the same places, ignoring sub-4 pt jitter and window IDs.
    public func isEquivalent(to other: MacSnapshot) -> Bool {
        topologyKey == other.topologyKey && fingerprint == other.fingerprint
    }

    public var fingerprint: [String] {
        displays.flatMap { $0.spaces.flatMap(\.windows) }.map { w in
            let q = { (v: Double) in Int((v / 4).rounded()) }
            return "\(w.appKey)|\(w.windowTitle)|\(w.displayUUID)|\(w.spaceIndex)|\(w.isFullscreen)|\(q(w.frame.x)),\(q(w.frame.y)),\(q(w.frame.width)),\(q(w.frame.height))"
        }.sorted()
    }

    /// This snapshot with `intended` windows recorded at their intended positions instead of
    /// wherever they are now. Windows a restore has not placed yet keep the position from the
    /// layout being restored, so a half-finished restore never overwrites the good layout.
    public func keeping(intended: [WindowSnapshotInfo]) -> MacSnapshot {
        guard !intended.isEmpty else { return self }
        let ids = Set(intended.map(\.windowNumber))
        var copy = self
        for d in copy.displays.indices {
            for s in copy.displays[d].spaces.indices {
                copy.displays[d].spaces[s].windows.removeAll { ids.contains($0.windowNumber) }
            }
        }
        for w in intended {
            guard let d = copy.displays.firstIndex(where: { $0.uuid == w.displayUUID }),
                  !copy.displays[d].spaces.isEmpty else { continue }
            let s = copy.displays[d].spaces.firstIndex(where: { $0.spaceIndex == w.spaceIndex }) ?? 0
            copy.displays[d].spaces[s].windows.append(w)
        }
        return copy
    }
}
