import Foundation
import AppKit
import CoreGraphics

public enum DisplayHelper {
    /// Returns a persistent hardware UUID string for a CGDirectDisplayID.
    public static func displayUUID(for displayID: CGDirectDisplayID) -> String {
        if let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
           let str = CFUUIDCreateString(nil, cfUUID) as String? {
            return str
        }
        // Fallback using vendor + model + serial +builtin flag
        let vendor = CGDisplayVendorNumber(displayID)
        let model = CGDisplayModelNumber(displayID)
        let serial = CGDisplaySerialNumber(displayID)
        let builtin = CGDisplayIsBuiltin(displayID)
        return "DISP-\(vendor)-\(model)-\(serial)-\(builtin)"
    }

    /// Returns all currently active displays in Quartz global coordinate space (origin at top-left of main display).
    public static func currentConnectedDisplays(customNames: [String: String]) -> [(
        uuid: String,
        cgDisplayID: CGDirectDisplayID,
        systemName: String,
        customName: String,
        isBuiltIn: Bool,
        quartzFrame: CGRect
    )] {
        var result: [(String, CGDirectDisplayID, String, String, Bool, CGRect)] = []

        for screen in NSScreen.screens {
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }
            let displayID = CGDirectDisplayID(screenNumber.uint32Value)
            let uuid = displayUUID(for: displayID)
            let isBuiltIn = CGDisplayIsBuiltin(displayID) != 0
            let bounds = CGDisplayBounds(displayID) // Already in Quartz global top-left coordinates!
            let sysName = screen.localizedName
            let friendlyName = customNames[uuid]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalCustomName = (friendlyName?.isEmpty == false) ? friendlyName! : sysName

            result.append((
                uuid: uuid,
                cgDisplayID: displayID,
                systemName: sysName,
                customName: finalCustomName,
                isBuiltIn: isBuiltIn,
                quartzFrame: bounds
            ))
        }

        // Sort consistently: external ultrawides/monitors first or by UUID for deterministic topology keys
        return result.sorted { $0.0 < $1.0 }
    }

    /// Generates a deterministic topology key representing the exact set of currently connected monitors.
    public static func currentTopologyKey(customNames: [String: String] = [:]) -> String {
        let displays = currentConnectedDisplays(customNames: customNames)
        if displays.isEmpty { return "headless" }
        return displays.map { $0.uuid }.sorted().joined(separator: "__")
    }
}
