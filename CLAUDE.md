# File Diff Copy — Project Instructions

## Project Overview

A native macOS desktop application that copies files from a **source folder** to a **destination folder**, only copying files that are newer than what already exists at the destination. Four comparison modes: Fast, Thorough, Date Only, Mirror.

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

**1-second date granularity (`FileSyncEngine.copyReason`)**
`FileManager.setAttributes(.modificationDate:)` truncates sub-second precision when writing back to the destination file. Without floor-rounding both dates to the nearest second, every previously copied file shows the source as strictly newer (e.g. `1748123456.789 > 1748123456.0`) and gets re-copied on every run.

**Size checked before date (Fast mode)**
Size is checked first as a fast-reject: if byte counts differ the answer is obvious without reading the dates. Avoids extra stat() calls on the common case where a file has genuinely changed.

**`syncGeneration` counter (`FileSyncViewModel`)**
`onProgress` closures are dispatched as `Task { @MainActor }` from the cooperative thread pool. These tasks queue up and can fire *after* `startSync()` has already reset state for a new run, stamping old counts and log entries back into the UI. The generation counter is compared inside each closure; stale closures from the previous run are silently discarded.

**`@MainActor` on `AppDelegate`**
AppKit calls all `NSApplicationDelegate` / `NSWindowDelegate` methods on the main thread. Without `@MainActor`, accessing `@MainActor`-isolated `@Published` properties on `FileSyncViewModel` from those methods is a compile error.

**Mirror mode reuses Fast comparison for its copy pass**
`copyReason` has `case .fast, .mirror:` — Mirror adds a deletion pass after the copy loop, it doesn't change how copy decisions are made. Orphans are pre-scanned at the start of `sync()` (not at the end) so their count is included in `totalFiles`, keeping the progress bar accurate during the deletion pass.

**Mirror is a unified radio button (all four modes in one group)**
Mirror lives in the same `.radioGroup` Picker as Fast / Thorough / Date Only. A warning label (`exclamationmark.triangle.fill`) appears below the picker when Mirror is selected, and the confirmation sheet's "Delete and Sync" button has no `.keyboardShortcut(.defaultAction)` so Enter cannot trigger a deletion.

**`dryRun` parameter on `sync()` (Preview feature)**
Passing `dryRun: true` skips all I/O (`performCopy`, `removeItem`) but runs the full comparison and logs `.wouldCopy(CopyReason)` / `.wouldDelete` entries instead of `.copied` / `.deleted`. Preview bypasses the Mirror confirmation sheet since nothing is modified. The ViewModel's `isDryRun: Bool` flag drives label changes in `ProgressSection` ("Would Copy" / "Would Delete") and GroupBox titles ("Preview" / "Preview Log").

**`CopyReason` enum and `copyReason()` return type**
`needsCopy` was replaced by `copyReason(source:destination:mode:) throws -> CopyReason?`. Returning an optional enum instead of a plain Bool lets the engine record *why* each file was copied (`.newFile`, `.sizeChanged`, `.dateNewer`, `.xattrChanged`, `.checksumDiffered`), which appears in every log entry as e.g. `[COPIED] file.txt (size changed)`.

**xattr comparison is Thorough-only**
xattr checking was removed from Fast mode. On a NAS, extended attributes change autonomously (Spotlight, app metadata writes) causing spurious re-copies unrelated to file content. Fast mode now uses size + modification date only. xattr comparison remains in Thorough as the second check (after size, before SHA-256).

**Picker tooltip fix — binding no-op instead of `.disabled()`**
`.disabled()` on the comparison-mode Picker tears down AppKit tooltip tracking areas, so hover tooltips stop working once a sync starts. The fix: remove `.disabled()` entirely, use a binding that no-ops the setter when `isRunning`, and apply `.opacity(0.5)` for the visual disabled appearance. Tracking areas are never torn down so tooltips always work.

**Window height constants on `AppDelegate`**
`compactHeight` and `expandedHeight` are `static let` on `AppDelegate`, referenced by both `AppDelegate` and `ContentView` (via `AppDelegate.compactHeight`). Adding or removing a permanently-visible row in the folder-picker `GroupBox` requires bumping `compactHeight` to match the new natural content height. Current value: `270`.

`setWindowHeight` sets the **NSWindow frame** height (which includes the title bar). The VStack frame uses `.frame(minWidth: 600)` with no `minHeight` — removing `minHeight` was intentional: passing `compactHeight` as the SwiftUI content minimum height caused SwiftUI to request `compactHeight + ~32px (title bar)` from the window, making the window 32px taller than intended. Without `minHeight`, SwiftUI defers to `setWindowHeight` rather than fighting it.

The outer VStack has no `Spacer()`. A trailing `Spacer()` requests infinite preferred height, which caused SwiftUI to override `setWindowHeight` calls and grow the window. Window sizing is handled entirely by explicit `setWindowHeight` calls in `onAppear` and `onChange(of: vm.isRunning)`.

