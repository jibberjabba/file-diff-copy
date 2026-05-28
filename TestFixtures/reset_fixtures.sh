#!/bin/bash
# Resets ~/Desktop/FileCopyTest to the original test state.
# Safe to run repeatedly — wipes and recreates from scratch each time.

set -e

BASE=~/Desktop/FileCopyTest

echo "Resetting test fixtures at $BASE ..."

rm -rf "$BASE"
mkdir -p "$BASE/source/subdir"
mkdir -p "$BASE/destination/subdir"

# ── 1. NEW FILE — exists only in source ──────────────────────────────────────
echo "I am a brand new file." > "$BASE/source/new_file.txt"
touch -t 202605281000 "$BASE/source/new_file.txt"

# ── 2. UP-TO-DATE — identical mod date and size in both ──────────────────────
echo "This file is already synced." > "$BASE/source/up_to_date.txt"
echo "This file is already synced." > "$BASE/destination/up_to_date.txt"
touch -t 202605271200 "$BASE/source/up_to_date.txt"
touch -t 202605271200 "$BASE/destination/up_to_date.txt"

# ── 3. SOURCE NEWER — source has a later mod date ────────────────────────────
echo "Updated content in source." > "$BASE/source/source_newer.txt"
echo "Old content at destination." > "$BASE/destination/source_newer.txt"
touch -t 202605281500 "$BASE/source/source_newer.txt"
touch -t 202605271500 "$BASE/destination/source_newer.txt"

# ── 4. DESTINATION NEWER — destination mod date ahead of source (anomaly) ────
echo "Source has older date." > "$BASE/source/dest_newer.txt"
echo "Destination was somehow modified after source." > "$BASE/destination/dest_newer.txt"
touch -t 202605271000 "$BASE/source/dest_newer.txt"
touch -t 202605281000 "$BASE/destination/dest_newer.txt"

# ── 5. SIZE MISMATCH — same mod date, different byte counts (Date Only anomaly)
printf "Short."                    > "$BASE/source/size_mismatch.txt"
printf "Much longer content here." > "$BASE/destination/size_mismatch.txt"
touch -t 202605271800 "$BASE/source/size_mismatch.txt"
touch -t 202605271800 "$BASE/destination/size_mismatch.txt"

# ── 6. CHECKSUM ONLY — same size+date, different content (Thorough mode only) ─
printf "AAAAAAAAAA" > "$BASE/source/checksum_only.txt"
printf "BBBBBBBBBB" > "$BASE/destination/checksum_only.txt"
touch -t 202605271800 "$BASE/source/checksum_only.txt"
touch -t 202605271800 "$BASE/destination/checksum_only.txt"

# ── 7. ORPHAN FILE — exists only in destination (Mirror deletes it) ───────────
echo "I should not exist at destination." > "$BASE/destination/orphan_file.txt"
touch -t 202605271200 "$BASE/destination/orphan_file.txt"

# ── 8. SUBDIRECTORY — nested new file + nested up-to-date file ───────────────
echo "Nested new file in subdir."  > "$BASE/source/subdir/nested_new.txt"
touch -t 202605281000 "$BASE/source/subdir/nested_new.txt"

echo "Nested up-to-date file." > "$BASE/source/subdir/nested_uptodate.txt"
echo "Nested up-to-date file." > "$BASE/destination/subdir/nested_uptodate.txt"
touch -t 202605271200 "$BASE/source/subdir/nested_uptodate.txt"
touch -t 202605271200 "$BASE/destination/subdir/nested_uptodate.txt"

# ── 9. ORPHAN SUBDIR — directory only in destination (Mirror deletes whole dir)
mkdir -p "$BASE/destination/orphan_subdir"
echo "I am in an orphan directory." > "$BASE/destination/orphan_subdir/orphan_in_dir.txt"
touch -t 202605271200 "$BASE/destination/orphan_subdir/orphan_in_dir.txt"

# ── Verify ────────────────────────────────────────────────────────────────────
echo ""
echo "=== SOURCE ==="
find "$BASE/source" -type f | sort | while read f; do
    size=$(stat -f%z "$f")
    mdate=$(stat -f"%Sm" -t "%Y-%m-%d %H:%M" "$f")
    printf "  %-45s  %5d bytes  mod: %s\n" "${f##*source/}" "$size" "$mdate"
done

echo ""
echo "=== DESTINATION ==="
find "$BASE/destination" -type f | sort | while read f; do
    size=$(stat -f%z "$f")
    mdate=$(stat -f"%Sm" -t "%Y-%m-%d %H:%M" "$f")
    printf "  %-45s  %5d bytes  mod: %s\n" "${f##*destination/}" "$size" "$mdate"
done

echo ""
echo "Done. Fixtures ready at $BASE"
