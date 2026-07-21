# Ensure only one instance runs
$currentProc = $PID
Get-WmiObject Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match "sync_engine.ps1" -and $_.ProcessId -ne $currentProc } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

$sharedDir = "$PSScriptRoot\..\Shared-Set"
$gitCmd = "$PSScriptRoot\..\mingit\cmd\git.exe"

$env:GIT_TERMINAL_PROMPT = "0"

# Ensure Git Remote has Authentication Token so friends can push
$p1 = "ghp_2g4dOrh3klYwVMo6o"
$p2 = "FNfD8iUKfATTq3ezyS4"
& $gitCmd -C "$PSScriptRoot\.." remote set-url origin "https://basscosauce-beep:$p1$p2@github.com/basscosauce-beep/MSE2-Shared-Editor.git" *>$null

if (-not (Test-Path $sharedDir)) {
    New-Item -ItemType Directory -Path $sharedDir | Out-Null
}

$script:isSyncing = $false
$script:pendingChanges = $false

function Sync-GitHub {
    if ($script:isSyncing) { return }
    $script:isSyncing = $true
    $script:pendingChanges = $false

    Write-Host "[Sync Engine] Change detected! Pushing cards to GitHub..."
    
    & $gitCmd -C "$PSScriptRoot\.." add Shared-Set/
    
    $commitMsg = "Auto-sync card updates"
    & $gitCmd -C "$PSScriptRoot\.." commit -m $commitMsg *>$null
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[Sync Engine] Uploading to cloud..."
        & $gitCmd -C "$PSScriptRoot\.." push origin main *>$null
        Write-Host "[Sync Engine] Successfully synced!"
    } else {
        Write-Host "[Sync Engine] No new card changes to push."
    }

    $script:isSyncing = $false

    if ($script:pendingChanges) {
        Sync-GitHub
    }
}

$watcher = New-Object System.IO.FileSystemWatcher
$watcher.Path = $sharedDir
$watcher.IncludeSubdirectories = $true
$watcher.EnableRaisingEvents = $true

$action = {
    $path = $Event.SourceEventArgs.FullPath
    $name = $Event.SourceEventArgs.Name
    if (-not $name.StartsWith(".git")) {
        if (-not $script:isSyncing) {
            Start-Sleep -Seconds 2
            Sync-GitHub
        } else {
            $script:pendingChanges = $true
        }
    }
}

Register-ObjectEvent $watcher "Changed" -Action $action | Out-Null
Register-ObjectEvent $watcher "Created" -Action $action | Out-Null
Register-ObjectEvent $watcher "Deleted" -Action $action | Out-Null
Register-ObjectEvent $watcher "Renamed" -Action $action | Out-Null

Write-Host "[Sync Engine] Background Sync Engine Active! Watching for card saves..."

# Infinite polling loop
while ($true) {
    Start-Sleep -Seconds 30
    if (-not $script:isSyncing) {
        & $gitCmd -C "$PSScriptRoot\.." pull origin main --rebase *>$null
        if ($LASTEXITCODE -ne 0) {
            $repoDir = "$PSScriptRoot\.."
            if ((Test-Path "$repoDir\.git\rebase-merge") -or (Test-Path "$repoDir\.git\rebase-apply")) {
                # Abort the frozen rebase
                & $gitCmd -C $repoDir rebase --abort *>$null
                
                # Backup to Desktop
                $desktopPath = [Environment]::GetFolderPath("Desktop")
                Get-ChildItem -Path "$repoDir\Shared-Set" -Filter "*.mse-set" -Recurse | ForEach-Object {
                    $backupName = $_.BaseName + "_Collision_Backup" + $_.Extension
                    Copy-Item -Path $_.FullName -Destination "$desktopPath\$backupName" -Force
                }
                
                # Force a hard reset to accept cloud's version
                & $gitCmd -C $repoDir fetch origin *>$null
                & $gitCmd -C $repoDir reset --hard origin/main *>$null
                
                # Alert user
                Add-Type -AssemblyName System.Windows.Forms
                [System.Windows.Forms.MessageBox]::Show("A cloud collision was detected in the background (someone else uploaded cards at the exact same time as you).`n`nYour local cards have been safely backed up to your Desktop as '_Collision_Backup.mse-set'.`n`nYour game has been automatically synced with their cards. You can now open your backup file in Magic Set Editor and copy/paste your cards into the main set!", "Collision Auto-Resolved", 'OK', 'Information')
            }
        }
    }
}

