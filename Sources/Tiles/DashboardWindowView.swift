import SwiftUI
import AppKit

// MARK: - C1 Ceramic Bento Palette
public struct BentoPalette {
    public static let butterYellow = Color(red: 247/255, green: 223/255, blue: 139/255) // #F7DF8B
    public static let babyBlue     = Color(red: 169/255, green: 214/255, blue: 245/255) // #A9D6F5
    public static let babyPink     = Color(red: 245/255, green: 189/255, blue: 199/255) // #F5BDC7
    public static let mintCeramic  = Color(red: 168/255, green: 230/255, blue: 207/255) // #A8E6CF
    public static let lavender     = Color(red: 222/255, green: 210/255, blue: 249/255) // #DED2F9
    public static let peach        = Color(red: 252/255, green: 211/255, blue: 167/255) // #FCD3A7
    public static let textDark     = Color(red: 17/255, green: 24/255, blue: 39/255)    // #111827

    public static func colorForApp(_ appName: String) -> (background: Color, text: Color) {
        let lower = appName.lowercased()
        if lower.contains("claude") {
            return (babyPink, textDark)
        } else if lower.contains("chrome") || lower.contains("safari") || lower.contains("arc") || lower.contains("browser") {
            return (babyBlue, textDark)
        } else if lower.contains("gemini") || lower.contains("terminal") || lower.contains("iterm") || lower.contains("ghostty") {
            return (butterYellow, textDark)
        } else if lower.contains("code") || lower.contains("xcode") || lower.contains("cursor") {
            return (mintCeramic, textDark)
        } else if lower.contains("slack") || lower.contains("messages") || lower.contains("mail") {
            return (lavender, textDark)
        } else if lower.contains("notion") || lower.contains("notes") || lower.contains("figma") {
            return (peach, textDark)
        }

        let pastels = [butterYellow, babyBlue, babyPink, mintCeramic, lavender, peach]
        let hash = abs(appName.hashValue) % pastels.count
        return (pastels[hash], textDark)
    }
}

public struct DashboardWindowView: View {
    @ObservedObject var coordinator: TilesCoordinator

    public init(coordinator: TilesCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Precision Command Header
            commandHeaderBar

            Divider()
                .overlay(Color.white.opacity(0.08))

            // 3-Column Layout: Setups Sidebar | Compact Snapshots Timeline | Blueprint Stage
            HStack(spacing: 0) {
                setupsAndNavSidebar
                    .frame(width: 235)

                Divider()
                    .overlay(Color.white.opacity(0.08))

                snapshotTimelineColumn
                    .frame(width: 235)

                Divider()
                    .overlay(Color.white.opacity(0.08))

                mainStageContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 1080, minHeight: 680)
        .background(Color(red: 0.08, green: 0.09, blue: 0.11))
        .onAppear {
            syncEditingNames()
        }
        .background(hiddenKeyboardShortcuts)
    }

    private func syncEditingNames() {
        for disp in coordinator.connectedDisplays {
            coordinator.editingDisplayNames[disp.uuid] = disp.customName
        }
    }

    // MARK: - 1. Top Precision Command Bar

    private var commandHeaderBar: some View {
        HStack(spacing: 12) {
            // Prominent Setup Breadcrumb
            let activeSetup = coordinator.setupInfo(for: coordinator.viewingTopologyKey.isEmpty ? coordinator.currentTopologyKey : coordinator.viewingTopologyKey)

            HStack(spacing: 8) {
                Circle()
                    .fill(activeSetup.isConnected ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)

                HStack(spacing: 4) {
                    Text("SETUP /")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.secondary)
                    Text(activeSetup.title.uppercased())
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.primary.opacity(0.95))
                }

                if activeSetup.isConnected {
                    Text("ACTIVE")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.green.opacity(0.18))
                        .foregroundStyle(Color.green)
                        .clipShape(Capsule())
                }

                if coordinator.isAutoSnapshotEnabled {
                    Text("\(coordinator.secondsUntilNextSnapshot)s")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.white.opacity(0.06))
                        .foregroundStyle(Color.secondary)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Spacer()

            // Quick Status
            if !coordinator.lastStatusMessage.isEmpty {
                Text(coordinator.lastStatusMessage)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
            }

