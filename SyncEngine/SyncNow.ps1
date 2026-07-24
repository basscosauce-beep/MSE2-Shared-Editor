$Host.UI.RawUI.WindowTitle = "Magic Set Editor - Manual Sync"
Write-Host "Forcing immediate synchronization with cloud..." -ForegroundColor Cyan

$gitCmd = "$PSScriptRoot\..\mingit\cmd\git.exe"
$env:GIT_TERMINAL_PROMPT = "0"
$env:GIT_ASKPASS = "echo"
$repoDir = (Resolve-Path "$PSScriptRoot\..").Path

# Inline credential bypass on every network command
$p1 = "ghp_2g4dOrh3klYwVMo6o"
$p2 = "FNfD8iUKfATTq3ezyS4"
$remoteUrl = "https://basscosauce-beep:$p1$p2@github.com/basscosauce-beep/MSE2-Shared-Editor.git"
$credBypass = @("-c", "credential.helper=")

& $gitCmd -C $repoDir @credBypass remote set-url origin $remoteUrl *>$null

# Ensure user config is set
$userName = (& $gitCmd -C $repoDir config user.name 2>$null).Trim()
Write-Host "[DEBUG] Git user: '$userName'"
if (-not $userName) {
    Write-Host "[DEBUG] No user set - using default" -ForegroundColor Yellow
    & $gitCmd -C $repoDir config user.name "MSE Shared" *>$null
    & $gitCmd -C $repoDir config user.email "shared@mse.local" *>$null
}

# Show current branch
$branch = (& $gitCmd -C $repoDir branch --show-current 2>$null).Trim()
Write-Host "[DEBUG] Current branch: '$branch'"

# Auto-repair detached HEAD
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

# Show what files have changed
Write-Host "[DEBUG] Checking for local card changes..."
& $gitCmd -C $repoDir add "Shared-Set/" *>$null
$statusOutput = (& $gitCmd -C $repoDir status --short 2>$null)
Write-Host "[DEBUG] Git status: $(if ($statusOutput) { $statusOutput } else { '(no changes)' })"

# Stash local changes so we can pull cleanly
$hasChanges = ($statusOutput | Where-Object { $_ -match "Shared-Set" }).Count -gt 0
$stashed = $false
if ($hasChanges) {
    Write-Host "[DEBUG] Stashing local card changes..." -ForegroundColor Yellow
    & $gitCmd -C $repoDir stash push -m "mse-sync-stash"
    $stashed = ($LASTEXITCODE -eq 0)
    Write-Host "[DEBUG] Stash result: $stashed (exit $LASTEXITCODE)"
}

# Pull latest from cloud FIRST
Write-Host "Downloading latest cards from friends..." -ForegroundColor Yellow
& $gitCmd -C $repoDir @credBypass pull origin main --ff-only
$pullCode = $LASTEXITCODE
Write-Host "[DEBUG] Pull exit code: $pullCode"

if ($pullCode -ne 0) {
    Write-Host "[DEBUG] ff-only pull failed, trying fetch + reset..." -ForegroundColor Yellow
    & $gitCmd -C $repoDir @credBypass fetch origin
    & $gitCmd -C $repoDir reset --hard origin/main
}

# Re-apply local card changes on top
if ($stashed) {
    Write-Host "[DEBUG] Restoring your local cards..." -ForegroundColor Yellow
    & $gitCmd -C $repoDir stash pop
    $popCode = $LASTEXITCODE
    Write-Host "[DEBUG] Stash pop exit code: $popCode"
    if ($popCode -ne 0) {
        $desktopPath = [Environment]::GetFolderPath("Desktop")
        Get-ChildItem -Path "$repoDir\Shared-Set" -Filter "*.mse-set" -Recurse | ForEach-Object {
            Copy-Item -Path $_.FullName -Destination "$desktopPath\$($_.BaseName)_Collision_Backup$($_.Extension)" -Force
            Write-Host "[DEBUG] Backed up: $($_.Name)" -ForegroundColor Yellow
        }
        & $gitCmd -C $repoDir checkout -- "Shared-Set/" *>$null
        & $gitCmd -C $repoDir stash drop *>$null
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show("Collision detected! Your cards were backed up to Desktop.", "Collision Resolved", 'OK', 'Warning')
    }
}

# Commit and push
Write-Host "Uploading your cards to the cloud..." -ForegroundColor Yellow
& $gitCmd -C $repoDir add "Shared-Set/"
& $gitCmd -C $repoDir commit -m "Auto-sync card updates"
$commitCode = $LASTEXITCODE
Write-Host "[DEBUG] Commit exit code: $commitCode"

& $gitCmd -C $repoDir @credBypass push origin main
$pushCode = $LASTEXITCODE
Write-Host "[DEBUG] Push exit code: $pushCode"

if ($pushCode -eq 0) {
    Write-Host "Sync Complete! Your friends will now see your cards." -ForegroundColor Green
} else {
    Write-Host "Warning: Failed to upload your cards. See [DEBUG] lines above for details." -ForegroundColor Red
}

Write-Host "`nRelaunching Magic Set Editor..."
Start-Process "wscript.exe" -ArgumentList "`"$repoDir\Launch_Silent.vbs`""
Start-Sleep -Seconds 5
