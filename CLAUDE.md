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
│   ├── FileSyncViewModel.swift     # @MainActor ObservableObject
│   └── FileSyncViewModelTests.swift
├── Engine/
│   ├── FileSyncEngine.swift        # Pure Swift — ComparisonMode enum lives here
│   └── FileSyncEngineTests.swift
├── Utilities/
│   └── BookmarkManager.swift
└── MacOSFileCopyTool.entitlements
```

**Tests:** `MacOSFileCopyToolTests` is an unhosted XCTest bundle. It compiles `FileSyncEngine.swift`, `FileSyncViewModel.swift` and `BookmarkManager.swift` directly (no `@testable import`, no app launch, no sandbox). Test files live beside the file they cover and are members of the test target only. Run them with:
`xcodebuild -project MacOSFileCopy.xcodeproj -scheme MacOSFileCopy test`

---

## Non-obvious Architectural Decisions

**Mirror deletion safety (`FileSyncEngine.mirrorOrphans`)**
`fileExists` returns false for "unreachable" as well as "missing", so a file being absent from the source is only trusted when the source scan is complete. Mirror refuses to delete anything (throws `MirrorSafetyError`) if the source folder is unavailable, contains no files, or any item in either tree couldn't be read (the enumerator's `errorHandler` collects these; they are also logged as `[ERROR]` in every mode). A real Mirror run deletes only paths in `confirmedOrphans` (the list the user approved in the sheet) that are still orphaned at run time; `nil` deletes nothing. Before the deletion pass the source is re-checked, and each orphan is re-checked against the source just before it is removed. Trade-off: you can't Mirror an intentionally empty source.

**Relative paths and symlinked roots (`FileSyncEngine.scan`)**
Enumerating a symlink yields zero files, so the root is resolved with `resolvingSymlinksInPath()` first. The enumerator can report children under a different spelling of the root (`/tmp/x` → `/private/tmp/x`), so `rootPrefixes` accepts both the `/private` and non-`/private` forms. A path matching neither is reported as an error; the code never guesses a relative path.

**Ignored items are reported, not silently dropped (`FileSyncEngine.scan` → `ScanResult.ignored`)**
The enumerator runs *without* `.skipsHiddenFiles` so hidden items can be seen and reported. Hidden files, hidden folders (one entry, then `skipDescendants()`), symbolic links (never followed) and special files (pipes, sockets) are not synced. Every one found in the source becomes an `[IGNORED]` log entry with a reason and adds to `ignoredCount`, which the progress section shows as "N Ignored" when it's above zero. `.DS_Store` and this app's own `.fdc-*.tmp` files are skipped without a log entry, because they would only be noise. On the destination side, hidden items are never Mirror orphans. `skipDescendants()` is essential: without it, the non-hidden files inside a hidden destination folder would be offered for deletion. Known limit: on SMB shares from the Synology, a symlink created on the NAS is resolved on the server side and appears to macOS as a regular file, so it is copied as one. That happened before this change too.

**Mirror removes folders its deletions empty (`foldersLeftEmpty`, `removeEmptyFolder`)**
After the deletion pass, Mirror removes destination folders that this run's deletions left empty, deepest first, and logs each one as `[DELETED] folder/` (or `[WOULD DEL]` in Preview). It counts them in `deletedCount`. The rules are deliberately narrow:
- Only folders above a deleted file are considered, so a folder that was already empty is never touched.
- A folder that exists as a folder in the source is kept.
- Finder's `.DS_Store` doesn't count as content, but any other item does, hidden files included.
- Removal uses `rmdir(2)`, which refuses a non-empty folder, never the recursive `FileManager.removeItem`. A file that appears between the check and the removal therefore survives, and the folder is logged as `[NOTE] Kept folder …`.

**Atomic copy (`FileSyncEngine.performCopy`)**
The file is copied to a hidden `.fdc-<uuid>.tmp` beside the destination, the source mod-date is applied to it, and then it is swapped in with `replaceItemAt(... options: .usingNewMetadataOnly)` (or `moveItem` for a new file). If the copy fails, the old destination file is untouched and the temp file is removed. A temp file left behind by a crash is hidden, so the scan never treats it as a file to sync or as a Mirror orphan (and doesn't log it either; see `isSilentlyIgnored`). `copyItem` is an injectable property so tests can simulate a copy failing part-way.
The temp-and-swap is used only when the destination file already exists. A **new** file is copied straight to its final path, because there's nothing to protect and the extra rename round trip made new-file copies ~50% slower over SMB (measured on arrakis: 300 files, 54 s → 34 s, matching the pre-fix engine). If a new-file copy fails, the partial file is removed. Otherwise its newer mod-date would make Date Only mode skip it forever. The one exception is a `fileWriteFileExists` error, which means another writer created the file after our check; that file isn't ours, so it's left alone.

**Cancel stops mid-file (`FileSyncEngine.copyFile`, `contentsDiffer`)**
Copies use `copyfile(3)` directly, which is what `FileManager.copyItem` calls internally. It's called with the same flags: data, xattrs, ACLs and permissions, `COPYFILE_EXCL` (EEXIST is mapped to `CocoaError.fileWriteFileExists`, which `performCopy`'s race handling relies on) and `COPYFILE_CLONE`. The difference is a status callback that checks `isCancelled` after every chunk and returns `COPYFILE_QUIT`. The Thorough comparison checks it after every chunk too. Both throw `SyncFileError.cancelled`. `performCopy` then removes the partial file or temp file, as it does for any failed copy. `sync()` logs `[NOTE] Cancelled during <file> — left unchanged`, which isn't counted as an error, and stops the run. Before this, Cancel was only checked between files, so it waited for a whole multi-GB copy to finish. A local APFS clone can't be interrupted, but it's instant anyway. Measured on arrakis on 2026-10-06: Cancel stopped a 512 MB copy in 0.09 s and left nothing behind, and copy speed was the same as `copyItem` (300 files, 512 MB, overwrites). The `copyItem` property is still the injection point for tests; its default calls `copyFile` and is set in `init()`, because the closure needs `self`.

**One engine per run; sticky cancellation (`FileSyncViewModel.activeEngine`)**
Each run or Mirror scan creates a new `FileSyncEngine`. `isCancelled` is guarded by an `OSAllocatedUnfairLock`, is never reset, and also honours `Task.isCancelled`. `resetForNextSession()` bumps `syncGeneration`, which discards queued progress closures *and* the abandoned run's completion block (that block is generation-guarded too). Each new task first awaits the previous `activeTask`, so two runs never touch the destination at the same time. Previously one shared engine reset `isCancelled = false` in `sync()`, so a new run could revive a cancelled one.

**1-second date granularity (`FileSyncEngine.copyReason`)**
`FileManager.setAttributes(.modificationDate:)` truncates sub-second precision when writing back to the destination file. Without floor-rounding both dates to the nearest second, every previously copied file shows the source as strictly newer (e.g. `1748123456.789 > 1748123456.0`) and gets re-copied on every run.

**A newer destination is never overwritten, in any mode (`copyReason` → `destinationIsNewer`)**
Before any mode-specific comparison, `copyReason` returns `nil` if the destination's mod-date is strictly newer than the source's (1-second floor). `detectAnomaly` then logs it as `[NEWER DST]`. This also applies when the size (Fast/Mirror) or content (Thorough) differs. Previously the size check ran first and returned `.sizeChanged`, which silently overwrote edits made at the destination and contradicted the app's "copy only newer files" purpose. Trade-off: Mirror no longer forces the destination to match the source for files edited there. They stay put and are flagged with a warning.

**Size checked before date (Fast mode), once the newer-destination check passes**
Size is a fast-reject: if the byte counts differ, the file is copied without comparing dates any further.

**A source file never replaces a destination folder (`SyncFileError.destinationIsFolder`)**
If the destination path is a directory, `copyReason` throws, and the file is logged as `[ERROR] … a folder with this name exists at the destination — not replaced`, in every mode including Preview. Replacing it would have recursively deleted the folder. In Mirror, the folder's files still show up as orphans in the confirmation sheet, so they are deleted only if the user confirms them. If they are deleted, the emptied folder is removed too (M4), and the next run copies the file in.

**`syncGeneration` counter (`FileSyncViewModel`)**
A run abandoned by `resetForNextSession()` keeps running until it notices it was cancelled, and its progress updates would otherwise stamp old counts and log entries onto the new session. The generation counter is compared inside each progress closure and in the completion block; anything from a previous run is silently discarded.

**Progress updates: throttled, awaited, deltas only (`FileSyncEngine.sync` → `report`)**
The engine sends a progress update at most every `progressInterval` (100 ms), plus always the first and the last. Each `SyncProgress` carries only `newLogEntries` (entries since the previous update), which the ViewModel appends. The `onProgress` closure is `async` and the engine awaits it (the ViewModel hops with `await MainActor.run`), so updates arrive in order and can never pile up on the main actor. Previously every file sent the whole log array, which SwiftUI re-diffed each time (O(files × log size)), via an unbounded queue of `Task { @MainActor }`s. Measured headless on 20,000 files: 1.88 s → 0.69 s. The UI saving is larger, because the log view now re-renders about 10 times a second instead of once per file.

**`syncHasStarted` flag (`FileSyncViewModel`)**
`isRunning` is set synchronously in `beginCopy()` before the engine `Task` starts. Wiring the window resize and the progress-section guard to `isRunning` caused the window to expand before any content was ready. `syncHasStarted` is reset to `false` at the start of `beginCopy()` and set to `true` on the first `onProgress` callback. Both `ContentView.onChange(of: vm.syncHasStarted)` (resize) and the `if vm.syncHasStarted || vm.isComplete` progress-section guard are wired to this flag so the window expansion and populated content appear together.

**`isPreparing` flag and `prepareTimer` (`FileSyncViewModel`)**
File enumeration and Mirror's orphan pre-scan block the engine from firing `onProgress` for potentially several seconds (large folders, NAS, Thorough mode). A `prepareTimer: Task<Void, Never>?` is started at `beginCopy()` and sets `isPreparing = true` after 500 ms if `syncHasStarted` is still false. When `isPreparing` is true, the Start button swaps its label for a `ProgressView` spinner + "Preparing…". The timer is cancelled and `isPreparing` cleared the moment the first `onProgress` fires.

**`@MainActor` on `AppDelegate`**
AppKit calls all `NSApplicationDelegate` / `NSWindowDelegate` methods on the main thread. Without `@MainActor`, accessing `@MainActor`-isolated `@Published` properties on `FileSyncViewModel` from those methods is a compile error.

**Mirror mode reuses Fast comparison for its copy pass**
`copyReason` has `case .fast, .mirror:` — Mirror adds a deletion pass after the copy loop, it doesn't change how copy decisions are made. Orphans are pre-scanned at the start of `sync()` (not at the end) so their count is included in `totalFiles`, keeping the progress bar accurate during the deletion pass.

**Mirror is a unified radio button (all four modes in one group)**
Mirror lives in the same `.radioGroup` Picker as Fast / Thorough / Date Only. A warning label (`exclamationmark.triangle.fill`) appears below the picker when Mirror is selected, and the confirmation sheet's "Delete and Sync" button has no `.keyboardShortcut(.defaultAction)` so Enter cannot trigger a deletion.

**`dryRun` parameter on `sync()` (Preview feature)**
Passing `dryRun: true` skips all I/O (`performCopy`, `removeItem`) but runs the full comparison and logs `.wouldCopy(CopyReason)` / `.wouldDelete` entries instead of `.copied` / `.deleted`. Preview bypasses the Mirror confirmation sheet since nothing is modified. The ViewModel's `isDryRun: Bool` flag drives label changes in `ProgressSection` ("Would Copy" / "Would Delete") and GroupBox titles ("Preview" / "Preview Log").

**`CopyReason` enum and `copyReason()` return type**
`needsCopy` was replaced by `copyReason(source:destination:mode:) throws -> CopyReason?`. Returning an optional enum instead of a plain Bool lets the engine record *why* each file was copied (`.newFile`, `.sizeChanged`, `.dateNewer`, `.xattrChanged`, `.contentDiffered`), which appears in every log entry as e.g. `[COPIED] file.txt (size changed)`.

**Thorough compares bytes, not hashes (`FileSyncEngine.contentsDiffer`)**
Thorough reads both files 1 MB at a time (`compareChunkSize`) and stops at the first chunk that differs. It used to SHA-256 both files in full, which always read every byte of both, and the digests weren't kept, so the hash bought nothing. Each pair of chunks is read inside `autoreleasepool`. Without it, `FileHandle.read` chunks piled up until the comparison finished: the old code peaked at about 2 GB of memory comparing two 1 GB files, and now it uses 9–15 MB. `readFully` loops until a full chunk or end of file, so a short read over SMB isn't mistaken for a difference. `readChunk` can be injected (like `copyItem`) so tests can count bytes read and simulate short reads. Measured on 2026-10-06 with 512 MB files on arrakis: a file differing at the start went from 24.6 s to 0.59 s; identical files are network-bound (~16 s) either way.

**xattr comparison is Thorough-only**
xattr checking was removed from Fast mode. On a NAS, extended attributes change autonomously (Spotlight, app metadata writes) causing spurious re-copies unrelated to file content. Fast mode now uses size + modification date only. xattr comparison remains in Thorough as the second check (after size, before the content comparison).

**Picker tooltip fix — binding no-op instead of `.disabled()`**
`.disabled()` on the comparison-mode Picker tears down AppKit tooltip tracking areas, so hover tooltips stop working once a sync starts. The fix: remove `.disabled()` entirely, use a binding that no-ops the setter when `isRunning`, and apply `.opacity(0.5)` for the visual disabled appearance. Tracking areas are never torn down so tooltips always work.

**Window height constants on `AppDelegate`**
`compactHeight` and `expandedHeight` are `static let` on `AppDelegate`, referenced by both `AppDelegate` and `ContentView` (via `AppDelegate.compactHeight`). Adding or removing a permanently-visible row in the folder-picker `GroupBox` requires bumping `compactHeight` to match the new natural content height. Current value: `270`.

`setWindowHeight` sets the **NSWindow frame** height (which includes the title bar). The VStack frame uses `.frame(minWidth: 600)` with no `minHeight` — removing `minHeight` was intentional: passing `compactHeight` as the SwiftUI content minimum height caused SwiftUI to request `compactHeight + ~32px (title bar)` from the window, making the window 32px taller than intended. Without `minHeight`, SwiftUI defers to `setWindowHeight` rather than fighting it.

The outer VStack has no `Spacer()`. A trailing `Spacer()` requests infinite preferred height, which caused SwiftUI to override `setWindowHeight` calls and grow the window. Window sizing is handled entirely by explicit `setWindowHeight` calls in `onAppear` and `onChange(of: vm.syncHasStarted)`.

**xattr filter list (`FileSyncEngine.isIgnoredXattr`)**
Thorough mode doesn't compare xattrs that macOS writes by itself; they are still copied. Those are `com.apple.quarantine`, `com.apple.lastuseddate#PS`, `com.apple.macl`, `com.apple.provenance` and any `com.apple.metadata:kMDLabel_*`. User-meaningful ones are still compared: Finder tags, FinderInfo, WhereFroms, resource forks and third-party xattrs.
- `quarantine` is essential: the sandbox stamps it on every file the app writes, so without the filter every file would be re-copied on every run.
- `macl` is the other essential one. It records sandbox access grants and is added when a file is opened in a sandboxed app such as Preview or TextEdit. A sandboxed process can't write it when it overwrites a destination file. So a source file opened in Preview was re-copied on *every* Thorough run, forever. This was measured on 2026-10-06 with an ad-hoc-signed sandboxed probe running the engine. The unsandboxed test runner can't reproduce it, because there everything round-trips, on local disk and on SMB alike.

