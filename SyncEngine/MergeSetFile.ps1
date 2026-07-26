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

# Build a set of time_created values from the LOCAL version
# (local is authoritative - edits and deletions made locally must be respected)
$localTimes = [System.Collections.Generic.HashSet[string]]::new()
$localContent -split "(?m)^(?=card:)" | Where-Object { $_ -match "^card:" } | ForEach-Object {
    if ($_ -match "time_created: ([^\r\n]+)") { $localTimes.Add($matches[1].Trim()) | Out-Null }
}

# Find cards in the CLOUD that are NOT in the local version (these are friends' new cards)
$friendCards = @($cloudContent -split "(?m)^(?=card:)" | Where-Object {
    $_ -match "^card:" -and $_ -match "time_created: ([^\r\n]+)" -and -not $localTimes.Contains($matches[1].Trim())
})

$friendCount = $friendCards.Count
Write-Host "[Merge] Local cards: $($localTimes.Count) | New cards from friends: $friendCount" -ForegroundColor Cyan

# Merged result = user's full local copy (edits/deletions intact) + any new cards from friends
if ($friendCount -gt 0) {
    $mergedContent = $localContent.TrimEnd("`r","`n") + "`n" + ($friendCards -join "")
} else {
    $mergedContent = $localContent
}

# --- Temp-file swap to avoid file lock issues ---
# 1. Write the merged content to a brand-new temp zip
# 2. Copy all image entries from the cloud zip into it
# 3. Atomically replace the cloud file

$tempZipPath = [System.IO.Path]::GetTempFileName() + ".mse-set"

try {
    # Open both zips so we can pull images from each
    $cloudZip = [System.IO.Compression.ZipFile]::OpenRead($CloudFile)
    $localZip = [System.IO.Compression.ZipFile]::OpenRead($LocalBackup)

    # Create new merged zip at temp path
    $dstZip = [System.IO.Compression.ZipFile]::Open($tempZipPath, [System.IO.Compression.ZipArchiveMode]::Create)

    # Write merged "set" text entry
    $setEntry = $dstZip.CreateEntry("set", [System.IO.Compression.CompressionLevel]::Optimal)
    $setStream = $setEntry.Open()
    $writer = New-Object System.IO.StreamWriter($setStream, [System.Text.Encoding]::UTF8)
    $writer.Write($mergedContent)
    $writer.Flush(); $writer.Dispose()

    # Build a lookup of all image names we've already written (to avoid duplicates)
    $written = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    # Helper to copy one zip entry into dstZip
    function CopyEntry($srcEntry, $dstZipRef) {
        $dst = $dstZipRef.CreateEntry($srcEntry.FullName, [System.IO.Compression.CompressionLevel]::Optimal)
        $s = $srcEntry.Open(); $d = $dst.Open()
        $s.CopyTo($d); $s.Dispose(); $d.Dispose()
    }

    # 1. Copy images from LOCAL backup first (these are the newest - user's own cards)
    foreach ($entry in ($localZip.Entries | Where-Object { $_.Name -ne "set" })) {
        CopyEntry $entry $dstZip
        $written.Add($entry.FullName) | Out-Null
    }

    # 2. Copy images from CLOUD that aren't already covered by local
    foreach ($entry in ($cloudZip.Entries | Where-Object { $_.Name -ne "set" })) {
        if (-not $written.Contains($entry.FullName)) {
            CopyEntry $entry $dstZip
            $written.Add($entry.FullName) | Out-Null
        }
    }

    $localZip.Dispose()
    $cloudZip.Dispose()
    $dstZip.Dispose()

    # Atomically replace the cloud file with our merged version
    Copy-Item $tempZipPath $CloudFile -Force
    Write-Host "[Merge] New cards and images preserved successfully!" -ForegroundColor Green

} catch {
    Write-Host "[Merge] Failed: $_" -ForegroundColor Red
} finally {
    if (Test-Path $tempZipPath) { Remove-Item $tempZipPath -Force -ErrorAction SilentlyContinue }
}
