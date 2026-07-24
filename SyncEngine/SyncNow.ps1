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

# ---- CRITICAL: Check if repo has any commits at all ----
$hasCommits = (& $gitCmd -C $repoDir log --oneline -1 2>$null).Trim()
if (-not $hasCommits) {
    Write-Host "First-time setup detected - downloading game files..." -ForegroundColor Yellow
    Write-Host "(This may take a moment)" -ForegroundColor Yellow
    & $gitCmd -C $repoDir @credBypass fetch origin *>$null
    # Force checkout overwrites all local untracked files with cloud versions
    & $gitCmd -C $repoDir checkout -B main origin/main -f *>$null
    & $gitCmd -C $repoDir branch --set-upstream-to=origin/main main *>$null
    Write-Host "Setup complete! Now syncing your cards..." -ForegroundColor Green
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
Start-Sleep -Seconds 1

# Stash local card changes so we can pull cleanly
& $gitCmd -C $repoDir add "Shared-Set/" *>$null
$hasChanges = (& $gitCmd -C $repoDir diff --cached --name-only "Shared-Set/" 2>$null).Trim()
$stashed = $false
if ($hasChanges) {
    Write-Host "Saving your local cards..." -ForegroundColor Yellow
    & $gitCmd -C $repoDir stash push -m "mse-sync-stash" *>$null
    $stashed = ($LASTEXITCODE -eq 0)
}

# Pull latest from cloud FIRST
Write-Host "Downloading latest cards from friends..." -ForegroundColor Yellow
& $gitCmd -C $repoDir @credBypass pull origin main --ff-only *>$null
if ($LASTEXITCODE -ne 0) {
    & $gitCmd -C $repoDir @credBypass fetch origin *>$null
    & $gitCmd -C $repoDir reset --hard origin/main *>$null
}

# Re-apply local card changes on top
if ($stashed) {
    Write-Host "Restoring your local cards..." -ForegroundColor Yellow
    & $gitCmd -C $repoDir stash pop *>$null
    if ($LASTEXITCODE -ne 0) {
        $desktopPath = [Environment]::GetFolderPath("Desktop")
        Get-ChildItem -Path "$repoDir\Shared-Set" -Filter "*.mse-set" -Recurse | ForEach-Object {
            Copy-Item -Path $_.FullName -Destination "$desktopPath\$($_.BaseName)_Collision_Backup$($_.Extension)" -Force
        }
        & $gitCmd -C $repoDir checkout -- "Shared-Set/" *>$null
        & $gitCmd -C $repoDir stash drop *>$null
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show("Collision detected! Your cards were backed up to Desktop.", "Collision Resolved", 'OK', 'Warning')
    }
}

# Commit and push
Write-Host "Uploading your cards to the cloud..." -ForegroundColor Yellow
& $gitCmd -C $repoDir add "Shared-Set/" *>$null
& $gitCmd -C $repoDir commit -m "Auto-sync card updates" *>$null

& $gitCmd -C $repoDir @credBypass push origin main

if ($LASTEXITCODE -eq 0) {
    Write-Host "Sync Complete! Your friends will now see your cards." -ForegroundColor Green
} else {
    Write-Host "Warning: Failed to upload your cards. Please try again later." -ForegroundColor Red
}

Write-Host "`nRelaunching Magic Set Editor..."
Start-Process "wscript.exe" -ArgumentList "`"$repoDir\Launch_Silent.vbs`""
Start-Sleep -Seconds 2
