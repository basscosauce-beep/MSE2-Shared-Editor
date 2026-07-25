# MergeSetFile.ps1
# Merges new locally-created cards back into the cloud-pulled set file.
# Since .mse-set files are binary zips, git can't merge them automatically.
# This script reads both versions and preserves any cards that only exist locally.

param(
    [string]$LocalBackup,   # Path to the local backup (saved before pull)
    [string]$CloudFile      # Path to the current cloud set file (after pull)
)

if (-not (Test-Path $LocalBackup) -or -not (Test-Path $CloudFile)) { return }

Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression

function Read-SetContent($path) {
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($path)
        $entry = $zip.Entries | Where-Object { $_.Name -eq "set" }
        if (-not $entry) { $zip.Dispose(); return $null }
        $reader = New-Object System.IO.StreamReader($entry.Open(), [System.Text.Encoding]::UTF8)
        $content = $reader.ReadToEnd()
        $reader.Dispose(); $zip.Dispose()
        return $content
    } catch { return $null }
}

$localContent = Read-SetContent $LocalBackup
$cloudContent = Read-SetContent $CloudFile
if (-not $localContent -or -not $cloudContent) { return }

# Build a set of time_created values that already exist in the cloud version
$cloudTimes = [System.Collections.Generic.HashSet[string]]::new()
$cloudContent -split "(?m)^(?=card:)" | Where-Object { $_ -match "^card:" } | ForEach-Object {
    if ($_ -match "time_created: ([^\r\n]+)") { $cloudTimes.Add($matches[1].Trim()) | Out-Null }
}

# Find cards in the local backup that are NOT in the cloud version (brand new cards)
$newCards = $localContent -split "(?m)^(?=card:)" | Where-Object {
    $_ -match "^card:" -and $_ -match "time_created: ([^\r\n]+)" -and -not $cloudTimes.Contains($matches[1].Trim())
}

if (-not $newCards -or $newCards.Count -eq 0) { return }

Write-Host "[Merge] Preserving $($newCards.Count) new local card(s) that aren't in the cloud yet..." -ForegroundColor Cyan

# Append new local cards to the end of the cloud set file content
$mergedContent = $cloudContent.TrimEnd("`r", "`n") + "`n" + ($newCards -join "")

# Write the merged content back into the zip
try {
    $zip = [System.IO.Compression.ZipFile]::Open($CloudFile, [System.IO.Compression.ZipArchiveMode]::Update)
    $entry = $zip.Entries | Where-Object { $_.Name -eq "set" }
    $entry.Delete()
    $newEntry = $zip.CreateEntry("set", [System.IO.Compression.CompressionLevel]::Optimal)
    $stream   = $newEntry.Open()
    $writer   = New-Object System.IO.StreamWriter($stream, [System.Text.Encoding]::UTF8)
    $writer.Write($mergedContent)
    $writer.Flush(); $writer.Dispose()
    $zip.Dispose()
    Write-Host "[Merge] New cards preserved successfully!" -ForegroundColor Green
} catch {
    Write-Host "[Merge] Could not write merged set file: $_" -ForegroundColor Red
}
