# MergeSetFile.ps1 - Smart card merge with:
#   - Tombstone-based permanent deletion tracking
#   - Last-known snapshot (with content hashes) to detect changes per user
#   - Change-wins conflict resolution: edited > unedited, creator as tiebreaker

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

# --- Helper: compute a short SHA256 hash of card text for change detection ---
function Get-CardHash($text) {
    $sha  = [System.Security.Cryptography.SHA256]::Create()
    $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text))
    $sha.Dispose()
    # Return first 16 hex chars — plenty to detect any change
    return ([System.BitConverter]::ToString($hash) -replace '-','').Substring(0, 16)
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
# Format per line: "time_created|sha256hash"  (hash lets us detect if user changed a card)
$safeUser      = $UserName -replace '[\\/:*?"<>|]', '_'
$lastKnownFile = "$setDir\last_known_$safeUser.txt"
$lastKnownHash = @{}   # tc -> hash at last sync
$lastKnown     = [System.Collections.Generic.HashSet[string]]::new()
if (Test-Path $lastKnownFile) {
    Get-Content $lastKnownFile | ForEach-Object {
        $line = $_.Trim()
        if ($line) {
            $parts = $line -split '\|', 2
            $tc    = $parts[0]
            $hash  = if ($parts.Count -gt 1) { $parts[1] } else { '' }
            $lastKnown.Add($tc)         | Out-Null
            $lastKnownHash[$tc] = $hash
        }
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
    # Tombstone always wins — skip regardless of source
    if ($tombstone.Contains($tc)) {
        Write-Host "[Merge] Tombstoned card removed from local: $tc" -ForegroundColor DarkGray
        continue
    }

    $localCard = $localMap[$tc]

    if ($cloudMap.Contains($tc)) {
        $cloudCard = $cloudMap[$tc]

        if ($localCard -eq $cloudCard) {
            # Identical — no conflict
            $mergedCards.Add($localCard) | Out-Null
        } else {
            # Different versions — apply change-wins resolution:
            #   • Compute what the user had at last sync (baseline hash)
            #   • If user's copy matches baseline → user DIDN'T change it → cloud wins
            #   • If cloud matches baseline  → cloud DIDN'T change  → user wins
            #   • Both changed → creator wins as tiebreaker
            $baselineHash  = $lastKnownHash[$tc]   # may be empty on first sync
            $localHash     = Get-CardHash $localCard
            $cloudHash     = Get-CardHash $cloudCard

            $userChanged   = ($localHash  -ne $baselineHash)
            $friendChanged = ($cloudHash  -ne $baselineHash)

            if ($userChanged -and -not $friendChanged) {
                # Only user changed → user wins
                $mergedCards.Add($localCard) | Out-Null
                Write-Host "[Merge] Your edit wins (friend had stale copy): $(($localCard -split '\r?\n')[0].Trim())" -ForegroundColor Cyan
            } elseif ($friendChanged -and -not $userChanged) {
                # Only friend changed → cloud wins
                $mergedCards.Add($cloudCard) | Out-Null
                Write-Host "[Merge] Friend's edit wins (your copy was stale): $(($cloudCard -split '\r?\n')[0].Trim())" -ForegroundColor DarkCyan
            } else {
                # Both changed (or baseline unknown) → creator wins as tiebreaker
                $creator = Get-CardCreator $localCard
                if ($creator -eq $UserName) {
                    $mergedCards.Add($localCard) | Out-Null
                    Write-Host "[Merge] Both edited — your card, your edit kept: $(($localCard -split '\r?\n')[0].Trim())" -ForegroundColor Cyan
                } else {
                    $mergedCards.Add($cloudCard) | Out-Null
                    Write-Host "[Merge] Both edited — friend's card, cloud edit kept: $(($cloudCard -split '\r?\n')[0].Trim())" -ForegroundColor DarkCyan
                }
            }
        }
    } else {
        # Card only in local (new card user made) — keep it
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
# Format: "time_created|sha256hash" — hash lets us detect future changes
# -----------------------------------------------------------------------
$knownLines = foreach ($card in $mergedCards) {
    if ($card -match "time_created: ([^\r\n]+)") {
        $tc   = $matches[1].Trim()
        $hash = Get-CardHash $card
        "$tc|$hash"
    }
}
Set-Content $lastKnownFile -Value ($knownLines -join "`n") -Encoding UTF8

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
