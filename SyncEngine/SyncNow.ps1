$Host.UI.RawUI.WindowTitle = "Magic Set Editor - Manual Sync"
Write-Host "Forcing immediate synchronization with cloud..." -ForegroundColor Cyan

$gitCmd = "$PSScriptRoot\..\mingit\cmd\git.exe"
$env:GIT_TERMINAL_PROMPT = "0"
$env:GIT_ASKPASS = "echo"
$repoDir = (Resolve-Path "$PSScriptRoot\..").Path

# Inline credential bypass - prevents Windows Credential Manager override
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
}

# CRITICAL: Check if repo has any commits at all (first-time setup)
$hasCommits = (& $gitCmd -C $repoDir log --oneline -1 2>$null).Trim()
if (-not $hasCommits) {
    Write-Host "First-time setup detected - downloading game files..." -ForegroundColor Yellow
    & $gitCmd -C $repoDir @credBypass fetch origin *>$null
    & $gitCmd -C $repoDir checkout -B main origin/main -f *>$null
    & $gitCmd -C $repoDir branch --set-upstream-to=origin/main main *>$null
    Write-Host "Setup complete!" -ForegroundColor Green
}

# Auto-repair: if on wrong branch, switch to main
$branch = (& $gitCmd -C $repoDir branch --show-current 2>$null).Trim()
if ($branch -ne "main") {
    Write-Host "Repairing git branch..." -ForegroundColor Yellow
    & $gitCmd -C $repoDir @credBypass fetch origin *>$null
    & $gitCmd -C $repoDir checkout -B main origin/main -f *>$null
    & $gitCmd -C $repoDir branch --set-upstream-to=origin/main main *>$null
}

# Kill MSE2 to release file locks
Write-Host "Closing Magic Set Editor to unlock files..."
Stop-Process -Name "magicseteditor" -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

# STEP 1: Back up the local set file BEFORE pulling
# (We can't use git stash on binary files - it causes merge conflicts on pop)
$setFile = Get-ChildItem "$repoDir\Shared-Set" -Recurse -Filter "*.mse-set" | Select-Object -First 1
$localBackupPath = "$env:TEMP\mse_local_backup_$([System.IO.Path]::GetRandomFileName()).mse-set"
if ($setFile) {
    Copy-Item $setFile.FullName $localBackupPath -Force
}

# STEP 2: Pull latest from cloud (overwrites local set file with cloud version)
Write-Host "Downloading latest cards from friends..." -ForegroundColor Yellow
& $gitCmd -C $repoDir @credBypass pull origin main --ff-only *>$null
if ($LASTEXITCODE -ne 0) {
    & $gitCmd -C $repoDir @credBypass fetch origin *>$null
    & $gitCmd -C $repoDir reset --hard origin/main *>$null
}

# STEP 3: Merge any new local cards back in (cards not yet on cloud)
if ($localBackupPath -and (Test-Path $localBackupPath) -and $setFile) {
    $cloudSetFile = Get-ChildItem "$repoDir\Shared-Set" -Recurse -Filter "*.mse-set" | Select-Object -First 1
    . "$PSScriptRoot\MergeSetFile.ps1" -LocalBackup $localBackupPath -CloudFile $cloudSetFile.FullName
    Remove-Item $localBackupPath -Force -ErrorAction SilentlyContinue
}

# STEP 4: Auto-fill the "By" column for any cards missing a creator
. "$PSScriptRoot\FillCreators.ps1" -RepoDir $repoDir -GitCmd $gitCmd -CredBypass $credBypass

# STEP 5: Commit and push everything (new cards + creator fields)
Write-Host "Uploading your cards to the cloud..." -ForegroundColor Yellow
& $gitCmd -C $repoDir add "Shared-Set/" *>$null
& $gitCmd -C $repoDir commit -m "Auto-sync card updates" *>$null

& $gitCmd -C $repoDir @credBypass push origin main

if ($LASTEXITCODE -eq 0) {
    Write-Host "Sync Complete! Your friends will now see your cards." -ForegroundColor Green
} else {
    Write-Host "Warning: Failed to upload. Please try again." -ForegroundColor Red
}

Write-Host "`nRelaunching Magic Set Editor..."
Start-Process "wscript.exe" -ArgumentList "`"$repoDir\Launch_Silent.vbs`""
Start-Sleep -Seconds 2
