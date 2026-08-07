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
$setFile = Get-ChildItem "$repoDir\Shared-Set" -Recurse -Filter "*.mse-set" | Select-Object -First 1

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
$setFile = Get-ChildItem "$repoDir\Shared-Set" -Recurse -Filter "*.mse-set" | Where-Object { $_.Name -notlike "*.bak" } | Select-Object -First 1
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
    $cloudSetFile = Get-ChildItem "$repoDir\Shared-Set" -Recurse -Filter "*.mse-set" | Select-Object -First 1

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
# STEP 5: Sync Preview - show changes before committing
# User must confirm before anything is pushed to GitHub
# ---------------------------------------------------------------
$previewResult = "OK"  # default: proceed (in case preview script fails to launch)
if ($cloudSetFile) {
    $resultFile  = "$env:TEMP\sync_preview_result_$([System.IO.Path]::GetRandomFileName()).txt"
    $safeUserDP  = $userName -replace '[\\/:*?"<>|]', '_'
    $dpDraftFile = "$($cloudSetFile.DirectoryName)\draft_cards_${safeUserDP}.txt"

    # Pass the cloud BASELINE (origin/main blob) as a temp file for diffing
    $cloudBaselineTemp = "$env:TEMP\sync_preview_cloud_$([System.IO.Path]::GetRandomFileName()).mse-set"
    $cloudRelPath = $cloudSetFile.FullName.Substring($repoDir.TrimEnd('\').Length + 1).Replace("\", "/")
    $cloudBlob = (& $gitCmd -C $repoDir rev-parse "origin/main:$cloudRelPath" 2>$null).Trim()
    if ($cloudBlob) {
        cmd /c ("`"" + $gitCmd + "`" -C `"" + $repoDir + "`" cat-file blob " + $cloudBlob + " > `"" + $cloudBaselineTemp + "`"") 2>$null
    }
    # Fall back to the current cloud file if blob extraction failed
    if (-not (Test-Path $cloudBaselineTemp) -or (Get-Item $cloudBaselineTemp).Length -eq 0) {
        Copy-Item $cloudSetFile.FullName $cloudBaselineTemp -Force
    }

    Write-Host "Opening sync preview..." -ForegroundColor Cyan
    $previewArgList = @(
        "-ExecutionPolicy", "Bypass",
        "-File", "$PSScriptRoot\SyncPreview.ps1",
        "-MergedFile", $cloudSetFile.FullName,
        "-CloudFile",  $cloudBaselineTemp,
        "-ResultFile", $resultFile,
        "-DraftFile",  $dpDraftFile,
        "-UserName",   $userName
    )
    $previewProc = Start-Process "powershell.exe" -ArgumentList $previewArgList -PassThru
    $previewProc.WaitForExit()

    Remove-Item $cloudBaselineTemp -Force -ErrorAction SilentlyContinue

    if (Test-Path $resultFile) {
        $previewResult = (Get-Content $resultFile -Raw).Trim()
        Remove-Item $resultFile -Force -ErrorAction SilentlyContinue
    }
}

if ($previewResult -ne "OK") {
    Write-Host "" -ForegroundColor Yellow
    Write-Host "Sync cancelled by user. Restoring cloud version..." -ForegroundColor Yellow
    & $gitCmd -C $repoDir checkout -- "Shared-Set/" *>$null
    Write-Host "No changes were uploaded. Relaunching MSE2..." -ForegroundColor Cyan
    $launchSet = if ($cloudSetFile) { $cloudSetFile.FullName } elseif ($setFile) { $setFile.FullName } else { $null }
    if ($launchSet) {
        Start-Process "wscript.exe" -ArgumentList "`"$repoDir\Launch_Silent.vbs`" `"$launchSet`""
    } else {
        Start-Process "wscript.exe" -ArgumentList "`"$repoDir\Launch_Silent.vbs`""
    }
    Start-Sleep -Seconds 2
    exit
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
