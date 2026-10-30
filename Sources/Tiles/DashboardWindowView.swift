import SwiftUI
import AppKit

public struct DashboardWindowView: View {
    @ObservedObject var coordinator: TilesCoordinator

    public init(coordinator: TilesCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        NavigationSplitView {
            sidebarView
                .navigationSplitViewColumnWidth(min: 270, ideal: 295, max: 340)
        } detail: {
            detailContentView
        }
        .frame(minWidth: 960, minHeight: 620)
        .onAppear {
            syncEditingNames()
        }
    }

    private func syncEditingNames() {
        for disp in coordinator.connectedDisplays {
            coordinator.editingDisplayNames[disp.uuid] = disp.customName
        }
    }

    // MARK: - Left Sidebar (Connected Displays + Last 10 Snapshots)

    private var sidebarView: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Auto-Snapshot Timer Card
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Automatic Snapshot", systemImage: "clock.arrow.circlepath")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Spacer()
                    Toggle("", isOn: $coordinator.isAutoSnapshotEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }

                HStack {
                    Text(coordinator.isAutoSnapshotEnabled
                         ? "Next disk snapshot in \(coordinator.secondsUntilNextSnapshot)s"
                         : "Auto-snapshot timer paused")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("+ Snap Now") {
                        coordinator.takeSnapshotNow(reason: "Manual snapshot")
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                }
            }
            .padding(12)
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            // Editable Display Names Section
            VStack(alignment: .leading, spacing: 8) {
                Text("DETECTED DISPLAYS (CUSTOM NAMES)")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundStyle(.secondary)

                ForEach(coordinator.connectedDisplays, id: \.uuid) { disp in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 7, height: 7)
                            Text(disp.isBuiltIn ? "Internal Display" : "External Display")
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundStyle(disp.isBuiltIn ? Color.secondary : Color.indigo)
                            Spacer()
                            Text("\(Int(disp.quartzFrame.width))×\(Int(disp.quartzFrame.height))")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 6) {
                            TextField(
                                disp.systemName,
                                text: Binding(
                                    get: { coordinator.editingDisplayNames[disp.uuid] ?? disp.customName },
                                    set: { coordinator.editingDisplayNames[disp.uuid] = $0 }
                                )
                            )
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                            .onSubmit {
                                if let val = coordinator.editingDisplayNames[disp.uuid] {
                                    coordinator.updateCustomName(val, forDisplayUUID: disp.uuid)
                                }
                            }

                            Button("Save") {
                                if let val = coordinator.editingDisplayNames[disp.uuid] {
                                    coordinator.updateCustomName(val, forDisplayUUID: disp.uuid)
                                }
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(10)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }

            Divider()

            // Configuration (Topology) Selector + Rolling 10 Snapshots List
            VStack(alignment: .leading, spacing: 6) {
                Text("DISPLAY CONFIGURATION PROFILE")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundStyle(.secondary)

                Picker(
                    "",
                    selection: Binding(
                        get: { coordinator.viewingTopologyKey },
                        set: { coordinator.selectViewingTopology($0) }
                    )
                ) {
                    ForEach(coordinator.availableTopologies, id: \.self) { topo in
                        let isLive = (topo == coordinator.currentTopologyKey)
                        Text(isLive ? "● \(coordinator.friendlyName(forTopologyKey: topo)) (Active)" : coordinator.friendlyName(forTopologyKey: topo))
                            .tag(topo)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)

                HStack {
                    Text("LAST 10 SNAPSHOTS FOR CONFIG")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        NSWorkspace.shared.open(coordinator.store.snapshotsRootDirectory)
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.top, 4)

                List(selection: $coordinator.selectedSnapshotID) {
                    ForEach(Array(coordinator.recentSnapshots.enumerated()), id: \.element.id) { idx, snap in
                        HStack(spacing: 10) {
                            Text("#\(idx + 1)")
                                .font(.caption.monospacedDigit())
                                .fontWeight(.bold)
                                .foregroundStyle(idx == 0 ? Color.green : Color.secondary)
                                .frame(width: 26, alignment: .leading)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(Self.timeFormatter.string(from: snap.capturedAt))
                                    .font(.caption)
                                    .fontWeight(idx == 0 ? .semibold : .regular)
                                Text("\(snap.displays.count) screens • \(snap.totalDesktopCount) desktops • \(snap.totalWindowCount) windows")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if idx == 0 {
                                Text("Latest")
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.green.opacity(0.18))
                                    .foregroundStyle(Color.green)
                                    .clipShape(Capsule())
                            }
                        }
                        .tag(snap.id)
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.sidebar)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(14)
    }

    // MARK: - Right Detail View (Visual All-Display & All-Desktop Map)

    private var detailContentView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top Action Bar
            HStack {
                if let snap = coordinator.selectedSnapshot {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Snapshot captured at \(Self.timeFormatter.string(from: snap.capturedAt))")
                            .font(.headline)
                        Text("\(snap.displays.count) Displays • \(snap.totalDesktopCount) Desktops • \(snap.totalWindowCount) Windows remembered • Missing windows leave space empty")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("No Snapshot Selected")
                        .font(.headline)
                }

                Spacer()

                if !coordinator.isAccessibilityGranted {
                    Button {
                        coordinator.checkAccessibility(prompt: true)
                    } label: {
                        Label("Grant Accessibility Permission", systemImage: "lock.shield")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }

                if let snap = coordinator.selectedSnapshot {
                    Button {
                        coordinator.restoreSnapshot(snap)
                    } label: {
                        Label("Restore This Snapshot Now", systemImage: "arrow.uturn.backward.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                }
            }
            .padding(16)
            .background(Color.primary.opacity(0.03))

            Divider()

            // Scrollable Visual Map of Every Display & Its Desktops
            if let snap = coordinator.selectedSnapshot {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(snap.displays) { disp in
                            displayMapCard(for: disp)
                        }
                    }
                    .padding(18)
                }
            } else {
                ContentUnavailableView(
                    "No Snapshots Recorded Yet",
                    systemImage: "macwindow.on.rectangle",
                    description: Text("Tiles automatically snapshots all displays and desktops every 60 seconds.")
                )
            }
        }
    }

    @ViewBuilder
    private func displayMapCard(for disp: DisplaySnapshotInfo) -> some View {
        let activeSpaceIdx = coordinator.selectedSpaceByDisplay[disp.uuid]
            ?? disp.spaces.first(where: { $0.isCurrentSpace })?.spaceIndex
            ?? disp.spaces.first?.spaceIndex
            ?? 1

        let currentSpaceObj = disp.spaces.first(where: { $0.spaceIndex == activeSpaceIdx }) ?? disp.spaces.first
        let aspect = max(1.2, min(3.6, disp.frame.width / max(1.0, disp.frame.height)))
        let liveDispName = coordinator.customDisplayNames[disp.uuid] ?? disp.customName

        VStack(alignment: .leading, spacing: 12) {
            // Card Header with Display Info & Desktop (Space) Picker Tabs
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: disp.isBuiltIn ? "laptopcomputer" : "display")
                        .font(.title3)
                        .foregroundStyle(disp.isBuiltIn ? Color.green : Color.indigo)

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(liveDispName)
                                .font(.subheadline)
                                .fontWeight(.bold)
                            Text(disp.isBuiltIn ? "Internal" : "External")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background((disp.isBuiltIn ? Color.green : Color.indigo).opacity(0.15))
                                .foregroundStyle(disp.isBuiltIn ? Color.green : Color.indigo)
                                .clipShape(Capsule())
                        }
                        Text("Resolution: \(Int(disp.frame.width))×\(Int(disp.frame.height)) • UUID: \(disp.uuid.prefix(12))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // Desktop (Space) Selector Buttons
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(disp.spaces) { sp in
                            let isSelected = (sp.spaceIndex == activeSpaceIdx)
                            Button {
                                coordinator.selectedSpaceByDisplay[disp.uuid] = sp.spaceIndex
                            } label: {
                                HStack(spacing: 4) {
                                    Text(sp.isFullscreenSpace ? "Fullscreen \(sp.spaceIndex)" : "Desktop \(sp.spaceIndex)")
                                        .font(.caption)
                                        .fontWeight(isSelected ? .semibold : .regular)
                                    Text("(\(sp.windows.count))")
                                        .font(.caption2)
                                        .opacity(0.75)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(isSelected ? Color.indigo : Color.primary.opacity(0.06))
                                .foregroundStyle(isSelected ? Color.white : Color.primary)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            // Proportional Screen Canvas (32:9 for 49" Ultrawide, 16:10 for MacBook)
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.black.opacity(0.22))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1.5)
                        )

                    if let sp = currentSpaceObj {
                        if sp.windows.isEmpty {
                            VStack(spacing: 4) {
                                Text("No Windows on Desktop \(sp.spaceIndex)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            // Reverse so frontmost windows draw on top
                            ForEach(sp.windows.reversed()) { win in
                                let rel = win.relativeFrame
                                let boxX = max(0, min(1, CGFloat(rel.x))) * geo.size.width
                                let boxY = max(0, min(1, CGFloat(rel.y))) * geo.size.height
                                let boxW = max(60, min(geo.size.width - boxX, CGFloat(rel.width) * geo.size.width))
                                let boxH = max(44, min(geo.size.height - boxY, CGFloat(rel.height) * geo.size.height))

                                windowPreviewBox(win: win)
                                    .frame(width: boxW, height: boxH)
                                    .offset(x: boxX, y: boxY)
                            }
                        }
                    }
                }
            }
            .aspectRatio(aspect, contentMode: .fit)
            .frame(maxHeight: disp.isBuiltIn ? 230 : 260)
        }
        .padding(16)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func windowPreviewBox(win: WindowSnapshotInfo) -> some View {
        let isRunning = NSWorkspace.shared.runningApplications.contains { app in
            if let sBid = win.bundleIdentifier, let aBid = app.bundleIdentifier {
                return sBid == aBid
            }
            return app.localizedName?.caseInsensitiveCompare(win.ownerName) == .orderedSame
        }

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(win.ownerName)
                    .font(.caption)
                    .fontWeight(.bold)
                    .lineLimit(1)
                Spacer()
                Text(isRunning ? "Present" : "Closed (Leave Empty)")
                    .font(.caption2)
                    .foregroundStyle(isRunning ? Color.green : Color.secondary)
            }

            if !win.windowTitle.isEmpty {
                Text(win.windowTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            Text("x:\(Int(win.frame.x)) y:\(Int(win.frame.y)) • \(Int(win.frame.width))×\(Int(win.frame.height))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.windowBackgroundColor).opacity(isRunning ? 0.92 : 0.45))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isRunning ? Color.indigo.opacity(0.8) : Color.secondary.opacity(0.4),
                    style: StrokeStyle(lineWidth: 1.5, dash: isRunning ? [] : [5, 4])
                )
        )
        .padding(2)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return f
    }()
}