            // Command Shortcut Actions
            HStack(spacing: 8) {
                Button {
                    coordinator.takeSnapshotNow(isManual: true, reason: "Manual capture ⌘S")
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "camera")
                            .font(.system(size: 10))
                        Text("Capture")
                        Text("⌘S")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .opacity(0.7)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if let snap = coordinator.selectedSnapshot {
                    let isPin = coordinator.isPinned(snap)
                    Button {
                        if isPin {
                            coordinator.unpinSnapshot(snap)
                        } else {
                            coordinator.pinSnapshot(snap)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isPin ? "pin.slash" : "pin.fill")
                                .font(.system(size: 10))
                            Text(isPin ? "Unpin" : "Pin")
                            Text("⌘P")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .opacity(0.7)
                        }
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        coordinator.restoreSnapshot(snap)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.uturn.backward.circle.fill")
                                .font(.system(size: 10))
                            Text("Restore")
                            Text("⌘R")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .opacity(0.85)
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.indigo)
                    .controlSize(.small)
                }

                if !coordinator.isAccessibilityGranted {
                    Button {
                        coordinator.checkAccessibility(prompt: true)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.shield.fill")
                            Text("Grant Access")
                        }
                        .font(.system(size: 11, weight: .bold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.orange)
                    .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(red: 0.10, green: 0.11, blue: 0.13))
    }

    // MARK: - 2. Column 1: Prominent Setups Sidebar

