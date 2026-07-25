# MergeSetFile.ps1 - Merges new locally-created cards into the cloud-pulled set file.
# Uses a temp-file swap instead of in-place zip editing to avoid file lock issues.

param(
    [string]$LocalBackup,
    [string]$CloudFile
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

# Build a set of time_created values from the cloud version
$cloudTimes = [System.Collections.Generic.HashSet[string]]::new()
$cloudContent -split "(?m)^(?=card:)" | Where-Object { $_ -match "^card:" } | ForEach-Object {
    if ($_ -match "time_created: ([^\r\n]+)") { $cloudTimes.Add($matches[1].Trim()) | Out-Null }
}

# Find cards in the local backup that are NOT in the cloud version
$newCards = @($localContent -split "(?m)^(?=card:)" | Where-Object {
    $_ -match "^card:" -and $_ -match "time_created: ([^\r\n]+)" -and -not $cloudTimes.Contains($matches[1].Trim())
})

if ($newCards.Count -eq 0) { return }

Write-Host "[Merge] Preserving $($newCards.Count) new local card(s)..." -ForegroundColor Cyan

$mergedContent = $cloudContent.TrimEnd("`r","`n") + "`n" + ($newCards -join "")

# --- Temp-file swap to avoid file lock issues ---
# 1. Write the merged content to a brand-new temp zip
# 2. Copy all image entries from the cloud zip into it
# 3. Atomically replace the cloud file

$tempZipPath = [System.IO.Path]::GetTempFileName() + ".mse-set"

try {
    # Open cloud zip to copy images from
    $srcZip = [System.IO.Compression.ZipFile]::OpenRead($CloudFile)

    # Create new zip at temp path
    $dstZip = [System.IO.Compression.ZipFile]::Open($tempZipPath, [System.IO.Compression.ZipArchiveMode]::Create)

    # Write merged "set" text entry
    $setEntry = $dstZip.CreateEntry("set", [System.IO.Compression.CompressionLevel]::Optimal)
    $setStream = $setEntry.Open()
    $writer = New-Object System.IO.StreamWriter($setStream, [System.Text.Encoding]::UTF8)
    $writer.Write($mergedContent)
    $writer.Flush(); $writer.Dispose()

    # Copy all image entries from cloud zip
    foreach ($imgEntry in ($srcZip.Entries | Where-Object { $_.Name -ne "set" })) {
        $dstEntry = $dstZip.CreateEntry($imgEntry.FullName, [System.IO.Compression.CompressionLevel]::Optimal)
        $srcStream = $imgEntry.Open()
        $dstStream = $dstEntry.Open()
        $srcStream.CopyTo($dstStream)
        $srcStream.Dispose(); $dstStream.Dispose()
    }

    $srcZip.Dispose()
    $dstZip.Dispose()

    # Atomically replace the cloud file with our merged version
    Copy-Item $tempZipPath $CloudFile -Force
    Write-Host "[Merge] New cards preserved successfully!" -ForegroundColor Green

} catch {
    Write-Host "[Merge] Failed: $_" -ForegroundColor Red
} finally {
    if (Test-Path $tempZipPath) { Remove-Item $tempZipPath -Force -ErrorAction SilentlyContinue }
}
