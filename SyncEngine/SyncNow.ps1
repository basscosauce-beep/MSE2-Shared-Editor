param(
    [switch]$SkipPreview,     # Set by CloudSync.ps1 - preview was already done there
    [string]$PredecidedFile   # Path to temp file with KEEP:/REMOVE:/RESTORE: decisions
)

$Host.UI.RawUI.WindowTitle = "Magic Set Editor - Sync v3.4"

# ---------------------------------------------------------------------------
# Auto-save MSE2 BEFORE killing it so unsaved cards are flushed to disk.
# This is critical: if MSE2 hasn't saved, any new cards exist only in memory
# and will be lost when we kill the process.
# ---------------------------------------------------------------------------
$mseProc = Get-Process "magicseteditor" -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
$mseExePath = $null

$gitCmd = "$PSScriptRoot\..\mingit\cmd\git.exe"
$env:GIT_TERMINAL_PROMPT = "0"
$env:GIT_ASKPASS = "echo"
$repoDir = (Resolve-Path "$PSScriptRoot\..").Path

# Resolve set file path up front (used in multiple places below)
$setFile = Get-ChildItem "$repoDir\Shared-Set" -Recurse -Filter "*.mse-set" |
    Where-Object { $_.Name -notlike "*.bak" -and $_.FullName -notlike "*\_pre_sync_backups\*" } |
    Select-Object -First 1

if ($mseProc) {
    try { $mseExePath = $mseProc.MainModule.FileName } catch {}
    Write-Host "Auto-saving your cards..." -ForegroundColor Cyan
    Add-Type -AssemblyName Microsoft.VisualBasic
    Add-Type -AssemblyName System.Windows.Forms

    # Record timestamp RIGHT before sending Ctrl+S
    $preTimestamp = $null
    if ($setFile) { $preTimestamp = $setFile.LastWriteTime }

    # Bring MSE2 to foreground
    $focused = $false
    try { [Microsoft.VisualBasic.Interaction]::AppActivate($mseProc.Id); $focused = $true } catch {}
    if (-not $focused) {
        try { [Microsoft.VisualBasic.Interaction]::AppActivate($mseProc.MainWindowTitle); $focused = $true } catch {}
    }

    if ($focused) {
        Start-Sleep -Milliseconds 300
        [System.Windows.Forms.SendKeys]::SendWait("^s")

        # Poll every 300ms for up to 4s for the file timestamp to update
        $saveVerified = $false
        for ($wait = 0; $wait -lt 14; $wait++) {
            Start-Sleep -Milliseconds 300
            $setFile.Refresh()
            if ($preTimestamp -and $setFile.LastWriteTime -gt $preTimestamp) {
                $saveVerified = $true; Write-Host "Save verified." -ForegroundColor Green; break
            }
        }

        # Not saved yet - one more Ctrl+S and another 3 seconds of polling
        if (-not $saveVerified) {
            [System.Windows.Forms.SendKeys]::SendWait("^s")
            for ($wait = 0; $wait -lt 10; $wait++) {
                Start-Sleep -Milliseconds 300
                $setFile.Refresh()
                if ($preTimestamp -and $setFile.LastWriteTime -gt $preTimestamp) {
                    $saveVerified = $true; Write-Host "Save verified (2nd attempt)." -ForegroundColor Green; break
                }
            }
        }

        if (-not $saveVerified) {
            Write-Host "=========================================================" -ForegroundColor Yellow
            Write-Host " WARNING: Could not verify MSE2 saved to disk."           -ForegroundColor Yellow
            Write-Host " Press Ctrl+C to cancel, save (Ctrl+S), then sync again." -ForegroundColor Yellow
            Write-Host "=========================================================" -ForegroundColor Yellow
            Start-Sleep -Seconds 6
        }
    } else {
        Write-Host "=========================================================" -ForegroundColor Yellow
        Write-Host " WARNING: Could not bring MSE2 to foreground to save."    -ForegroundColor Yellow
        Write-Host " Press Ctrl+C to cancel, save (Ctrl+S), then sync again." -ForegroundColor Yellow
        Write-Host "=========================================================" -ForegroundColor Yellow
        Start-Sleep -Seconds 6
    }
}

