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

# ---------------------------------------------------------------------------
# Helper: read "set" entry text from an .mse-set zip
# ---------------------------------------------------------------------------
function Read-SetContent {
    param([string]$path)
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($path)
        $entry = $zip.Entries | Where-Object { $_.Name -eq "set" }
        if (-not $entry) { $zip.Dispose(); return $null }
        $reader = New-Object System.IO.StreamReader($entry.Open(), [System.Text.Encoding]::UTF8)
        $content = $reader.ReadToEnd()
        $reader.Dispose()
        $zip.Dispose()
        return $content
    }
    catch { return $null }
}

# ---------------------------------------------------------------------------
# Helper: parse cards into an ordered dictionary keyed by time_created
# ---------------------------------------------------------------------------
function Get-CardMap {
    param([string]$content)
    $map = New-Object System.Collections.Specialized.OrderedDictionary
    if (-not $content) { return $map }
    $content -split "(?m)^(?=card:)" | Where-Object { $_ -match "^card:" } | ForEach-Object {
        if ($_ -match "time_created: ([^\r\n]+)") {
            $map[$matches[1].Trim()] = $_
        }
    }
    return $map
}

# ---------------------------------------------------------------------------
# Helper: extract everything before the first card: block (set metadata)
# ---------------------------------------------------------------------------
function Get-SetHeader {
    param([string]$content)
    if (-not $content) { return "" }
    $idx = $content.IndexOf("`ncard:")
    if ($idx -lt 0) { return $content }
    return $content.Substring(0, $idx + 1)
}

# ---------------------------------------------------------------------------
# Helper: get creator field value from card text
# ---------------------------------------------------------------------------
function Get-CardCreator {
    param([string]$cardText)
    if ($cardText -match "(?m)^\s*creator:\s*(.+)") { return $matches[1].Trim() }
    return ""
}

# ---------------------------------------------------------------------------
# Helper: get card name for display
# ---------------------------------------------------------------------------
function Get-CardName {
    param([string]$cardText, [string]$fallback)
    if ($cardText -match "(?m)^\s*name:\s*(.+)") { return $matches[1].Trim() }
    return $fallback
}

# ---------------------------------------------------------------------------
# Helper: return everything before the first keyword: or card: block
# (mse version, game, stylesheet, set info, etc.)
# ---------------------------------------------------------------------------
function Get-PreKeywordHeader {
    param([string]$content)
    if (-not $content) { return "" }
    $kwIdx   = $content.IndexOf("`nkeyword:")
    $cardIdx = $content.IndexOf("`ncard:")
    $idx     = [int]::MaxValue
    if ($kwIdx   -ge 0 -and $kwIdx   -lt $idx) { $idx = $kwIdx }
    if ($cardIdx -ge 0 -and $cardIdx -lt $idx) { $idx = $cardIdx }
    if ($idx -eq [int]::MaxValue) { return $content }
    return $content.Substring(0, $idx + 1)
}

# ---------------------------------------------------------------------------
# Helper: extract keyword blocks from set content as an ordered hashtable
# keyed by the keyword name (the 'keyword: Name' field inside each block)
# ---------------------------------------------------------------------------
function Get-KeywordMap {
    param([string]$content)
    $map = [ordered]@{}
    $content -split "(?m)^(?=keyword:)" | Where-Object { $_ -match "^keyword:" } | ForEach-Object {
        $block = $_
        if ($block -match "(?m)^\tkeyword:\s+(.+)") {
            $map[$matches[1].Trim()] = $block
        } else {
            # Unnamed keyword block - use positional key
            $map["_kw_$($map.Count)"] = $block
        }
    }
    return $map
}

# ---------------------------------------------------------------------------
# Helper: compute a 16-char SHA256 hash of card text for change detection
# ---------------------------------------------------------------------------
function Get-CardHash {
    param([string]$text)
    $sha   = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
    $hash  = $sha.ComputeHash($bytes)
    $sha.Dispose()
    $hex   = [System.BitConverter]::ToString($hash) -replace "-", ""
    return $hex.Substring(0, 16)
}

