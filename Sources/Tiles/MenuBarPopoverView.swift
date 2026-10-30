import SwiftUI
import AppKit

public struct MenuBarPopoverView: View {
    @ObservedObject var coordinator: TilesCoordinator
    @Environment(\.openWindow) private var openWindow

    public init(coordinator: TilesCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header Bar
            popoverHeader

            Divider()
                .overlay(Color.white.opacity(0.08))

            // Primary Command Actions
            VStack(spacing: 6) {
                // Primary Action: Restore Default / Latest
                primaryRestoreCard

                // Secondary Action: Manual Capture
                manualCaptureCard
            }
            .padding(10)

            Divider()
                .overlay(Color.white.opacity(0.08))

            // Recent Snapshots List
            recentSnapshotsSection
                .padding(.horizontal, 10)
                .padding(.vertical, 8)

            Divider()
                .overlay(Color.white.opacity(0.08))

            // Footer Bar
            popoverFooter
        }
        .frame(width: 340)
        .background(Color(red: 0.09, green: 0.10, blue: 0.12))
    }

    // MARK: - Header Bar

    private var popoverHeader: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "macwindow.on.rectangle")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.indigo)
                Text("Tiles Command")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.primary)
            }

            Spacer()

            // Current Topology Badge
            Text(currentTopologyShortBadge)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2.5)
                .background(Color.white.opacity(0.07))
                .foregroundStyle(Color.primary.opacity(0.8))
                .clipShape(RoundedRectangle(cornerRadius: 4))

            Circle()
                .fill(coordinator.isAutoSnapshotEnabled ? Color.green : Color.orange)
                .frame(width: 6, height: 6)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(red: 0.11, green: 0.12, blue: 0.14))
    }

    private var currentTopologyShortBadge: String {
        let setup = coordinator.setupInfo(for: coordinator.currentTopologyKey)
        if setup.title.contains("49\"") {
            return "49\" + RETINA"
        } else if setup.title.contains("Internal") {
            return "BUILT-IN"
        }
        return setup.title.uppercased()
    }

    // MARK: - Primary Action Cards

    private var primaryRestoreCard: some View {
        let preferred = coordinator.store.preferredRestoreSnapshot(forTopology: coordinator.currentTopologyKey)
        let isPin = preferred.map { coordinator.isPinned($0) } ?? false

        return Button {
            coordinator.restoreSnapshot(nil)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Image(systemName: isPin ? "pin.fill" : "bolt.horizontal.circle.fill")
                            .font(.system(size: 11))
                        Text(isPin ? "Restore Pinned Default" : "Restore Latest Layout")
                            .font(.system(size: 12, weight: .bold))
                    }

                    if let snap = preferred {
                        let setup = coordinator.setupInfo(for: snap.topologyKey)
                        Text("\(setup.title) • \(snap.totalWindowCount) win")
                            .font(.system(size: 10, design: .monospaced))
                            .opacity(0.85)
                    } else {
                        Text("No snapshot recorded yet")
                            .font(.system(size: 10))
                            .opacity(0.7)
                    }
                }

                Spacer()

                Text("↵")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.18))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.indigo)
            .foregroundStyle(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: Color.indigo.opacity(0.3), radius: 4, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }

    private var manualCaptureCard: some View {
        Button {
            coordinator.takeSnapshotNow(isManual: true, reason: "Manual popover capture")
        } label: {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                    Text("Capture Manual Snapshot")
                        .font(.system(size: 11, weight: .medium))
                }

                Spacer()

                Text("⌘S")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.08))
                    .foregroundStyle(Color.secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.04))
            .foregroundStyle(Color.primary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Recent Snapshots

    private var recentSnapshotsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("RECENT LAYOUTS")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.secondary)
                Spacer()
                Text("\(coordinator.recentSnapshots.count) saved")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Color.secondary.opacity(0.8))
            }

            if coordinator.recentSnapshots.isEmpty {
                Text("No snapshots recorded yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondary)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 4) {
                    ForEach(Array(coordinator.recentSnapshots.prefix(5).enumerated()), id: \.element.id) { idx, snap in
                        recentSnapshotRow(index: idx, snap: snap)
                    }
                }
            }
        }
    }

    private func recentSnapshotRow(index: Int, snap: MacSnapshot) -> some View {
        let isPin = coordinator.isPinned(snap)
        let topApps = coordinator.topApps(for: snap, limit: 2)
        let shortcut = index < 9 ? "⌘\(index + 1)" : nil

        return Button {
            coordinator.restoreSnapshot(snap)
        } label: {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    if isPin {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(Color.orange)
                    }
                    Text(Self.timeFormatter.string(from: snap.capturedAt))
                        .font(.system(size: 11, weight: isPin ? .bold : .medium))
                        .foregroundStyle(isPin ? Color.orange : Color.primary)
                }

                if !topApps.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(topApps, id: \.self) { appName in
                            let pal = BentoPalette.colorForApp(appName)
                            Text(appName)
                                .font(.system(size: 8, weight: .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(pal.background)
                                .foregroundStyle(pal.text)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                                .lineLimit(1)
                        }
                    }
                }

                Spacer()

                Text("\(snap.totalWindowCount) win")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Color.secondary)

                if let sc = shortcut {
                    Text(sc)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1.5)
                        .background(Color.white.opacity(0.08))
                        .foregroundStyle(Color.secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Restore Layout") {
                coordinator.restoreSnapshot(snap)
            }
            if isPin {
                Button("Unpin") {
                    coordinator.unpinSnapshot(snap)
                }
            } else {
                Button("Pin as Default") {
                    coordinator.pinSnapshot(snap)
                }
            }
            Divider()
            Button("Delete Snapshot", role: .destructive) {
                coordinator.deleteSnapshot(snap)
            }
        }
    }

    // MARK: - Footer Bar

    private var popoverFooter: some View {
        HStack {
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 5, height: 5)
                Text("Daemon: Active (\(coordinator.snapshotIntervalSeconds)s)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Color.secondary)
            }

            Spacer()

            Button {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "dashboard")
            } label: {
                HStack(spacing: 3) {
                    Text("Dashboard")
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9))
                }
                .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.indigo)

            Text("•")
                .font(.system(size: 8))
                .foregroundStyle(Color.secondary.opacity(0.5))

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.system(size: 10))
            .foregroundStyle(Color.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(red: 0.08, green: 0.08, blue: 0.10))
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
}
