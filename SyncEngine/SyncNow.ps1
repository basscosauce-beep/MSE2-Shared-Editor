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
    Write-Host "⚠️ Warning: Failed to download updates. Make sure you are connected to the internet." -ForegroundColor Red
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