# ---------------------------------------------------------------------------
# Helper: save last_known hashes from a final set file (called after FillCreators)
# ---------------------------------------------------------------------------
function Save-LastKnown {
    param([string]$SetFilePath, [string]$KnownFile)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Add-Type -AssemblyName System.IO.Compression
    $fc = Read-SetContent $SetFilePath
    if (-not $fc) { return }
    $sha   = [System.Security.Cryptography.SHA256]::Create()
    $lines = New-Object System.Collections.Generic.List[string]
    $fc -split "(?m)^(?=card:)" | Where-Object { $_ -match "^card:" } | ForEach-Object {
        if ($_ -match "time_created: ([^\r\n]+)") {
            $tc   = $matches[1].Trim()
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($_)
            $hex   = [System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace "-", ""
            $lines.Add($tc + "|" + $hex.Substring(0, 16))
        }
    }
    $sha.Dispose()
    Set-Content $KnownFile -Value ($lines -join "`n") -Encoding UTF8
}

# ===========================================================================
# Load data
# ===========================================================================
$localContent = Read-SetContent $LocalBackup
$cloudContent = Read-SetContent $CloudFile
if (-not $localContent -or -not $cloudContent) {
    Write-Host "[Merge] Skipped: could not read set files." -ForegroundColor Yellow
    return
}

$setDir = [System.IO.Path]::GetDirectoryName($CloudFile)

# Tombstone: shared deletion record committed to git (everyone respects it)
$tombstoneFile = "$setDir\deleted_cards.txt"
$tombstone = New-Object System.Collections.Generic.HashSet[string]
if (Test-Path $tombstoneFile) {
    Get-Content $tombstoneFile | ForEach-Object {
        $line = $_.Trim()
        if ($line) { $tombstone.Add($line) | Out-Null }
    }
}

# Last-known: what this user had after THEIR last sync (gitignored, per-user)
# Format per line: "time_created|sha256hash"
$safeUser      = $UserName -replace '[\\/:*?"<>|]', '_'
$lastKnownFile = "$setDir\last_known_$safeUser.txt"
$lastKnownHash = @{}
$lastKnown     = New-Object System.Collections.Generic.HashSet[string]
if (Test-Path $lastKnownFile) {
    Get-Content $lastKnownFile | ForEach-Object {
        $line = $_.Trim()
        if ($line) {
            $parts = $line -split "\|", 2
            $tc    = $parts[0]
            if ($parts.Count -gt 1) {
                $h = $parts[1]
            }
            else {
                $h = ""
            }
            $lastKnown.Add($tc) | Out-Null
            $lastKnownHash[$tc] = $h
        }
    }
}

# ===========================================================================
# Parse card maps
# ===========================================================================
$localMap = Get-CardMap $localContent
$cloudMap = Get-CardMap $cloudContent

# ===========================================================================
# Detect newly deleted cards
# A card is "newly deleted" if the user had it at last sync but not now.
# ===========================================================================
$newTombstones = 0
foreach ($tc in $lastKnown) {
    if (-not $localMap.Contains($tc)) {
        if ($tombstone.Add($tc)) {
            $newTombstones++
            Write-Host "[Merge] Card permanently deleted: $tc" -ForegroundColor Yellow
        }
    }
}

# ===========================================================================
# Build the merged card list
# ===========================================================================
$mergedCards = New-Object System.Collections.Generic.List[string]

# --- Pass 1: process every card in local ---
foreach ($tc in $localMap.Keys) {

    # Tombstone always wins - skip regardless of source
    if ($tombstone.Contains($tc)) {
        Write-Host "[Merge] Tombstoned: $tc" -ForegroundColor DarkGray
        continue
    }

    $localCard = $localMap[$tc]

    if ($cloudMap.Contains($tc)) {
        $cloudCard = $cloudMap[$tc]

        if ($localCard -eq $cloudCard) {
            # Identical - no conflict
            $mergedCards.Add($localCard) | Out-Null
        }
        else {
            # Content differs - resolve using change detection
            $cardName = Get-CardName $localCard $tc

            # Look up the baseline hash we saved after last sync
            if ($lastKnownHash.ContainsKey($tc)) {
                $baselineHash = $lastKnownHash[$tc]
            }
            else {
                $baselineHash = $null
            }

            if (-not $baselineHash) {
                # No baseline available (first sync after upgrade, or brand-new card).
                # Safe fallback: keep local. Self-corrects after one sync when hashes are written.
                $mergedCards.Add($localCard) | Out-Null
                Write-Host "[Merge] No baseline - keeping local: $cardName" -ForegroundColor DarkGray
            }
            else {
                $localHash     = Get-CardHash $localCard
                $cloudHash     = Get-CardHash $cloudCard
                $userChanged   = ($localHash  -ne $baselineHash)
                $friendChanged = ($cloudHash  -ne $baselineHash)

                if ($userChanged -and (-not $friendChanged)) {
                    # Only user changed -> user wins
                    $mergedCards.Add($localCard) | Out-Null
                    Write-Host "[Merge] Your edit wins: $cardName" -ForegroundColor Cyan
                }
                elseif ($friendChanged -and (-not $userChanged)) {
                    # Only friend changed -> cloud wins
                    $mergedCards.Add($cloudCard) | Out-Null
                    Write-Host "[Merge] Friend's edit wins: $cardName" -ForegroundColor DarkCyan
                }
                else {
                    # Both changed -> creator wins as tiebreaker
                    $creator = Get-CardCreator $localCard
                    if ($creator -eq $UserName) {
                        $mergedCards.Add($localCard) | Out-Null
                        Write-Host "[Merge] Both edited, your card wins: $cardName" -ForegroundColor Cyan
                    }
                    else {
                        $mergedCards.Add($cloudCard) | Out-Null
                        Write-Host "[Merge] Both edited, friend's card wins: $cardName" -ForegroundColor DarkCyan
                    }
                }
            }
        }
    }
    else {
        # Card only in local (user's new card) - keep it
        $mergedCards.Add($localCard) | Out-Null
    }
}

# --- Pass 2: add friend's new cards from cloud (not in local, not tombstoned) ---
$friendCount = 0
foreach ($tc in $cloudMap.Keys) {
    if ((-not $localMap.Contains($tc)) -and (-not $tombstone.Contains($tc))) {
        $mergedCards.Add($cloudMap[$tc]) | Out-Null
        $friendCount++
    }
}

Write-Host "[Merge] Local: $($localMap.Count) | Friends new: $friendCount | Tombstoned: $($tombstone.Count)" -ForegroundColor Cyan

# ===========================================================================
# Rebuild set content: merged header + all merged cards
# The header is: cloud's base metadata + union of keywords (cloud wins on
# conflicts, local-only keywords are preserved)
# ===========================================================================
$cloudHeader   = Get-SetHeader $cloudContent
$localHeader   = Get-SetHeader $localContent
$cloudKeywords = Get-KeywordMap $cloudContent
$localKeywords = Get-KeywordMap $localContent

# Union: start with cloud keywords, then add local-only ones
$mergedKeywords = [ordered]@{}
foreach ($kw in $cloudKeywords.Keys) { $mergedKeywords[$kw] = $cloudKeywords[$kw] }
foreach ($kw in $localKeywords.Keys) {
    if (-not $mergedKeywords.ContainsKey($kw)) {
        $mergedKeywords[$kw] = $localKeywords[$kw]
        Write-Host "[Merge] New local keyword preserved: $kw" -ForegroundColor Cyan
    }
}
if ($cloudKeywords.Count -ne $mergedKeywords.Count) {
    Write-Host "[Merge] Keywords: $($cloudKeywords.Count) from cloud + $($mergedKeywords.Count - $cloudKeywords.Count) local-only" -ForegroundColor Cyan
} else {
    Write-Host "[Merge] Keywords: $($mergedKeywords.Count) (in sync)" -ForegroundColor DarkGray
}

# Base metadata (mse version, stylesheet, set info) comes from cloud
$preHeader     = Get-PreKeywordHeader $cloudContent
$keywordText   = ($mergedKeywords.Values | Where-Object { $_ }) -join ""
$header        = $preHeader + $keywordText
$mergedContent = $header + ($mergedCards -join "")

# Save initial last_known hashes (SyncNow.ps1 overwrites this after FillCreators runs)
Save-LastKnown -SetFilePath $CloudFile -KnownFile $lastKnownFile

# Write updated tombstone (git-committed so all users see it)
Set-Content $tombstoneFile -Value (($tombstone | Sort-Object) -join "`n") -Encoding UTF8

# ===========================================================================
# Temp-file swap: write merged zip without touching the live file
# until the final Copy-Item (avoids file lock errors)
# ===========================================================================
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
    $writer.Flush()
    $writer.Dispose()

    $written = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)

    # Local images first (user's own cards - most up-to-date)
    foreach ($entry in ($localZip.Entries | Where-Object { $_.Name -ne "set" })) {
        $dst = $dstZip.CreateEntry($entry.FullName, [System.IO.Compression.CompressionLevel]::Optimal)
        $s = $entry.Open()
        $d = $dst.Open()
        $s.CopyTo($d)
        $s.Dispose()
        $d.Dispose()
        $written.Add($entry.FullName) | Out-Null
    }

    # Cloud images for friend's cards not already covered
    foreach ($entry in ($cloudZip.Entries | Where-Object { $_.Name -ne "set" })) {
        if (-not $written.Contains($entry.FullName)) {
            $dst = $dstZip.CreateEntry($entry.FullName, [System.IO.Compression.CompressionLevel]::Optimal)
            $s = $entry.Open()
            $d = $dst.Open()
            $s.CopyTo($d)
            $s.Dispose()
            $d.Dispose()
            $written.Add($entry.FullName) | Out-Null
        }
    }

    $localZip.Dispose()
    $cloudZip.Dispose()
    $dstZip.Dispose()

    Copy-Item $tempZipPath $CloudFile -Force
    Write-Host "[Merge] Merge complete!" -ForegroundColor Green
}
catch {
    Write-Host "[Merge] Failed: $_" -ForegroundColor Red
}
finally {
    if (Test-Path $tempZipPath) { Remove-Item $tempZipPath -Force -ErrorAction SilentlyContinue }
}