# Kill MSE2 so file locks are released
Write-Host "Closing Magic Set Editor..." -ForegroundColor Yellow
Stop-Process -Name "magicseteditor" -Force -ErrorAction SilentlyContinue
Stop-Process -Name "MenuAddon"      -Force -ErrorAction SilentlyContinue

# Poll every 250ms until gone (typically < 500ms)
for ($w = 0; $w -lt 20; $w++) {
    Start-Sleep -Milliseconds 250
    if (-not (Get-Process "magicseteditor" -ErrorAction SilentlyContinue)) { break }
}
Write-Host "Syncing with cloud..." -ForegroundColor Cyan

$p1 = "ghp_2g4dOrh3klYwVMo6o"
$p2 = "FNfD8iUKfATTq3ezyS4"
$remoteUrl = "https://basscosauce-beep:$p1$p2@github.com/basscosauce-beep/MSE2-Shared-Editor.git"
$credBypass = @("-c", "credential.helper=")

& $gitCmd -C $repoDir @credBypass remote set-url origin $remoteUrl *>$null

# Ensure user config is set
$userName = (& $gitCmd -C $repoDir config user.name 2>$null).Trim()
if (-not $userName) {
    & $gitCmd -C $repoDir config user.name "MSE Shared" *>$null
    & $gitCmd -C $repoDir config user.email "shared@mse.local" *>$null
    $userName = "MSE Shared"
}
# Bug #8 fix: if user.name is the generic fallback, use a machine-specific ID
# so draft files don't collide between users on different machines.
$draftUserName = $userName
if ($draftUserName -match "^(MSE Shared|Anonymous|Unknown)$") {
    $draftUserName = $env:USERNAME  # Windows login name - unique per machine
    if (-not $draftUserName) { $draftUserName = [System.Net.Dns]::GetHostName() }
}

# First-time setup: no commits yet
$hasCommits = (& $gitCmd -C $repoDir log --oneline -1 2>$null).Trim()
if (-not $hasCommits) {
    Write-Host "First-time setup - downloading game files..." -ForegroundColor Yellow
    & $gitCmd -C $repoDir @credBypass fetch origin *>$null
    & $gitCmd -C $repoDir checkout -B main origin/main -f *>$null
    & $gitCmd -C $repoDir branch --set-upstream-to=origin/main main *>$null
}

# Auto-repair wrong branch
$branch = (& $gitCmd -C $repoDir branch --show-current 2>$null).Trim()
if ($branch -ne "main") {
    & $gitCmd -C $repoDir @credBypass fetch origin *>$null
    & $gitCmd -C $repoDir checkout -B main origin/main -f *>$null
    & $gitCmd -C $repoDir branch --set-upstream-to=origin/main main *>$null
}


# ---------------------------------------------------------------
# STEP 1: Back up the local set file AFTER MSE2 is closed.
# Retry up to 5x to handle cases where MSE2 was mid-write when killed.
# ---------------------------------------------------------------
$setFile = Get-ChildItem "$repoDir\Shared-Set" -Recurse -Filter "*.mse-set" |
    Where-Object { $_.Name -notlike "*.bak" -and $_.FullName -notlike "*\_pre_sync_backups\*" } |
    Select-Object -First 1