**xattr filter list**
`com.apple.quarantine` and `com.apple.lastuseddate#PS` are excluded from xattr comparison. Both are written by macOS automatically (Gatekeeper and Launch Services respectively) without user action; including them would cause spurious copies on every run.

**No window resize when maximised or full-screen**
`ContentView.onChange(of: vm.isRunning)` skips `setWindowHeight` when `window.isZoomed || window.styleMask.contains(.fullScreen)`. `AppDelegate.windowDidExitFullScreen` is responsible for restoring the correct height on the way back out.

**Anomaly detection on skipped files (`FileSyncEngine.detectAnomaly`)**
When `copyReason` returns `nil`, the engine calls `detectAnomaly` before logging a plain skip. This surfaces two conditions worth flagging:
- `.newerDestination` — destination mod-date is strictly newer than source (all modes)
- `.sizeMismatch` — same mod-date but different byte counts (Date Only mode only; other modes already copy on size difference)

Anomalies increment `warningCount` (not `skippedCount`) and appear as orange `[NEWER DST]` / `[SIZE DIFF]` entries in the log.

**Log entry cap (`FileSyncEngine.appendLog`)**
All log entries route through `appendLog(_:to:)` which enforces a 20,000-entry limit. When the cap is reached a `[NOTE]` sentinel entry is appended and all subsequent entries are silently dropped. The full counts (copiedCount etc.) are unaffected — only the in-memory display array is capped.

**`BookmarkManager.RestoreResult`**
`BookmarkManager.restore(key:)` returns `.success(URL)`, `.notStored`, or `.unavailable` (bookmark exists but the volume can't be resolved). The ViewModel uses this to set `sourceBookmarkUnavailable` / `destinationBookmarkUnavailable` flags, which surface an orange warning in the UI rather than silently showing "No folder selected."

**App icon design and versioning**
The icon is generated by a Swift CoreGraphics script (`gen_icon.swift`) in each version's backup folder. All sizes (16–1024 px) are produced from a single script run. Each iteration is saved to a new numbered folder under `Icon Resources/` — never overwrite an existing version. Current icon (v4): blue gradient background, cream/ivory source pages, mint-green destination page, amber/gold gradient arrow, "File Diff" / "Copy" labels in Avenir Next Heavy.

| Folder | Description |
|--------|-------------|
| `Icon Resources/v1-arrow-only/` | Original blue gradient, white arrow only |
| `Icon Resources/v2-pages-arrow/` | Added document pages, white coloring, bold text |
| `Icon Resources/v3-pages-arrow-color/` | Color variation: cream pages, gold arrow, mint destination |
| `Icon Resources/v4-pages-arrow-color-avenir/` | Same colors, font changed to Avenir Next Heavy ← **current** |

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
| 2026-05-28 | Mirror mode | Pre-scan → confirmation sheet → copy + delete pass. `[DELETED]` log entries in red; Deleted counter in red. |
| 2026-05-28 | Window polish | Full-screen/zoom guard on resize; app icon (blue gradient, white arrow). |
| 2026-05-28 | Anomaly detection | `[NEWER DST]` and `[SIZE DIFF]` warnings in log; orange "X Warnings" counter in progress section. |
| 2026-05-28 | UX hardening | Mirror separated to checkbox; Preview (dry-run) button; copy reason in log; xattr moved to Thorough-only; "Date Only" rename; Thorough warning; bookmark unavailability warning; Mirror progress bar fixed; log capped at 5,000 entries. |
| 2026-05-28 | Tooltip fix + Mirror reunified | Fixed hover tooltips breaking during sync (binding no-op replaces `.disabled()`); Mirror moved back into unified radio group with warning label. |
| 2026-05-28 | Icon redesign | Pages + arrow icon; cream source pages, mint destination page, amber/gold arrow; Avenir Next Heavy font; "File Diff" / "Copy" labels. |
| 2026-05-28 | All modes tested | Fast, Thorough, Date Only, Mirror, Preview all pass against `TestFixtures/reset_fixtures.sh`. Fixture fix: `dest_newer.txt` made same-size so `[NEWER DST]` anomaly fires correctly in Fast mode. |
| 2026-05-28 | Compact window + color polish | compactHeight 305→240; tighter VStack/GroupBox spacing; single ZStack warning slot; Spacer() and `minHeight` removed (both fought `setWindowHeight`). `[DELETED]`/`[WOULD DEL]` log entries and Deleted counter changed from orange to red — orange is now anomaly warnings only. |
| 2026-05-28 | Deployment target lowered | `MACOSX_DEPLOYMENT_TARGET` 26.0 → 13.0 (macOS Ventura, Macs from 2017+). `onChange(of:)` calls updated to `perform:` closure form — the two-parameter `{ _, value in }` syntax requires macOS 14+. `AccentColor.colorset` added to asset catalog (was missing, causing a build warning). |

**Current phase:** Feature-complete, all modes tested and passing. Release build in `~/Applications/File Diff Copy.app`.
**Next step:** Re-run test fixtures after macOS 13 compatibility changes, then run a real-world sync against a NAS to validate Mirror deletion, Preview mode, xattr comparison, and anomaly detection under network I/O conditions.
