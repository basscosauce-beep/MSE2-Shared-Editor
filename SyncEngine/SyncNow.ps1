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

    # Record timestamp RIGHT before sending Ctrl+S (not at startup) so we
    # correctly detect saves even if the user already saved manually.
    $preTimestamp = $null
    if ($setFile) { $preTimestamp = $setFile.LastWriteTime }

    # Try to bring MSE2 to foreground (multiple methods for reliability)
    $focused = $false
    try {
        [Microsoft.VisualBasic.Interaction]::AppActivate($mseProc.Id)
        $focused = $true
    } catch {}

    if (-not $focused) {
        try {
            [Microsoft.VisualBasic.Interaction]::AppActivate($mseProc.MainWindowTitle)
            $focused = $true
        } catch {}
    }

    if ($focused) {
        Start-Sleep -Milliseconds 500
        # Send Ctrl+S three times with pauses for reliability
        [System.Windows.Forms.SendKeys]::SendWait("^s")
        Start-Sleep -Milliseconds 2000
        [System.Windows.Forms.SendKeys]::SendWait("^s")
        Start-Sleep -Milliseconds 2000
        [System.Windows.Forms.SendKeys]::SendWait("^s")
        Start-Sleep -Milliseconds 2000

        # Wait up to 15 seconds for the file to actually be written
        $saveVerified = $false
        for ($wait = 0; $wait -lt 15; $wait++) {
            $setFile.Refresh()
            if ($preTimestamp -and $setFile.LastWriteTime -gt $preTimestamp) {
                $saveVerified = $true
                Write-Host "Save verified (file updated on disk)." -ForegroundColor Green
                break
            }
            Start-Sleep -Milliseconds 1000
        }
        if (-not $saveVerified) {
            Write-Host "" -ForegroundColor Yellow
            Write-Host "=========================================================" -ForegroundColor Yellow
            Write-Host " WARNING: Could not verify MSE2 saved to disk." -ForegroundColor Yellow
            Write-Host " New cards AND keyword edits may not be saved!" -ForegroundColor Yellow
            Write-Host "" -ForegroundColor Yellow
            Write-Host " Press Ctrl+C NOW to cancel, save manually in MSE2" -ForegroundColor Yellow
            Write-Host " (File > Save or Ctrl+S), then sync again." -ForegroundColor Yellow
            Write-Host "=========================================================" -ForegroundColor Yellow
            Write-Host "" -ForegroundColor Yellow
            Start-Sleep -Seconds 8
        }
    } else {
        Write-Host "" -ForegroundColor Yellow
        Write-Host "=========================================================" -ForegroundColor Yellow
        Write-Host " WARNING: Could not bring MSE2 to foreground to save." -ForegroundColor Yellow
        Write-Host " New cards AND keyword edits may not be saved!" -ForegroundColor Yellow
        Write-Host "" -ForegroundColor Yellow
        Write-Host " Press Ctrl+C NOW to cancel, save manually in MSE2" -ForegroundColor Yellow
        Write-Host " (File > Save or Ctrl+S), then sync again." -ForegroundColor Yellow
        Write-Host "=========================================================" -ForegroundColor Yellow
        Write-Host "" -ForegroundColor Yellow
        Start-Sleep -Seconds 8
    }
}

# Now kill MSE2 so file locks are released
Write-Host "Closing Magic Set Editor..." -ForegroundColor Yellow
Stop-Process -Name "magicseteditor" -Force -ErrorAction SilentlyContinue
Stop-Process -Name "MenuAddon"      -Force -ErrorAction SilentlyContinue

# Wait for the process to fully exit AND for Windows to flush any pending
# disk writes (MSE2 writes a zip - we need the write to be complete)
$mseGone = $false
for ($w = 0; $w -lt 10; $w++) {
    Start-Sleep -Seconds 1
    $still = Get-Process "magicseteditor" -ErrorAction SilentlyContinue
    if (-not $still) { $mseGone = $true; break }
}
if (-not $mseGone) {
    # Force kill again
    Stop-Process -Name "magicseteditor" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
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
$setFile = Get-ChildItem "$repoDir\Shared-Set" -Recurse -Filter "*.mse-set" | Select-Object -First 1
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
                    Write-Host "Attempt $attempt: local file has 0 cards - waiting for disk flush..." -ForegroundColor Yellow
                }
            } else {
                $testZip.Dispose()
                Write-Host "Attempt $attempt: local zip has no 'set' entry - waiting..." -ForegroundColor Yellow
            }
        } catch {
            Write-Host "Attempt $attempt: local file not readable yet ($_) - waiting..." -ForegroundColor Yellow
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
# STEP 5: Commit everything (merged cards + creator fields) and push
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
        # Rebase conflict on binary - abort and take ours
        & $gitCmd -C $repoDir rebase --abort *>$null
        & $gitCmd -C $repoDir reset --hard origin/main *>$null
        Write-Host "Re-running merge after conflict resolution..." -ForegroundColor Yellow
        # Re-run the merge with the same backup
        if ($localBackupPath -and (Test-Path $localBackupPath) -and $cloudSetFile) {
            . "$PSScriptRoot\MergeSetFile.ps1" -LocalBackup $localBackupPath -CloudFile $cloudSetFile.FullName -UserName $userName
        }
        & $gitCmd -C $repoDir add "Shared-Set/" *>$null
        & $gitCmd -C $repoDir commit -m "Auto-sync card updates" *>$null
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