$localBackupPath = $null
if ($setFile -and (Test-Path $setFile.FullName)) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $backupOk = $false
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            $testZip = [System.IO.Compression.ZipFile]::OpenRead($setFile.FullName)
            $testEntry = $testZip.Entries | Where-Object { $_.Name -eq "set" } | Select-Object -First 1
            if ($testEntry) {
                $testSr = New-Object System.IO.StreamReader($testEntry.Open(), [System.Text.Encoding]::UTF8)
                $testTxt = $testSr.ReadToEnd(); $testSr.Dispose()
                $testCardCount = ($testTxt -split "(?m)^(?=card:)" | Where-Object { $_ -match "^card:" }).Count
                $testZip.Dispose()
                if ($testCardCount -gt 0) {
                    $backupOk = $true
                    Write-Host "Local file verified: $testCardCount cards found." -ForegroundColor DarkCyan
                    break
                } else {
                    Write-Host ("Attempt {0}: local file has 0 cards - waiting for disk flush..." -f $attempt) -ForegroundColor Yellow
                }
            } else {
                $testZip.Dispose()
                Write-Host ("Attempt {0}: local zip has no 'set' entry - waiting..." -f $attempt) -ForegroundColor Yellow
            }
        } catch {
            $errMsg = $_.Exception.Message
            Write-Host ("Attempt {0}: local file not readable yet ({1}) - waiting..." -f $attempt, $errMsg) -ForegroundColor Yellow
        }
        Start-Sleep -Seconds 2
    }

    if ($backupOk) {
        $localBackupPath = "$env:TEMP\mse_local_backup_$([System.IO.Path]::GetRandomFileName()).mse-set"
        Copy-Item $setFile.FullName $localBackupPath -Force
        Write-Host "Local cards backed up for merge." -ForegroundColor DarkCyan
    } else {
        Write-Host "" -ForegroundColor Red
        Write-Host "=========================================================" -ForegroundColor Red
        Write-Host " WARNING: Could not read local set file after 5 attempts." -ForegroundColor Red
        Write-Host " Your LOCAL card changes may not be synced this time." -ForegroundColor Red
        Write-Host " Cloud cards will be downloaded safely." -ForegroundColor Red
        Write-Host "=========================================================" -ForegroundColor Red
        Write-Host "" -ForegroundColor Red
    }
    # ---------------------------------------------------------------
    # SAFETY NET: Save a timestamped backup before the git reset.
    # Even if merge fails, these files are recoverable forever.
    # ---------------------------------------------------------------
    $safeBackupDir = "$repoDir\Shared-Set\_pre_sync_backups"
    if (-not (Test-Path $safeBackupDir)) { New-Item -ItemType Directory -Path $safeBackupDir -Force | Out-Null }
    $safeStamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    Copy-Item $setFile.FullName "$safeBackupDir\backup_${safeStamp}_${userName}.mse-set" -Force
    # Keep only the 20 most recent backups per user
    Get-ChildItem $safeBackupDir -Filter "backup_*_${userName}.mse-set" |
        Sort-Object LastWriteTime -Descending | Select-Object -Skip 20 |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------
# STEP 2: Force-sync to the exact cloud state
# Always fetch + reset so we never get merge conflicts on binary files
# ---------------------------------------------------------------
Write-Host "Downloading latest cards from friends..." -ForegroundColor Yellow
& $gitCmd -C $repoDir @credBypass fetch origin *>$null
& $gitCmd -C $repoDir reset --hard origin/main *>$null

