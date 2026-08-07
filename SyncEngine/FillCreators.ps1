# FillCreators.ps1
# One-time cleanup: if any cards in the cloud still have no creator field
# (legacy cards made before this system), assign them to the current user
# who is syncing right now.
#
# NEW BEHAVIOUR: Creator is stamped ONCE and NEVER changed again.
# - Cards that already have a creator: untouched.
# - Cards with no creator: stamped with the current user.
# No more git-history guessing (which was assigning wrong names).

param(
    [string]$RepoDir,
    [string]$GitCmd,
    [array]$CredBypass
)

$setFile = Get-ChildItem "$RepoDir\Shared-Set" -Recurse -Filter "*.mse-set" | Select-Object -First 1
if (-not $setFile) { return }

Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression

function Read-SetEntry($zipPath) {
    try {
        $zip    = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
        $entry  = $zip.Entries | Where-Object { $_.Name -eq "set" }
        if (-not $entry) { $zip.Dispose(); return $null }
        $reader = New-Object System.IO.StreamReader($entry.Open(), [System.Text.Encoding]::UTF8)
        $content = $reader.ReadToEnd()
        $reader.Dispose(); $zip.Dispose()
        return $content
    } catch { return $null }
}

$content = Read-SetEntry $setFile.FullName
if (-not $content) { return }

# Check if any cards are missing a creator
$cardBlocks = $content -split "(?m)^(?=card:)"
$hasEmpty = $cardBlocks | Where-Object { $_ -match "^card:" -and $_ -notmatch "(?m)^\tcreator: \S" }
if (-not $hasEmpty) { return }  # All cards already have creators - nothing to do

# Who is syncing right now? Use git user.name (set per-machine during setup)
$currentUser = (& $GitCmd -C $RepoDir config user.name 2>$null).Trim()
if (-not $currentUser -or $currentUser -match "^(MSE Shared|Anonymous|Unknown)$") {
    # Fallback to Windows login name
    $currentUser = $env:USERNAME
}
if (-not $currentUser) { return }

Write-Host "[By Column] Stamping creator '$currentUser' on $($hasEmpty.Count) card(s) with no creator..." -ForegroundColor Yellow

$anyUpdated = $false
$newBlocks = foreach ($block in $cardBlocks) {
    if ($block -match "^card:" -and $block -notmatch "(?m)^\tcreator: \S") {
        $cardName = ""
        if ($block -match "(?m)^\tname:\s*(.+)") { $cardName = $matches[1].Trim() }

        # Insert creator after time_modified, or after time_created as fallback
        if ($block -match "(?m)(^\ttime_modified: .+)") {
            $block = $block -replace "(?m)(^\ttime_modified: .+)", ('$1' + "`n`tcreator: $currentUser")
        } elseif ($block -match "(?m)(^\ttime_created: .+)") {
            $block = $block -replace "(?m)(^\ttime_created: .+)", ('$1' + "`n`tcreator: $currentUser")
        }

        Write-Host "  -> '$cardName' creator set to '$currentUser'" -ForegroundColor Cyan
        $anyUpdated = $true
    }
    $block
}

if (-not $anyUpdated) { return }

$newContent = $newBlocks -join ""

# Temp-file swap to avoid file lock issues
$tempZipPath = [System.IO.Path]::GetTempFileName() + ".mse-set"
try {
    $srcZip = [System.IO.Compression.ZipFile]::OpenRead($setFile.FullName)
    $dstZip = [System.IO.Compression.ZipFile]::Open($tempZipPath, [System.IO.Compression.ZipArchiveMode]::Create)

    $setEntry  = $dstZip.CreateEntry("set", [System.IO.Compression.CompressionLevel]::Optimal)
    $setStream = $setEntry.Open()
    $writer    = New-Object System.IO.StreamWriter($setStream, [System.Text.Encoding]::UTF8)
    $writer.Write($newContent)
    $writer.Flush(); $writer.Dispose()

    foreach ($imgEntry in ($srcZip.Entries | Where-Object { $_.Name -ne "set" })) {
        $dstEntry = $dstZip.CreateEntry($imgEntry.FullName, [System.IO.Compression.CompressionLevel]::Optimal)
        $s = $imgEntry.Open(); $d = $dstEntry.Open()
        $s.CopyTo($d); $s.Dispose(); $d.Dispose()
    }
    $srcZip.Dispose(); $dstZip.Dispose()

    Copy-Item $tempZipPath $setFile.FullName -Force
    Write-Host "[By Column] Done. Legacy cards attributed to '$currentUser'." -ForegroundColor Green
} catch {
    Write-Host "[By Column] Could not update set file: $_" -ForegroundColor Red
} finally {
    if (Test-Path $tempZipPath) { Remove-Item $tempZipPath -Force -ErrorAction SilentlyContinue }
}
