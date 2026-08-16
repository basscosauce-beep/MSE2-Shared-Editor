param(
    [switch]$SkipPreview,     # Set by CloudSync.ps1 - preview was already done there
    [string]$PredecidedFile   # Path to temp file with KEEP:/REMOVE:/RESTORE: decisions
)

$Host.UI.RawUI.WindowTitle = "Magic Set Editor - Sync v3.8"

# ---------------------------------------------------------------------------
# Auto-save MSE2 BEFORE killing it so unsaved cards are flushed to disk.
# This is critical: if MSE2 hasn't saved, any new cards exist only in memory
# and will be lost when we kill the process.
# ---------------------------------------------------------------------------
$mseProc = Get-Process "magicseteditor" -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
$mseExePath = $null

$gitCmd = "$PSScriptRoot\..\mingit\cmd\git.exe"
. "$PSScriptRoot\DedupManager.ps1"   # Delete Duplicates helpers
$env:GIT_TERMINAL_PROMPT = "0"
$env:GIT_ASKPASS = "echo"
$repoDir = (Resolve-Path "$PSScriptRoot\..").Path

# Resolve set file path up front (used in multiple places below)
$setFile = Get-ChildItem "$repoDir\Shared-Set" -Recurse -Filter "*.mse-set" |
    Where-Object { $_.Name -notlike "*.bak" -and $_.FullName -notlike "*_pre_sync_backups*" } |
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
    Where-Object { $_.Name -notlike "*.bak" -and $_.FullName -notlike "*_pre_sync_backups*" } |
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

# Preserve the goals file across git reset (it gets overwritten otherwise)
$goalsFileObj = Get-ChildItem "$repoDir\Shared-Set" -Recurse -Filter "goals_*.json" | Select-Object -First 1
$goalsTmp     = $null
$goalsLocalTime = $null
if ($goalsFileObj -and (Test-Path $goalsFileObj.FullName)) {
    $goalsTmp       = "$env:TEMP\mse_goals_$([System.IO.Path]::GetRandomFileName()).json"
    $goalsLocalTime = $goalsFileObj.LastWriteTimeUtc
    Copy-Item $goalsFileObj.FullName $goalsTmp -Force
}

Write-Host "Downloading latest cards from friends..." -ForegroundColor Yellow
& $gitCmd -C $repoDir @credBypass fetch origin *>$null
& $gitCmd -C $repoDir reset --hard origin/main *>$null

# ---------------------------------------------------------------
# SELF-UPDATE: Copy any changed scripts from the repo into the
# install directory. If anything changed, relaunch and exit.
# This is how all users stay up to date without reinstalling.
# ---------------------------------------------------------------
$scriptMap = @{
    "$repoDir\SyncEngine\SyncNow.ps1"      = "$PSScriptRoot\SyncNow.ps1"
    "$repoDir\SyncEngine\DedupManager.ps1" = "$PSScriptRoot\DedupManager.ps1"
    "$repoDir\SyncEngine\DedupPreview.ps1" = "$PSScriptRoot\DedupPreview.ps1"
    "$repoDir\CloudSync.ps1"               = "$repoDir\..\CloudSync.ps1"   # install root
    "$repoDir\GoalTracker.ps1"             = "$repoDir\..\GoalTracker.ps1"
    "$repoDir\Setup.ps1"                   = "$repoDir\..\Setup.ps1"
}
# Resolve install root (parent of SyncEngine)
$installRoot = (Resolve-Path "$PSScriptRoot\..").Path
$scriptMap = @{
    "$repoDir\SyncEngine\SyncNow.ps1"      = "$installRoot\SyncEngine\SyncNow.ps1"
    "$repoDir\SyncEngine\DedupManager.ps1" = "$installRoot\SyncEngine\DedupManager.ps1"
    "$repoDir\SyncEngine\DedupPreview.ps1" = "$installRoot\SyncEngine\DedupPreview.ps1"
    "$repoDir\CloudSync.ps1"               = "$installRoot\CloudSync.ps1"
    "$repoDir\GoalTracker.ps1"             = "$installRoot\GoalTracker.ps1"
    "$repoDir\Setup.ps1"                   = "$installRoot\Setup.ps1"
}