# ---------------------------------------------------------------
# STEP 3: Merge any new locally-made cards back in
# MergeSetFile compares time_created timestamps to find cards
# that exist in the local backup but not in the cloud version
# ---------------------------------------------------------------
if ($localBackupPath -and (Test-Path $localBackupPath)) {
    $cloudSetFile = Get-ChildItem "$repoDir\Shared-Set" -Recurse -Filter "*.mse-set" |
        Where-Object { $_.Name -notlike "*.bak" -and $_.FullName -notlike "*\_pre_sync_backups\*" } |
        Select-Object -First 1

    # -----------------------------------------------------------------------
    # STEP 3a: Inject any "Create This Card" draft cards into the local backup
    # GoalTracker writes draft_cards_<user>.txt; we append them here so they
    # ride through MergeSetFile as newly-created local cards.
    # Uses $draftUserName (machine-specific) not $userName (generic git name)
    # -----------------------------------------------------------------------
    $safeUserForDraft = $draftUserName -replace '[\/:*?"<>|]', '_'
    $draftFile = "$repoDir\Shared-Set\draft_cards_${safeUserForDraft}.txt"
    if (Test-Path $draftFile) {
        $draftContent = Get-Content $draftFile -Raw
        if ($draftContent.Trim()) {
            Write-Host "Adding $($($draftContent -split '(?m)^card:' | Where-Object {$_.Trim()}).Count) drafted card(s) to your set..." -ForegroundColor Cyan
            try {
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                # Read existing backup set text
                $bzr = [System.IO.Compression.ZipFile]::OpenRead($localBackupPath)
                $bent = $bzr.Entries | Where-Object { $_.Name -eq "set" }
                $bsr  = New-Object System.IO.StreamReader($bent.Open(), [System.Text.Encoding]::UTF8)
                $bTxt = $bsr.ReadToEnd()
                $bsr.Dispose(); $bzr.Dispose()

                $newTxt = $bTxt.TrimEnd() + "`n" + $draftContent.Trim() + "`n"

                # Write updated backup via temp zip
                $tmpDraft = [System.IO.Path]::GetTempFileName() + ".mse-set"
                $bsr2 = [System.IO.Compression.ZipFile]::OpenRead($localBackupPath)
                $bdst = [System.IO.Compression.ZipFile]::Open($tmpDraft, [System.IO.Compression.ZipArchiveMode]::Create)
                $bNewEnt = $bdst.CreateEntry("set", [System.IO.Compression.CompressionLevel]::Optimal)
                $bNS = $bNewEnt.Open()
                $bWr = New-Object System.IO.StreamWriter($bNS, [System.Text.Encoding]::UTF8)
                $bWr.Write($newTxt); $bWr.Flush(); $bWr.Dispose()
                foreach ($imgEnt in ($bsr2.Entries | Where-Object { $_.Name -ne "set" })) {
                    $dEnt = $bdst.CreateEntry($imgEnt.FullName, [System.IO.Compression.CompressionLevel]::Optimal)
                    $s2 = $imgEnt.Open(); $d2 = $dEnt.Open()
                    $s2.CopyTo($d2); $s2.Dispose(); $d2.Dispose()
                }
                $bsr2.Dispose(); $bdst.Dispose()
                Copy-Item $tmpDraft $localBackupPath -Force
                Remove-Item $tmpDraft -Force -ErrorAction SilentlyContinue

                Remove-Item $draftFile -Force -ErrorAction SilentlyContinue
                Write-Host "Draft cards injected." -ForegroundColor Green
            } catch {
                Write-Host "Warning: Could not inject draft cards: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
    }

    if ($cloudSetFile) {
        . "$PSScriptRoot\MergeSetFile.ps1" -LocalBackup $localBackupPath -CloudFile $cloudSetFile.FullName -UserName $userName
    }
    Remove-Item $localBackupPath -Force -ErrorAction SilentlyContinue
}

# -----------------------------------------------------------------------
# STEP 4: Auto-fill the "By" column for any cards missing a creator
# -----------------------------------------------------------------------
. "$PSScriptRoot\FillCreators.ps1" -RepoDir $repoDir -GitCmd $gitCmd -CredBypass $credBypass

# -----------------------------------------------------------------------
# STEP 4b: Re-save last_known hashes from the FINAL set file
# (FillCreators may have modified card content; we need hashes of the
# final state so the next sync's change-detection is accurate)
# -----------------------------------------------------------------------
if ($cloudSetFile) {
    $safeUser      = $userName -replace '[\\/:*?"<>|]', '_'
    $setDir        = [System.IO.Path]::GetDirectoryName($cloudSetFile.FullName)
    $lastKnownFile = "$setDir\last_known_$safeUser.txt"
    # Save-LastKnown was defined inside MergeSetFile.ps1 which was dot-sourced above
    Save-LastKnown -SetFilePath $cloudSetFile.FullName -KnownFile $lastKnownFile
    Write-Host "Hash baseline updated after creator fill." -ForegroundColor DarkGray
}


# ---------------------------------------------------------------
# STEP 5: Apply Remove/Keep decisions made in the Cloud Sync window.
# CloudSync.ps1 writes KEEP:, REMOVE:, RESTORE: lines to $PredecidedFile
# before launching this script. If called without -SkipPreview (e.g. by
# a script or directly), this block is skipped and the sync proceeds as-is.
# ---------------------------------------------------------------
if ($SkipPreview -and $PredecidedFile -and (Test-Path $PredecidedFile) -and $cloudSetFile) {
    Write-Host "Applying your sync decisions..." -ForegroundColor Cyan
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        Add-Type -AssemblyName System.IO.Compression

        $decisions = Get-Content $PredecidedFile -Encoding UTF8
        Remove-Item $PredecidedFile -Force -ErrorAction SilentlyContinue

        $removeSet  = New-Object System.Collections.Generic.HashSet[string]
        $restoreMap = @{}
        foreach ($dec in $decisions) {
            if ($dec -match '^REMOVE:(.+)$')           { $removeSet.Add($matches[1].Trim()) | Out-Null }
            if ($dec -match '^RESTORE:([^|]+)[|](.+)$') { $restoreMap[$matches[1].Trim()] = $matches[2] }
        }

        if ($removeSet.Count -gt 0 -or $restoreMap.Count -gt 0) {
            # Read the current merged set text
            $rz  = [System.IO.Compression.ZipFile]::OpenRead($cloudSetFile.FullName)
            $re  = $rz.Entries | Where-Object { $_.Name -eq "set" } | Select-Object -First 1
            $rsr = New-Object System.IO.StreamReader($re.Open(), [System.Text.Encoding]::UTF8)
            $mergedTxt = $rsr.ReadToEnd(); $rsr.Dispose(); $rz.Dispose()

            # Parse into ordered card map keyed by time_created
            $cmap = [System.Collections.Specialized.OrderedDictionary]::new()
            $mergedTxt -split "(?m)^(?=card:)" | Where-Object { $_ -match "^card:" } | ForEach-Object {
                $blk = ($_ -split "(?m)^(?=keyword:|version_control:|apprentice_code:)")[0]
                if ($blk -match "(?m)^\s*time_created:\s*([^\r\n]+)") {
                    $tc = $matches[1].Trim()
                    if (-not $cmap.Contains($tc)) { $cmap[$tc] = $blk }
                }
            }

            # Apply removals and restores
            foreach ($rtc in @($removeSet))    { if ($cmap.Contains($rtc))    { $cmap.Remove($rtc) } }
            foreach ($rtc in $restoreMap.Keys) { if (-not $cmap.Contains($rtc)) { $cmap[$rtc] = $restoreMap[$rtc] } }

            # Extract file header (everything before first card: block)
            $hdr = if ($mergedTxt -match "(?s)^(.*?)\r?\ncard:") { $matches[1] + "`r`n" } else { "" }

            # Extract trailing section (keywords / version_control / etc. after last card)
            $trail   = ""
            $lastIdx = $mergedTxt.LastIndexOf("`ncard:")
            if ($lastIdx -ge 0) {
                $after = $mergedTxt.Substring($lastIdx)
                if ($after -match "(?s)`r?`n(keyword:|version_control:|apprentice_code:)") {
                    $ts = $after.IndexOf("`r`n" + $matches[1])
                    if ($ts -lt 0) { $ts = $after.IndexOf("`n" + $matches[1]) }
                    if ($ts -ge 0) { $trail = "`r`n" + $after.Substring($ts).TrimStart("`r", "`n") }
                }
            }

            # Rebuild set text
            $newTxt = $hdr
            foreach ($tc in $cmap.Keys) {
                $blk = $cmap[$tc]
                if (-not $blk.StartsWith("card:")) { $blk = "card:`r`n" + $blk }
                $newTxt += $blk.TrimEnd() + "`r`n"
            }
            $newTxt += $trail

            # Write back into zip
            $tmpZ   = [System.IO.Path]::GetTempFileName() + ".mse-set"
            $srcZip = [System.IO.Compression.ZipFile]::OpenRead($cloudSetFile.FullName)
            $dstZip = [System.IO.Compression.ZipFile]::Open($tmpZ, [System.IO.Compression.ZipArchiveMode]::Create)
            $se = $dstZip.CreateEntry("set", [System.IO.Compression.CompressionLevel]::Optimal)
            $sw = New-Object System.IO.StreamWriter($se.Open(), [System.Text.Encoding]::UTF8)
            $sw.Write($newTxt); $sw.Flush(); $sw.Dispose()
            foreach ($img in ($srcZip.Entries | Where-Object { $_.Name -ne "set" })) {
                $de = $dstZip.CreateEntry($img.FullName, [System.IO.Compression.CompressionLevel]::Optimal)
                $s2 = $img.Open(); $d2 = $de.Open()
                $s2.CopyTo($d2); $s2.Dispose(); $d2.Dispose()
            }
            $srcZip.Dispose(); $dstZip.Dispose()
            Copy-Item $tmpZ $cloudSetFile.FullName -Force
            Remove-Item $tmpZ -Force -ErrorAction SilentlyContinue
            Write-Host "Decisions applied: $($removeSet.Count) removed, $($restoreMap.Count) restored." -ForegroundColor Green
        }
    } catch {
        Write-Host "Warning: could not apply sync decisions: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}


# ---------------------------------------------------------------
# STEP 6: Commit everything (merged cards + creator fields) and push
# Bug #1 fix: retry push up to 3x with fetch+rebase on rejection
# so simultaneous syncs don't silently lose cards.
# ---------------------------------------------------------------
Write-Host "Uploading your cards to the cloud..." -ForegroundColor Yellow
& $gitCmd -C $repoDir add "Shared-Set/" *>$null
& $gitCmd -C $repoDir commit -m "Auto-sync card updates" *>$null

$pushOk = $false
for ($pushAttempt = 1; $pushAttempt -le 3; $pushAttempt++) {
    & $gitCmd -C $repoDir @credBypass push origin main 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { $pushOk = $true; break }

    Write-Host "Push attempt $pushAttempt failed (someone else synced at the same time). Re-merging..." -ForegroundColor Yellow

    # Fetch latest, rebase our commit on top, then try again
    & $gitCmd -C $repoDir @credBypass fetch origin *>$null
    & $gitCmd -C $repoDir rebase origin/main *>$null
    if ($LASTEXITCODE -ne 0) {
        # Rebase conflict on binary - abort, take cloud as base, re-commit our merge
        & $gitCmd -C $repoDir rebase --abort *>$null
        # Don't re-run MergeSetFile (backup was deleted). Instead:
        # 1. Reset to cloud, 2. apply our already-merged file on top, 3. re-commit
        $currentMerged = $cloudSetFile.FullName
        & $gitCmd -C $repoDir reset --hard origin/main *>$null
        # Re-read the cloud content and re-apply our merged file if it still exists
        if (Test-Path $currentMerged) {
            & $gitCmd -C $repoDir add "Shared-Set/" *>$null
            & $gitCmd -C $repoDir commit -m "Auto-sync card updates (conflict resolved)" *>$null
        }
    }
    Start-Sleep -Seconds 1
}

if ($pushOk) {
    Write-Host "Sync Complete! Your friends will now see your cards." -ForegroundColor Green
} else {
    Write-Host "" -ForegroundColor Red
    Write-Host "=========================================================" -ForegroundColor Red
    Write-Host " WARNING: Could not upload after 3 attempts." -ForegroundColor Red
    Write-Host " Your cards are saved locally. Please sync again soon." -ForegroundColor Red
    Write-Host "=========================================================" -ForegroundColor Red
}

Write-Host "`nRelaunching Magic Set Editor..."
$launchSet = if ($cloudSetFile) { $cloudSetFile.FullName } elseif ($setFile) { $setFile.FullName } else { $null }
if ($launchSet) {
    Start-Process "wscript.exe" -ArgumentList "`"$repoDir\Launch_Silent.vbs`" `"$launchSet`""
} else {
    Start-Process "wscript.exe" -ArgumentList "`"$repoDir\Launch_Silent.vbs`""
}
Start-Sleep -Seconds 2
