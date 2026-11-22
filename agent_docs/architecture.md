# XNK Disk — Architecture & Design Notes

## Overview

**XNK Disk** is a native macOS desktop disk space analyzer built in Go (`darwin/arm64`) with zero third-party Go modules, zero Node/Electron/Qt dependencies, and a native Cocoa `NSWindow` + `WKWebView` shell.

## Key Architectural Decisions

### 1. Native macOS Desktop Window via CGo + Cocoa (`internal/macui`)
- [webview_darwin.m](../internal/macui/webview_darwin.m) and [webview_darwin.go](../internal/macui/webview_darwin.go) host an `NSApplication` + `NSWindow` (`NSAppearanceNameDarkAqua`) containing a full-bleed `WKWebView`.
- `runtime.LockOSThread()` is called in `init()` on both `main` and `macui` so AppKit always executes on the primary OS thread.
- The Go backend starts a loopback HTTP + SSE server on `127.0.0.1:0` ([server.go](../internal/server/server.go)) serving the embedded `web/` assets (`//go:embed`).

### 2. macOS Volume Discovery & APFS Handling (`internal/volumes`)
- Uses `syscall.Getfsstat` (`MNT_NOWAIT`) to list mounted volumes instantly on launch (<10ms) with live **Used vs. Available** stats.
- Filters out pseudo-filesystems (`devfs`, `autofs`, `volfs`, `nullfs`, `lifs`, `fdesc`), internal system mounts, and `MNT_DONTBROWSE` volumes (such as `/Volumes/Recovery`).
- Resolves the friendly boot volume name (e.g., `Macintosh HD`) via `/Volumes` symlink inspection.
- Tracks both `/` (SSV) and `/System/Volumes/Data` (fallback `/Users`) device IDs in `AllowedDevs` so scanning `/` traverses APFS firmlinks (`/Users`, `/Applications`, `/Library`, `/opt`) without double-counting `/System/Volumes/Data` or crossing into `/Volumes/*`.

### 3. Parallel Multi-Core Scanner (`internal/scanner`)
- **Explicit on-demand scanning only**: scans run only when the user clicks **Scan Disk** or **Rescan** (with **Cancel** support via `context.Context`).
- **Concurrency**: Bounded non-blocking worker pool semaphore (`sem := make(chan struct{}, workers)`, `2 * NumCPU` capped at 24) that dispatches subdirectories to goroutines when capacity is available and falls back to inline recursion when saturated—avoiding recursive deadlocks while saturating NVMe I/O.
- **Accuracy**:
  - Measures actual allocated blocks (`st_blocks * 512`) so sparse files and evicted iCloud files don't distort disk usage.
  - Deduplicates hard links (`st_nlink > 1`) across a 64-shard `(st_dev, st_ino)` map.
  - Never follows symlinks.
  - Gracefully counts `EPERM`/`EACCES` directories (macOS TCC restrictions) without failing the scan.
- **Live progress**: Streams atomic counters (`files`, `dirs`, `bytes`, `currentPath`, `workers`) over SSE (`/api/scan/events`) every 80ms.

### 4. Persistent Scan Cache (`internal/scanner/cache.go`)
- Completed scans—as well as live tree updates from **Move to Trash** and **Undo**—are atomically persisted (temp file + `os.Rename`) as gzip-compressed `gob` archives in `~/Library/Caches/com.jefflunt.xnk-disk/scans/`.
- On startup, `server.New()` reloads all cached scans so users can immediately open **View Breakdown** without rescanning.

### 5. Safe Native Trash & Undo (`internal/trash`)
- Uses Objective-C `NSFileManager`'s `trashItemAtURL:resultingItemURL:error:` to move files/folders to the native macOS Trash (internal and external volumes).
- Records `resultingItemURL` on an in-memory Undo stack and restores items via `moveItemAtURL:toURL:error:` on **Undo** or `⌘Z`.
- Prunes and re-inserts nodes directly in the in-memory tree (`RemovePath` / `RestoreNode`) so the visualization updates instantaneously.
- **Safety**: Protected system/root paths (`/`, `/System`, `/Users`, `/Applications`, volume mount points, etc.) are rejected; permanent deletion and Empty Trash are intentionally omitted.

### 6. Horizontal Icicle Visualization & XNK Visual Identity (`web/`, `assets/`)
- **Layout & Consistent Controls**: Left-to-right **Horizontal Icicle** (`L0 · Disk` Used/Available on the left, deeper folder levels to the right). The top toolbar houses drive pills (with embedded `%` used, avoiding redundant Used/Avail and file-count readouts) and all view controls at uniform `26px` height: **Scrollable | Fit** segmented control, **Depth** custom-chevron select (`5`, `10` default, `20`, `50`, `Unlimited`), and canonical macOS sliding toggle switches for **Group `<1.2%`**, **Hide Free Space**, and **Rebuilds Itself**. The breadcrumb bar is dedicated to path navigation and focused-folder actions (**Undo**, **Move to Trash**, **Reveal in Finder**) at uniform `24px` height with matching icons.
- **Vertical-Only Pinch-to-Zoom & Scrolling**: `XnkWebView` (a `WKWebView` subclass in [webview_darwin.m](../internal/macui/webview_darwin.m)) overrides `-magnifyWithEvent:` to stream continuous native AppKit trackpad magnification deltas and cursor Y coordinates directly to `window.__xnkMagnify` (immune to WebKit DOM `gesturechange` detachment during `innerHTML` re-renders), with a `wheel` + `ctrlKey` fallback and `⌘+`/`⌘−`/`⌘0` shortcuts. Zoom expands icicle blocks vertically (`1×` to `25×`) anchored to the cursor while keeping column widths fixed, with vertical viewport scrolling, sticky level column headers, and a toolbar reset pill (`1.0×`).
- **Developer Cache Classification & Custom Rules (`internal/scanner/devcache.go`, `internal/scanner/rules.go`)**: Classifies ~30 high-confidence macOS developer caches and space consumers during `ProjectView` (so existing cached scans immediately receive hints without rescanning), using sibling-file checks (`Cargo.toml`, `pom.xml`, `Podfile`, `package.json`, `pyproject.toml`, `build.gradle`) to avoid false positives on generic folder names. Annotates tooltips, tall tiles, and context menus with friendly names and cautious tags (**`Rebuilds itself`** vs. **`May hold your data`**). Enabling the **`Rebuilds Itself`** macOS toggle switch dims non-cache tiles so only cleanable caches stay highlighted. Users customize rules safely via right-click (**Mark as "Rebuilds Itself"** / **Remove "Rebuilds Itself" Tag**), persisted atomically in `~/Library/Application Support/com.jefflunt.xnk-disk/rules.json`.
- **Interaction**: Ancestor-to-descendant **Lineage Highlighting** on hover with a floating tooltip, **Click-to-Zoom & Re-anchoring**, top **Breadcrumbs**, and right-click context menu (*Zoom Into Folder*, *Reveal in Finder*, *Mark/Remove "Rebuilds Itself"*, *Move to Trash*).
- **Branding**: Grounded in the `xnk` design system (`#000000` void, `#0c0c0e`/`#141417` obsidian surfaces, frost hairlines) with **Blue (`#2f81f7`)** as primary, **Orange (`#ff7722`)** as contrast accent, **Emerald (`#10b981`)** reserved exclusively for recognized **`Rebuilds itself`** developer caches (removed from the general folder palette), rounded icicle tiles, and a matching Concept 01 Retina `.icns` app icon generated by [make-icon.swift](../scripts/make-icon.swift).
