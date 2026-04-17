# diff-buddy
A PowerShell 7+ utility for comparing two drives or folders by file hash and relative path. Scans both paths simultaneously using parallel background jobs, hashes every file with your choice of algorithm (MD5 through SHA512), and outputs a focused diff report as a CSV. Handles locked files gracefully, auto-detects same-disk comparisons to avoid I/O contention, and includes structured error logging. Built for verifying drive migrations, backups, and large file copies — tested up to 125 GB. The script and documentation were written with Claude to move fast.


---

## Requirements

- **PowerShell 7+** — Required. The script uses `ForEach-Object -Parallel` and `Start-Job` features not available in Windows PowerShell 5.x.
- **Windows** — The GUI uses `System.Windows.Forms`, which is Windows-only.
- **Run as Administrator** — Recommended. Some system folders and locked files will be skipped without elevated permissions.

To check your PowerShell version:
```powershell
$PSVersionTable.PSVersion
```

To install PowerShell 7+: https://aka.ms/powershell

---

## How to Run

1. Place `diff-buddy.ps1` in a folder — this is where all output files will be saved.
2. Open a PowerShell 7 terminal and navigate to that folder:
   ```powershell
   cd "C:\path\to\diff_buddy"
   ```
3. Run the script:
   ```powershell
   .\diff-buddy.ps1
   ```
4. The options dialog will appear. Fill in your paths, choose your settings, and click **Start Comparison**.

> **Tip:** You can also right-click the script and choose "Run with PowerShell" — but running from a terminal lets you see the console output and progress.

---

## Options Dialog

When the script launches, a small window will appear with the following options:

