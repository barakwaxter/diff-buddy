#Requires -Version 7.0
<#
.SYNOPSIS
    Compares two paths (drives or folders) for file and folder differences.
.DESCRIPTION
    Scans two paths in parallel, hashes all files, then compares by relative
    path. Outputs diffs.csv and a summary to the console.
.NOTES
    Requires PowerShell 7+
    Run from the directory where you want output files saved.
#>

# ─────────────────────────────────────────────
#  ASSEMBLY LOADS
# ─────────────────────────────────────────────
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ─────────────────────────────────────────────
#  GLOBALS
# ─────────────────────────────────────────────
$ScriptRoot = $PWD.Path
$LogLocked  = Join-Path $ScriptRoot "locked_files.log"
$LogError   = Join-Path $ScriptRoot "error.log"
$CsvDiffs   = Join-Path $ScriptRoot "diffs.csv"

# ─────────────────────────────────────────────
#  LOGGING HELPERS
# ─────────────────────────────────────────────
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO","WARN","ERROR")][string]$Level = "INFO",
        [string]$LogPath = $LogError
    )
    $ts   = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "[$ts] [$Level] $Message"
    Add-Content -Path $LogPath -Value $line -Encoding UTF8
    if ($Level -eq "ERROR") {
        Write-Host "  [ERROR] $Message" -ForegroundColor Red
    }
}

function Write-Warn {
    param([string]$Message)
    Write-Host "  ⚠  $Message" -ForegroundColor Yellow
    Write-Log -Message $Message -Level "WARN"
}

# ─────────────────────────────────────────────
#  CLEANUP PRIOR RUNS
# ─────────────────────────────────────────────
foreach ($f in @($CsvDiffs, $LogLocked, $LogError)) {
    try {
        if (Test-Path $f) { Remove-Item $f -Force -ErrorAction Stop }
    } catch {
        Write-Host "  Could not delete prior file: $f — $_" -ForegroundColor Yellow
    }
}

Write-Log "Session started." -Level INFO

