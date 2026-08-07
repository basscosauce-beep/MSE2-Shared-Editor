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
    $idx = 0
    $content -split "(?m)^(?=card:)" | Where-Object { $_ -match "^card:" } | ForEach-Object {
        # Strip any trailing keyword:/version_control:/apprentice_code: blocks.
        # MSE2 writes these at the very end of the file after all cards.
        # Without this, the last card carries them into the merge output.
        $cardBlock = ($_ -split "(?m)^(?=keyword:|version_control:|apprentice_code:)")[0]
        if ($cardBlock -match "time_created: ([^\r\n]+)") {
            $tc = $matches[1].Trim()
            if (-not $map.Contains($tc)) {
                $map[$tc] = $cardBlock
            }
            # If duplicate time_created, keep the longer (more complete) version
            elseif ($cardBlock.Length -gt $map[$tc].Length) {
                $map[$tc] = $cardBlock
            }
        } else {
            # No time_created field - assign a positional fallback so the card
            # is never silently dropped. This can happen if MSE2 wrote a card
            # without the field, or the backup was truncated mid-write.
            $fallback = "_notime_$idx"
            $map[$fallback] = $cardBlock
            Write-Host "[Merge] WARNING: Card at position $idx has no time_created - using fallback key '$fallback'" -ForegroundColor Yellow
        }
        $idx++
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
# Helper: permanently stamp a creator onto a card block that has none.
# Inserts after time_modified (or time_created as fallback).
# If the card already has a creator, returns it unchanged - never overwrites.
# ---------------------------------------------------------------------------
function Set-CardCreator {
    param([string]$cardText, [string]$creator)
    # Never overwrite an existing creator
    if ($cardText -match "(?m)^\s*creator:\s*\S") { return $cardText }
    if (-not $creator) { return $cardText }
    # Insert after time_modified if present, else after time_created
    if ($cardText -match "(?m)(^\ttime_modified: .+)") {
        return $cardText -replace "(?m)(^\ttime_modified: .+)", ('$1' + "`n`tcreator: $creator")
    } elseif ($cardText -match "(?m)(^\ttime_created: .+)") {
        return $cardText -replace "(?m)(^\ttime_created: .+)", ('$1' + "`n`tcreator: $creator")
    }
    return $cardText
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
# Helper: return the pre-card header with its own keyword blocks deduplicated.
# Uses the header string itself (NOT the full content) to find the boundary,
# so the metadata section is never confused with content from after the first card:.
# ---------------------------------------------------------------------------
function Get-DedupedHeader {
    param([string]$header)
    if (-not $header) { return "" }
    $kwIdx = $header.IndexOf("`nkeyword:")
    if ($kwIdx -lt 0) { return $header }   # no keywords in header - return as-is
    $preMeta     = $header.Substring(0, $kwIdx + 1)  # metadata before first keyword:
    $kwSection   = $header.Substring($kwIdx + 1)     # everything from keyword: onwards
    $kwMap       = Get-KeywordMap $kwSection
    $dedupedKws  = ($kwMap.Values | Where-Object { $_ }) -join ""
    return $preMeta + $dedupedKws
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
        # Strip trailing metadata blocks exactly like Get-CardMap does,
        # so the saved hash matches what Get-CardMap will produce next sync.
        # Without this, hashes never match and change-detection always fires.
        $stripped = ($_ -split "(?m)^(?=keyword:|version_control:|apprentice_code:)")[0]
        if ($stripped -match "time_created: ([^\r\n]+)") {
            $tc    = $matches[1].Trim()
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($stripped)
            $hex   = [System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace "-", ""
            $lines.Add($tc + "|" + $hex.Substring(0, 16))
        }
    }
    $sha.Dispose()
    Set-Content $KnownFile -Value ($lines -join "`n") -Encoding UTF8
    Write-Host "[Merge] Saved $($lines.Count) card baselines to $(Split-Path $KnownFile -Leaf)" -ForegroundColor DarkGray
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

Write-Host "[Merge] Cards found - Local backup: $($localMap.Count) | Cloud: $($cloudMap.Count) | Last-known: $($lastKnown.Count)" -ForegroundColor DarkGray

# ===========================================================================
# SAFETY CHECK 1: If the local backup looks completely wrong
# (0 cards while we know the user had cards), skip tombstoning entirely.
# A legitimate 0-card backup could only happen on a brand-new set.
# This prevents a bad backup from tombstoning the entire set.
# ===========================================================================
$skipTombstone = $false
if ($localMap.Count -eq 0 -and $lastKnown.Count -ge 3) {
    Write-Host "[Merge] SAFETY: Local backup has 0 cards but $($lastKnown.Count) were expected. Tombstone skipped to prevent mass deletion." -ForegroundColor Red
    Write-Host "[Merge] SAFETY: If you intentionally deleted all cards, run a second sync." -ForegroundColor Red
    $skipTombstone = $true
}

# Also block if we would tombstone more than half the known cards in one sync.
# Single-card deletions are common; losing >50% at once is almost certainly a bug.
if (-not $skipTombstone -and $lastKnown.Count -ge 6) {
    $wouldTombstone = ($lastKnown | Where-Object { -not $localMap.Contains($_) }).Count
    if ($wouldTombstone -gt [math]::Floor($lastKnown.Count * 0.5)) {
        Write-Host "[Merge] SAFETY: Would tombstone $wouldTombstone/$($lastKnown.Count) cards in one sync. Tombstone skipped." -ForegroundColor Red
        $skipTombstone = $true
    }
}

# ===========================================================================
# Detect newly deleted cards
# A card is "newly deleted" if the user had it at last sync but not now.
# ASK the user before permanently tombstoning each one.
# ===========================================================================
$newTombstones = 0
if (-not $skipTombstone) {
    $candidatesForDeletion = @()
    foreach ($tc in $lastKnown) {
        if (-not $localMap.Contains($tc)) {
            $candidatesForDeletion += $tc
        }
    }

    if ($candidatesForDeletion.Count -gt 0) {
        Write-Host ""
        Write-Host "============================================================" -ForegroundColor Yellow
        Write-Host " $($candidatesForDeletion.Count) card(s) appear to have been deleted." -ForegroundColor Yellow
        Write-Host "============================================================" -ForegroundColor Yellow
        Write-Host ""

        foreach ($tc in $candidatesForDeletion) {
            # Try to find the card name from the cloud version
            $cardName = $tc
            if ($cloudMap.Contains($tc)) {
                $cBlock = $cloudMap[$tc]
                if ($cBlock -match "(?m)^\tname:\s*(.+)") {
                    $n = $matches[1].Trim()
                    if ($n) { $cardName = $n }
                }
            }

            Write-Host "  Card: '$cardName' (created: $tc)" -ForegroundColor White
            $answer = Read-Host "  Permanently delete this card for everyone? (y/N)"
            if ($answer -match "^[Yy]") {
                if ($tombstone.Add($tc)) {
                    $newTombstones++
                    Write-Host "  -> Permanently deleted." -ForegroundColor Red
                }
            } else {
                Write-Host "  -> Kept (will be restored from cloud)." -ForegroundColor Green
            }
            Write-Host ""
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
        # Card only in local - this user just created it.
        # Stamp their name as creator NOW, permanently. Never overwritten.
        $stamped = Set-CardCreator $localCard $UserName
        $mergedCards.Add($stamped) | Out-Null
        $cardName = Get-CardName $localCard $tc
        if ($stamped -ne $localCard) {
            Write-Host "[Merge] New card '$cardName' creator stamped: '$UserName'" -ForegroundColor Cyan
        }
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
#
# Keyword strategy: LOCAL-WINS merge.
#   - Scan the ENTIRE local backup (header + after cards) for keywords,
#     because MSE2 sometimes writes keywords at the end of the file.
#   - Start with cloud keywords as the base
#   - If local has a keyword with the same name, LOCAL version wins
#     (so user edits to reminder text etc. are preserved)
#   - If local has a keyword not in cloud, it's added (new keyword)
#   - Cloud-only keywords are kept as-is
# ===========================================================================
$cloudHeader   = Get-DedupedHeader (Get-SetHeader $cloudContent)
# Scan the FULL local backup content for keywords (not just the header)
# so any keywords MSE2 appended after the card section are captured too.
$cloudKeywords = Get-KeywordMap $cloudContent
$localKeywords = Get-KeywordMap $localContent

Write-Host "[Merge] Cloud keywords: $($cloudKeywords.Count)" -ForegroundColor DarkGray
foreach ($kw in $cloudKeywords.Keys) {
    $rem = ""
    if ($cloudKeywords[$kw] -match "\treminder:\s+(.+)") { $rem = $matches[1].Trim().Substring(0,[Math]::Min(50,$matches[1].Trim().Length)) }
    Write-Host "  cloud kw: '$kw' reminder='$rem'" -ForegroundColor DarkGray
}
Write-Host "[Merge] Local keywords: $($localKeywords.Count)" -ForegroundColor DarkGray
foreach ($kw in $localKeywords.Keys) {
    $rem = ""
    if ($localKeywords[$kw] -match "\treminder:\s+(.+)") { $rem = $matches[1].Trim().Substring(0,[Math]::Min(50,$matches[1].Trim().Length)) }
    Write-Host "  local kw: '$kw' reminder='$rem'" -ForegroundColor DarkGray
}

# Build final keyword set: start with cloud, overlay local
$finalKeywords = [ordered]@{}
foreach ($kw in $cloudKeywords.Keys) {
    $finalKeywords[$kw] = $cloudKeywords[$kw]
}
foreach ($kw in $localKeywords.Keys) {
    if ($finalKeywords.Contains($kw)) {
        # Local version wins (preserves user edits to reminder text etc.)
        $finalKeywords[$kw] = $localKeywords[$kw]
        Write-Host "[Merge] Keyword '$kw': local wins" -ForegroundColor DarkGray
    } else {
        # New local keyword - add it
        $finalKeywords[$kw] = $localKeywords[$kw]
        Write-Host "[Merge] New local keyword preserved: '$kw'" -ForegroundColor Cyan
    }
}
Write-Host "[Merge] Final keywords: $($finalKeywords.Count) total" -ForegroundColor DarkGray

# Build the pre-card header WITHOUT any keywords, then append merged keywords
$cloudHeaderNoKw = ($cloudHeader -split "(?m)^(?=keyword:)")[0]
$mergedKwText = ($finalKeywords.Values | Where-Object { $_ }) -join ""
Write-Host "[Merge] Merged result: $mergedCardCount cards." -ForegroundColor DarkGray

# Write updated tombstone (git-committed so all users see it)
# Note: if skipTombstone fired, the tombstone set is unchanged from what was read from disk
Set-Content $tombstoneFile -Value (($tombstone | Sort-Object) -join "`n") -Encoding UTF8

# Bug #4 fix: tighten sanitization - only strip trailing metadata blocks that
# appear AFTER all tab-indented content ends, not mid-card version_control: fields.
# The previous regex could truncate cards that have version_control as a field.
$rawCardText = $mergedCards -join ""
# Only strip blocks that start at column 0 (no leading tab) - these are file-level
# metadata, not card fields (which are always tab-indented)
$cleanParts = $rawCardText -split "(?m)^(?=keyword:|version_control:|apprentice_code:)"
$cleanCardText = ($cleanParts | Where-Object { $_ -ne "" -and $_ -notmatch "^(keyword|version_control|apprentice_code):" }) -join ""

$mergedContent = $cloudHeaderNoKw + $mergedKwText + $cleanCardText

# ===========================================================================
# SAFETY CHECK 2: Never write an empty set when the cloud had cards.
# If every card was somehow stripped from the merge result, abort here.
# The cloud file is left exactly as-is so cards are not destroyed.
# ===========================================================================
$cloudCardCount = $cloudMap.Count
$mergedCardCount = $mergedCards.Count
if ($mergedCardCount -eq 0 -and ($cloudCardCount -gt 0 -or $lastKnown.Count -gt 0)) {
    Write-Host "" -ForegroundColor Red
    Write-Host "============================================================" -ForegroundColor Red
    Write-Host " SAFETY ABORT: Merge would delete ALL $cloudCardCount cards!" -ForegroundColor Red
    Write-Host " Cloud file left unchanged. Please sync again or run" -ForegroundColor Red
    Write-Host " RecoverSet.ps1 if cards are missing from the cloud." -ForegroundColor Red
    Write-Host "============================================================" -ForegroundColor Red
    Write-Host "" -ForegroundColor Red
    return
}

Write-Host "[Merge] Merged result: $mergedCardCount cards." -ForegroundColor DarkGray

# Save initial last_known hashes (SyncNow.ps1 overwrites this after FillCreators runs)
Save-LastKnown -SetFilePath $CloudFile -KnownFile $lastKnownFile

# Write updated tombstone (git-committed so all users see it)
# Note: if skipTombstone fired, the tombstone set is unchanged from what was read from disk
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

    # CLOUD images first - these are the authoritative source.
    # Image filenames (image1.png, image2.png...) are tied to card positions in
    # the set file. The cloud is the shared truth, so cloud images always win.
    # If we took local images first, a local image1.png (pointing to a different
    # card slot) would overwrite the cloud's image1.png and swap art between cards.
    foreach ($entry in ($cloudZip.Entries | Where-Object { $_.Name -ne "set" })) {
        $dst = $dstZip.CreateEntry($entry.FullName, [System.IO.Compression.CompressionLevel]::Optimal)
        $s = $entry.Open()
        $d = $dst.Open()
        $s.CopyTo($d)
        $s.Dispose()
        $d.Dispose()
        $written.Add($entry.FullName) | Out-Null
    }

    # Local images only for filenames NOT in the cloud (brand-new cards the user
    # just created that haven't been pushed to cloud yet).
    foreach ($entry in ($localZip.Entries | Where-Object { $_.Name -ne "set" })) {
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

    # Bug #2 fix: Save last_known AFTER the merged zip is written to disk.
    # Previously this was saved from the pre-merge cloud file (wrong baseline).
    # Now it reflects the actual merged result so next sync's change-detection is accurate.
    Save-LastKnown -SetFilePath $CloudFile -KnownFile $lastKnownFile
}
catch {
    Write-Host "[Merge] Failed: $_" -ForegroundColor Red
}
finally {
    if (Test-Path $tempZipPath) { Remove-Item $tempZipPath -Force -ErrorAction SilentlyContinue }
}