    private var setupsAndNavSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("DISPLAY SETUPS")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.secondary)

                Spacer()

                Text("\(coordinator.allSetupInfos.count)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Color.white.opacity(0.06))
                    .foregroundStyle(Color.secondary)
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(red: 0.09, green: 0.10, blue: 0.12).opacity(0.6))

            Divider()
                .overlay(Color.white.opacity(0.06))

            // Setups List
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(coordinator.allSetupInfos) { setup in
                        setupCardView(setup: setup)
                    }
                }
                .padding(10)
            }

            Spacer(minLength: 0)

            Divider()
                .overlay(Color.white.opacity(0.06))

            // Navigation Tabs at Bottom
            VStack(spacing: 3) {
                navTabRow(tab: .map, icon: "rectangle.3.group.fill", title: "Blueprint Map", shortcut: "⇧⌘M")
                navTabRow(tab: .log, icon: "list.bullet.rectangle.portrait", title: "Activity Log", shortcut: "⇧⌘L")
                navTabRow(tab: .settings, icon: "gearshape.fill", title: "Preferences", shortcut: "⌘,")
            }
            .padding(8)
            .background(Color(red: 0.07, green: 0.08, blue: 0.10))
        }
        .background(Color(red: 0.09, green: 0.10, blue: 0.12))
    }

    private func setupCardView(setup: TilesCoordinator.SetupInfo) -> some View {
        let isSelected = (setup.topologyKey == coordinator.viewingTopologyKey)

        return Button {
            coordinator.selectViewingTopology(setup.topologyKey)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                // Top Row: Title + Status
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: setup.icon)
                        .font(.system(size: 13))
                        .foregroundStyle(setup.isConnected ? Color.green : (isSelected ? Color.indigo : Color.secondary))
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(setup.title)
                            .font(.system(size: 11, weight: isSelected ? .bold : .semibold))
                            .foregroundStyle(Color.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)

                        Text(setup.subtitle)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Color.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    if setup.isConnected {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                            .padding(.top, 2)
                    }
                }

                // Bottom row: Snapshots count + Pinned badge
                HStack(spacing: 6) {
                    if setup.hasPin {
                        HStack(spacing: 2) {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 8))
                            Text("DEFAULT")
                                .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1.5)
                        .background(Color.orange.opacity(0.18))
                        .foregroundStyle(Color.orange)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    }

                    Text("\(setup.snapshotCount) snap\(setup.snapshotCount == 1 ? "" : "s")")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Color.secondary.opacity(0.8))

                    Spacer()

                    if setup.isConnected {
                        Text("LIVE")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.green)
                    }
                }
                .padding(.top, 2)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color(red: 0.15, green: 0.17, blue: 0.22) : Color.white.opacity(0.025))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isSelected ? Color.indigo.opacity(0.85) : (setup.isConnected ? Color.green.opacity(0.3) : Color.white.opacity(0.05)),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func navTabRow(tab: DashboardTab, icon: String, title: String, shortcut: String) -> some View {
        let isSelected = (coordinator.selectedDashboardTab == tab)
        return Button {
            coordinator.selectedDashboardTab = tab
        } label: {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Color.white : Color.secondary)
                    .frame(width: 16)

                Text(title)
                    .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                    .foregroundStyle(isSelected ? Color.white : Color.secondary)

                Spacer()

                Text(shortcut)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Color.secondary.opacity(0.6))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isSelected ? Color.white.opacity(0.10) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 3. Column 2: Compact Snapshots Timeline

    private var snapshotTimelineColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("SNAPSHOTS")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.secondary)

                Spacer()

                Text("\(coordinator.recentSnapshots.count)/\(coordinator.historyLimit)")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.secondary.opacity(0.8))

                Button {
                    NSWorkspace.shared.open(coordinator.store.snapshotsRootDirectory)
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.secondary)
                }
                .buttonStyle(.plain)
                .help("Show in Finder")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .background(Color(red: 0.08, green: 0.09, blue: 0.11).opacity(0.6))

            Divider()
                .overlay(Color.white.opacity(0.06))

            if coordinator.recentSnapshots.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "macwindow.badge.plus")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                    Text("No Snapshots")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                    Text("Auto-saving every \(coordinator.snapshotIntervalSeconds)s.")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.secondary.opacity(0.7))
                        .multilineTextAlignment(.center)
                    Button("+ Capture") {
                        coordinator.takeSnapshotNow(isManual: true, reason: "Manual snapshot")
                    }
                    .controlSize(.mini)
                    .buttonStyle(.bordered)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .padding(12)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(coordinator.recentSnapshots.enumerated()), id: \.element.id) { idx, snap in
                            compactSnapshotCard(index: idx, snap: snap)
                        }
                    }
                    .padding(6)
                }
            }
        }
        .background(Color(red: 0.08, green: 0.09, blue: 0.11))
    }

    private func compactSnapshotCard(index: Int, snap: MacSnapshot) -> some View {
        let isSelected = (coordinator.selectedSnapshotID == snap.id)
        let isPin = coordinator.isPinned(snap)
        let shortcutKey = index < 9 ? "⌘\(index + 1)" : nil
        let topApps = coordinator.topApps(for: snap, limit: 3)
        let drift = coordinator.driftSummary(for: snap)

        return Button {
            coordinator.selectedSnapshotID = snap.id
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                // Row 1: Shortcut / Time / Default / Drift
                HStack(spacing: 4) {
                    if let sc = shortcutKey {
                        Text(sc)
                            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 3.5)
                            .padding(.vertical, 1)
                            .background(Color.white.opacity(0.08))
                            .foregroundStyle(Color.secondary)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }

                    if isPin {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(Color.orange)
                    }

                    Text(Self.compactTimeFormatter.string(from: snap.capturedAt))
                        .font(.system(size: 10.5, weight: isSelected ? .bold : .semibold))
                        .foregroundStyle(Color.primary)

                    if snap.isManual {
                        Text("M")
                            .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(Color.indigo.opacity(0.2))
                            .foregroundStyle(Color.indigo)
                            .clipShape(RoundedRectangle(cornerRadius: 2.5))
                    }

                    Spacer()

                    HStack(spacing: 2) {
                        Circle()
                            .fill(drift.driftCount == 0 ? Color.green : Color.orange)
                            .frame(width: 4.5, height: 4.5)
                        Text(drift.driftCount == 0 ? "Match" : "\(drift.driftCount) diff")
                            .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(drift.driftCount == 0 ? Color.green : Color.orange)
                    }
                }

                // Row 2: Window Count + Compact App Chips
                HStack(spacing: 4) {
                    Text("\(snap.totalWindowCount)w")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Color.secondary)

                    if !topApps.isEmpty {
                        HStack(spacing: 3) {
                            ForEach(topApps, id: \.self) { appName in
                                let palette = BentoPalette.colorForApp(appName)
                                Text(appName)
                                    .font(.system(size: 7.5, weight: .bold))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(palette.background)
                                    .foregroundStyle(palette.text)
                                    .clipShape(RoundedRectangle(cornerRadius: 2.5))
                                    .lineLimit(1)
                            }
                        }
                    }
                    Spacer()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? Color(red: 0.15, green: 0.17, blue: 0.22) : Color.white.opacity(0.025))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(
                        isSelected ? Color.indigo.opacity(0.85) : (isPin ? Color.orange.opacity(0.35) : Color.white.opacity(0.05)),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Restore Layout") {
                coordinator.restoreSnapshot(snap)
            }
            if isPin {
                Button("Unpin Default") {
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

    // MARK: - 4. Column 3: Main Stage (Detail View)

    @ViewBuilder
    private var mainStageContent: some View {
        switch coordinator.selectedDashboardTab {
        case .map:
            blueprintCanvasView
        case .log:
            activityLogView
        case .settings:
            settingsView
        }
    }

    // MARK: - Blueprint Canvas View

    private var blueprintCanvasView: some View {
        Group {
            if let snap = coordinator.selectedSnapshot {
                let currentSetup = coordinator.setupInfo(for: snap.topologyKey)

                VStack(spacing: 0) {
                    // Stage Header Bar
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text("Architectural Blueprint")
                                    .font(.headline)
                                Text("•")
                                    .foregroundStyle(Color.secondary)
                                Text(currentSetup.title)
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(Color.primary)

                                if currentSetup.isConnected {
                                    Text("CURRENTLY ACTIVE")
                                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1.5)
                                        .background(Color.green.opacity(0.18))
                                        .foregroundStyle(Color.green)
                                        .clipShape(Capsule())
                                } else {
                                    Text("OFFLINE PROFILE")
                                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1.5)
                                        .background(Color.white.opacity(0.08))
                                        .foregroundStyle(Color.secondary)
                                        .clipShape(Capsule())
                                }
                            }
                            Text("\(snap.displays.count) Displays • \(snap.totalDesktopCount) Desktops • \(snap.totalWindowCount) Windows • Color-coded ceramic bento tiles")
                                .font(.caption2)
                                .foregroundStyle(Color.secondary.opacity(0.8))
                        }

                        Spacer()

                        Button {
                            coordinator.restoreSnapshot(snap)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.uturn.backward.circle.fill")
                                Text("Apply Layout")
                                Text("⌘R")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .opacity(0.8)
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.indigo)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(Color(red: 0.10, green: 0.11, blue: 0.13))

                    Divider()
                        .overlay(Color.white.opacity(0.08))

                    // Blueprint Grid Stage
                    ScrollView {
                        VStack(spacing: 16) {
                            ForEach(snap.displays) { disp in
                                displayBlueprintCard(for: disp)
                            }
                        }
                        .padding(18)
                    }
                    .background(blueprintGridPattern)
                }
            } else {
                ContentUnavailableView(
                    "No Snapshot Selected",
                    systemImage: "macwindow.on.rectangle",
                    description: Text("Select a snapshot from the timeline to inspect its window blueprint.")
                )
            }
        }
    }

    private var blueprintGridPattern: some View {
        ZStack {
            Color(red: 0.07, green: 0.08, blue: 0.10)
            GeometryReader { geo in
                Path { path in
                    let step: CGFloat = 28
                    var x: CGFloat = 0
                    while x < geo.size.width {
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: geo.size.height))
                        x += step
                    }
                    var y: CGFloat = 0
                    while y < geo.size.height {
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: geo.size.width, y: y))
                        y += step
                    }
                }
                .stroke(Color.white.opacity(0.025), lineWidth: 1)
            }
        }
    }

    @ViewBuilder
    private func displayBlueprintCard(for disp: DisplaySnapshotInfo) -> some View {
        let activeSpaceIdx = coordinator.selectedSpaceByDisplay[disp.uuid]
            ?? disp.spaces.first(where: { $0.isCurrentSpace })?.spaceIndex
            ?? disp.spaces.first?.spaceIndex
            ?? 1

        let currentSpaceObj = disp.spaces.first(where: { $0.spaceIndex == activeSpaceIdx }) ?? disp.spaces.first
        let aspect = max(1.3, min(3.8, disp.frame.width / max(1.0, disp.frame.height)))
        let liveDispName = coordinator.customDisplayNames[disp.uuid] ?? disp.customName

        VStack(alignment: .leading, spacing: 10) {
            // Display Header
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: disp.isBuiltIn ? "laptopcomputer" : "display")
                        .font(.system(size: 15))
                        .foregroundStyle(disp.isBuiltIn ? Color.green : Color.indigo)

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(liveDispName)
                                .font(.system(size: 13, weight: .bold))
                            Text(disp.isBuiltIn ? "Built-in" : "External")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background((disp.isBuiltIn ? Color.green : Color.indigo).opacity(0.18))
                                .foregroundStyle(disp.isBuiltIn ? Color.green : Color.indigo)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        Text("\(Int(disp.frame.width))×\(Int(disp.frame.height)) • UUID: \(disp.uuid.prefix(8))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color.secondary)
                    }
                }

                Spacer()

                // Spaces selector pills
                HStack(spacing: 5) {
                    ForEach(disp.spaces) { sp in
                        let isSelected = (sp.spaceIndex == activeSpaceIdx)
                        Button {
                            coordinator.selectedSpaceByDisplay[disp.uuid] = sp.spaceIndex
                        } label: {
                            HStack(spacing: 4) {
                                Text(sp.isFullscreenSpace ? "FS \(sp.spaceIndex)" : "Desktop \(sp.spaceIndex)")
                                    .font(.system(size: 10, weight: isSelected ? .bold : .medium))
                                Text("(\(sp.windows.count))")
                                    .font(.system(size: 9, design: .monospaced))
                                    .opacity(0.7)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(isSelected ? Color.indigo : Color.white.opacity(0.06))
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Screen Frame + Bento Windows
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    // Monitor bezel background
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(red: 0.05, green: 0.05, blue: 0.07))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1.5)
                        )

                    if let sp = currentSpaceObj {
                        if sp.windows.isEmpty {
                            VStack(spacing: 4) {
                                Text("No Windows on Desktop \(sp.spaceIndex)")
                                    .font(.caption)
                                    .foregroundStyle(Color.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            ForEach(Array(sp.windows.reversed().enumerated()), id: \.element.id) { index, win in
                                let rel = win.relativeFrame
                                let boxX = max(0, min(1, CGFloat(rel.x))) * geo.size.width
                                let boxY = max(0, min(1, CGFloat(rel.y))) * geo.size.height
                                let boxW = max(70, min(geo.size.width - boxX, CGFloat(rel.width) * geo.size.width))
                                let boxH = max(46, min(geo.size.height - boxY, CGFloat(rel.height) * geo.size.height))

                                bentoWindowTile(win: win, index: index)
                                    .frame(width: boxW, height: boxH)
                                    .offset(x: boxX, y: boxY)
                            }
                        }
                    }
                }
            }
            .aspectRatio(aspect, contentMode: .fit)
            .frame(maxHeight: disp.isBuiltIn ? 240 : 270)
        }
        .padding(14)
        .background(Color(red: 0.10, green: 0.11, blue: 0.13))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func bentoWindowTile(win: WindowSnapshotInfo, index: Int) -> some View {
        let isRunning = NSWorkspace.shared.runningApplications.contains { app in
            if let sBid = win.bundleIdentifier, let aBid = app.bundleIdentifier {
                return sBid == aBid
            }
            return app.localizedName?.caseInsensitiveCompare(win.ownerName) == .orderedSame
        }

        let palette = BentoPalette.colorForApp(win.ownerName)

        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(win.ownerName)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)

                Spacer()

                Circle()
                    .fill(isRunning ? Color.green : Color.secondary.opacity(0.6))
                    .frame(width: 5, height: 5)
            }

            if !win.windowTitle.isEmpty {
                Text(win.windowTitle)
                    .font(.system(size: 9))
                    .foregroundStyle(palette.text.opacity(0.85))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            HStack {
                Text("\(Int(win.frame.width))×\(Int(win.frame.height))")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(palette.text.opacity(0.75))
                    .lineLimit(1)
                Spacer()
            }
        }
        .padding(7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(palette.background)
                .shadow(color: Color.black.opacity(0.25), radius: 3, x: 0, y: 1.5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.black.opacity(0.12), lineWidth: 1)
        )
        .padding(1.5)
    }

    // MARK: - Activity Log View

    private var activityLogView: some View {
        VStack(spacing: 0) {
            // Log Header
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Activity Log")
                        .font(.headline)
                    Text("Last 200 lines of tiles.log • Automatic 1 MB log rotation")
                        .font(.caption2)
                        .foregroundStyle(Color.secondary)
                }

                Spacer()

                TextField("Filter log...", text: $coordinator.logSearchFilter)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .controlSize(.small)

                Button {
                    coordinator.refreshActivityLog()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .buttonStyle(.bordered)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(coordinator.activityLogText, forType: .string)
                } label: {
                    Label("Copy All", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
                .buttonStyle(.bordered)

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([coordinator.store.logFileURL])
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
            }
            .padding(14)
            .background(Color(red: 0.10, green: 0.11, blue: 0.13))

            Divider()
                .overlay(Color.white.opacity(0.08))

            // Log Console Text
            ScrollView {
                let filteredLines = coordinator.activityLogText
                    .components(separatedBy: "\n")
                    .filter { line in
                        coordinator.logSearchFilter.isEmpty || line.localizedCaseInsensitiveContains(coordinator.logSearchFilter)
                    }
                    .joined(separator: "\n")

                Text(filteredLines.isEmpty ? "No log entries found." : filteredLines)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color(red: 0.85, green: 0.88, blue: 0.92))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .background(Color(red: 0.05, green: 0.05, blue: 0.07))
        }
        .onAppear {
            coordinator.refreshActivityLog()
        }
    }

    // MARK: - Settings View

    private var settingsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Preferences & Bento Configurations")
                    .font(.title3)
                    .fontWeight(.bold)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                    // Card 1: Background Automation
                    settingsBentoCard(title: "Background Automation & Daemon", icon: "clock.arrow.circlepath") {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle("Automatic background snapshots", isOn: $coordinator.isAutoSnapshotEnabled)
                                .font(.subheadline)

                            Divider()

                            Toggle("Auto-restore on display plug / unplug", isOn: $coordinator.isAutoRestoreEnabled)
                                .font(.subheadline)

                            Divider()

                            Toggle("Restore app windows after an app relaunches", isOn: $coordinator.isRelaunchRestoreEnabled)
                                .font(.subheadline)
                                .help("When an app quits and relaunches within 10 minutes (e.g. after an update), put its windows back.")

                            Divider()

                            HStack {
                                Text("Snapshot interval")
                                    .font(.subheadline)
                                Spacer()
                                Picker("", selection: $coordinator.snapshotIntervalSeconds) {
                                    Text("15 seconds").tag(15)
                                    Text("30 seconds").tag(30)
                                    Text("1 minute").tag(60)
                                    Text("2 minutes").tag(120)
                                    Text("5 minutes").tag(300)
                                }
                                .labelsHidden()
                                .frame(width: 130)
                            }

                            Divider()

                            Toggle("Open Tiles automatically at login", isOn: $coordinator.openAtLogin)
                                .font(.subheadline)
                        }
                    }

                    // Card 2: Permissions & Security
                    settingsBentoCard(title: "Accessibility Permission & Trust", icon: "lock.shield") {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 10) {
                                Image(systemName: coordinator.isAccessibilityGranted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                                    .font(.title2)
                                    .foregroundStyle(coordinator.isAccessibilityGranted ? Color.green : Color.orange)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(coordinator.isAccessibilityGranted ? "Permission Granted" : "Permission Required")
                                        .font(.subheadline)
                                        .fontWeight(.bold)
                                    Text("Required to reach windows on hidden desktops and reposition live windows.")
                                        .font(.caption2)
                                        .foregroundStyle(Color.secondary)
                                }
                            }

                            Button(coordinator.isAccessibilityGranted ? "Check Again" : "Grant Access…") {
                                coordinator.checkAccessibility(prompt: true)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(coordinator.isAccessibilityGranted ? Color.indigo : Color.orange)
                            .controlSize(.small)
                        }
                    }

                    // Card 3: Storage & Retention
                    settingsBentoCard(title: "Storage & Retention Limit", icon: "externaldrive") {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("History limit per profile")
                                        .font(.subheadline)
                                    Text("Pinned default layouts are permanently kept.")
                                        .font(.caption2)
                                        .foregroundStyle(Color.secondary)
                                }
                                Spacer()
                                Picker("", selection: $coordinator.historyLimit) {
                                    ForEach(TilesCoordinator.allowedHistoryLimits, id: \.self) { limit in
                                        Text("\(limit)").tag(limit)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 80)
                            }

                            Divider()

                            HStack {
                                Text("Storage location")
                                    .font(.subheadline)
                                Spacer()
                                Button("Open Folder") {
                                    NSWorkspace.shared.open(coordinator.store.snapshotsRootDirectory)
                                }
                                .controlSize(.small)
                            }
                        }
                    }

                    // Card 4: Detected Displays Custom Naming
                    settingsBentoCard(title: "Detected Displays (Custom Names)", icon: "display.2") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(coordinator.connectedDisplays, id: \.uuid) { disp in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(disp.isBuiltIn ? "Internal Display" : "External Display")
                                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                                            .foregroundStyle(disp.isBuiltIn ? Color.green : Color.indigo)
                                        Spacer()
                                        Text("\(Int(disp.quartzFrame.width))×\(Int(disp.quartzFrame.height))")
                                            .font(.system(size: 9, design: .monospaced))
                                            .foregroundStyle(Color.secondary)
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
                                .padding(8)
                                .background(Color.white.opacity(0.03))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(Color(red: 0.08, green: 0.09, blue: 0.11))
    }

    private func settingsBentoCard<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(Color.indigo)
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.bold)
            }

            content()
        }
        .padding(16)
        .background(Color(red: 0.10, green: 0.11, blue: 0.13))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Keyboard Shortcuts

    private var hiddenKeyboardShortcuts: some View {
        ZStack {
            Button("") {
                coordinator.takeSnapshotNow(isManual: true, reason: "Manual shortcut ⌘S")
            }
            .keyboardShortcut("s", modifiers: .command)

            Button("") {
                coordinator.restoreSnapshot(coordinator.selectedSnapshot)
            }
            .keyboardShortcut("r", modifiers: .command)

            Button("") {
                if let snap = coordinator.selectedSnapshot {
                    if coordinator.isPinned(snap) {
                        coordinator.unpinSnapshot(snap)
                    } else {
                        coordinator.pinSnapshot(snap)
                    }
                }
            }
            .keyboardShortcut("p", modifiers: .command)

            Button("") { coordinator.selectedDashboardTab = .map }
                .keyboardShortcut("m", modifiers: [.command, .shift])

            Button("") { coordinator.selectedDashboardTab = .log }
                .keyboardShortcut("l", modifiers: [.command, .shift])

            Button("") { coordinator.selectedDashboardTab = .settings }
                .keyboardShortcut(",", modifiers: .command)

            // Number keys 1..9 for snapshot restore
            Button("") { coordinator.restoreSnapshotAtIndex(0) }.keyboardShortcut("1", modifiers: .command)
            Button("") { coordinator.restoreSnapshotAtIndex(1) }.keyboardShortcut("2", modifiers: .command)
            Button("") { coordinator.restoreSnapshotAtIndex(2) }.keyboardShortcut("3", modifiers: .command)
            Button("") { coordinator.restoreSnapshotAtIndex(3) }.keyboardShortcut("4", modifiers: .command)
            Button("") { coordinator.restoreSnapshotAtIndex(4) }.keyboardShortcut("5", modifiers: .command)
            Button("") { coordinator.restoreSnapshotAtIndex(5) }.keyboardShortcut("6", modifiers: .command)
            Button("") { coordinator.restoreSnapshotAtIndex(6) }.keyboardShortcut("7", modifiers: .command)
            Button("") { coordinator.restoreSnapshotAtIndex(7) }.keyboardShortcut("8", modifiers: .command)
            Button("") { coordinator.restoreSnapshotAtIndex(8) }.keyboardShortcut("9", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
    }

    private static let compactTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
}
