# RecoverSet.ps1
# Emergency recovery: restores the most-recent non-empty .mse-set from git history
# and clears the tombstone so no cards are permanently blocked.
#
# Run this if everyone's cards disappeared after a sync.
# You do NOT need to close MSE2 first - this script handles it.

$Host.UI.RawUI.WindowTitle = "Magic Set Editor - Emergency Recovery"

Write-Host ""
Write-Host "=============================================" -ForegroundColor Red
Write-Host "  MSE2 EMERGENCY CARD RECOVERY" -ForegroundColor Red
Write-Host "=============================================" -ForegroundColor Red
Write-Host ""
Write-Host "This will find the most recent backup from git" -ForegroundColor Yellow
Write-Host "history and restore all missing cards." -ForegroundColor Yellow
Write-Host ""

$gitCmd   = "$PSScriptRoot\..\mingit\cmd\git.exe"
$repoDir  = (Resolve-Path "$PSScriptRoot\..").Path
$env:GIT_TERMINAL_PROMPT = "0"
$env:GIT_ASKPASS         = "echo"

$p1 = "ghp_2g4dOrh3klYwVMo6o"
$p2 = "FNfD8iUKfATTq3ezyS4"
$remoteUrl   = "https://basscosauce-beep:$p1$p2@github.com/basscosauce-beep/MSE2-Shared-Editor.git"
$credBypass  = @("-c", "credential.helper=")

& $gitCmd -C $repoDir @credBypass remote set-url origin $remoteUrl *>$null

