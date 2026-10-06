# File Diff Copy — Project Status

## Build
| Item | Status |
|------|--------|
| Xcode build (Debug) | PASSED — `** BUILD SUCCEEDED **` (2026-05-28) |
| Xcode build (Release) | PASSED — `** BUILD SUCCEEDED **` (2026-10-06, `main` @ `bf001b4`, clean build, no Swift warnings) |
| Unit tests | 65 passing — `xcodebuild -project MacOSFileCopy.xcodeproj -scheme MacOSFileCopy test` (2026-10-06) |
| Signing | Team `6HZ82RF7UX`, hardened runtime on, **no App Sandbox** (since 2026-10-06; see CLAUDE.md "No App Sandbox") |
| App name | **File Diff Copy** (scheme: `MacOSFileCopy`, bundle: `File Diff Copy.app`) |
| App launch | CONFIRMED — compact window (~270px), Compare radio group visible |
| Deployment target | macOS 13.0 Ventura (lowered from 26.0 on 2026-05-28) |
| AccentColor warning | Fixed — `AccentColor.colorset` added to `Assets.xcassets` (2026-05-28) |
| Release location | `~/Applications/File Diff Copy.app` (installed 2026-10-06; launches and quits cleanly) |
| Project build copies | `build/Debug/` and `build/Release/` (gitignored) |

---

## Test Fixtures
Created at `~/Desktop/FileCopyTest/` (2026-05-28). Reset script: `TestFixtures/reset_fixtures.sh`.

| File | Scenario |
|------|----------|
| `source/new_file.txt` | New file — exists only in source |
| `source/up_to_date.txt` | Identical date+size in both — should skip |
| `source/source_newer.txt` | Source mod date newer than destination |
| `source/dest_newer.txt` | Same size, destination mod date newer — anomaly |
| `source/size_mismatch.txt` | Same mod date, different byte counts — anomaly (Date Only) |
| `source/checksum_only.txt` | Same size+date, different content — only caught by Thorough |
| `destination/orphan_file.txt` | Exists only in destination — deleted by Mirror |
| `destination/orphan_subdir/` | Directory only in destination — its file is deleted by Mirror, then the emptied folder is removed (`[DELETED] orphan_subdir/`, M4) |
| `source/subdir/nested_new.txt` | New nested file in subdirectory |
| `source/subdir/nested_uptodate.txt` | Nested file already in sync |
| `source/dest_edited.txt` | Destination newer **and** different size → `[NEWER DST]` in every mode, never overwritten (H1, added 2026-10-05) |
| `source/collision` | Source file vs destination folder `collision/` → `[ERROR]`, folder kept (H2, added 2026-10-05). In Mirror, once `collision/keep_me.txt` is deleted the empty folder is removed too, and the next run copies the file (M4) |
| `source/.hidden_config`, `source/link_to_new.txt` | Hidden file and symlink → `[IGNORED]` in every mode, never copied, "2 Ignored" counter (H5, added 2026-10-06) |

**Fixture fix (2026-05-28):** `dest_newer.txt` previously had different content sizes (23 vs 48 bytes), causing Fast mode to copy it as "size changed" before reaching anomaly detection. Fixed to use identical 33-byte content in both copies so the size check passes through to date comparison.

---

## Test Results

### Fast Mode — PASSED (2026-05-28)
| # | Scenario | Expected | Result |
|---|----------|----------|--------|
| 1 | `new_file.txt` | `[COPIED]` new file | PASS |
| 2 | `up_to_date.txt` | `[SKIPPED]` | PASS |
| 3 | `source_newer.txt` | `[COPIED]` size changed | PASS |
| 4 | `dest_newer.txt` | `[NEWER DST]` warning (orange) | PASS |
| 5 | `size_mismatch.txt` | `[COPIED]` size changed | PASS |
| 6 | `checksum_only.txt` | `[SKIPPED]` (same size+date) | PASS |
| 7 | `subdir/nested_new.txt` | `[COPIED]` new file | PASS |
| 8 | `subdir/nested_uptodate.txt` | `[SKIPPED]` | PASS |

### Thorough Mode — PASSED (2026-05-28)
| # | Scenario | Expected | Result |
|---|----------|----------|--------|
| 1 | `checksum_only.txt` | `[COPIED]` content changed | PASS |
| 2 | Thorough warning label visible | Orange warning below picker | PASS |
| 3 | All others | Same results as Fast mode | PASS |

### Date Only Mode — PASSED (2026-05-28)
| # | Scenario | Expected | Result |
|---|----------|----------|--------|
| 1 | `dest_newer.txt` | `[NEWER DST]` warning (orange) | PASS |
| 2 | `size_mismatch.txt` | `[SIZE DIFF]` warning (orange) | PASS |
| 3 | `source_newer.txt` | `[COPIED]` source is newer | PASS |
| 4 | `checksum_only.txt` | `[SKIPPED]` (same date) | PASS |
| 5 | Warnings counter | Shows "2 Warnings" in orange | PASS |

