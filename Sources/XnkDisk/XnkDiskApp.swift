import SwiftUI
import AppKit

@main
struct XnkDiskApp: App {
    @StateObject private var model = AppModel()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("XNK Disk") {
            ContentView(model: model)
                .frame(minWidth: 860, minHeight: 540)
        }
        .defaultSize(width: 1320, height: 820)
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("Undo Move to Trash") {
                    model.undoLastTrash()
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(model.undoStack.isEmpty)
            }
            CommandGroup(after: .toolbar) {
                Button("Zoom In Vertically") {
                    model.adjustZoom(multiplier: 1.35)
                }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(model.viewMode != .icicle)

                Button("Zoom Out Vertically") {
                    model.adjustZoom(multiplier: 1.0 / 1.35)
                }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(model.viewMode != .icicle)

                Button("Reset Vertical Zoom") {
                    model.resetZoom()
                }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(model.viewMode != .icicle || model.vZoom <= 1.01)
            }
        }
    }
}
