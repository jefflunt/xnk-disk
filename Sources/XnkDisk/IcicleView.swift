import SwiftUI
import AppKit
import XnkDiskCore

struct HoverTooltipState: Equatable {
    let absDepth: Int
    let path: String
    let name: String
    let size: UInt64
    let files: Int64
    let pctUsed: Double
    let pctDisk: Double
    let hint: NodeHint?
    let pointInContainer: CGPoint
}

struct IcicleRepresentable: NSViewRepresentable {
    @ObservedObject var model: AppModel
    @Binding var hoverInfo: HoverTooltipState?

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, hoverBinding: $hoverInfo)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = IcicleScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.backgroundColor = .black
        scroll.drawsBackground = true
        scroll.borderType = .noBorder
        scroll.allowsMagnification = false
        scroll.coordinator = context.coordinator

        let doc = IcicleDocumentView(frame: .zero)
        doc.coordinator = context.coordinator
        scroll.documentView = doc
        context.coordinator.scrollView = scroll
        context.coordinator.docView = doc

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.boundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scroll.contentView
        )
        scroll.contentView.postsBoundsChangedNotifications = true

        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.model = model
        context.coordinator.hoverBinding = $hoverInfo
        context.coordinator.syncFromModel()
    }

    final class Coordinator: NSObject {
        var model: AppModel
        var hoverBinding: Binding<HoverTooltipState?>
        weak var scrollView: NSScrollView?
        weak var docView: IcicleDocumentView?

        init(model: AppModel, hoverBinding: Binding<HoverTooltipState?>) {
            self.model = model
            self.hoverBinding = hoverBinding
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc func boundsDidChange(_ note: Notification) {
            // Redraw sticky column headers cleanly on scroll
            docView?.needsDisplay = true
        }

        @MainActor
        func syncFromModel() {
            guard let doc = docView, let scroll = scrollView else { return }
            let vpSize = scroll.contentView.bounds.size
            doc.configure(
                root: model.focusedRoot,
                treeGeneration: model.treeGeneration,
                volume: model.selectedVolume,
                isRoot: model.isAtVolumeRoot,
                baseDepth: max(0, model.breadcrumbs.count - 1),
                maxDepth: model.deepestLevel,
                layoutMode: model.layoutMode,
                hideFreeSpace: model.hideFreeSpace,
                highlightRebuildsOnly: model.highlightRebuildsOnly && model.hasVisibleRebuilds,
                vZoom: model.vZoom,
                viewportSize: vpSize
            )
        }

        @MainActor
        func handleMagnify(delta: CGFloat, windowPoint: NSPoint) {
            guard let scroll = scrollView, let doc = docView else { return }
            let oldZoom = model.vZoom
            let newZoom = min(25.0, max(1.0, oldZoom * exp(delta * 2.0)))
            if abs(newZoom - oldZoom) < 0.002 { return }

            let clipBounds = scroll.contentView.bounds
            let ptInClip = scroll.contentView.convert(windowPoint, from: nil)
            let anchorYInViewport = ptInClip.y - clipBounds.minY
            let headH = IcicleDocumentView.headerHeight
            let baseH = max(380.0, clipBounds.height - headH - 12.0)

            let contentY = clipBounds.minY + anchorYInViewport - headH
            let ratio = max(0, contentY) / max(1, baseH * oldZoom)

            model.vZoom = newZoom
            syncFromModel()

            let targetScrollY = max(0, ratio * (baseH * newZoom) - (anchorYInViewport - headH))
            let maxScrollY = max(0, doc.frame.height - clipBounds.height)
            let clampedY = min(maxScrollY, targetScrollY)
            scroll.contentView.scroll(to: NSPoint(x: clipBounds.minX, y: clampedY))
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        @MainActor
        func updateHover(_ info: HoverTooltipState?) {
            hoverBinding.wrappedValue = info
        }
    }
}

final class IcicleScrollView: NSScrollView {
    weak var coordinator: IcicleRepresentable.Coordinator?

    override func magnify(with event: NSEvent) {
        let delta = event.magnification
        guard delta != 0 else { return }
        let pt = event.locationInWindow
        Task { @MainActor [weak self] in
            self?.coordinator?.handleMagnify(delta: delta, windowPoint: pt)
        }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        Task { @MainActor [weak self] in
            self?.coordinator?.syncFromModel()
        }
    }
}

struct RenderedBlock {
    let node: ViewNode
    let colIdx: Int
    let absDepth: Int
    let rect: CGRect
    let color: NSColor
    let baseAlpha: CGFloat
    let inRebuilds: Bool
    let ancestorPaths: Set<String>
}

final class IcicleDocumentView: NSView {
    static let headerHeight: CGFloat = 26
    static let colGap: CGFloat = 6
    static let padX: CGFloat = 8
    static let padBottom: CGFloat = 10
    static let scrollColWidth: CGFloat = 172

    // XNK Functional Palette (Emerald reserved exclusively for Rebuildable caches)
    private static let palette: [NSColor] = [
        NSColor(srgbRed: 0x2f/255.0, green: 0x81/255.0, blue: 0xf7/255.0, alpha: 1), // Primary Blue
        NSColor(srgbRed: 0xff/255.0, green: 0x77/255.0, blue: 0x22/255.0, alpha: 1), // Ember Orange
        NSColor(srgbRed: 0x38/255.0, green: 0xbd/255.0, blue: 0xf8/255.0, alpha: 1), // Icy Cyan
        NSColor(srgbRed: 0x63/255.0, green: 0x66/255.0, blue: 0xf1/255.0, alpha: 1), // Indigo
        NSColor(srgbRed: 0xf5/255.0, green: 0x9e/255.0, blue: 0x0b/255.0, alpha: 1), // Amber
        NSColor(srgbRed: 0x8b/255.0, green: 0x5c/255.0, blue: 0xf6/255.0, alpha: 1), // Violet
        NSColor(srgbRed: 0xf4/255.0, green: 0x3f/255.0, blue: 0x5e/255.0, alpha: 1), // Crimson
        NSColor(srgbRed: 0xec/255.0, green: 0x48/255.0, blue: 0x99/255.0, alpha: 1)  // Rose Pink
    ]
    private static let colorRebuilds = NSColor(srgbRed: 0x10/255.0, green: 0xb9/255.0, blue: 0x81/255.0, alpha: 1)
    private static let colorMuted = NSColor(srgbRed: 0x27/255.0, green: 0x27/255.0, blue: 0x2a/255.0, alpha: 1)
    private static let colorFreeBG = NSColor(srgbRed: 0x14/255.0, green: 0x14/255.0, blue: 0x17/255.0, alpha: 1)

    weak var coordinator: IcicleRepresentable.Coordinator?

    private var columns: [[RenderedBlock]] = []
    private var colX: [CGFloat] = []
    private var colW: CGFloat = scrollColWidth
    private var baseDepth: Int = 0
    private var isRoot: Bool = true
    private var scaleBytes: UInt64 = 1
    private var volumeTotalBytes: UInt64 = 1
    private var volumeUsedBytes: UInt64 = 1
    private var volumeID: String = ""
    private var highlightRebuildsOnly: Bool = false

    private struct LayoutKey: Equatable {
        let treeGeneration: UInt64
        let rootPath: String
        let isRoot: Bool
        let baseDepth: Int
        let maxDepth: Int
        let layoutMode: LayoutMode
        let hideFreeSpace: Bool
        let vZoomKey: Int
        let vpWidth: Int
        let vpHeight: Int
    }

    private var lastLayoutKey: LayoutKey?
    private var hoveredBlock: RenderedBlock?
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea {
            removeTrackingArea(ta)
        }
        let ta = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(ta)
        trackingArea = ta
    }

    func configure(
        root: ViewNode?,
        treeGeneration: UInt64,
        volume: VolumeInfo?,
        isRoot: Bool,
        baseDepth: Int,
        maxDepth: Int,
        layoutMode: LayoutMode,
        hideFreeSpace: Bool,
        highlightRebuildsOnly: Bool,
        vZoom: CGFloat,
        viewportSize: CGSize
    ) {
        let prevHighlight = self.highlightRebuildsOnly
        self.highlightRebuildsOnly = highlightRebuildsOnly

        let key = LayoutKey(
            treeGeneration: treeGeneration,
            rootPath: root?.path ?? "",
            isRoot: isRoot,
            baseDepth: baseDepth,
            maxDepth: maxDepth,
            layoutMode: layoutMode,
            hideFreeSpace: hideFreeSpace,
            vZoomKey: Int((vZoom * 1000).rounded()),
            vpWidth: Int(viewportSize.width.rounded()),
            vpHeight: Int(viewportSize.height.rounded())
        )
        if key == lastLayoutKey {
            if prevHighlight != highlightRebuildsOnly {
                needsDisplay = true
            }
            return
        }
        lastLayoutKey = key

        self.baseDepth = baseDepth
        self.isRoot = isRoot
        self.volumeTotalBytes = max(1, volume?.totalBytes ?? root?.size ?? 1)
        self.volumeUsedBytes = max(1, volume?.usedBytes ?? root?.size ?? 1)
        self.volumeID = volume?.id ?? ""

        guard let root = root else {
            columns = []
            needsDisplay = true
            return
        }

        let vpW = max(320, viewportSize.width)
        let vpH = max(380, viewportSize.height)
        let baseH = max(380, vpH - Self.headerHeight - Self.padBottom)
        let totalH = (baseH * vZoom).rounded()

        // Append System / APFS Snapshots gap slice if at disk root and Used > Scanned
        var rootChildren = root.children
        var rootDisplaySize = root.size
        if isRoot, let vol = volume, vol.usedBytes > root.size {
            let gap = vol.usedBytes - root.size
            if gap > UInt64(Double(vol.totalBytes) * 0.005) {
                rootChildren.append(ViewNode(
                    name: "System / APFS Snapshots",
                    path: "(system-unscanned)",
                    size: gap,
                    apparent: gap,
                    isSystemGap: true
                ))
                rootDisplaySize = vol.usedBytes
            }
        }
        let rootClone = ViewNode(
            name: root.name, path: root.path, size: rootDisplaySize,
            apparent: root.apparent, files: root.files, dirs: root.dirs,
            skipped: root.skipped, isDir: root.isDir, hint: root.hint,
            children: rootChildren
        )

        let showFree = isRoot && !hideFreeSpace && (volume?.totalBytes ?? 0) > 0
        let usedHeight: CGFloat
        if showFree, let vol = volume, vol.totalBytes > 0 {
            usedHeight = CGFloat(Double(min(rootDisplaySize, vol.totalBytes)) / Double(vol.totalBytes)) * totalH
        } else {
            usedHeight = totalH
        }
        self.scaleBytes = showFree ? (volume?.totalBytes ?? max(1, rootDisplaySize)) : max(1, rootDisplaySize)

        let colCount = max(2, maxDepth + 1)
        var rawCols: [[(node: ViewNode, y: CGFloat, h: CGFloat, color: NSColor, inRebuilds: Bool, anc: Set<String>)]] =
            Array(repeating: [], count: colCount)

        func walk(_ node: ViewNode, _ relDepth: Int, _ yStart: CGFloat, _ height: CGFloat, _ color: NSColor, _ anc: Set<String>, _ inRebuilds: Bool) {
            if relDepth >= colCount || height < 1.2 { return }
            let nodeRebuilds = inRebuilds || (node.hint?.safety == .rebuilds)
            let nodeColor = nodeRebuilds ? Self.colorRebuilds : color
            var nextAnc = anc
            nextAnc.insert(node.path)

            rawCols[relDepth].append((node, yStart, height, nodeColor, nodeRebuilds, nextAnc))

            let kids = node.children
            if kids.isEmpty { return }
            let sumKids = kids.reduce(UInt64(0)) { $0 + $1.size }
            let denom = Double(sumKids > 0 ? sumKids : max(1, node.size))
            var curY = yStart
            for (i, child) in kids.enumerated() {
                let ch = CGFloat(Double(child.size) / denom) * height
                let childColor: NSColor
                if relDepth == 0 && !nodeRebuilds {
                    childColor = (child.isSystemGap || child.isGrouped)
                        ? Self.colorMuted
                        : Self.palette[i % Self.palette.count]
                } else if child.isGrouped {
                    childColor = Self.colorMuted
                } else {
                    childColor = nodeColor
                }
                walk(child, relDepth + 1, curY, ch, childColor, nextAnc, nodeRebuilds)
                curY += ch
            }
        }

        walk(rootClone, 0, 0, usedHeight, Self.palette[0], [], false)

        if showFree, let vol = volume, totalH - usedHeight >= 2 {
            let freeNode = ViewNode(
                name: "Available Space",
                path: vol.id + " (available)",
                size: vol.availBytes,
                isFree: true
            )
            rawCols[0].append((freeNode, usedHeight, totalH - usedHeight, Self.colorFreeBG, false, []))
        }

        var lastNonEmpty = colCount - 1
        while lastNonEmpty > 1 && rawCols[lastNonEmpty].isEmpty {
            lastNonEmpty -= 1
        }
        let activeCount = lastNonEmpty + 1

        if layoutMode == .fit {
            let availW = vpW - Self.padX * 2 - Self.colGap * CGFloat(activeCount - 1)
            self.colW = max(78, floor(availW / CGFloat(activeCount)))
        } else {
            self.colW = Self.scrollColWidth
        }

        var newCols: [[RenderedBlock]] = []
        var newColX: [CGFloat] = []
        var curX = Self.padX
        for cIdx in 0..<activeCount {
            newColX.append(curX)
            let baseAlpha: CGFloat = max(0.44, 0.96 - CGFloat(cIdx) * 0.042)
            var blocks: [RenderedBlock] = []
            blocks.reserveCapacity(rawCols[cIdx].count)
            for item in rawCols[cIdx] {
                let gap: CGFloat = item.h >= 10 ? 3 : (item.h >= 5 ? 2 : 1)
                let bh = max(1.5, item.h - gap)
                let rect = CGRect(x: curX, y: Self.headerHeight + item.y, width: colW, height: bh)
                blocks.append(RenderedBlock(
                    node: item.node,
                    colIdx: cIdx,
                    absDepth: baseDepth + cIdx,
                    rect: rect,
                    color: item.color,
                    baseAlpha: item.node.isFree ? 1.0 : baseAlpha,
                    inRebuilds: item.inRebuilds,
                    ancestorPaths: item.anc
                ))
            }
            newCols.append(blocks)
            curX += colW + Self.colGap
        }

        self.columns = newCols
        self.colX = newColX

        let docW = max(vpW, curX - Self.colGap + Self.padX)
        let docH = max(vpH, Self.headerHeight + totalH + Self.padBottom)
        if frame.size != CGSize(width: docW, height: docH) {
            frame = CGRect(x: 0, y: 0, width: docW, height: docH)
        }
        needsDisplay = true
    }

    // MARK: - Hit Testing
    private func block(at point: CGPoint) -> RenderedBlock? {
        guard point.y >= visibleRect.minY + Self.headerHeight else { return nil }
        for (cIdx, x) in colX.enumerated() {
            if point.x >= x && point.x <= x + colW {
                // Binary search vertically inside column
                let list = columns[cIdx]
                var lo = 0
                var hi = list.count - 1
                while lo <= hi {
                    let mid = (lo + hi) / 2
                    let r = list[mid].rect
                    if point.y < r.minY {
                        hi = mid - 1
                    } else if point.y > r.maxY {
                        lo = mid + 1
                    } else {
                        return list[mid]
                    }
                }
                return nil
            }
        }
        return nil
    }

    // MARK: - Mouse Interaction
    override func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let hit = block(at: pt)
        if hit?.node.path != hoveredBlock?.node.path {
            hoveredBlock = hit
            needsDisplay = true
        }
        if let h = hit, let scroll = enclosingScrollView {
            let ptInScroll = scroll.convert(event.locationInWindow, from: nil)
            let flippedPt = CGPoint(x: ptInScroll.x, y: scroll.bounds.height - ptInScroll.y)
            let pctUsed = Double(h.node.size) / Double(volumeUsedBytes) * 100.0
            let pctDisk = Double(h.node.size) / Double(volumeTotalBytes) * 100.0
            let info = HoverTooltipState(
                absDepth: h.absDepth,
                path: h.node.path,
                name: h.node.name,
                size: h.node.size,
                files: h.node.files,
                pctUsed: pctUsed,
                pctDisk: pctDisk,
                hint: h.node.hint,
                pointInContainer: flippedPt
            )
            Task { @MainActor [weak self] in
                self?.coordinator?.updateHover(info)
            }
        } else {
            Task { @MainActor [weak self] in
                self?.coordinator?.updateHover(nil)
            }
        }
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredBlock != nil {
            hoveredBlock = nil
            needsDisplay = true
        }
        Task { @MainActor [weak self] in
            self?.coordinator?.updateHover(nil)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        guard let hit = block(at: pt) else { return }
        let n = hit.node
        guard n.isDir, !n.isFree, !n.isSystemGap, !n.isGrouped else { return }
        Task { @MainActor [weak self] in
            self?.coordinator?.updateHover(nil)
            self?.coordinator?.model.openTree(volumeID: self?.volumeID ?? "", path: n.path, resetZoom: true)
        }
    }

    // Native macOS right-click context menu!
    override func menu(for event: NSEvent) -> NSMenu? {
        let pt = convert(event.locationInWindow, from: nil)
        guard let hit = block(at: pt) else { return nil }
        let n = hit.node
        guard !n.isFree, !n.isSystemGap, !n.isGrouped else { return nil }

        let menu = NSMenu(title: n.name)
        if let hint = n.hint {
            let header = NSMenuItem(title: "\(hint.label) — \(hint.tag)", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(.separator())
        }

        if n.isDir {
            let zoomItem = NSMenuItem(title: "Zoom Into Folder", action: #selector(ctxZoom(_:)), keyEquivalent: "")
            zoomItem.target = self
            zoomItem.representedObject = n
            menu.addItem(zoomItem)
        }

        if !n.path.hasSuffix("(direct files)") {
            let revealItem = NSMenuItem(title: "Reveal in Finder", action: #selector(ctxReveal(_:)), keyEquivalent: "")
            revealItem.target = self
            revealItem.representedObject = n
            menu.addItem(revealItem)
        }

        if n.isDir && !n.path.hasSuffix("(direct files)") && n.path != volumeID {
            if n.hint?.safety == .rebuilds {
                let unmark = NSMenuItem(title: "Remove \"Rebuildable\" Tag", action: #selector(ctxUnmark(_:)), keyEquivalent: "")
                unmark.target = self
                unmark.representedObject = n
                menu.addItem(unmark)
            } else {
                let mark = NSMenuItem(title: "Mark as \"Rebuildable\"", action: #selector(ctxMark(_:)), keyEquivalent: "")
                mark.target = self
                mark.representedObject = n
                menu.addItem(mark)
            }
        }

        if TrashManager.isTrashable(path: n.path, volumeID: volumeID) {
            menu.addItem(.separator())
            let trashItem = NSMenuItem(
                title: "Move to Trash (\(Formatters.bytes(n.size)))",
                action: #selector(ctxTrash(_:)),
                keyEquivalent: ""
            )
            trashItem.target = self
            trashItem.representedObject = n
            menu.addItem(trashItem)
        }

        return menu.items.isEmpty ? nil : menu
    }

    @objc private func ctxZoom(_ sender: NSMenuItem) {
        guard let n = sender.representedObject as? ViewNode else { return }
        Task { @MainActor [weak self] in
            self?.coordinator?.model.openTree(volumeID: self?.volumeID ?? "", path: n.path, resetZoom: true)
        }
    }

    @objc private func ctxReveal(_ sender: NSMenuItem) {
        guard let n = sender.representedObject as? ViewNode else { return }
        Task { @MainActor [weak self] in
            self?.coordinator?.model.revealInFinder(path: n.path)
        }
    }

    @objc private func ctxMark(_ sender: NSMenuItem) {
        guard let n = sender.representedObject as? ViewNode else { return }
        Task { @MainActor [weak self] in
            self?.coordinator?.model.markRebuilds(path: n.path, label: n.name)
        }
    }

    @objc private func ctxUnmark(_ sender: NSMenuItem) {
        guard let n = sender.representedObject as? ViewNode else { return }
        Task { @MainActor [weak self] in
            self?.coordinator?.model.unmarkRebuilds(path: n.path, label: n.name)
        }
    }

    @objc private func ctxTrash(_ sender: NSMenuItem) {
        guard let n = sender.representedObject as? ViewNode else { return }
        Task { @MainActor [weak self] in
            self?.coordinator?.model.moveToTrash(path: n.path)
        }
    }

    // MARK: - CoreGraphics Drawing (120fps)
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        dirtyRect.fill()

        guard !columns.isEmpty else { return }

        let titleFont = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        let subFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        let hintFont = NSFont.systemFont(ofSize: 10, weight: .medium)
        let headFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail

        let hovered = hoveredBlock

        for cIdx in 0..<columns.count {
            let x = colX[cIdx]
            if x + colW < dirtyRect.minX || x > dirtyRect.maxX { continue }

            for blk in columns[cIdx] {
                let r = blk.rect
                if r.maxY < dirtyRect.minY || r.minY > dirtyRect.maxY { continue }

                let alpha: CGFloat
                var borderColor = NSColor(white: 1.0, alpha: 0.08)
                var borderWidth: CGFloat = 1.0

                if let h = hovered {
                    let hp = h.node.path
                    let p = blk.node.path
                    let isSelf = (p == hp)
                    let isAnc = h.ancestorPaths.contains(p)
                    let isDesc = !h.node.isFree && !h.node.isSystemGap && (
                        (hp == "/" && p.hasPrefix("/") && p != "/" && !p.contains("(available)")) ||
                        (hp != "/" && p.hasPrefix(hp + "/"))
                    )
                    if isSelf {
                        alpha = 1.0
                        borderColor = NSColor(srgbRed: 214/255, green: 235/255, blue: 253/255, alpha: 0.95)
                        borderWidth = 1.5
                    } else if isAnc || isDesc {
                        alpha = 0.96
                        borderColor = NSColor(white: 1.0, alpha: 0.25)
                    } else {
                        alpha = 0.16
                    }
                } else if highlightRebuildsOnly {
                    if blk.inRebuilds {
                        alpha = 1.0
                        borderColor = NSColor(srgbRed: 167/255, green: 243/255, blue: 208/255, alpha: 0.85)
                        borderWidth = 1.2
                    } else {
                        alpha = 0.15
                    }
                } else {
                    alpha = blk.baseAlpha
                    if blk.inRebuilds {
                        borderColor = NSColor(srgbRed: 167/255, green: 243/255, blue: 208/255, alpha: 0.45)
                    } else if blk.node.isFree {
                        borderColor = NSColor(white: 1.0, alpha: 0.11)
                    }
                }

                let radius: CGFloat = r.height >= 20 ? 7 : (r.height >= 11 ? 4 : (r.height >= 5 ? 2.5 : 1))
                let path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)

                blk.color.withAlphaComponent(alpha).setFill()
                path.fill()

                borderColor.setStroke()
                path.lineWidth = borderWidth
                path.stroke()

                // Text inside tiles when tall enough
                if r.height >= 20 {
                    let showSub = r.height >= 36
                    let showHintLine = (blk.node.hint != nil && r.height >= 54)
                    let showHintDot = (blk.node.hint != nil && !showHintLine)

                    let textColor: NSColor = blk.node.isFree
                        ? NSColor(srgbRed: 0x8a/255, green: 0x8a/255, blue: 0x93/255, alpha: alpha)
                        : NSColor(white: 1.0, alpha: alpha)
                    let subColor: NSColor = blk.node.isFree
                        ? NSColor(srgbRed: 0x8a/255, green: 0x8a/255, blue: 0x93/255, alpha: alpha)
                        : NSColor(white: 1.0, alpha: alpha * 0.85)

                    let totalTextH: CGFloat = showHintLine ? 44 : (showSub ? 28 : 14)
                    var ty = r.midY - totalTextH / 2.0
                    var tx = r.minX + 8
                    let maxW = max(8, r.width - 16)

                    if showHintDot, let hint = blk.node.hint {
                        let dotRect = CGRect(x: tx, y: ty + 4, width: 6, height: 6)
                        let dotColor: NSColor = hint.safety == .rebuilds
                            ? NSColor(srgbRed: 209/255, green: 250/255, blue: 229/255, alpha: alpha)
                            : NSColor(srgbRed: 252/255, green: 211/255, blue: 77/255, alpha: alpha)
                        dotColor.setFill()
                        NSBezierPath(ovalIn: dotRect).fill()
                        tx += 10
                    }

                    let titleAttrs: [NSAttributedString.Key: Any] = [
                        .font: titleFont,
                        .foregroundColor: textColor,
                        .paragraphStyle: paragraph
                    ]
                    let titleRect = CGRect(x: tx, y: ty, width: max(8, r.maxX - 8 - tx), height: 15)
                    (blk.node.name as NSString).draw(in: titleRect, withAttributes: titleAttrs)
                    ty += 15

                    if showSub {
                        let pct = Double(blk.node.size) / Double(max(1, scaleBytes)) * 100.0
                        let subStr = String(format: "%@ · %.1f%%", Formatters.bytes(blk.node.size), pct)
                        let subAttrs: [NSAttributedString.Key: Any] = [
                            .font: subFont,
                            .foregroundColor: subColor,
                            .paragraphStyle: paragraph
                        ]
                        (subStr as NSString).draw(
                            in: CGRect(x: r.minX + 8, y: ty, width: maxW, height: 14),
                            withAttributes: subAttrs
                        )
                        ty += 15
                    }

                    if showHintLine, let hint = blk.node.hint {
                        let hintStr = "\(hint.tag) · \(hint.label)"
                        let hintAttrs: [NSAttributedString.Key: Any] = [
                            .font: hintFont,
                            .foregroundColor: NSColor(white: 1.0, alpha: alpha * 0.92),
                            .paragraphStyle: paragraph
                        ]
                        (hintStr as NSString).draw(
                            in: CGRect(x: r.minX + 8, y: ty, width: maxW, height: 13),
                            withAttributes: hintAttrs
                        )
                    }
                }
            }
        }

        // Sticky Column Headers pinned to visibleRect.minY
        let stickyY = visibleRect.minY
        let headerBand = CGRect(x: dirtyRect.minX, y: stickyY, width: dirtyRect.width, height: Self.headerHeight)
        NSColor.black.setFill()
        headerBand.fill()

        let headMuted = NSColor(srgbRed: 0x8a/255, green: 0x8a/255, blue: 0x93/255, alpha: 1)
        let headDim = NSColor(srgbRed: 0x8a/255, green: 0x8a/255, blue: 0x93/255, alpha: 0.6)

        for cIdx in 0..<columns.count {
            let x = colX[cIdx]
            if x + colW < dirtyRect.minX || x > dirtyRect.maxX { continue }

            let title = (isRoot && cIdx == 0) ? "L0 · Disk" : "L\(baseDepth + cIdx)"
            let countStr = "\(columns[cIdx].count)"

            (title as NSString).draw(
                at: NSPoint(x: x + 6, y: stickyY + 5),
                withAttributes: [.font: headFont, .foregroundColor: headMuted]
            )
            let countSize = (countStr as NSString).size(withAttributes: [.font: headFont])
            (countStr as NSString).draw(
                at: NSPoint(x: x + colW - countSize.width - 6, y: stickyY + 5),
                withAttributes: [.font: headFont, .foregroundColor: headDim]
            )
        }
    }
}
