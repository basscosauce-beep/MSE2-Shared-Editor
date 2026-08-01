# MergeSetFile.ps1 - Smart card merge with:
#   - Tombstone-based permanent deletion tracking
#   - Last-known snapshot to detect new deletions per user
#   - Ownership-based conflict resolution (your edits to your cards win)

param(
    [string]$LocalBackup,
    [string]$CloudFile,
    [string]$UserName = "Unknown"
)

if (-not (Test-Path $LocalBackup) -or -not (Test-Path $CloudFile)) { return }

Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression

# --- Helper: read "set" entry text from an .mse-set zip ---
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

# --- Helper: parse cards into a hashtable keyed by time_created ---
function Get-CardMap($content) {
    $map = [System.Collections.Specialized.OrderedDictionary]::new()
    if (-not $content) { return $map }
    $content -split "(?m)^(?=card:)" | Where-Object { $_ -match "^card:" } | ForEach-Object {
        if ($_ -match "time_created: ([^\r\n]+)") {
            $map[$matches[1].Trim()] = $_
        }
    }
    return $map
}

# --- Helper: extract everything before the first card: block (set metadata) ---
function Get-SetHeader($content) {
    if (-not $content) { return "" }
    $idx = $content.IndexOf("`ncard:")
    if ($idx -lt 0) { return $content }
    return $content.Substring(0, $idx + 1)
}

# --- Helper: get creator field from a card's text ---
function Get-CardCreator($cardText) {
    if ($cardText -match "(?m)^\s*creator:\s*(.+)") { return $matches[1].Trim() }
    return ""
}

# -----------------------------------------------------------------------
# Load data
# -----------------------------------------------------------------------
$localContent = Read-SetContent $LocalBackup
$cloudContent = Read-SetContent $CloudFile
if (-not $localContent -or -not $cloudContent) {
    Write-Host "[Merge] Skipped: could not read set files." -ForegroundColor Yellow
    return
}

$setDir  = [System.IO.Path]::GetDirectoryName($CloudFile)

# Tombstone: shared deletion record committed to git (everyone respects it)
$tombstoneFile = "$setDir\deleted_cards.txt"
$tombstone = [System.Collections.Generic.HashSet[string]]::new()
if (Test-Path $tombstoneFile) {
    Get-Content $tombstoneFile | ForEach-Object {
        $line = $_.Trim()
        if ($line) { $tombstone.Add($line) | Out-Null }
    }
}

# Last-known: what this user had after THEIR last sync (gitignored, per-user)
# Lets us detect brand-new deletions vs cards we never had
$safeUser     = $UserName -replace '[\\/:*?"<>|]', '_'
$lastKnownFile = "$setDir\last_known_$safeUser.txt"
$lastKnown    = [System.Collections.Generic.HashSet[string]]::new()
if (Test-Path $lastKnownFile) {
    Get-Content $lastKnownFile | ForEach-Object {
        $line = $_.Trim()
        if ($line) { $lastKnown.Add($line) | Out-Null }
    }
}

# -----------------------------------------------------------------------
# Parse card maps
# -----------------------------------------------------------------------
$localMap = Get-CardMap $localContent
$cloudMap = Get-CardMap $cloudContent

# -----------------------------------------------------------------------
# Detect newly deleted cards
# A card is "newly deleted" if the user had it at last sync but doesn't have it now.
# -----------------------------------------------------------------------
$newTombstones = 0
foreach ($tc in $lastKnown) {
    if (-not $localMap.Contains($tc)) {
        if ($tombstone.Add($tc)) {
            $newTombstones++
            Write-Host "[Merge] Card permanently deleted: $tc" -ForegroundColor Yellow
        }
    }
}

# -----------------------------------------------------------------------
# Build the merged card list
# -----------------------------------------------------------------------
$mergedCards = [System.Collections.Generic.List[string]]::new()

