# File Diff Copy — Project Status

## Build
| Item | Status |
|------|--------|
| Xcode build (Debug) | PASSED — `** BUILD SUCCEEDED **` (2026-05-28) |
| App launch | CONFIRMED — process running, 640×337 window on-screen |

---

## Test Fixtures
Created at `~/Desktop/FileCopyTest/` (2026-05-28).

| File | Scenario |
|------|----------|
| `source/new_file.txt` | New file — exists only in source |
| `source/up_to_date.txt` | Identical date+size in both — should skip |
| `source/source_newer.txt` | Source mod date newer than destination |
| `source/dest_newer.txt` | Destination mod date newer than source — anomaly |
| `source/size_mismatch.txt` | Same mod date, different byte counts — anomaly (Date Only) |
| `source/checksum_only.txt` | Same size+date, different content — only caught by Thorough |
| `destination/orphan_file.txt` | Exists only in destination — deleted by Mirror |
| `destination/orphan_subdir/` | Directory only in destination — deleted by Mirror |
| `source/subdir/nested_new.txt` | New nested file in subdirectory |
| `source/subdir/nested_uptodate.txt` | Nested file already in sync |

---

## Test Results

### Fast Mode
| # | Scenario | Expected | Result |
|---|----------|----------|--------|
| 1 | `new_file.txt` | `[COPIED]` new file | NOT TESTED |
| 2 | `up_to_date.txt` | `[SKIPPED]` | NOT TESTED |
| 3 | `source_newer.txt` | `[COPIED]` date newer | NOT TESTED |
| 4 | `dest_newer.txt` | `[NEWER DST]` warning (orange) | NOT TESTED |
| 5 | `size_mismatch.txt` | `[COPIED]` size changed | NOT TESTED |
| 6 | `checksum_only.txt` | `[SKIPPED]` (same size+date) | NOT TESTED |
| 7 | `subdir/nested_new.txt` | `[COPIED]` new file | NOT TESTED |
| 8 | `subdir/nested_uptodate.txt` | `[SKIPPED]` | NOT TESTED |

### Thorough Mode
| # | Scenario | Expected | Result |
|---|----------|----------|--------|
| 1 | `checksum_only.txt` | `[COPIED]` checksum differed | NOT TESTED |
| 2 | All others | Same as Fast mode | NOT TESTED |

### Date Only Mode
| # | Scenario | Expected | Result |
|---|----------|----------|--------|
| 1 | `size_mismatch.txt` | `[SIZE DIFF]` warning (orange) | NOT TESTED |
| 2 | `source_newer.txt` | `[COPIED]` date newer | NOT TESTED |
| 3 | `checksum_only.txt` | `[SKIPPED]` (same date) | NOT TESTED |

### Mirror Mode
| # | Scenario | Expected | Result |
|---|----------|----------|--------|
| 1 | `orphan_file.txt` | `[DELETED]` (orange) | NOT TESTED |
| 2 | `orphan_subdir/` | `[DELETED]` entire directory (orange) | NOT TESTED |
| 3 | Copy pass | Same results as Fast mode | NOT TESTED |
| 4 | Confirmation sheet | "Delete and Sync" button, no Enter shortcut | NOT TESTED |

### Preview (Dry Run)
| # | Scenario | Expected | Result |
|---|----------|----------|--------|
| 1 | Fast preview | `[WOULD COPY]` entries, no files changed | NOT TESTED |
| 2 | Mirror preview | Bypasses confirmation sheet | NOT TESTED |
| 3 | UI labels | GroupBox shows "Preview" / "Preview Log" | NOT TESTED |

---

## Blockers / Notes
- Screen Recording permission not yet granted to terminal — screenshots blocked. Grant via: **System Settings → Privacy & Security → Screen Recording**.
- Test fixtures are one-shot: once a sync runs, destination state changes. Re-run the fixture script before each isolated mode test, or snapshot the destination folder first.
- Fixture script location: embedded in conversation (2026-05-28 session). Consider saving it as `TestFixtures/reset_fixtures.sh` for repeatable resets.

---

## Next Steps
1. Grant Screen Recording permission → confirm UI visually via screenshot
2. Run Fast mode sync → verify log entries match expected column above
3. Reset destination → run Thorough mode → confirm `checksum_only.txt` is caught
4. Reset destination → run Date Only mode → confirm `[SIZE DIFF]` anomaly appears
5. Reset destination → run Mirror mode → confirm orphan deletion and confirmation sheet
6. Run Preview mode for Fast and Mirror → confirm no files are modified
7. Save `reset_fixtures.sh` script to repo for repeatable testing
