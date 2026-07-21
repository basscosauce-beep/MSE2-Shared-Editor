$sharedDir = "$PSScriptRoot\..\Shared-Set"
$gitCmd = "$PSScriptRoot\..\mingit\cmd\git.exe"

$env:GIT_TERMINAL_PROMPT = "0"

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
        & $gitCmd -C "$PSScriptRoot\.." pull origin main *>$null
    }
}
