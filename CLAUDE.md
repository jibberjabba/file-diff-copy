# File Diff Copy — Project Instructions

## Project Overview

A native macOS desktop application that copies files from a **source folder** to a **destination folder**, only copying files that are newer than what already exists at the destination. Four comparison modes: Fast, Thorough, Archive, Mirror.

**Tech stack:** Swift + SwiftUI, macOS 13+ target, no third-party dependencies.

---

## Project File Structure

```
MacOSFileCopyTool/
├── MacOSFileCopyToolApp.swift      # @main, AppDelegate (window sizing)
├── ContentView.swift               # Main layout, window resize logic
├── Views/
│   ├── FolderPickerRow.swift
│   ├── ProgressSection.swift
│   ├── LogView.swift
│   └── MirrorConfirmationView.swift
├── ViewModel/
│   └── FileSyncViewModel.swift     # @MainActor ObservableObject
├── Engine/
│   └── FileSyncEngine.swift        # Pure Swift — ComparisonMode enum lives here
├── Utilities/
│   └── BookmarkManager.swift
└── MacOSFileCopyTool.entitlements
```

---

## Non-obvious Architectural Decisions

**1-second date granularity (`FileSyncEngine.needsCopy`)**
`FileManager.setAttributes(.modificationDate:)` truncates sub-second precision when writing back to the destination file. Without floor-rounding both dates to the nearest second, every previously copied file shows the source as strictly newer (e.g. `1748123456.789 > 1748123456.0`) and gets re-copied on every run.

**Size checked before date (Fast mode)**
Size is checked first as a fast-reject: if byte counts differ the answer is obvious without reading the dates or xattrs. Avoids extra stat() calls on the common case where a file has genuinely changed.

**`syncGeneration` counter (`FileSyncViewModel`)**
`onProgress` closures are dispatched as `Task { @MainActor }` from the cooperative thread pool. These tasks queue up and can fire *after* `startSync()` has already reset state for a new run, stamping old counts and log entries back into the UI. The generation counter is compared inside each closure; stale closures from the previous run are silently discarded.

**`@MainActor` on `AppDelegate`**
AppKit calls all `NSApplicationDelegate` / `NSWindowDelegate` methods on the main thread. Without `@MainActor`, accessing `@MainActor`-isolated `@Published` properties on `FileSyncViewModel` from those methods is a compile error.

**Mirror mode reuses Fast comparison for its copy pass**
`needsCopy` has `case .fast, .mirror:` — Mirror adds a deletion pass after the copy loop, it doesn't change how copy decisions are made. The `mode == .mirror` branch at the bottom of `sync()` is the only Mirror-specific logic in the engine.

**Window height constants on `AppDelegate`**
`compactHeight` and `expandedHeight` are `static let` on `AppDelegate`, referenced by both `AppDelegate` and `ContentView` (via `AppDelegate.compactHeight`). Adding or removing a row in the folder-picker `GroupBox` requires bumping `compactHeight` to match the new natural content height.

**xattr filter list**
`com.apple.quarantine` and `com.apple.lastuseddate#PS` are excluded from xattr comparison. Both are written by macOS automatically (Gatekeeper and Launch Services respectively) without user action; including them would cause spurious copies on every run.

**No window resize when maximised or full-screen**
`ContentView.onChange(of: vm.isRunning)` skips `setWindowHeight` when `window.isZoomed || window.styleMask.contains(.fullScreen)`. `AppDelegate.windowDidExitFullScreen` is responsible for restoring the correct height on the way back out.

---

## Still Out of Scope

- Bi-directional sync
- Scheduling / automatic sync
- Multiple source folders
- Exclude patterns / filters

---

## Build Status

| Date | Status | Notes |
|------|--------|-------|
| 2026-05-27 | Spec complete | CLAUDE.md written. No Swift code yet. |
| 2026-05-27 | Source complete | All Swift source files and Xcode project generated. |
| 2026-05-28 | First clean build | Fixed `@MainActor` missing from `AppDelegate`. |
| 2026-05-28 | Core bugs fixed | Stale-closure race (syncGeneration), date-precision re-copy (1-sec floor rounding). |
| 2026-05-28 | Comparison modes | Added Fast / Thorough (SHA-256) / Archive radio buttons; xattr comparison in Fast and Thorough. |
| 2026-05-28 | Mirror mode | Pre-scan → confirmation sheet → copy + delete pass. `[DELETED]` log entries in orange. |
| 2026-05-28 | Window polish | Full-screen/zoom guard on resize; app icon (blue gradient, white arrow). |

**Current phase:** Feature-complete, building cleanly.
**Next step:** Run a real-world sync against a NAS to validate Mirror mode deletion and xattr comparison under network I/O conditions. Consider adding exclude-pattern filtering as the next feature.
