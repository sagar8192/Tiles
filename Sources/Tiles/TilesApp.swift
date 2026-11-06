import SwiftUI
import AppKit

@main
struct TilesApp: App {
    @StateObject private var coordinator = TilesCoordinator()

    var body: some Scene {
        // 1. Always-On Menu Bar Extra for background daemon & quick restore
        MenuBarExtra {
            MenuBarPopoverView(coordinator: coordinator)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "macwindow.on.rectangle")
                Text("Tiles")
            }
        }
        .menuBarExtraStyle(.window)

        // 2. Primary Window: Multi-Display & Multi-Desktop Snapshot Map (opened on demand from Menu Bar)
        WindowGroup("Tiles — All-Display & Desktop Snapshot Manager", id: "dashboard") {
            DashboardWindowView(coordinator: coordinator)
        }
        .defaultSize(width: 1080, height: 700)
    }
}