# ─────────────────────────────────────────────
#  GUI — PATH PICKER
# ─────────────────────────────────────────────
function Show-PathDialog {
    $form                 = New-Object System.Windows.Forms.Form
    $form.Text            = "Compare-Paths"
    $form.Size            = New-Object System.Drawing.Size(560, 335)
    $form.StartPosition   = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox     = $false
    $form.Font            = New-Object System.Drawing.Font("Segoe UI", 9)
    $form.BackColor       = [System.Drawing.Color]::FromArgb(245, 245, 245)

    $title          = New-Object System.Windows.Forms.Label
    $title.Text     = "Drive / Folder Comparison"
    $title.Font     = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
    $title.Location = New-Object System.Drawing.Point(20, 15)
    $title.Size     = New-Object System.Drawing.Size(500, 28)
    $form.Controls.Add($title)

    function New-PathRow {
        param([string]$LabelText, [int]$Top)

        $lbl          = New-Object System.Windows.Forms.Label
        $lbl.Text     = $LabelText
        $lbl.Location = New-Object System.Drawing.Point(20, ($Top + 3))
        $lbl.Size     = New-Object System.Drawing.Size(55, 20)

        $txt          = New-Object System.Windows.Forms.TextBox
        $txt.Location = New-Object System.Drawing.Point(80, $Top)
        $txt.Size     = New-Object System.Drawing.Size(360, 24)

        $btn          = New-Object System.Windows.Forms.Button
        $btn.Text     = "Browse..."
        $btn.Location = New-Object System.Drawing.Point(450, ($Top - 1))
        $btn.Size     = New-Object System.Drawing.Size(80, 26)

        $capturedTxt = $txt
        $btn.Add_Click({
            $dlg             = New-Object System.Windows.Forms.FolderBrowserDialog
            $dlg.Description = "Select a folder or drive root"
            if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                $capturedTxt.Text = $dlg.SelectedPath
            }
        }.GetNewClosure())

        return @{ Label = $lbl; TextBox = $txt; Button = $btn }
    }

    $row1 = New-PathRow -LabelText "Path 1:" -Top 60
    $row2 = New-PathRow -LabelText "Path 2:" -Top 100
    foreach ($r in @($row1, $row2)) {
        $form.Controls.Add($r.Label)
        $form.Controls.Add($r.TextBox)
        $form.Controls.Add($r.Button)
    }

    $algLabel          = New-Object System.Windows.Forms.Label
    $algLabel.Text     = "Hash Algorithm:"
    $algLabel.Location = New-Object System.Drawing.Point(20, 145)
    $algLabel.Size     = New-Object System.Drawing.Size(115, 20)
    $form.Controls.Add($algLabel)

    $algBox               = New-Object System.Windows.Forms.ComboBox
    $algBox.DropDownStyle = "DropDownList"
    $algBox.Location      = New-Object System.Drawing.Point(140, 142)
    $algBox.Size          = New-Object System.Drawing.Size(260, 24)
    @("MD5  (recommended)", "SHA1", "SHA256", "SHA384", "SHA512") |
        ForEach-Object { [void]$algBox.Items.Add($_) }
    $algBox.SelectedIndex = 0
    $form.Controls.Add($algBox)

    $chkMatches          = New-Object System.Windows.Forms.CheckBox
    $chkMatches.Text     = "Show matches in output file"
    $chkMatches.Location = New-Object System.Drawing.Point(20, 172)
    $chkMatches.Size     = New-Object System.Drawing.Size(250, 20)
    $chkMatches.Checked  = $false
    $form.Controls.Add($chkMatches)

    $sep             = New-Object System.Windows.Forms.Label
    $sep.BorderStyle = "Fixed3D"
    $sep.Location    = New-Object System.Drawing.Point(20, 205)
    $sep.Size        = New-Object System.Drawing.Size(510, 2)
    $form.Controls.Add($sep)

    $btnOK              = New-Object System.Windows.Forms.Button
    $btnOK.Text         = "Start Comparison"
    $btnOK.Location     = New-Object System.Drawing.Point(330, 220)
    $btnOK.Size         = New-Object System.Drawing.Size(140, 30)
    $btnOK.BackColor    = [System.Drawing.Color]::FromArgb(0, 120, 215)
    $btnOK.ForeColor    = [System.Drawing.Color]::White
    $btnOK.FlatStyle    = "Flat"
    $btnOK.DialogResult = [System.Windows.Forms.DialogResult]::OK

    $capturedRow1 = $row1
    $capturedRow2 = $row2
    $capturedForm = $form
    $btnOK.Add_Click({
        if (-not $capturedRow1.TextBox.Text -or
            -not (Test-Path $capturedRow1.TextBox.Text)) {
            [void][System.Windows.Forms.MessageBox]::Show(
                "Path 1 is invalid or does not exist.", "Error")
            $capturedForm.DialogResult = [System.Windows.Forms.DialogResult]::None
            return
        }
        if (-not $capturedRow2.TextBox.Text -or
            -not (Test-Path $capturedRow2.TextBox.Text)) {
            [void][System.Windows.Forms.MessageBox]::Show(
                "Path 2 is invalid or does not exist.", "Error")
            $capturedForm.DialogResult = [System.Windows.Forms.DialogResult]::None
            return
        }
    }.GetNewClosure())

    $btnCancel              = New-Object System.Windows.Forms.Button
    $btnCancel.Text         = "Cancel"
    $btnCancel.Location     = New-Object System.Drawing.Point(200, 220)
    $btnCancel.Size         = New-Object System.Drawing.Size(120, 30)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

    $form.Controls.Add($btnOK)
    $form.Controls.Add($btnCancel)
    $form.AcceptButton = $btnOK
    $form.CancelButton = $btnCancel

    $result = $form.ShowDialog()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return $null }

    $alg = ($algBox.SelectedItem -replace '\s+\(.*\)', '').Trim()
    return @{
        Path1       = $row1.TextBox.Text.TrimEnd('\')
        Path2       = $row2.TextBox.Text.TrimEnd('\')
        Algorithm   = $alg
        ShowMatches = $chkMatches.Checked
    }
}

# ─────────────────────────────────────────────
#  THROTTLE HELPER
# ─────────────────────────────────────────────
function Get-SafeThrottle {
    param([string]$P1, [string]$P2)

    $cores = [Environment]::ProcessorCount
    $base  = [Math]::Max(2, [Math]::Floor($cores * 0.75))

    try {
        $root1  = [System.IO.Path]::GetPathRoot($P1).TrimEnd('\')
        $root2  = [System.IO.Path]::GetPathRoot($P2).TrimEnd('\')
        $serial = @{}
        Get-CimInstance Win32_LogicalDiskToPartition | ForEach-Object {
            $ltr = $_.Dependent.DeviceID
            if ($ltr) { $serial[$ltr] = $_.Antecedent.DeviceID }
        }
        $disk1 = $serial[$root1]
        $disk2 = $serial[$root2]

        if ($disk1 -and $disk2 -and ($disk1 -eq $disk2)) {
            $t = [Math]::Max(1, [Math]::Floor($base / 2))
            Write-Host "  Both paths are on the same disk. Throttle limited to $t threads." -ForegroundColor Yellow
            Write-Log "Same-disk detected ($root1). Throttle set to $t." -Level INFO
            return $t
        }
    } catch {
        Write-Log "WMI disk-detection failed: $_ — using base throttle $base." -Level WARN
    }

    Write-Host "  Using $base parallel threads." -ForegroundColor Cyan
    Write-Log "Throttle set to $base threads." -Level INFO
    return $base
}

# ─────────────────────────────────────────────
#  RELATIVE PATH HELPER
# ─────────────────────────────────────────────
function Get-RelativePath {
    param([string]$FullPath, [string]$Root)
    $norm = $Root.TrimEnd('\')
    if ($FullPath.StartsWith($norm, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $FullPath.Substring($norm.Length).TrimStart('\')
    }
    return $FullPath
}

# ─────────────────────────────────────────────
#  SCAN SCRIPTBLOCK
#  Args: $root, $alg, $throttle, $lockLog, $errLog
#  No $using: references — everything via params.
# ─────────────────────────────────────────────
$ScanBlock = {
    param(
        [string]$root,
        [string]$alg,
        [int]   $throttle,
        [string]$lockLog,
        [string]$errLog
    )

    function JobLog {
        param([string]$Msg, [string]$Level = "INFO", [string]$Path)
        $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Add-Content -Path $Path -Value "[$ts] [$Level] $Msg" -Encoding UTF8
    }

    $lockedList  = [System.Collections.Generic.List[string]]::new()
    $lockedRoots = [System.Collections.Generic.HashSet[string]]::new(
                       [System.StringComparer]::OrdinalIgnoreCase)
    $folderRows  = [System.Collections.Generic.List[PSCustomObject]]::new()

    # ── Enumerate ────────────────────────────
    try {
        $allItems = @(Get-ChildItem -Path $root -Recurse -Force -ErrorAction SilentlyContinue)
    } catch {
        JobLog "Get-ChildItem failed on root '$root': $_" -Level ERROR -Path $errLog
        return @{ Data = @(); LockedCount = 0 }
    }

    # ── Lock detection + folder collection ───
    foreach ($item in $allItems) {
        $skip = $false
        foreach ($lr in $lockedRoots) {
            if ($item.FullName.StartsWith($lr, [System.StringComparison]::OrdinalIgnoreCase)) {
                $skip = $true; break
            }
        }
        if ($skip) { continue }

        $isLocked = $false
        try {
            if ($item.PSIsContainer) {
                Get-ChildItem -Path $item.FullName -ErrorAction Stop | Out-Null
            } else {
                $fs = [System.IO.File]::Open(
                    $item.FullName,
                    [System.IO.FileMode]::Open,
                    [System.IO.FileAccess]::Read,
                    [System.IO.FileShare]::ReadWrite)
                $fs.Close(); $fs.Dispose()
            }
        } catch {
            $isLocked = $true
            [void]$lockedRoots.Add($item.FullName)
            $lockedList.Add($item.FullName)
            JobLog "Locked item skipped: $($item.FullName)" -Level WARN -Path $errLog
        }

        if (-not $isLocked -and $item.PSIsContainer) {
            $folderRows.Add([PSCustomObject]@{
                name              = $item.Name
                path              = $item.FullName
                file_hash         = ""
                folder_file_count = 0
                type              = "folder"
            })
        }
    }

    # ── Accessible files ──────────────────────
    $accessibleFiles = $allItems | Where-Object {
        if ($_.PSIsContainer) { return $false }
        $fp = $_.FullName
        foreach ($lr in $lockedRoots) {
            if ($fp.StartsWith($lr, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
        }
        return $true
    }

    # ── Folder file counts ────────────────────
    $folderCounts = @{}
    foreach ($f in $accessibleFiles) {
        $p = $f.DirectoryName
        if (-not $folderCounts.ContainsKey($p)) { $folderCounts[$p] = 0 }
        $folderCounts[$p]++
    }

    $updatedFolders = $folderRows | ForEach-Object {
        $cnt = if ($folderCounts.ContainsKey($_.path)) { $folderCounts[$_.path] } else { 0 }
        [PSCustomObject]@{
            name              = $_.name
            path              = $_.path
            file_hash         = ""
            folder_file_count = $cnt
            type              = "folder"
        }
    }

    # ── Hash files (plain foreach — no $using:) ─
    $hashedFiles = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($f in $accessibleFiles) {
        try {
            $hash = (Get-FileHash -Path $f.FullName -Algorithm $alg -ErrorAction Stop).Hash
            $hashedFiles.Add([PSCustomObject]@{
                name              = $f.Name
                path              = $f.FullName
                file_hash         = $hash
                folder_file_count = ""
                type              = "file"
            })
        } catch {
            $lockedList.Add($f.FullName)
            JobLog "Hash failed for '$($f.FullName)': $_" -Level ERROR -Path $errLog
        }
    }

    if ($lockedList.Count -gt 0) {
        $lockedList | Sort-Object | Set-Content -Path $lockLog -Encoding UTF8
    }

    $allRows = @($updatedFolders) + @($hashedFiles)
    return @{ Data = $allRows; LockedCount = $lockedList.Count }
}

# ═════════════════════════════════════════════
#  MAIN
# ═════════════════════════════════════════════

# 1 — GUI
try {
    $params = Show-PathDialog
} catch {
    Write-Log "GUI failed to launch: $_" -Level ERROR
    Write-Host "Fatal: could not open dialog. See error.log." -ForegroundColor Red
    exit 1
}

if ($null -eq $params) {
    Write-Log "User cancelled at path dialog." -Level INFO
    Write-Host "Cancelled." -ForegroundColor Yellow
    exit
}

$Path1       = $params.Path1
$Path2       = $params.Path2
$Algorithm   = $params.Algorithm
$ShowMatches = $params.ShowMatches

Write-Log "Path 1: $Path1 | Path 2: $Path2 | Algorithm: $Algorithm" -Level INFO

Write-Host ""
Write-Host "═══════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Compare-Paths" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Path 1    : $Path1"
Write-Host "  Path 2    : $Path2"
Write-Host "  Algorithm : $Algorithm"
Write-Host "  Output    : $ScriptRoot"
Write-Host "═══════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# 2 — Throttle
Write-Host "[1/5] Determining thread count..." -ForegroundColor Cyan
$Throttle = Get-SafeThrottle -P1 $Path1 -P2 $Path2

# 3 — Scan both paths in parallel
Write-Host ""
Write-Host "[2/5] Scanning paths (parallel)..." -ForegroundColor Cyan
Write-Progress -Activity "Compare-Paths" -Status "Scanning both paths..." -PercentComplete 10

$lockLog1 = Join-Path $ScriptRoot "locked-1.tmp"
$lockLog2 = Join-Path $ScriptRoot "locked-2.tmp"
$errLog1  = Join-Path $ScriptRoot "error-1.tmp"
$errLog2  = Join-Path $ScriptRoot "error-2.tmp"

Write-Log "Starting scan jobs." -Level INFO

try {
    $job1 = Start-Job -ScriptBlock $ScanBlock `
                      -ArgumentList $Path1, $Algorithm, $Throttle, $lockLog1, $errLog1
    $job2 = Start-Job -ScriptBlock $ScanBlock `
                      -ArgumentList $Path2, $Algorithm, $Throttle, $lockLog2, $errLog2
} catch {
    Write-Log "Failed to start scan jobs: $_" -Level ERROR
    Write-Host "Fatal: could not start background jobs. See error.log." -ForegroundColor Red
    exit 1
}

while ($job1.State -eq 'Running' -or $job2.State -eq 'Running') {
    Start-Sleep -Milliseconds 600
    Write-Progress -Activity "Compare-Paths" -Status "Scanning paths..." -PercentComplete 20
}

$result1 = Receive-Job -Job $job1 -ErrorAction SilentlyContinue
$result2 = Receive-Job -Job $job2 -ErrorAction SilentlyContinue

foreach ($j in @($job1, $job2)) {
    $jLabel = if ($j.Id -eq $job1.Id) { "job1 (Path 1)" } else { "job2 (Path 2)" }
    $j.ChildJobs | ForEach-Object {
        if ($_.JobStateInfo.Reason) {
            $msg = "$jLabel terminated: $($_.JobStateInfo.Reason)"
            Write-Log $msg -Level ERROR
            Write-Host "  [ERROR] $msg" -ForegroundColor Red
        }
    }
}

Remove-Job -Job $job1, $job2 -Force

# Merge per-job logs
foreach ($tmp in @($errLog1, $errLog2)) {
    if (Test-Path $tmp) {
        Get-Content $tmp | Add-Content -Path $LogError -Encoding UTF8
        Remove-Item $tmp -Force
    }
}

$allLocked = @()
foreach ($tmp in @($lockLog1, $lockLog2)) {
    if (Test-Path $tmp) {
        $allLocked += Get-Content $tmp
        Remove-Item $tmp -Force
    }
}
if ($allLocked.Count -gt 0) {
    $allLocked | Sort-Object -Unique | Set-Content -Path $LogLocked -Encoding UTF8
    Write-Warn "$($allLocked.Count) item(s) locked and skipped. See: locked_files.log"
}

$scan1 = if ($result1 -and $result1.Data) { @($result1.Data) } else { @() }
$scan2 = if ($result2 -and $result2.Data) { @($result2.Data) } else { @() }

if ($scan1.Count -eq 0) { Write-Log "Scan returned 0 items for Path 1 ($Path1)." -Level WARN }
if ($scan2.Count -eq 0) { Write-Log "Scan returned 0 items for Path 2 ($Path2)." -Level WARN }

Write-Host ("  ✓ Scan complete.  Path 1: {0} items  |  Path 2: {1} items" `
    -f $scan1.Count, $scan2.Count) -ForegroundColor Green
Write-Log "Scan complete. P1=$($scan1.Count) items, P2=$($scan2.Count) items." -Level INFO

# ─────────────────────────────────────────────
#  4 — COMPARE FILES
#
#  Keyed on relative path — one row per unique
#  relative path regardless of hash value.
#  hash_match = true only when both sides exist
#  AND their hashes are identical.
# ─────────────────────────────────────────────
Write-Host ""
Write-Host "[3/5] Comparing files..." -ForegroundColor Cyan
Write-Progress -Activity "Compare-Paths" -Status "Comparing files..." -PercentComplete 40

$files1 = @($scan1 | Where-Object { $_.type -eq "file" })
$files2 = @($scan2 | Where-Object { $_.type -eq "file" })

$files1ByRel = @{}
$files1 | ForEach-Object { $files1ByRel[(Get-RelativePath $_.path $Path1)] = $_ }

$files2ByRel = @{}
$files2 | ForEach-Object { $files2ByRel[(Get-RelativePath $_.path $Path2)] = $_ }

# Union of all relative paths — guarantees one row per file
$allFileRels = (
    @($files1 | ForEach-Object { Get-RelativePath $_.path $Path1 }) +
    @($files2 | ForEach-Object { Get-RelativePath $_.path $Path2 })
) | Sort-Object -Unique

try {
    $fileDiffRows = $allFileRels | ForEach-Object -Parallel {
        $rel   = $_
        $f1Rel = $using:files1ByRel
        $f2Rel = $using:files2ByRel

        $entry1 = if ($f1Rel.ContainsKey($rel)) { $f1Rel[$rel] } else { $null }
        $entry2 = if ($f2Rel.ContainsKey($rel)) { $f2Rel[$rel] } else { $null }

        $inP1 = $null -ne $entry1
        $inP2 = $null -ne $entry2

        # path_match: same relative path exists on both sides
        $pathMatch = $inP1 -and $inP2

        # hash_match: both sides exist AND hashes are identical
        $hashMatch = $inP1 -and $inP2 -and ($entry1.file_hash -eq $entry2.file_hash)

        $p1Loc = if ($entry1) { [System.IO.Path]::GetDirectoryName($entry1.path) } else { "" }
        $p2Loc = if ($entry2) { [System.IO.Path]::GetDirectoryName($entry2.path) } else { "" }

        [PSCustomObject]@{
            name              = if ($entry1) { $entry1.name } elseif ($entry2) { $entry2.name } else { "" }
            file_hash         = if ($entry1) { $entry1.file_hash } else { $entry2.file_hash }
            hash_match        = $hashMatch
            path_match        = $pathMatch
            "path-1_location" = $p1Loc
            "path-2_location" = $p2Loc
        }
    } -ThrottleLimit $Throttle
} catch {
    Write-Log "File comparison failed: $_" -Level ERROR
    $fileDiffRows = @()
}

Write-Host ("  ✓ File comparison complete. {0} unique file(s) evaluated." `
    -f @($fileDiffRows).Count) -ForegroundColor Green
Write-Log "File comparison complete. $(@($fileDiffRows).Count) unique files." -Level INFO

# ─────────────────────────────────────────────
#  5 — COMPARE FOLDERS
# ─────────────────────────────────────────────
Write-Host ""
Write-Host "[4/5] Comparing folders..." -ForegroundColor Cyan
Write-Progress -Activity "Compare-Paths" -Status "Comparing folders..." -PercentComplete 60

$folders1 = @($scan1 | Where-Object { $_.type -eq "folder" })
$folders2 = @($scan2 | Where-Object { $_.type -eq "folder" })

$fold1ByRel = @{}
$folders1 | ForEach-Object { $fold1ByRel[(Get-RelativePath $_.path $Path1)] = $_ }

$fold2ByRel = @{}
$folders2 | ForEach-Object { $fold2ByRel[(Get-RelativePath $_.path $Path2)] = $_ }

$allFolderRels = (
    @($folders1 | ForEach-Object { Get-RelativePath $_.path $Path1 }) +
    @($folders2 | ForEach-Object { Get-RelativePath $_.path $Path2 })
) | Sort-Object -Unique

try {
    $folderDiffRows = $allFolderRels | ForEach-Object -Parallel {
        $rel     = $_
        $f1ByRel = $using:fold1ByRel
        $f2ByRel = $using:fold2ByRel

        $inP1   = $f1ByRel.ContainsKey($rel)
        $inP2   = $f2ByRel.ContainsKey($rel)
        $entry1 = if ($inP1) { $f1ByRel[$rel] } else { $null }
        $entry2 = if ($inP2) { $f2ByRel[$rel] } else { $null }

        [PSCustomObject]@{
            name              = if ($entry1) { $entry1.name } elseif ($entry2) { $entry2.name } else { $rel }
            path_match        = ($inP1 -and $inP2)
            "path-1_location" = if ($entry1) { $entry1.path } else { "" }
            "path-2_location" = if ($entry2) { $entry2.path } else { "" }
        }
    } -ThrottleLimit $Throttle
} catch {
    Write-Log "Folder comparison failed: $_" -Level ERROR
    $folderDiffRows = @()
}

Write-Host ("  ✓ Folder comparison complete. {0} unique folder(s) evaluated." `
    -f @($folderDiffRows).Count) -ForegroundColor Green
Write-Log "Folder comparison complete. $(@($folderDiffRows).Count) unique folders." -Level INFO

# ─────────────────────────────────────────────
#  6 — MERGE INTO diffs.csv
# ─────────────────────────────────────────────
Write-Host ""
Write-Host "[5/5] Writing diffs.csv..." -ForegroundColor Cyan
Write-Progress -Activity "Compare-Paths" -Status "Writing diffs.csv..." -PercentComplete 80

$diffRows = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($row in @($fileDiffRows)) {
    $diffRows.Add([PSCustomObject]@{
        name              = $row.name
        path              = $row."path-1_location"
        type              = "file"
        path_match        = $row.path_match
        hash_match        = $row.hash_match
        "path-1_location" = $row."path-1_location"
        "path-2_location" = $row."path-2_location"
    })
}

foreach ($row in @($folderDiffRows)) {
    $diffRows.Add([PSCustomObject]@{
        name              = $row.name
        path              = $row."path-1_location"
        type              = "folder"
        path_match        = $row.path_match
        hash_match        = ""
        "path-1_location" = $row."path-1_location"
        "path-2_location" = $row."path-2_location"
    })
}

# Filter out full matches if ShowMatches is unchecked
$rowsToWrite = if ($ShowMatches) {
    $diffRows
} else {
    @($diffRows | Where-Object {
        -not ($_.path_match -eq $true -and ($_.type -eq "folder" -or $_.hash_match -eq $true))
    })
}

try {
    $rowsToWrite | Export-Csv -Path $CsvDiffs -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
} catch {
    Write-Log "Failed to write diffs.csv: $_" -Level ERROR
}

Write-Progress -Activity "Compare-Paths" -Status "Done" -PercentComplete 100
Start-Sleep -Milliseconds 300
Write-Progress -Activity "Compare-Paths" -Completed

# ─────────────────────────────────────────────
#  SUMMARY
# ─────────────────────────────────────────────
$totalScanned = $diffRows.Count
$mismatched   = @($diffRows | Where-Object {
    ($_.type -eq "file"   -and ($_.path_match -eq $false -or $_.hash_match -eq $false)) -or
    ($_.type -eq "folder" -and  $_.path_match -eq $false)
})

Write-Host ""
Write-Host "═══════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  RESULTS" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════" -ForegroundColor Cyan

if ($mismatched.Count -eq 0) {
    Write-Host ""
    Write-Host ("  ✓ All files/folders match ({0} scanned)" -f $totalScanned) -ForegroundColor Green
    Write-Host ""
    Write-Log "Result: all $totalScanned items match." -Level INFO
} else {
    Write-Host ""
    Write-Host ("  ✗ {0} mismatch(es) of {1} items. See: {2}" `
        -f $mismatched.Count, $totalScanned, $CsvDiffs) -ForegroundColor Red
    Write-Host ""
    $mismatched |
        Select-Object name, type, path_match, hash_match,
            @{N="path-1_location"; E={ $_."path-1_location" }},
            @{N="path-2_location"; E={ $_."path-2_location" }} |
        Format-Table -AutoSize -Wrap
    Write-Log "Result: $($mismatched.Count) mismatch(es) out of $totalScanned items." -Level WARN
}

Write-Host "═══════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Output: $ScriptRoot" -ForegroundColor DarkCyan
Write-Host "═══════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

Write-Log "Session complete." -Level INFO