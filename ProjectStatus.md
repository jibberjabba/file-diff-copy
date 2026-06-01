# File Diff Copy — Project Status

## Build
| Item | Status |
|------|--------|
| Xcode build (Debug) | PASSED — `** BUILD SUCCEEDED **` (2026-05-28) |
| Xcode build (Release) | PASSED — `** BUILD SUCCEEDED **` (2026-06-01) |
| App name | **File Diff Copy** (scheme: `MacOSFileCopy`, bundle: `File Diff Copy.app`) |
| App launch | CONFIRMED — compact window (~270px), Compare radio group visible |
| Deployment target | macOS 13.0 Ventura (lowered from 26.0 on 2026-05-28) |
| AccentColor warning | Fixed — `AccentColor.colorset` added to `Assets.xcassets` (2026-05-28) |
| Release location | `~/Applications/File Diff Copy.app` |
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
| `destination/orphan_subdir/` | Directory only in destination — deleted by Mirror |
| `source/subdir/nested_new.txt` | New nested file in subdirectory |
| `source/subdir/nested_uptodate.txt` | Nested file already in sync |

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
| 1 | `checksum_only.txt` | `[COPIED]` checksum differed | PASS |
| 2 | SHA-256 warning label visible | Orange warning below picker | PASS |
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
- Test results above were recorded on 2026-05-28 against the macOS 26 build. The deployment target was subsequently lowered to macOS 13 and `onChange` syntax was updated. Re-run all fixture tests to confirm results still hold.

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

## Next Steps
1. Re-run all fixture tests against the macOS 13 build to confirm no regressions.
2. Run a real-world sync against a NAS to validate Mirror deletion, Preview mode, xattr comparison, and anomaly detection under network I/O conditions.
