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

/// A complete Mac-wide snapshot taken at a point in time across all displays and desktops.
public struct MacSnapshot: Codable, Identifiable, Equatable {
    public let id: String
    public let capturedAt: Date
    public let topologyKey: String
    public var displays: [DisplaySnapshotInfo]

    public init(
        id: String = UUID().uuidString,
        capturedAt: Date = Date(),
        topologyKey: String,
        displays: [DisplaySnapshotInfo]
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.topologyKey = topologyKey
        self.displays = displays
    }

    public var totalDesktopCount: Int {
        displays.reduce(0) { $0 + $1.spaces.count }
    }

    public var totalWindowCount: Int {
        displays.reduce(0) { acc, disp in
            acc + disp.spaces.reduce(0) { $0 + $1.windows.count }
        }
    }
}
