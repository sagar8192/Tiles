import SwiftUI
import AppKit

public struct MenuBarPopoverView: View {
    @ObservedObject var coordinator: TilesCoordinator
    @Environment(\.openWindow) private var openWindow

    public init(coordinator: TilesCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerSection
            Divider()
            displaysSection
            Divider()
            snapshotsSection
            Divider()
            footerSection
        }
        .padding(14)
        .frame(width: 360)
    }

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "macwindow.on.rectangle")
                        .foregroundStyle(.indigo)
                    Text("Tiles")
                        .font(.headline)
                    Text("• All-Display Snapshot Daemon")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(coordinator.lastStatusMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            HStack(spacing: 4) {
                Circle()
                    .fill(coordinator.isAutoSnapshotEnabled ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(coordinator.isAutoSnapshotEnabled ? "\(coordinator.secondsUntilNextSnapshot)s" : "Paused")
                    .font(.caption.monospacedDigit())
                    .fontWeight(.semibold)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.06))
            .clipShape(Capsule())
        }
    }

    private var displaysSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("ACTIVE CONFIGURATION")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(coordinator.connectedDisplays.count) display(s)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(coordinator.friendlyName(forTopologyKey: coordinator.currentTopologyKey))
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(Color.indigo)
                .lineLimit(1)

            ForEach(coordinator.connectedDisplays, id: \.uuid) { disp in
                HStack(spacing: 8) {
                    Image(systemName: disp.isBuiltIn ? "laptopcomputer" : "display")
                        .foregroundStyle(disp.isBuiltIn ? Color.secondary : Color.indigo)
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(disp.customName)
                            .font(.caption)
                            .fontWeight(.medium)
                        Text("\(Int(disp.quartzFrame.width))×\(Int(disp.quartzFrame.height)) • \(disp.isBuiltIn ? "Internal" : "External")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var snapshotsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("RECENT SNAPSHOTS (\(coordinator.recentSnapshots.count)/10)")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Snap Now") {
                    coordinator.takeSnapshotNow(reason: "Manual snapshot")
                }
                .buttonStyle(.borderless)
                .font(.caption2)
            }

            if coordinator.recentSnapshots.isEmpty {
                Text("No snapshots recorded yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(Array(coordinator.recentSnapshots.enumerated()), id: \.element.id) { idx, snap in
                            HStack {
                                Text("#\(idx + 1)")
                                    .font(.caption2.monospacedDigit())
                                    .fontWeight(.bold)
                                    .foregroundStyle(idx == 0 ? Color.green : Color.secondary)
                                    .frame(width: 24, alignment: .leading)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(Self.timeFormatter.string(from: snap.capturedAt))
                                        .font(.caption)
                                        .fontWeight(idx == 0 ? .semibold : .regular)
                                    Text("\(snap.displays.count) displays • \(snap.totalDesktopCount) desktops • \(snap.totalWindowCount) windows")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(idx == 0 ? "Restore Latest" : "Restore") {
                                    coordinator.restoreSnapshot(snap)
                                }
                                .controlSize(.mini)
                                .buttonStyle(.bordered)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(idx == 0 ? Color.indigo.opacity(0.12) : Color.primary.opacity(0.03))
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                        }
                    }
                }
                .frame(maxHeight: 190)
            }
        }
    }

    private var footerSection: some View {
        VStack(spacing: 8) {
            if !coordinator.isAccessibilityGranted {
                Button {
                    coordinator.checkAccessibility(prompt: true)
                } label: {
                    Label("Grant Accessibility Permission to Move Windows", systemImage: "exclamationmark.shield.fill")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }

            HStack {
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "dashboard")
                } label: {
                    Label("Open Snapshot Map & Display Names…", systemImage: "rectangle.3.group")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()
}
