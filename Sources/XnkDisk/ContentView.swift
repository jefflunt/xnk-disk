import SwiftUI
import XnkDiskCore

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var hoverInfo: HoverTooltipState?

    private let surfaceBG = Color(red: 0x0c/255, green: 0x0c/255, blue: 0x0e/255)
    private let sidebarBG = Color(red: 0x14/255, green: 0x14/255, blue: 0x17/255)
    private let primaryBlue = Color(red: 0x2f/255, green: 0x81/255, blue: 0xf7/255)
    private let emerald = Color(red: 0x10/255, green: 0xb9/255, blue: 0x81/255)
    private let mutedFG = Color(red: 0x8a/255, green: 0x8a/255, blue: 0x93/255)

    var body: some View {
        VStack(spacing: 0) {
            topToolbar
            Divider().background(Color.white.opacity(0.11))
            breadcrumbBar
            Divider().background(Color.white.opacity(0.06))

            if model.isScanningSelected, let prog = model.activeScanProgressForSelected {
                scanProgressStrip(prog)
                Divider().background(Color.white.opacity(0.11))
            }

            ZStack(alignment: .topLeading) {
                Color.black

                if model.viewMode == .icicle, model.focusedRoot != nil {
                    GeometryReader { geo in
                        ZStack(alignment: .topLeading) {
                            IcicleRepresentable(model: model, hoverInfo: $hoverInfo)
                            if let info = hoverInfo {
                                hoverTooltip(info, in: geo.size)
                            }
                        }
                    }
                } else {
                    drivesOverview
                }

                if let toast = model.toast {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            toastView(toast)
                                .padding(16)
                        }
                    }
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $model.showPurgeSheet) {
            purgeConfirmationSheet
        }
    }

    // MARK: - Top Toolbar
    private var topToolbar: some View {
        HStack(spacing: 10) {
            Button(action: { model.goHome() }) {
                HStack(spacing: 6) {
                    Image(systemName: "internaldrive.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(primaryBlue)
                    Text("Drives")
                        .font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(model.viewMode == .overview ? sidebarBG : Color.clear)
                .cornerRadius(7)
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(model.viewMode == .overview ? Color.white.opacity(0.22) : Color.clear, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            Rectangle()
                .fill(Color.white.opacity(0.11))
                .frame(width: 1, height: 18)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.volumes) { vol in
                        let isActive = (vol.id == model.selectedVolumeID && model.viewMode == .icicle)
                        Button(action: { model.selectVolume(vol.id) }) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(model.isScanned(vol.id) ? emerald : mutedFG.opacity(0.4))
                                    .frame(width: 7, height: 7)
                                Text(vol.name)
                                    .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                                Text("\(vol.usedPercent)%")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 9)
                            .frame(height: 26)
                            .background(isActive ? sidebarBG : Color.clear)
                            .cornerRadius(7)
                            .overlay(
                                RoundedRectangle(cornerRadius: 7)
                                    .stroke(isActive ? Color(red: 214/255, green: 235/255, blue: 253/255).opacity(0.32) : Color.clear, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Spacer(minLength: 8)

            if model.viewMode == .icicle {
                HStack(spacing: 10) {
                    Picker("", selection: $model.layoutMode) {
                        ForEach(LayoutMode.allCases) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 132)

                    Picker("Depth", selection: $model.maxDepth) {
                        Text("5").tag(5)
                        Text("10").tag(10)
                        Text("20").tag(20)
                        Text("50").tag(50)
                        Text("All").tag(0)
                    }
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(width: 100)
                    .onChange(of: model.maxDepth) { _, _ in
                        model.reloadCurrentTree(resetZoom: false)
                    }

                    Toggle("Group <1.2%", isOn: $model.groupSmall)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .font(.system(size: 11.5))
                        .fixedSize()
                        .onChange(of: model.groupSmall) { _, _ in
                            model.reloadCurrentTree(resetZoom: false)
                        }

                    Toggle("Hide Free Space", isOn: $model.hideFreeSpace)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .font(.system(size: 11.5))
                        .fixedSize()

                    Toggle(isOn: $model.highlightRebuildsOnly) {
                        HStack(spacing: 4) {
                            Circle().fill(emerald).frame(width: 6, height: 6)
                            Text("Rebuildable")
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(emerald)
                    .font(.system(size: 11.5))
                    .fixedSize()
                    .disabled(!model.hasVisibleRebuilds)
                    .opacity(model.hasVisibleRebuilds ? 1.0 : 0.45)

                    Button(action: { model.showPurgeSheet = true }) {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                                .font(.system(size: 10.5, weight: .semibold))
                            Text(model.isPurging ? "Purging…" : "Purge Rebuildable")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(Color(red: 110/255, green: 231/255, blue: 183/255))
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(emerald.opacity(0.14))
                        .cornerRadius(6)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(emerald.opacity(0.42), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .disabled(model.rebuildableTargets.isEmpty || model.isPurging)
                    .opacity((model.rebuildableTargets.isEmpty || model.isPurging) ? 0.4 : 1.0)
                    .help("Move the contents of all Rebuildable folders in this view to Trash (keeps folders in place; supports Undo)")

                    if model.vZoom > 1.01 {
                        Button(action: { model.resetZoom() }) {
                            Text(String(format: "%.1f× · Reset", model.vZoom))
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(Color(red: 147/255, green: 197/255, blue: 253/255))
                                .padding(.horizontal, 8)
                                .frame(height: 24)
                                .background(primaryBlue.opacity(0.16))
                                .cornerRadius(6)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(primaryBlue.opacity(0.45), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .fixedSize()
                    }
                }
                .fixedSize()
                .layoutPriority(1)
            }

            if model.isScanningSelected {
                Button("Cancel") {
                    model.cancelScan()
                }
                .controlSize(.small)
            }

            Button(action: {
                if let vol = model.selectedVolume {
                    model.startScan(volumeID: vol.id)
                }
            }) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11.5, weight: .semibold))
                    Text(model.isScanningSelected ? "Scanning…" : (model.selectedVolume.map { model.isScanned($0.id) } == true ? "Rescan" : "Scan Disk"))
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(primaryBlue)
                .cornerRadius(7)
            }
            .buttonStyle(.plain)
            .disabled(model.isScanningSelected)
            .opacity(model.isScanningSelected ? 0.6 : 1.0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(surfaceBG)
    }

    // MARK: - Breadcrumb Bar
    private var breadcrumbBar: some View {
        HStack(spacing: 10) {
            if model.viewMode == .icicle, !model.breadcrumbs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        Button("Drives") { model.goHome() }
                            .buttonStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundColor(mutedFG)
                        Text("/").foregroundColor(mutedFG.opacity(0.45))

                        ForEach(Array(model.breadcrumbs.enumerated()), id: \.element.id) { idx, crumb in
                            let isLast = (idx == model.breadcrumbs.count - 1)
                            Button(crumb.name) {
                                model.openTree(volumeID: model.selectedVolumeID, path: crumb.path, resetZoom: true)
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: isLast ? .semibold : .regular))
                            .foregroundColor(isLast ? .primary : mutedFG)

                            if !isLast {
                                Text("/").foregroundColor(mutedFG.opacity(0.45))
                            }
                        }
                    }
                }
            } else {
                Text("Installed Drives")
                    .font(.system(size: 12, weight: .semibold))
            }

            Spacer()

            HStack(spacing: 8) {
                if let lastUndo = model.undoStack.last {
                    Button(action: { model.undoLastTrash() }) {
                        Label("Undo \"\(lastUndo.name)\"", systemImage: "arrow.uturn.backward")
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .foregroundColor(Color(red: 1.0, green: 166/255, blue: 107/255))
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                            .background(Color.orange.opacity(0.14))
                            .cornerRadius(6)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.orange.opacity(0.42), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }

                if model.viewMode == .icicle, let root = model.focusedRoot {
                    if model.canTrashFocused {
                        Button(action: { model.moveToTrash(path: root.path) }) {
                            Label("Move to Trash", systemImage: "trash")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Color(red: 253/255, green: 164/255, blue: 175/255))
                                .padding(.horizontal, 8)
                                .frame(height: 24)
                                .background(Color.red.opacity(0.12))
                                .cornerRadius(6)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.red.opacity(0.38), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }

                    Button(action: { model.revealInFinder(path: root.path) }) {
                        Label("Reveal in Finder", systemImage: "folder")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.primary)
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                            .background(Color.clear)
                            .cornerRadius(6)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.14), lineWidth: 1))
                    }
                    .buttonStyle(.plain)

                    let base = max(0, model.breadcrumbs.count - 1)
                    Text("Levels L\(base) → L\(base + model.deepestLevel)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(mutedFG)
                } else {
                    Text("Used vs. Available")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(mutedFG)
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(Color.black)
    }

    // MARK: - Live Scan Progress Strip
    private func scanProgressStrip(_ prog: ScanProgress) -> some View {
        let vol = model.volumes.first(where: { $0.id == prog.volumeID })
        let frac: Double = {
            guard let v = vol, v.usedBytes > 0 else { return 0.1 }
            return min(0.98, max(0.04, Double(prog.bytes) / Double(v.usedBytes)))
        }()

        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Scanning (\(prog.workers) workers): \(prog.currentPath)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(mutedFG)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("\(Formatters.bytes(prog.bytes)) · \(Formatters.count(prog.files)) files · \(String(format: "%.1fs", Double(prog.elapsedMs) / 1000.0))")
                    .font(.system(size: 11, design: .monospaced))
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.1))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(primaryBlue)
                        .frame(width: max(8, g.size.width * frac))
                }
            }
            .frame(height: 4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(surfaceBG)
    }

    // MARK: - Drives Overview
    private var drivesOverview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Installed Volumes")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Showing live used vs. available capacity. Select a drive and click Scan Disk to inspect nested folder usage.")
                        .font(.system(size: 12))
                        .foregroundColor(mutedFG)
                }

                ForEach(model.volumes) { vol in
                    driveCard(vol)
                }
            }
            .frame(maxWidth: 820)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }

    private func driveCard(_ vol: VolumeInfo) -> some View {
        let usedFrac = vol.totalBytes > 0 ? min(1.0, Double(vol.usedBytes) / Double(vol.totalBytes)) : 0
        let selected = (vol.id == model.selectedVolumeID)
        let scanned = model.isScanned(vol.id)

        return VStack(alignment: .leading, spacing: 11) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(vol.name)
                            .font(.system(size: 14, weight: .semibold))
                        Text(vol.fsType)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(mutedFG)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.07))
                            .cornerRadius(4)
                    }
                    Text("\(vol.mountPoint) · \(vol.device)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(mutedFG)
                }
                Spacer()
                HStack(spacing: 8) {
                    if scanned {
                        Button("View Breakdown") {
                            model.openTree(volumeID: vol.id, path: "", resetZoom: true)
                        }
                        .controlSize(.small)
                    }
                    Button(scanned ? "Rescan" : "Scan Disk") {
                        model.startScan(volumeID: vol.id)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(primaryBlue)
                    .controlSize(.small)
                    .disabled(model.store.isScanning(vol.id))
                }
            }

            GeometryReader { geo in
                HStack(spacing: 3) {
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 6).fill(primaryBlue)
                        if usedFrac >= 0.14 {
                            Text("Used · \(Formatters.bytes(vol.usedBytes)) (\(vol.usedPercent)%)")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 10)
                                .lineLimit(1)
                        }
                    }
                    .frame(width: max(6, (geo.size.width - 3) * usedFrac))

                    ZStack(alignment: .trailing) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(sidebarBG)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.07), lineWidth: 1))
                        if (1.0 - usedFrac) >= 0.14 {
                            Text("Available · \(Formatters.bytes(vol.availBytes))")
                                .font(.system(size: 12))
                                .foregroundColor(mutedFG)
                                .padding(.horizontal, 10)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .frame(height: 36)
            .padding(3)
            .background(Color.black)
            .cornerRadius(9)
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.11), lineWidth: 1))

            HStack {
                Text("Total Capacity: \(Formatters.bytes(vol.totalBytes))")
                Spacer()
                if let dt = model.scannedAt(vol.id) {
                    Text("Cached (\(Formatters.timeAgo(dt))) — click View Breakdown or Rescan")
                } else {
                    Text("Ready to scan on demand")
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(mutedFG)
        }
        .padding(16)
        .background(surfaceBG)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(selected ? Color(red: 214/255, green: 235/255, blue: 253/255).opacity(0.45) : Color.white.opacity(0.11), lineWidth: 1)
        )
        .onTapGesture {
            model.selectedVolumeID = vol.id
        }
    }

    // MARK: - Floating Hover Tooltip
    private func hoverTooltip(_ info: HoverTooltipState, in size: CGSize) -> some View {
        let tw: CGFloat = 380
        let th: CGFloat = info.hint != nil ? 96 : 56
        let pad: CGFloat = 14
        var x = info.pointInContainer.x + pad
        var y = info.pointInContainer.y + pad
        if x + tw > size.width - 10 { x = max(8, info.pointInContainer.x - tw - pad) }
        if y + th > size.height - 10 { y = max(8, info.pointInContainer.y - th - pad) }

        return VStack(alignment: .leading, spacing: 4) {
            if let hint = info.hint {
                HStack(spacing: 8) {
                    Text(hint.label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                    Spacer()
                    Text(hint.tag)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(hint.safety == .rebuilds ? emerald.opacity(0.20) : Color.orange.opacity(0.18))
                        .foregroundColor(hint.safety == .rebuilds ? Color(red: 110/255, green: 231/255, blue: 183/255) : Color(red: 252/255, green: 211/255, blue: 77/255))
                        .cornerRadius(999)
                        .overlay(
                            RoundedRectangle(cornerRadius: 999)
                                .stroke(hint.safety == .rebuilds ? emerald.opacity(0.55) : Color.orange.opacity(0.5), lineWidth: 1)
                        )
                }
                Text(hint.description)
                    .font(.system(size: 11))
                    .foregroundColor(mutedFG)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("L\(info.absDepth) · \(info.path)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white)
                .lineLimit(2)
                .truncationMode(.middle)

            HStack(spacing: 10) {
                Text(Formatters.bytes(info.size))
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                Text(String(format: "%.1f%% used (%.1f%% disk)", info.pctUsed, info.pctDisk))
                if info.files > 0 {
                    Text("\(Formatters.count(info.files)) files")
                }
            }
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundColor(mutedFG)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: tw, alignment: .leading)
        .background(.ultraThinMaterial)
        .background(Color(red: 12/255, green: 12/255, blue: 14/255).opacity(0.85))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(red: 214/255, green: 235/255, blue: 253/255).opacity(0.28), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.6), radius: 14, y: 6)
        .offset(x: x, y: y)
        .allowsHitTesting(false)
    }

    // MARK: - Action Toast
    private func toastView(_ toast: ToastMessage) -> some View {
        HStack(spacing: 10) {
            Text(toast.text)
                .font(.system(size: 12))
                .foregroundColor(toast.isError ? Color(red: 253/255, green: 164/255, blue: 175/255) : .white)
            if toast.showUndo && !model.undoStack.isEmpty {
                Button("Undo") {
                    model.undoLastTrash()
                }
                .controlSize(.small)
                .tint(.orange)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .background(sidebarBG.opacity(0.92))
        .cornerRadius(9)
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(toast.isError ? Color.red.opacity(0.55) : Color(red: 214/255, green: 235/255, blue: 253/255).opacity(0.28), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.55), radius: 14, y: 6)
    }

    // MARK: - Purge Rebuildable Confirmation Sheet
    private var purgeConfirmationSheet: some View {
        let targets = model.rebuildableTargets
        let totalSize = targets.reduce(UInt64(0)) { $0 + $1.node.size }
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "trash.circle.fill")
                    .font(.system(size: 26))
                    .foregroundColor(emerald)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Purge Rebuildable Contents on \(model.selectedVolume?.name ?? "Disk")?")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Moves the contents of \(targets.count) \(targets.count == 1 ? "folder" : "folders") (\(Formatters.bytes(totalSize))) in this view to Trash while keeping each folder in place. You can restore everything with Undo (⌘Z).")
                        .font(.system(size: 12))
                        .foregroundColor(mutedFG)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(targets) { item in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.hint.label)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.primary)
                                Text(CustomRulesStore.collapseHome(item.node.path, home: home))
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundColor(mutedFG)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Text(Formatters.bytes(item.node.size))
                                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                .foregroundColor(Color(red: 110/255, green: 231/255, blue: 183/255))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(sidebarBG)
                        .cornerRadius(7)
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.08), lineWidth: 1))
                    }
                }
            }
            .frame(maxHeight: 260)

            HStack {
                Spacer()
                Button("Cancel") {
                    model.showPurgeSheet = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Move Contents to Trash") {
                    model.purgeRebuildable()
                }
                .buttonStyle(.borderedProminent)
                .tint(emerald)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(surfaceBG)
        .preferredColorScheme(.dark)
    }
}