# 1. Process all cards in local: resolve conflicts for cards that also exist in cloud
foreach ($tc in $localMap.Keys) {
    # Skip ANY card in the tombstone — even if it's still in local
    # (This is what makes deletions propagate to everyone: a tombstoned card
    #  is excluded from the merge no matter which zip it comes from)
    if ($tombstone.Contains($tc)) {
        Write-Host "[Merge] Tombstoned card removed from local: $tc" -ForegroundColor DarkGray
        continue
    }

    $localCard = $localMap[$tc]

    if ($cloudMap.Contains($tc)) {
        $cloudCard = $cloudMap[$tc]

        if ($localCard -ne $cloudCard) {
            # Same card, different content — resolve by creator ownership
            $localCreator = Get-CardCreator $localCard
            $cloudCreator = Get-CardCreator $cloudCard

            if ($localCreator -eq $UserName) {
                # It's your card — your local edit wins
                $mergedCards.Add($localCard) | Out-Null
                Write-Host "[Merge] Your edit kept for: $(($localCard -split '\r?\n')[1].Trim())" -ForegroundColor Cyan
            } else {
                # Friend's card — cloud version wins (friend may have updated it)
                $mergedCards.Add($cloudCard) | Out-Null
                Write-Host "[Merge] Friend's update accepted for: $(($cloudCard -split '\r?\n')[1].Trim())" -ForegroundColor DarkCyan
            }
        } else {
            $mergedCards.Add($localCard) | Out-Null
        }
    } else {
        # Card only in local (user's new card) — keep it
        $mergedCards.Add($localCard) | Out-Null
    }
}

# 2. Add friend's new cards from cloud (not in local, not tombstoned)
$friendCount = 0
foreach ($tc in $cloudMap.Keys) {
    if (-not $localMap.Contains($tc) -and -not $tombstone.Contains($tc)) {
        $mergedCards.Add($cloudMap[$tc]) | Out-Null
        $friendCount++
    }
}

Write-Host "[Merge] Local: $($localMap.Count) | Friends new: $friendCount | Tombstoned: $($tombstone.Count)" -ForegroundColor Cyan

# -----------------------------------------------------------------------
# Rebuild the set content: header + all merged cards
# -----------------------------------------------------------------------
$header = Get-SetHeader $localContent
$mergedContent = $header + ($mergedCards -join "")

# -----------------------------------------------------------------------
# Update last_known snapshot for this user (saved locally, gitignored)
# -----------------------------------------------------------------------
$knownTimes = foreach ($card in $mergedCards) {
    if ($card -match "time_created: ([^\r\n]+)") { $matches[1].Trim() }
}
Set-Content $lastKnownFile -Value ($knownTimes -join "`n") -Encoding UTF8

# -----------------------------------------------------------------------
# Write updated tombstone (will be git-committed so all users see it)
# -----------------------------------------------------------------------
Set-Content $tombstoneFile -Value (($tombstone | Sort-Object) -join "`n") -Encoding UTF8

# -----------------------------------------------------------------------
# Temp-file swap — write merged zip without touching the target file
# until the very last Copy-Item (avoids file lock errors)
# -----------------------------------------------------------------------
$tempZipPath = [System.IO.Path]::GetTempFileName() + ".mse-set"

try {
    $cloudZip = [System.IO.Compression.ZipFile]::OpenRead($CloudFile)
    $localZip = [System.IO.Compression.ZipFile]::OpenRead($LocalBackup)
    $dstZip   = [System.IO.Compression.ZipFile]::Open($tempZipPath, [System.IO.Compression.ZipArchiveMode]::Create)

    # Write merged "set" text entry
    $setEntry  = $dstZip.CreateEntry("set", [System.IO.Compression.CompressionLevel]::Optimal)
    $setStream = $setEntry.Open()
    $writer    = New-Object System.IO.StreamWriter($setStream, [System.Text.Encoding]::UTF8)
    $writer.Write($mergedContent)
    $writer.Flush(); $writer.Dispose()

    $written = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    function CopyEntry($srcEntry, $dstZipArg) {
        $dst = $dstZipArg.CreateEntry($srcEntry.FullName, [System.IO.Compression.CompressionLevel]::Optimal)
        $s = $srcEntry.Open(); $d = $dst.Open()
        $s.CopyTo($d); $s.Dispose(); $d.Dispose()
    }

    # Local images first (newest — user's own cards)
    foreach ($entry in ($localZip.Entries | Where-Object { $_.Name -ne "set" })) {
        CopyEntry $entry $dstZip
        $written.Add($entry.FullName) | Out-Null
    }

    # Cloud images for friend's cards not covered by local
    foreach ($entry in ($cloudZip.Entries | Where-Object { $_.Name -ne "set" })) {
        if (-not $written.Contains($entry.FullName)) {
            CopyEntry $entry $dstZip
            $written.Add($entry.FullName) | Out-Null
        }
    }

    $localZip.Dispose()
    $cloudZip.Dispose()
    $dstZip.Dispose()

    Copy-Item $tempZipPath $CloudFile -Force
    Write-Host "[Merge] Merge complete!" -ForegroundColor Green

} catch {
    Write-Host "[Merge] Failed: $_" -ForegroundColor Red
} finally {
    if (Test-Path $tempZipPath) { Remove-Item $tempZipPath -Force -ErrorAction SilentlyContinue }
}
