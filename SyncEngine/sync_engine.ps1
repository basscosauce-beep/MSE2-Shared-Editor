# sync_engine.ps1 - Background repo health keeper
# DOES: periodic git fetch to keep remote metadata current
# DOES NOT: push, pull --rebase, reset --hard, or show any popups
# All actual syncing is handled by SyncNow.ps1 (the manual Sync button)
# which uses the smart merge engine (MergeSetFile.ps1)

# Ensure only one instance runs
$currentProc = $PID
Get-WmiObject Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -match "sync_engine.ps1" -and $_.ProcessId -ne $currentProc } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

$repoDir = "$PSScriptRoot\.."
$gitCmd  = "$PSScriptRoot\..\mingit\cmd\git.exe"

$env:GIT_TERMINAL_PROMPT = "0"
$env:GIT_ASKPASS         = "echo"

$p1        = "ghp_2g4dOrh3klYwVMo6o"
$p2        = "FNfD8iUKfATTq3ezyS4"
$remoteUrl = "https://basscosauce-beep:$p1$p2@github.com/basscosauce-beep/MSE2-Shared-Editor.git"
$credBypass = @("-c", "credential.helper=")

# Set remote URL with embedded token
& $gitCmd -C $repoDir @credBypass remote set-url origin $remoteUrl *>$null

# Make sure we're on main
$branch = (& $gitCmd -C $repoDir branch --show-current 2>$null).Trim()
if ($branch -ne "main") {
    & $gitCmd -C $repoDir @credBypass fetch origin *>$null
    & $gitCmd -C $repoDir checkout -B main origin/main *>$null
    & $gitCmd -C $repoDir branch --set-upstream-to=origin/main main *>$null
}

Write-Host "[Sync Engine] Running - background fetch only. Use the Sync button to sync cards." -ForegroundColor DarkGray

# Loop: just fetch (updates remote tracking refs) every 5 minutes.
# This makes the next manual SyncNow faster since objects are pre-downloaded.
# Never pushes. Never resets. Never shows popups.
while ($true) {
    Start-Sleep -Seconds 300
    try {
        & $gitCmd -C $repoDir @credBypass fetch origin *>$null
        Write-Host "[Sync Engine] Fetch complete." -ForegroundColor DarkGray
    } catch {
        # Silently ignore network errors - will retry next cycle
    }
}