**No window resize when maximised or full-screen**
`ContentView.onChange(of: vm.syncHasStarted)` skips `setWindowHeight` when `window.isZoomed || window.styleMask.contains(.fullScreen)`. `AppDelegate.windowDidExitFullScreen` is responsible for restoring the correct height on the way back out.

**Anomaly detection on skipped files (`FileSyncEngine.detectAnomaly`)**
When `copyReason` returns `nil`, the engine calls `detectAnomaly` before logging a plain skip. This surfaces two conditions worth flagging:
- `.newerDestination` — destination mod-date is strictly newer than source (all modes; such files are never copied)
- `.sizeMismatch` — same mod-date but different byte counts (Date Only mode only; other modes already copy on size difference)

Anomalies increment `warningCount` (not `skippedCount`) and appear as orange `[NEWER DST]` / `[SIZE DIFF]` entries in the log.

**Log entry cap and the full log file (`FileSyncEngine.RunLog`)**
The on-screen log is capped at `maxLogEntries` (20,000). When the cap is reached a `[NOTE]` sentinel entry is added and later entries are not shown. Every entry is also written, uncapped, to a per-run text file in the app's temporary directory (`FileDiffCopy-<uuid>.log`, passed as `sync(logFile:)`). **Save Log** copies that file (`FileSyncViewModel.writeLog(to:)`), so the export is complete even when the screen log was truncated. It falls back to the on-screen entries only if the file couldn't be created. The file is deleted when the next run starts or the session is reset. The counts (copiedCount etc.) were never capped.

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
| 2026-06-01 | Resize timing fix | Window expansion deferred to first `onProgress` callback via `syncHasStarted` flag; eliminates premature expand-into-empty-content flash when the engine Task hasn't started yet. |
| 2026-06-01 | Preparing spinner | 500ms debounced `isPreparing` flag shows a `ProgressView` spinner + "Preparing…" inside the Start button during slow enumeration (large folders, NAS, Thorough mode). Clears the moment the first file is processed. |
| 2026-10-05 | Data-safety fixes | Review items C1–C5 on branch `fix/data-safety-c1-c5`: Mirror refuses to delete when the source is unavailable, empty or only partly readable, and deletes only the orphans the user confirmed; enumeration errors are logged; symlinked roots and `/private` path spellings are handled; overwrites go through a temp file that is swapped in (new files are copied directly, keeping SMB speed); one engine per run with generation-guarded completion. Added XCTest target (21 tests). Engine verified against TestFixtures and the arrakis NAS over SMB. |
| 2026-10-05 | Overwrite safety (H1/H2) | A newer destination file is never overwritten in any mode (it is flagged `[NEWER DST]` instead); a source file never replaces a destination folder (logged as `[ERROR]`). Fixtures 10 and 11 added. 28 tests. |
| 2026-10-05 | Log export and progress (H3/H4) | Save Log now exports every entry from an uncapped per-run log file, not just the 20,000 shown on screen. Progress updates are throttled to ~10/s, carry only new log entries, and are awaited by the engine. 34 tests. |
| 2026-10-06 | Ignored items reported (H5) | Hidden files and folders, symlinks and special files in the source are logged as `[IGNORED]` with a reason and counted ("N Ignored"), instead of being skipped silently. `.DS_Store` and the app's temp files stay silent. Mirror still never deletes hidden destination items. Fixture 12 added. Checked on TestFixtures and the arrakis NAS. 37 tests. |
| 2026-10-06 | Thorough xattr noise (M1) | Thorough no longer compares `com.apple.macl`, `com.apple.provenance` or `kMDLabel_*` xattrs. In the sandboxed app, a source file opened in Preview or TextEdit had been re-copied on every run, because the sandbox can't write `macl` to the destination. Verified with a sandboxed probe; 40 tests. |
| 2026-10-06 | Thorough content compare (M2) | SHA-256 of both files replaced by a 1 MB chunk comparison that stops at the first difference, with an `autoreleasepool` per chunk (peak memory for 1 GB files: ~2 GB → 15 MB). Short SMB reads handled. `CopyReason.checksumDiffered` renamed `.contentDiffered`. 44 tests. |
| 2026-10-06 | Cancel mid-file (M3) | Copies go through `copyfile(3)` with a per-chunk cancel callback, and the Thorough comparison checks cancel per chunk. Cancel now stops a large copy within ~0.1 s (measured on arrakis), leaving the destination as it was. Same flags as `copyItem`, so clones, metadata and SMB speed are unchanged. 50 tests. |
| 2026-10-06 | Mirror removes emptied folders (M4) | Folders left empty by a Mirror run's confirmed deletions are removed with `rmdir` (deepest first; `.DS_Store` ignored; folders in the source or with other content kept), and Preview reports them. Fixture 11's folder/file collision now resolves on the second Mirror run. Checked on TestFixtures and arrakis. 55 tests. |

**Current phase:** Feature-complete, all modes tested and passing. Release build in `~/Applications/File Diff Copy.app`.
**Next step:** Re-run test fixtures against the macOS 13 build to confirm no regressions, then run a real-world sync against a NAS to validate Mirror deletion, Preview mode, xattr comparison, and anomaly detection under network I/O conditions.
