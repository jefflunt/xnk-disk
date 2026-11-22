# XNK Disk — Architecture & Design Notes

## Overview

**XNK Disk** is a single-process native macOS desktop disk space analyzer built in **Swift, SwiftUI, and AppKit** (Swift Package Manager, `arm64`, macOS 14+) with zero third-party dependencies, zero webviews, and a 120Hz CoreGraphics **Horizontal Icicle** visualization (~1.5 MB release binary).

## Key Architectural Decisions

### 1. Single-Process Native SwiftUI + AppKit Shell (`Sources/XnkDisk/`)
- [XnkDiskApp.swift](../Sources/XnkDisk/XnkDiskApp.swift) launches a native macOS `WindowGroup` with dark appearance and keyboard shortcuts (`⌘Z` Undo, `⌘+`/`⌘−`/`⌘0` vertical zoom).
- [AppModel.swift](../Sources/XnkDisk/AppModel.swift) is a `@MainActor ObservableObject` coordinating volume discovery, multi-core scans, live progress polling, Trash/Undo, custom rules, and view state directly in-process—eliminating any local HTTP server or `WKWebView` helper processes. All heavy work (LZFSE cache loading, volume discovery, `projectView` / `collectRebuildableFolders` / `sortRecursive` on a serial `treeQueue`, and `FileManager` Trash/Undo IPC) runs off the main thread so the UI stays 120fps responsive.
- [ContentView.swift](../Sources/XnkDisk/ContentView.swift) uses native macOS controls: `Picker(.segmented)` for **Scrollable | Fit**, `Picker(.menu)` for **Depth**, canonical `.toggleStyle(.switch)` controls for **Group `<1.2%`**, **Hide Free Space**, and **Rebuildable**, SF Symbols, Drives Overview cards, floating frosted HUD tooltips, and action toasts. All toolbar view toggles and layout/depth preferences persist automatically across launches via [UserPreferences.swift](../Sources/XnkDiskCore/UserPreferences.swift) (`UserDefaults`).

### 2. macOS Volume Discovery & APFS Handling (`Sources/XnkDiskCore/Volume.swift`)
- Uses Darwin `getfsstat` (`MNT_NOWAIT`) to list mounted volumes instantly on launch with live **Used vs. Available** stats.
- Filters out pseudo-filesystems (`devfs`, `autofs`, `volfs`, `nullfs`, `lifs`, `fdesc`), internal system mounts, and `MNT_DONTBROWSE` volumes.
- Resolves the friendly boot volume name (e.g., `Macintosh HD`) via `/Volumes` symlink inspection.
- Tracks both `/` (SSV) and `/System/Volumes/Data` (fallback `/Users`) device IDs in `allowedDevs` so scanning `/` traverses APFS firmlinks (`/Users`, `/Applications`, `/Library`, `/opt`) without double-counting `/System/Volumes/Data` or crossing into `/Volumes/*`.

### 3. Multi-Core Parallel POSIX Scanner (`Sources/XnkDiskCore/Scanner.swift`)
- **Explicit on-demand scanning only**: scans run only when the user clicks **Scan Disk** or **Rescan** (with instant **Cancel** support).
- **Concurrency**: Uses raw Darwin `opendir`/`readdir` + `lstat` on a `.utility` QoS concurrent `DispatchQueue` with a non-blocking `DispatchSemaphore` worker pool (`2 * activeProcessorCount`, capped at 24) that dispatches subdirectories in parallel when capacity is available and falls back to inline recursion when saturated—saturating NVMe I/O without recursive deadlocks or starving UI events.
- **Accuracy**:
  - Measures actual allocated blocks (`st_blocks * 512`) so sparse files and evicted iCloud files don't distort disk usage.
  - Deduplicates hard links (`st_nlink > 1`) across a 64-shard `os_unfair_lock` `(st_dev, st_ino)` set.
  - Never follows symlinks.
  - Gracefully counts `EPERM`/`EACCES` directories (macOS TCC restrictions) without failing the scan.

### 4. Persistent LZFSE Scan Cache (`Sources/XnkDiskCore/ScanCache.swift`)
- Completed scans—as well as live tree updates from **Move to Trash** and **Undo**—are atomically persisted as binary PropertyLists compressed with hardware-accelerated **LZFSE** in `~/Library/Caches/com.jefflunt.xnk-disk/scans-native/`.
- On startup, `AppModel` reloads cached scans immediately so users can open **View Breakdown** without rescanning.

### 5. Safe Native Trash, Purge Rebuildable & Undo (`Sources/XnkDiskCore/TrashManager.swift`)
- Uses `FileManager.default.trashItem(at:resultingItemURL:)` to move files/folders to the native macOS Trash.
- **Purge Rebuildable**: Scoped to the currently focused folder, displays a confirmation sheet listing every rebuildable folder and total size, then moves each rebuildable folder's immediate top-level children to Trash while keeping the folder itself intact.
- Records top-level `(originalPath, trashedPath)` pairs and `PurgedFolderSnapshot`s (or single removed nodes) in a unified `UndoEntry` stack, restoring all purged items via `FileManager.default.moveItem(at:to:)` and updating the in-memory `DiskNode` tree (`removePath` / `restoreNode` / `clearDirectoryContents` / `restoreDirectoryContents`) on **Undo** or `⌘Z`.
- **Safety**: Protected system/root paths (`/`, `/System`, `/Users`, `/Applications`, volume mount points, etc.) are rejected; permanent deletion and Empty Trash are intentionally omitted.

### 6. CoreGraphics Horizontal Icicle & Developer Cache Classification (`Sources/XnkDisk/IcicleView.swift`, `Sources/XnkDiskCore/DevCache.swift`, `Sources/XnkDiskCore/CustomRules.swift`)
- **120Hz Native Rendering**: `IcicleDocumentView` (`NSView` inside `IcicleScrollView: NSScrollView`) draws rounded icicle tiles directly with CoreGraphics, with `LayoutKey` memoization (so hover tooltips never rebuild layout geometry), sticky `L0 · Disk`, `L1`, `L2` column headers pinned to `visibleRect.minY`, binary-search hit testing, hover lineage highlighting, and native `NSMenu` right-click context menus.
- **Vertical-Only Pinch-to-Zoom & Scrolling**: `IcicleScrollView` overrides `-magnify(with:)` to stream continuous native AppKit trackpad magnification deltas anchored to the cursor (`1×` to `25×`), expanding icicle blocks vertically while keeping column widths fixed.
- **Developer Cache Classification & Custom Rules**: Classifies ~30 high-confidence macOS developer caches and space consumers during `projectView` using sibling-file checks (`Cargo.toml`, `pom.xml`, `Podfile`, `package.json`, `pyproject.toml`, `build.gradle`). Annotates tooltips, tall tiles, and context menus with friendly names and cautious tags (**`Rebuildable`** vs. **`May hold your data`**). Emerald (`#10b981`) is reserved exclusively for **`Rebuildable`** caches (removed from the general folder palette), and enabling the **`Rebuildable`** macOS toggle switch dims non-cache tiles so only cleanable caches stay highlighted. Users customize rules via right-click (**Mark as "Rebuildable"** / **Remove "Rebuildable" Tag**), persisted atomically in `~/Library/Application Support/com.jefflunt.xnk-disk/rules.json`.