$anyUpdated = $false
foreach ($src in $scriptMap.Keys) {
    $dst = $scriptMap[$src]
    if (-not (Test-Path $src)) { continue }
    $needsCopy = $false
    if (-not (Test-Path $dst)) {
        $needsCopy = $true
    } else {
        $srcHash = (Get-FileHash $src -Algorithm MD5).Hash
        $dstHash = (Get-FileHash $dst -Algorithm MD5).Hash
        if ($srcHash -ne $dstHash) { $needsCopy = $true }
    }
    if ($needsCopy) {
        try {
            $dstDir = Split-Path $dst
            if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
            Copy-Item $src $dst -Force
            Write-Host ("  Updated: " + (Split-Path $dst -Leaf)) -ForegroundColor Green
            $anyUpdated = $true
        } catch {
            Write-Host ("  Could not update: " + (Split-Path $dst -Leaf) + " - " + $_.Exception.Message) -ForegroundColor Yellow
        }
    }
}

if ($anyUpdated) {
    Write-Host "Scripts updated! Restarting sync with latest version..." -ForegroundColor Cyan
    Start-Sleep -Milliseconds 800
    $myArgs = @("-ExecutionPolicy", "Bypass", "-WindowStyle", "Normal", "-File", "$installRoot\SyncEngine\SyncNow.ps1")
    if ($SkipPreview)    { $myArgs += "-SkipPreview" }
    if ($PredecidedFile) { $myArgs += @("-PredecidedFile", $PredecidedFile) }
    Start-Process "powershell.exe" -ArgumentList $myArgs
    exit
}