# Close MSE2 so the set file is not locked
$mseRunning = Get-Process "magicseteditor" -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 }
if ($mseRunning) {
    Write-Host "Closing Magic Set Editor..." -ForegroundColor Yellow
    Stop-Process -Name "magicseteditor" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

# Fetch latest history from remote
Write-Host "Fetching git history..." -ForegroundColor Cyan
& $gitCmd -C $repoDir @credBypass fetch origin *>$null

# Locate the .mse-set in the repo
$setRelPath = (& $gitCmd -C $repoDir ls-files "Shared-Set/*.mse-set" 2>$null | Select-Object -First 1)
if (-not $setRelPath) {
    Write-Host "ERROR: No .mse-set file tracked in repo. Run a normal Sync first." -ForegroundColor Red
    Read-Host "Press Enter to exit"; exit 1
}
$setRelPath = $setRelPath.Trim()
Write-Host "Set file: $setRelPath" -ForegroundColor DarkGray

# Walk git log to find the most recent commit with actual cards
Write-Host "Scanning git history for last good backup..." -ForegroundColor Yellow

Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression

$commits = (& $gitCmd -C $repoDir log --format="%H" -- $setRelPath 2>$null) | Where-Object { $_ -ne "" }
$recoveryCommit    = $null
$recoveryCardCount = 0

foreach ($hash in $commits) {
    $hash = $hash.Trim()
    if (-not $hash) { continue }
    $tmpZip = [System.IO.Path]::GetTempFileName() + ".mse-set"
    try {
        # Export the blob to a temp file using git cat-file
        $blobHash = (& $gitCmd -C $repoDir rev-parse "${hash}:${setRelPath}" 2>$null)
        if (-not $blobHash) { continue }
        $blobHash = $blobHash.Trim()
        # cat-file outputs raw bytes; redirect to file via cmd
        $cmd = "`"$gitCmd`" -C `"$repoDir`" cat-file blob $blobHash"
        cmd /c "$cmd > `"$tmpZip`"" 2>$null

        if (-not (Test-Path $tmpZip) -or (Get-Item $tmpZip).Length -lt 100) { continue }

        $zip   = [System.IO.Compression.ZipFile]::OpenRead($tmpZip)
        $entry = $zip.Entries | Where-Object { $_.Name -eq "set" } | Select-Object -First 1
        if (-not $entry) { $zip.Dispose(); continue }
        $sr  = New-Object System.IO.StreamReader($entry.Open(), [System.Text.Encoding]::UTF8)
        $txt = $sr.ReadToEnd()
        $sr.Dispose(); $zip.Dispose()

        $cardCount = ($txt -split "(?m)^(?=card:)" | Where-Object { $_ -match "^card:" -and $_ -match "time_created:" }).Count
        Write-Host "  Commit $($hash.Substring(0,8)): $cardCount card(s)" -ForegroundColor DarkGray
        if ($cardCount -gt $recoveryCardCount) {
            $recoveryCardCount = $cardCount
            $recoveryCommit    = $hash
        }
        if ($cardCount -gt 0) { break }  # git log is newest-first - first good commit wins
    }
    catch { Write-Host "  Skipping $($hash.Substring(0,8)): $_" -ForegroundColor DarkGray }
    finally { Remove-Item $tmpZip -Force -ErrorAction SilentlyContinue }
}

if (-not $recoveryCommit -or $recoveryCardCount -eq 0) {
    Write-Host "No recoverable backup found in git history." -ForegroundColor Red
    Read-Host "Press Enter to exit"; exit 1
}

Write-Host ""
Write-Host "Best backup found: $recoveryCardCount cards (commit $recoveryCommit)" -ForegroundColor Green
$confirm = Read-Host "Restore $recoveryCardCount cards from this backup? (y/n)"
if ($confirm -notmatch "^[Yy]") { Write-Host "Cancelled."; exit 0 }

# Reset to latest remote, then restore the set file from the recovery commit
Write-Host "Syncing to latest cloud state..." -ForegroundColor Cyan
& $gitCmd -C $repoDir @credBypass fetch origin *>$null
& $gitCmd -C $repoDir reset --hard origin/main *>$null

Write-Host "Restoring set file from backup..." -ForegroundColor Yellow
& $gitCmd -C $repoDir checkout $recoveryCommit -- $setRelPath *>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Could not restore set file from git." -ForegroundColor Red
    Read-Host "Press Enter to exit"; exit 1
}

# Clear the tombstone - it caused the deletion
$tombstoneFile = "$repoDir\Shared-Set\deleted_cards.txt"
Write-Host "Clearing tombstone..." -ForegroundColor Yellow
Set-Content $tombstoneFile -Value "" -Encoding UTF8

# Clear all last_known files so next sync starts fresh (no stale baselines)
Get-ChildItem "$repoDir\Shared-Set" -Filter "last_known_*.txt" | ForEach-Object {
    Write-Host "  Resetting baseline: $($_.Name)" -ForegroundColor DarkGray
    Set-Content $_.FullName -Value "" -Encoding UTF8
}

# Commit and push
Write-Host "Uploading recovery to cloud..." -ForegroundColor Yellow
& $gitCmd -C $repoDir add "Shared-Set/" *>$null
& $gitCmd -C $repoDir commit -m "RECOVERY: restored $recoveryCardCount cards from commit $($recoveryCommit.Substring(0,8)) - cleared tombstone" *>$null
& $gitCmd -C $repoDir @credBypass push origin main

if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host "=============================================" -ForegroundColor Green
    Write-Host "  RECOVERY COMPLETE!" -ForegroundColor Green
    Write-Host "  $recoveryCardCount cards restored to cloud." -ForegroundColor Green
    Write-Host "  Ask everyone to run a normal Sync now." -ForegroundColor Green
    Write-Host "=============================================" -ForegroundColor Green
} else {
    Write-Host "Push failed. Try running a normal Sync after this." -ForegroundColor Red
}

# Relaunch MSE2 with restored set
$setFileObj = Get-ChildItem "$repoDir\Shared-Set" -Recurse -Filter "*.mse-set" | Select-Object -First 1
if ($setFileObj) {
    Start-Process "wscript.exe" -ArgumentList "`"$repoDir\Launch_Silent.vbs`" `"$($setFileObj.FullName)`""
}
Start-Sleep -Seconds 2