### Mirror Mode — PASSED (2026-05-28)
| # | Scenario | Expected | Result |
|---|----------|----------|--------|
| 1 | `orphan_file.txt` | `[DELETED]` (red) | PASS |
| 2 | `orphan_subdir/orphan_in_dir.txt` | `[DELETED]` (red) | PASS |
| 3 | Orphans removed from disk | Files gone after sync | PASS |
| 4 | Copy pass | Same results as Fast mode | PASS |
| 5 | Confirmation sheet | Lists files to delete, shows count | PASS |
| 6 | Enter key blocked | Sheet stays open on Enter | PASS |
| 7 | "Delete and Sync" button | Confirms and runs sync | PASS |

### Preview (Dry Run) — PASSED (2026-05-28)
| # | Scenario | Expected | Result |
|---|----------|----------|--------|
| 1 | Fast preview | `[WOULD COPY]` entries, no files changed | PASS |
| 2 | GroupBox title | Shows "Preview" / "Preview Log" | PASS |
| 3 | Status message | "Preview complete — no files were modified." | PASS |
| 4 | Counters | Shows "X Would Copy" / "X Would Skip" | PASS |

---

## UI Polish (2026-05-28)
| Change | Detail |
|--------|--------|
| Compact window | `compactHeight` 305→240; outer VStack spacing 14→8, padding 20→16; GroupBox inner spacing 10→6 |
| Single warning slot | Thorough and Mirror warnings collapsed into one `ZStack` — mutually exclusive, saves one caption row |
| Spacer removed | Trailing `Spacer()` in outer VStack removed — was fighting `setWindowHeight`, inflating window to ~272px |
| `minHeight` removed | `.frame(minWidth: 600, minHeight: compactHeight)` → `.frame(minWidth: 600)` — SwiftUI was treating `minHeight` as content-area min, adding title-bar height on top |
| Deletion color | `[DELETED]` / `[WOULD DEL]` log entries and Deleted counter changed orange → **red**; orange now reserved for anomaly warnings only |

---

## Blockers / Notes
- Test fixtures are one-shot: once a sync runs, destination state changes. Run `TestFixtures/reset_fixtures.sh` before each isolated mode test.
- Test results above were recorded on 2026-05-28 against the macOS 26 build. On 2026-10-05/06 every mode, plus a Mirror preview, was re-run against fresh fixtures with the macOS 13-target build: through the engine and the ViewModel, and on the arrakis NAS over SMB. All results matched, apart from the intended changes listed below.
- If Xcode offers "Update to recommended settings", don't accept the deployment-target change: it raises the target to the current macOS, which drops support for 13–15.

---

## Changes (2026-05-30)
| Change | Detail |
|--------|--------|
| Log cap raised | `maxLogEntries` increased from 5,000 → 20,000 entries |

---

## Changes (2026-06-01)
| Change | Detail |
|--------|--------|
| Resize timing fix | Window expansion now deferred until the first `onProgress` fires (`syncHasStarted` flag). Previously expanded immediately on `isRunning = true`, before the engine Task had started, causing a flash of empty content. |
| Preparing spinner | Start button shows a `ProgressView` spinner + "Preparing…" after 500ms if the engine hasn't reported its first file yet. Covers slow enumeration on large folders or NAS. Clears instantly when processing begins. |

---

## Code Review Fixes (2026-10-05 – 2026-10-06)
Every item from the 2026-10-05 full-codebase review is fixed and merged (PRs #1–#10), each with regression tests checked to fail without the fix. Details are in CLAUDE.md's design notes and build-status table.

| Area | Change |
|------|--------|
| Mirror safety (C1–C3) | Mirror refuses to delete if the source is unavailable, empty or partly unreadable, and deletes only the orphans the user confirmed; symlinked roots and `/private` paths handled |
| Overwrites (C4, H1, H2) | Overwrites go through a temp file that is swapped in; a newer destination file is never overwritten; a source file never replaces a destination folder |
| Runs (C5) | One engine per run; a cancelled or abandoned run can't affect the next |
| Log (H3, H4) | Save Log exports every entry (no 20,000 cap); progress updates throttled and incremental |
| Ignored items (H5) | Hidden files, symlinks and special files logged as `[IGNORED]` and counted |
| Thorough (M1, M2) | System-written xattrs (`macl`, `provenance`, Spotlight labels) ignored; byte comparison stops at the first difference (1 GB compare: ~2 GB RAM → 15 MB) |
| Cancel (M3) | Stops part-way through a large copy (~0.1 s on the NAS) |
| Mirror folders (M4) | Folders emptied by Mirror's deletions are removed |
| Bookmarks, logging (M5, M6) | Stale bookmarks refreshed; Console shows paths and errors instead of `<private>` |
| Low items | Cancelled runs keep partial progress; unreadable xattr lists reported as errors; `.archive` → `.dateOnly` |
| App Sandbox removed | The sandbox quarantined every copied file (confirmed `0082;…;File Diff Copy;`), so copied apps and scripts tripped Gatekeeper. Verified 2026-10-06: a copy made by the unsandboxed build has no quarantine |

## Swap Source and Destination (2026-10-06)
A ⇅ button beside the folder rows exchanges Source and Destination. The saved bookmarks are swapped too, so the new order is kept after a relaunch, and an unavailable-volume warning moves with its folder. Disabled during a run.

## Next Steps
None outstanding. Every review item is fixed, and the unsandboxed release build is installed and verified.