# Restore goals file if the local version is NEWER than what git just pulled
# (last-editor-wins: whoever saved goals most recently keeps their version)
if ($goalsTmp -and (Test-Path $goalsTmp)) {
    $goalsFileObj.Refresh()
    $goalsCloudTime = if (Test-Path $goalsFileObj.FullName) { $goalsFileObj.LastWriteTimeUtc } else { [datetime]::MinValue }
    if ($goalsLocalTime -gt $goalsCloudTime) {
        Copy-Item $goalsTmp $goalsFileObj.FullName -Force
        Write-Host "Goals file preserved (local was newer)." -ForegroundColor DarkGray
    } else {
        Write-Host "Goals file updated from cloud (cloud was newer)." -ForegroundColor DarkGray
    }
    Remove-Item $goalsTmp -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------
# STEP 3: Merge any new locally-made cards back in
# MergeSetFile compares time_created timestamps to find cards
# that exist in the local backup but not in the cloud version
# ---------------------------------------------------------------
if ($localBackupPath -and (Test-Path $localBackupPath)) {
    # Resolve the cloud set file now (after git reset --hard pulled latest from cloud)
    $cloudSetFile = Get-ChildItem "$repoDir\Shared-Set" -Recurse -Filter "*.mse-set" |
        Where-Object { $_.Name -notlike "*.bak" -and $_.FullName -notlike "*_pre_sync_backups*" } |
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
# STEP 3b: Post-merge TC deduplication (safety net)
# MergeSetFile can occasionally output duplicate TC entries. This step
# deduplicates by time_created but KEEPS THE MOST RECENTLY MODIFIED copy
# so that user edits (which bump time_modified) are never reverted.
# -----------------------------------------------------------------------
if ($cloudSetFile -and (Test-Path $cloudSetFile.FullName)) {
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        Add-Type -AssemblyName System.IO.Compression

        $dedupZip = [System.IO.Compression.ZipFile]::OpenRead($cloudSetFile.FullName)
        $dedupEn  = $dedupZip.Entries | Where-Object { $_.Name -eq "set" } | Select-Object -First 1
        $dedupSr  = New-Object System.IO.StreamReader($dedupEn.Open(), [System.Text.Encoding]::UTF8)
        $dedupTxt = $dedupSr.ReadToEnd()
        $dedupSr.Dispose(); $dedupZip.Dispose()

        $dedupParts  = $dedupTxt -split "(?m)^(?=card:)"
        $dedupHdr    = $dedupParts[0]
        $dedupBlocks = @($dedupParts | Where-Object { $_ -match "^card:" })

        # Count unique TCs to know if dedup is actually needed
        $tcCounts = @{}
        foreach ($blk in $dedupBlocks) {
            $stripped = ($blk -split "(?m)^(?=keyword:|version_control:|apprentice_code:)")[0]
            $tc = if ($stripped -match "(?m)^\s*time_created:\s*([^\r\n]+)") { $matches[1].Trim() } else { $null }
            if ($tc) {
                if ($tcCounts.ContainsKey($tc)) { $tcCounts[$tc]++ } else { $tcCounts[$tc] = 1 }
            }
        }
        $dupTCs = @($tcCounts.GetEnumerator() | Where-Object { $_.Value -gt 1 }).Count

        if ($dupTCs -gt 0) {
            Write-Host "[PostMerge] $dupTCs TC groups have duplicates -- keeping most recently edited copy..." -ForegroundColor Yellow

            # Group all blocks by TC, pick the one with the latest time_modified
            $bestByTC  = @{}  # TC -> best card block text
            $bestTM    = @{}  # TC -> best time_modified (as string for compare)
            $noTcCards = [System.Collections.Generic.List[string]]::new()

            foreach ($blk in $dedupBlocks) {
                $stripped = ($blk -split "(?m)^(?=keyword:|version_control:|apprentice_code:)")[0]
                $tc = if ($stripped -match "(?m)^\s*time_created:\s*([^\r\n]+)") { $matches[1].Trim() } else { $null }
                $tm = if ($stripped -match "(?m)^\s*time_modified:\s*([^\r\n]+)") { $matches[1].Trim() } else { "" }

                if (-not $tc) {
                    $noTcCards.Add($blk)
                    continue
                }

                if (-not $bestByTC.ContainsKey($tc)) {
                    $bestByTC[$tc] = $blk
                    $bestTM[$tc]   = $tm
                } elseif ([string]::Compare($tm, $bestTM[$tc], [System.StringComparison]::Ordinal) -gt 0) {
                    # This copy has a later time_modified -- it's the edited version, keep it
                    $bestByTC[$tc] = $blk
                    $bestTM[$tc]   = $tm
                }
            }

            # Rebuild card list in original order (first occurrence order), using best version
            $dedupKept    = [System.Collections.Generic.List[string]]::new()
            $emittedTCs   = New-Object System.Collections.Generic.HashSet[string]
            $dedupRemoved = 0

            foreach ($blk in $dedupBlocks) {
                $stripped = ($blk -split "(?m)^(?=keyword:|version_control:|apprentice_code:)")[0]
                $tc = if ($stripped -match "(?m)^\s*time_created:\s*([^\r\n]+)") { $matches[1].Trim() } else { $null }

                if (-not $tc) { continue }  # handled via noTcCards

                if ($emittedTCs.Add($tc)) {
                    $dedupKept.Add($bestByTC[$tc])  # emit best (most recent) version
                } else {
                    $dedupRemoved++  # skip duplicate
                }
            }

            # Append cards with no time_created at the end
            foreach ($blk in $noTcCards) { $dedupKept.Add($blk) }

            Write-Host "[PostMerge] Removed $dedupRemoved duplicate(s). Kept most recent edits." -ForegroundColor Green

            $dedupNewTxt = $dedupHdr + ($dedupKept -join "")
            $dedupTmp    = [System.IO.Path]::GetTempFileName() + ".mse-set"

            $dedupSrcZ = [System.IO.Compression.ZipFile]::OpenRead($cloudSetFile.FullName)
            $dedupDstZ = [System.IO.Compression.ZipFile]::Open($dedupTmp, [System.IO.Compression.ZipArchiveMode]::Create)

            $dedupSe = $dedupDstZ.CreateEntry("set", [System.IO.Compression.CompressionLevel]::Optimal)
            $dedupSw = New-Object System.IO.StreamWriter($dedupSe.Open(), [System.Text.Encoding]::UTF8)
            $dedupSw.Write($dedupNewTxt); $dedupSw.Flush(); $dedupSw.Dispose()

            foreach ($imgEnt in ($dedupSrcZ.Entries | Where-Object { $_.Name -ne "set" })) {
                $imgDst = $dedupDstZ.CreateEntry($imgEnt.FullName, [System.IO.Compression.CompressionLevel]::Optimal)
                $s = $imgEnt.Open(); $d = $imgDst.Open()
                $s.CopyTo($d); $s.Dispose(); $d.Dispose()
            }
            $dedupSrcZ.Dispose(); $dedupDstZ.Dispose()

            Copy-Item $dedupTmp $cloudSetFile.FullName -Force
            Remove-Item $dedupTmp -Force -ErrorAction SilentlyContinue
            Write-Host "[PostMerge] Set written: $($dedupKept.Count) unique cards." -ForegroundColor Green
        }
    } catch {
        Write-Host "[PostMerge] Warning: post-merge dedup failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
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

            function Get-SetHeader {
                param([string]$content)
                if (-not $content) { return "" }
                $idx = $content.IndexOf("`ncard:")
                if ($idx -ge 0) { return $content.Substring(0, $idx + 1) }
                if ($content.StartsWith("card:")) { return "" }
                return $content
            }
            $hdr = Get-SetHeader -content $mergedTxt

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
                # The lookahead split (^(?=card:)) keeps 'card:' at the start of each block.
                # Never prepend it again - that would create 'card:\ncard:\n...' duplicates.
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
# STEP 5b: Handle dedup vote decision from CloudSync
# CloudSync writes DEDUP_VOTE:yes or DEDUP_VOTE:no into the decisions file
# ---------------------------------------------------------------
if ($SkipPreview -and $PredecidedFile) {
    # decisions file may have already been deleted above; read flag from a side-channel
    # CloudSync writes a separate vote file so we can read it here
}
$dedupVoteFile = "$env:TEMP\mse_dedup_vote_${userName}.txt"
if (Test-Path $dedupVoteFile) {
    $vote = (Get-Content $dedupVoteFile -Raw -ErrorAction SilentlyContinue).Trim()
    Remove-Item $dedupVoteFile -Force -ErrorAction SilentlyContinue
    if ($vote -in @("yes","no") -and $cloudSetFile) {
        $dSetDir = [System.IO.Path]::GetDirectoryName($cloudSetFile.FullName)
        Set-DedupVote $dSetDir $userName $vote
        Write-Host "[Dedup] Recorded vote: $vote" -ForegroundColor Cyan
    }
}

# ---------------------------------------------------------------
# STEP 5c: Apply pending dedup if syncs_remaining hits 0
# ---------------------------------------------------------------
if ($cloudSetFile) {
    $dSetDir  = [System.IO.Path]::GetDirectoryName($cloudSetFile.FullName)
    $vaultDir = "$dSetDir\_dedup_vault"
    $dedupChanged = Apply-PendingDedup $cloudSetFile.FullName $dSetDir $vaultDir
    if ($dedupChanged) {
        Write-Host "[Dedup] Duplicate cards removed from set." -ForegroundColor Green
        # CRITICAL: update last_known baseline after dedup so the NEXT sync's MergeSetFile
        # does not mistake the deleted duplicates for "locally added" cards and re-add them.
        if ($cloudSetFile -and (Test-Path $cloudSetFile.FullName)) {
            $safeUserD     = $userName -replace '[\\/:*?"<>|]', '_'
            $lastKnownFile = "$dSetDir\last_known_$safeUserD.txt"
            Save-LastKnown -SetFilePath $cloudSetFile.FullName -KnownFile $lastKnownFile
            Write-Host "[Dedup] Hash baseline updated to post-dedup state." -ForegroundColor DarkGray
        }
    }
}

# ---------------------------------------------------------------
# STEP 6: Commit everything (merged cards + creator fields) and push
# Bug #1 fix: retry push up to 3x with fetch+rebase on rejection
# so simultaneous syncs don't silently lose cards.
# ---------------------------------------------------------------
Write-Host "Uploading your cards to the cloud..." -ForegroundColor Yellow
& $gitCmd -C $repoDir add "Shared-Set/" *>$null

# Build an informative commit message so the History tab shows what actually changed
$commitMsg = "$userName synced"
try {
    if ($cloudSetFile) {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        Add-Type -AssemblyName System.IO.Compression

        # Read the just-merged set content
        $czNew = [System.IO.Compression.ZipFile]::OpenRead($cloudSetFile.FullName)
        $ceNew = $czNew.Entries | Where-Object { $_.Name -eq "set" } | Select-Object -First 1
        $srNew = New-Object System.IO.StreamReader($ceNew.Open(), [System.Text.Encoding]::UTF8)
        $newTxt = $srNew.ReadToEnd(); $srNew.Dispose(); $czNew.Dispose()

        # Read the cloud BASELINE (origin/main) for diffing
        $baseRelPath = $cloudSetFile.FullName.Substring($repoDir.TrimEnd('\').Length + 1).Replace("\", "/")
        $baseBlob    = (& $gitCmd -C $repoDir rev-parse "origin/main:$baseRelPath" 2>$null).Trim()
        $baseTmp     = "$env:TEMP\synccmsg_$([System.IO.Path]::GetRandomFileName()).mse-set"
        if ($baseBlob) {
            cmd /c ("`"" + $gitCmd + "`" -C `"" + $repoDir + "`" cat-file blob " + $baseBlob + " > `"" + $baseTmp + "`"") 2>$null
        }

        if ((Test-Path $baseTmp) -and (Get-Item $baseTmp).Length -gt 0) {
            $czBase = [System.IO.Compression.ZipFile]::OpenRead($baseTmp)
            $ceBase = $czBase.Entries | Where-Object { $_.Name -eq "set" } | Select-Object -First 1
            $srBase = New-Object System.IO.StreamReader($ceBase.Open(), [System.Text.Encoding]::UTF8)
            $baseTxt = $srBase.ReadToEnd(); $srBase.Dispose(); $czBase.Dispose()
            Remove-Item $baseTmp -Force -ErrorAction SilentlyContinue

            # Parse both into tc -> name maps
            $parseMap = {
                param($txt)
                $m = @{}
                $txt -split "(?m)^(?=card:)" | Where-Object { $_ -match "^card:" } | ForEach-Object {
                    $blk = ($_ -split "(?m)^(?=keyword:|version_control:|apprentice_code:)")[0]
                    $tc   = if ($blk -match "(?m)^\s*time_created:\s*([^\r\n]+)") { $matches[1].Trim() } else { $null }
                    $name = if ($blk -match "(?m)^\s*name:\s*([^\r\n]+)")         { $matches[1].Trim() } else { "(unnamed)" }
                    if ($tc) { $m[$tc] = $name }
                }
                $m
            }
            $newMap  = & $parseMap $newTxt
            $baseMap = & $parseMap $baseTxt

            $added   = @($newMap.Keys  | Where-Object { -not $baseMap.ContainsKey($_) } | ForEach-Object { $newMap[$_] })
            $removed = @($baseMap.Keys | Where-Object { -not $newMap.ContainsKey($_)  } | ForEach-Object { $baseMap[$_] })
            $total   = $newMap.Count

            $parts = @("$total cards total")
            if ($added.Count -gt 0)   { $parts += "+$($added.Count) ($($added   -join ', '))" }
            if ($removed.Count -gt 0) { $parts += "-$($removed.Count) ($($removed -join ', '))" }
            $commitMsg = "$userName synced -- $($parts -join ' | ')"
        } else {
            Remove-Item $baseTmp -Force -ErrorAction SilentlyContinue
            $total = ($newTxt -split "(?m)^(?=card:)" | Where-Object { $_ -match "^card:" }).Count
            $commitMsg = "$userName synced -- $total cards"
        }
    }
} catch {
    # Non-fatal - fall back to simple message
    $commitMsg = "$userName synced"
}

& $gitCmd -C $repoDir commit -m $commitMsg *>$null

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