### Path 1 / Path 2
The two locations to compare. These can be:
- A full drive root: `D:\` or `E:\`
- Any folder path: `C:\Users\me\Documents`

Type the path directly or use the **Browse...** button to pick a folder. Both paths must exist before the comparison can start.

### Hash Algorithm
The algorithm used to fingerprint each file's contents. A hash is a fixed-length value computed from a file's bytes — if two files have the same hash, their contents are identical.

| Option | Speed | Notes |
|---|---|---|
| **MD5** *(recommended)* | Fastest | More than sufficient for comparing copies of the same data. Not suitable for cryptographic/security use, but perfect here. |
| SHA1 | Fast | Has known theoretical vulnerabilities but fine for integrity checking. |
| SHA256 | Moderate | No known collisions. Use if you need higher confidence. |
| SHA384 | Slower | — |
| SHA512 | Slowest | Maximum confidence, maximum time. |

For most use cases — including comparing 100+ GB drives — **MD5 is the right choice**. The performance difference becomes significant at scale.

### Show matches in output file
**Unchecked by default.**

- **Unchecked:** `diffs.csv` will only contain items where something doesn't match — missing files, mismatched hashes, missing folders. This keeps the output focused and easier to act on.
- **Checked:** `diffs.csv` will contain every scanned item, including files and folders that matched perfectly on both sides. Useful if you want a complete audit trail.

> The console summary always reflects the full scan count regardless of this setting.

---

## How It Works

The script runs in five stages:

**1. Thread detection**
Before scanning, the script checks whether both paths live on the same physical disk using WMI. If they do, the parallel thread count is halved to avoid I/O contention and keep the disk usable. If they're on separate disks, it uses ~75% of your logical CPU cores.

**2. Parallel scan**
Both paths are scanned simultaneously in background jobs. For each path, the script:
- Recursively enumerates all files and folders
- Tests each item for read access (locked items are skipped and logged)
- Hashes every accessible file using the selected algorithm

**3. File comparison**
Files are compared by their **relative path** — meaning the root drive or folder is stripped before comparing. So `D:\Photos\vacation.jpg` and `E:\Photos\vacation.jpg` are treated as the same relative location `Photos\vacation.jpg`.

For each unique relative path across both sides:
- `path_match = TRUE` — the file exists at the same relative location on both sides
- `hash_match = TRUE` — the file exists on both sides **and** the contents are identical

A file can have `path_match = TRUE` but `hash_match = FALSE` — this means the file exists in both places but the contents differ (e.g. it was modified after copying).

**4. Folder comparison**
Folders are compared by relative path only (`path_match`). There is no hash for folders.

**5. Output**
Results are merged and written to `diffs.csv`. A summary prints to the console.

---

## Output Files

All output files are saved to the folder the script is run from.

### `diffs.csv`
The main output. One row per unique file or folder found across both paths.

| Column | Description |
|---|---|
| `name` | File or folder name |
| `path` | Parent directory path (from Path 1 side, if available) |
| `type` | `file` or `folder` |
| `path_match` | `TRUE` if the item exists at the same relative location on both sides |
| `hash_match` | `TRUE` if the file contents are identical on both sides. Blank for folders. |
| `path-1_location` | Full parent directory path on Path 1. Blank if not found on Path 1. |
| `path-2_location` | Full parent directory path on Path 2. Blank if not found on Path 2. |

**Reading the results:**

| `path_match` | `hash_match` | Meaning |
|---|---|---|
| TRUE | TRUE | ✓ File exists in both places with identical contents |
| TRUE | FALSE | ⚠ File exists in both places but contents differ |
| FALSE | FALSE | ✗ File only exists on one side (check which `_location` column is populated) |

### `locked_files.log`
Created only if locked or inaccessible items were found. Contains one path per line. Items listed here were skipped on **both** sides — if a folder is locked on Path 1, its contents are omitted from Path 2 as well, so the comparison stays apples-to-apples.

### `error.log`
Created only if errors occurred during the run. Contains timestamped entries at three severity levels:

- `[INFO]` — Normal operational events (scan start, thread count, results summary)
- `[WARN]` — Non-fatal issues (locked items, WMI detection failures)
- `[ERROR]` — Failures that may have affected results (job errors, hash failures, CSV write failures)

If the run completes cleanly with no warnings or errors, no `error.log` will be present.

> Each run cleans up output files from the previous run before starting, so you'll never see stale data mixed with new results.

---

## Performance Notes

- **MD5 is ~2–5x faster than SHA256** for large scans. On a 125 GB dataset this can mean the difference between a 5-minute and 15-minute run.
- **Same-disk comparisons are slower by design.** When both paths are on the same physical drive, the thread count is automatically reduced to avoid overwhelming the drive's I/O queue. This keeps your system responsive and actually tends to be faster overall than thrashing the disk with too many concurrent reads.
- **Locked files don't stall the scan.** Each item is tested before hashing. If something can't be read, it's logged and skipped immediately.
- The script has been tested on datasets up to ~125 GB. For multi-TB datasets, run times will scale roughly linearly with file count and total data size. MD5 is strongly recommended at that scale.

---

## Known Limitations

- Files with the **same name in the same relative path** but on different sides are compared as a pair. If a filename is duplicated within a single path (not possible on Windows, but relevant if porting), only the last-seen entry is used.
- **Symbolic links and junctions** are followed by `Get-ChildItem` by default. If your structure contains loops or cross-device links, this could cause unexpected behavior.
- The script compares by **relative path and hash only** — file metadata like timestamps, permissions, and attributes are not compared.

---

## Suggested Improvements

This script was built for a specific use case. I needed something that could quickly compare two drives for a work project. This repo will likely see no movement. But, I wanted to share it to potentially save other's some time. If I were to improve this script, I'd do the following:

- Improve progress in the console with a Master base + per-stage progress bars
- Build a secondary clean up / remedy script to move missing files to your target path
- Add deeper searching that checks for old vs new files and identifies similar files in different paths

## NOTICE

As stated above, this was written with Claude. I needed to quickly build a script to check if my data migration from a failing drive was successful. Please read through the code before you execute and make sure you are comfortable with its permissions. This script is not designed to write or delete any data from either target path. It should only write .tmp, .csv, and .log files to the path its exeucted in.
