$Host.UI.RawUI.WindowTitle = "Magic Set Editor - Manual Sync"
Write-Host "🔄 Forcing immediate synchronization with cloud..." -ForegroundColor Cyan

$gitCmd = "$PSScriptRoot\..\mingit\cmd\git.exe"
$env:GIT_TERMINAL_PROMPT = "0"
$repoDir = "$PSScriptRoot\.."

# Kill MSE2 to release file locks
Write-Host "Closing Magic Set Editor to unlock files..."
Stop-Process -Name "magicseteditor" -Force -ErrorAction SilentlyContinue

# Auto-commit any unsaved local changes first
& $gitCmd -C $repoDir add Shared-Set/
& $gitCmd -C $repoDir commit -m "Auto-sync card updates" *>$null

# Pull with rebase
Write-Host "Downloading latest cards from friends..." -ForegroundColor Yellow
& $gitCmd -C $repoDir pull origin main --rebase

if ($LASTEXITCODE -ne 0) {
    if ((Test-Path "$repoDir\.git\rebase-merge") -or (Test-Path "$repoDir\.git\rebase-apply")) {
        Write-Host "⚠️ CLOUD COLLISION DETECTED! Resolving automatically..." -ForegroundColor Red
        
        # Abort the frozen rebase to return to our pre-pull state
        & $gitCmd -C $repoDir rebase --abort *>$null
        
        # Safely backup all sets to the Desktop
        $desktopPath = [Environment]::GetFolderPath("Desktop")
        Get-ChildItem -Path "$repoDir\Shared-Set" -Filter "*.mse-set" -Recurse | ForEach-Object {
            $backupName = $_.BaseName + "_Collision_Backup" + $_.Extension
            Copy-Item -Path $_.FullName -Destination "$desktopPath\$backupName" -Force
        }
        
        # Force a hard reset to accept the cloud's version
        & $gitCmd -C $repoDir fetch origin *>$null
        & $gitCmd -C $repoDir reset --hard origin/main *>$null
        
        # Alert the user
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show("A cloud collision was detected (someone else uploaded cards at the exact same time as you).`n`nYour local cards have been safely backed up to your Desktop as '_Collision_Backup.mse-set'.`n`nYour game has been automatically synced with their cards. You can now open your backup file in Magic Set Editor and copy/paste your cards into the main set!", "Collision Auto-Resolved", 'OK', 'Information')
    } else {
        Write-Host "⚠️ Warning: Failed to download updates. Make sure you are connected to the internet." -ForegroundColor Red
    }
}

# Push
Write-Host "Uploading your cards to the cloud..." -ForegroundColor Yellow
& $gitCmd -C $repoDir push origin main

if ($LASTEXITCODE -eq 0) {
    Write-Host "✅ Sync Complete! Your friends will now see your cards." -ForegroundColor Green
} else {
    Write-Host "⚠️ Warning: Failed to upload your cards. Please try again later." -ForegroundColor Red
}

Write-Host "`nRelaunching Magic Set Editor..."
Start-Process "wscript.exe" -ArgumentList "`"$repoDir\Launch_Silent.vbs`""

Start-Sleep -Seconds 2
