# macOS File Copy Tool

A native macOS app that syncs files from a source folder to a destination folder. Built with SwiftUI and Swift concurrency.

## What it does

Compares source and destination folders and copies files that are new or changed. Four sync modes control how "changed" is determined:

| Mode | How it compares files |
|------|-----------------------|
| **Fast** | Size + modification date |
| **Thorough** | SHA-256 checksum + extended attributes — catches any content or metadata change |
| **Date Only** | Modification date only — copies when source is newer; ignores size differences |
| **Mirror** | Fast copy, then deletes destination files not present in source |

## Key features

- **Dry run / Preview** — see exactly what would be copied or deleted before committing
- **Live progress** — per-file status, counts (copied / skipped / warnings / deleted / errors), and a progress bar
- **Mirror confirmation** — before any deletions, shows the list of orphaned files for review
- **Cancel** — graceful stop mid-sync; partial progress is preserved
- **Save log** — export the full operation log to a `.txt` file
- **Bookmark persistence** — source and destination folders are remembered between launches via security-scoped bookmarks

## Project structure

```
MacOSFileCopyTool/
├── Engine/
│   └── FileSyncEngine.swift       # Core sync logic — pure Swift, no SwiftUI dependency
├── ViewModel/
│   └── FileSyncViewModel.swift    # ObservableObject bridging engine to UI
├── Views/
│   ├── FolderPickerRow.swift      # Reusable folder picker row component
│   └── MirrorConfirmationView.swift # Confirmation sheet for Mirror mode deletions
└── Utilities/
    └── BookmarkManager.swift      # Security-scoped bookmark persistence
```

## Architecture notes

The engine (`FileSyncEngine`) is intentionally decoupled from SwiftUI — it takes URLs and a callback, returns progress structs, and can be unit tested in isolation. The view model (`FileSyncViewModel`) owns the engine and translates its progress callbacks into `@Published` properties the views observe.

Sync runs as a Swift `async` task so the UI stays responsive. `Task.yield()` is called after each file to give the main actor a chance to update.

## Comparison logic

**All modes:** a destination file whose modification date is newer than the source's is never overwritten. It's reported as `[NEWER DST]`. A source file never replaces a destination *folder* of the same name; that's reported as an error.

**Fast / Mirror:** size first (fast reject), then modification date rounded to the nearest second.

**Thorough:** size first, then extended attributes (cheap metadata check), then full SHA-256 of file contents. Ignores `com.apple.quarantine` and `com.apple.lastuseddate#PS` xattrs.

**Date Only (Archive):** modification date only — size differences are logged as warnings (`[SIZE DIFF]`) but do not trigger a copy.

## Log entry types

| Tag | Meaning |
|-----|---------|
| `[COPIED]` | File was copied |
| `[WOULD COPY]` | Dry run — file would be copied |
| `[SKIPPED]` | File is already up to date |
| `[DELETED]` | Mirror mode — orphan removed from destination |
| `[WOULD DEL]` | Dry run — orphan would be deleted |
| `[NEWER DST]` | Destination is newer than source (warning) |
| `[SIZE DIFF]` | Same date, different sizes in Date Only mode (warning) |
| `[ERROR]` | File operation failed |

## Things to know

- Hidden files (dotfiles) are skipped during enumeration.
- The log is capped at 20,000 entries in memory; use **Save Log** to export all entries for large syncs.
- Mirror mode scans for orphans before the sync starts so the total file count includes deletions in the progress bar.
