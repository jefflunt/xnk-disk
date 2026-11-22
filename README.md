# XNK Disk

A fast, single-process native macOS disk space analyzer written in Swift, SwiftUI, and AppKit with a CoreGraphics left-to-right **Horizontal Icicle** visualization.

## Features
- **Instant Drive Overview:** Shows live **Used vs. Available** capacity for mounted macOS volumes via Darwin `getfsstat`.
- **On-Demand Multi-Core Scanning:** Parallel POSIX scanner (`opendir`/`readdir` + `lstat`) across CPU cores with APFS firmlink awareness, `st_blocks` allocated sizing, and 64-shard hard-link deduplication.
- **Persistent LZFSE Scan Cache:** Automatically persists scan results in `~/Library/Caches/com.jefflunt.xnk-disk/scans-native/` so previous results load immediately on relaunch.
- **CoreGraphics Horizontal Icicle:** 120Hz `NSScrollView` scrolling, native AppKit two-finger vertical pinch-to-zoom, sticky depth headers, hover lineage highlighting with floating HUD tooltips, click-to-zoom re-anchoring, and top breadcrumbs.
- **Developer Cache Labels & Safety Tags:** Recognizes ~30 macOS developer caches (`DerivedData`, `CoreSimulator`, `node_modules`, Homebrew, Cargo, Go, Gradle, etc.) with cautious tags (`Rebuildable` / `May hold your data`), a dedicated Emerald highlight + toggle, and right-click customization.
- **Safe Move to Trash + Undo:** Moves files/folders to the native macOS Trash via `FileManager.trashItem` with instant **Undo** (`⌘Z`) and live tree updates.

## Build & Run (macOS 14+)

```bash
bash scripts/build-app.sh
open "dist/XNK Disk.app"
```

## Tests

```bash
swift test
```
