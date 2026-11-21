# XNK Disk

A fast, native macOS disk space analyzer written in Go with a standalone Cocoa/`WKWebView` desktop window and a left-to-right **Horizontal Icicle** visualization.

## Features
- **Instant Drive Overview:** Shows live **Used vs. Available** capacity for installed macOS volumes via `statfs`.
- **On-Demand Parallel Multi-Core Scanning:** Scans only when you click **Scan Disk** or **Rescan**, parallelizing across CPU cores with APFS firmlink awareness, `st_blocks` allocated sizing, and hard-link deduplication.
- **Persistent Scan Cache:** Automatically caches scan results in `~/Library/Caches/com.jefflunt.xnk-disk/scans/` so previous results load immediately on relaunch.
- **Horizontal Icicle Visualization:** Scrollable (or Fit-to-window) depth columns (`5`, `10`, `20`, `50`, or `Unlimited`), hover lineage highlighting with floating tooltips, click-to-zoom re-anchoring, and top breadcrumbs.
- **Safe Move to Trash + Undo:** Moves files/folders to the native macOS Trash via `NSFileManager` with instant **Undo** (`⌘Z`) and live tree updates (no permanent deletion or Empty Trash).

## Build & Run (macOS)

```bash
bash scripts/build-app.sh
open "dist/XNK Disk.app"
```

## Tests

```bash
go test -v ./...
```
