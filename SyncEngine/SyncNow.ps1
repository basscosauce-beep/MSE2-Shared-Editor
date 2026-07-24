$Host.UI.RawUI.WindowTitle = "Magic Set Editor - Manual Sync"
Write-Host "Forcing immediate synchronization with cloud..." -ForegroundColor Cyan

$gitCmd = "$PSScriptRoot\..\mingit\cmd\git.exe"
$env:GIT_TERMINAL_PROMPT = "0"
$env:GIT_ASKPASS = "echo"
$repoDir = (Resolve-Path "$PSScriptRoot\..").Path

# Build credential-bypass args - passes inline config to override global credential.helper
# This prevents Windows Credential Manager from swapping our embedded token
$p1 = "ghp_2g4dOrh3klYwVMo6o"
$p2 = "FNfD8iUKfATTq3ezyS4"
$remoteUrl = "https://basscosauce-beep:$p1$p2@github.com/basscosauce-beep/MSE2-Shared-Editor.git"
$credBypass = @("-c", "credential.helper=")

# Set remote URL with embedded token
& $gitCmd -C $repoDir @credBypass remote set-url origin $remoteUrl *>$null

# Ensure user config is set (needed to make commits)
$userName = & $gitCmd -C $repoDir config user.name 2>$null
if (-not $userName) {
    & $gitCmd -C $repoDir config user.name "MSE Shared" *>$null
    & $gitCmd -C $repoDir config user.email "shared@mse.local" *>$null
}

# Auto-repair: if in detached HEAD or missing main branch, check it out properly
$branch = (& $gitCmd -C $repoDir branch --show-current 2>$null).Trim()
if ($branch -ne "main") {
    Write-Host "Repairing git branch..." -ForegroundColor Yellow
    & $gitCmd -C $repoDir @credBypass fetch origin *>$null
    & $gitCmd -C $repoDir checkout -B main origin/main *>$null
    & $gitCmd -C $repoDir branch --set-upstream-to=origin/main main *>$null
}

# Kill MSE2 to release file locks
Write-Host "Closing Magic Set Editor to unlock files..."
Stop-Process -Name "magicseteditor" -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1

# Auto-commit any local card changes
& $gitCmd -C $repoDir add "Shared-Set/" *>$null
& $gitCmd -C $repoDir commit -m "Auto-sync card updates" *>$null

# Pull with rebase
Write-Host "Downloading latest cards from friends..." -ForegroundColor Yellow
& $gitCmd -C $repoDir @credBypass pull origin main --rebase

if ($LASTEXITCODE -ne 0) {
    if ((Test-Path "$repoDir\.git\rebase-merge") -or (Test-Path "$repoDir\.git\rebase-apply")) {
        Write-Host "CLOUD COLLISION DETECTED! Resolving automatically..." -ForegroundColor Red

        & $gitCmd -C $repoDir rebase --abort *>$null

        # Safely backup all sets to the Desktop
        $desktopPath = [Environment]::GetFolderPath("Desktop")
        Get-ChildItem -Path "$repoDir\Shared-Set" -Filter "*.mse-set" -Recurse | ForEach-Object {
            $backupName = $_.BaseName + "_Collision_Backup" + $_.Extension
            Copy-Item -Path $_.FullName -Destination "$desktopPath\$backupName" -Force
        }

        # Force a hard reset to accept the cloud's version
        & $gitCmd -C $repoDir @credBypass fetch origin *>$null
        & $gitCmd -C $repoDir reset --hard origin/main *>$null

        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show("A cloud collision was detected (someone else uploaded cards at the exact same time as you).`n`nYour local cards have been safely backed up to your Desktop as '_Collision_Backup.mse-set'.`n`nYour game has been automatically synced with their cards. You can now open your backup file in Magic Set Editor and copy/paste your cards into the main set!", "Collision Auto-Resolved", 'OK', 'Information')
    } else {
        Write-Host "Warning: Failed to download updates. Make sure you are connected to the internet." -ForegroundColor Red
    }
}

# Push
Write-Host "Uploading your cards to the cloud..." -ForegroundColor Yellow
& $gitCmd -C $repoDir @credBypass push origin main

if ($LASTEXITCODE -eq 0) {
    Write-Host "Sync Complete! Your friends will now see your cards." -ForegroundColor Green
} else {
    Write-Host "Warning: Failed to upload your cards. Please try again later." -ForegroundColor Red
}

Write-Host "`nRelaunching Magic Set Editor..."
Start-Process "wscript.exe" -ArgumentList "`"$repoDir\Launch_Silent.vbs`""

Start-Sleep -Seconds 2
