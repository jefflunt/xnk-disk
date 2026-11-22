import AppKit
import SwiftUI
import XnkDiskCore

@MainActor
final class ManagedWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    let model: AppModel
    weak var manager: WindowManager?

    init(state: SavedWindowState, manager: WindowManager) {
        self.model = AppModel(savedState: state, store: .shared)
        self.manager = manager

        let initialRect: NSRect
        if let f = state.frame, f.width >= 600, f.height >= 400 {
            initialRect = NSRect(x: f.x, y: f.y, width: f.width, height: f.height)
        } else {
            initialRect = NSRect(x: 0, y: 0, width: 1320, height: 820)
        }

        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let win = NSWindow(
            contentRect: initialRect,
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        win.minSize = NSSize(width: 860, height: 540)
        win.appearance = NSAppearance(named: .darkAqua)
        win.backgroundColor = .black
        win.isReleasedWhenClosed = false
        win.title = model.windowTitle

        let host = NSHostingView(rootView: ContentView(model: model))
        win.contentView = host
        self.window = win

        super.init()
        win.delegate = self

        if state.frame == nil {
            if let keyWin = NSApp.keyWindow {
                let topLeft = NSPoint(x: keyWin.frame.minX + 28, y: keyWin.frame.maxY - 28)
                win.cascadeTopLeft(from: topLeft)
            } else {
                win.center()
            }
        }

        model.onStateChanged = { [weak self] in
            guard let self else { return }
            self.window.title = self.model.windowTitle
            self.manager?.scheduleSave()
        }
    }

    func snapshot() -> SavedWindowState {
        let f = window.frame
        let rect = WindowRect(
            x: Double(f.origin.x),
            y: Double(f.origin.y),
            width: Double(f.size.width),
            height: Double(f.size.height)
        )
        return model.snapshotState(frame: rect)
    }

    func windowDidMove(_ notification: Notification) {
        manager?.scheduleSave()
    }

    func windowDidResize(_ notification: Notification) {
        manager?.scheduleSave()
    }

    func windowWillClose(_ notification: Notification) {
        manager?.handleWindowClosed(self)
    }
}

@MainActor
final class WindowManager: NSObject, NSApplicationDelegate {
    static let shared = WindowManager()

    private var managedWindows: [ManagedWindow] = []
    private var isTerminating = false
    private var saveTimer: Timer?

    var keyModel: AppModel? {
        if let keyWin = NSApp.keyWindow,
           let match = managedWindows.first(where: { $0.window === keyWin }) {
            return match.model
        }
        return managedWindows.first?.model
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenus()

        // Ensure shared DiskStore boots immediately.
        _ = DiskStore.shared

        let saved = WindowSessionStore.load()
        if saved.isEmpty {
            // Migrate legacy single-window preferences if present on first run of multi-window.
            let legacy = PreferencesStore.load()
            let initial = SavedWindowState(
                layoutModeRaw: legacy.layoutModeRaw,
                maxDepth: legacy.maxDepth,
                groupSmall: legacy.groupSmall,
                hideFreeSpace: legacy.hideFreeSpace,
                highlightRebuildsOnly: legacy.highlightRebuildsOnly
            )
            openWindow(state: initial)
        } else {
            for st in saved {
                openWindow(state: st)
            }
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        saveNow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            openNewWindow()
        }
        return true
    }

    @discardableResult
    func openWindow(state: SavedWindowState) -> ManagedWindow {
        let mw = ManagedWindow(state: state, manager: self)
        managedWindows.append(mw)
        mw.window.makeKeyAndOrderFront(nil)
        scheduleSave()
        return mw
    }

    @objc func openNewWindow() {
        let state = SavedWindowState()
        openWindow(state: state)
    }

    func handleWindowClosed(_ mw: ManagedWindow) {
        guard !isTerminating else { return }
        managedWindows.removeAll { $0 === mw }
        saveNow()
    }

    func scheduleSave() {
        guard !isTerminating else { return }
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.saveNow()
            }
        }
    }

    func saveNow() {
        saveTimer?.invalidate()
        saveTimer = nil
        let snapshots = managedWindows.map { $0.snapshot() }
        WindowSessionStore.save(snapshots)
    }

    // MARK: - Menu Bar
    private func setupMenus() {
        let menubar = NSMenu()

        // App Menu
        let appMenuItem = NSMenuItem()
        menubar.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About XNK Disk", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide XNK Disk", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit XNK Disk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        // File Menu
        let fileMenuItem = NSMenuItem()
        menubar.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        let newWin = NSMenuItem(title: "New Window", action: #selector(openNewWindow), keyEquivalent: "n")
        newWin.target = self
        fileMenu.addItem(newWin)
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenuItem.submenu = fileMenu

        // Edit Menu
        let editMenuItem = NSMenuItem()
        menubar.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        let undoItem = NSMenuItem(title: "Undo Move to Trash", action: #selector(menuUndo), keyEquivalent: "z")
        undoItem.target = self
        editMenu.addItem(undoItem)
        editMenuItem.submenu = editMenu

        // View Menu
        let viewMenuItem = NSMenuItem()
        menubar.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        let zoomIn = NSMenuItem(title: "Zoom In Vertically", action: #selector(menuZoomIn), keyEquivalent: "+")
        zoomIn.target = self
        viewMenu.addItem(zoomIn)
        let zoomOut = NSMenuItem(title: "Zoom Out Vertically", action: #selector(menuZoomOut), keyEquivalent: "-")
        zoomOut.target = self
        viewMenu.addItem(zoomOut)
        let zoomReset = NSMenuItem(title: "Reset Vertical Zoom", action: #selector(menuZoomReset), keyEquivalent: "0")
        zoomReset.target = self
        viewMenu.addItem(zoomReset)
        viewMenuItem.submenu = viewMenu

        // Window Menu
        let windowMenuItem = NSMenuItem()
        menubar.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu

        NSApp.mainMenu = menubar
        NSApp.windowsMenu = windowMenu
    }

    @objc private func menuUndo() {
        keyModel?.undoLastTrash()
    }

    @objc private func menuZoomIn() {
        guard let m = keyModel, m.viewMode == .icicle else { return }
        m.adjustZoom(multiplier: 1.35)
    }

    @objc private func menuZoomOut() {
        guard let m = keyModel, m.viewMode == .icicle else { return }
        m.adjustZoom(multiplier: 1.0 / 1.35)
    }

    @objc private func menuZoomReset() {
        guard let m = keyModel, m.viewMode == .icicle else { return }
        m.resetZoom()
    }
}

@main
struct XnkDiskEntry {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = WindowManager.shared
        app.delegate = delegate
        app.run()
    }
}
