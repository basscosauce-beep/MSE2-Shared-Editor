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
    # Find the first card: block - could be at position 0 or after a newline
    $idx = $content.IndexOf("`ncard:")
    if ($idx -ge 0) { return $content.Substring(0, $idx + 1) }
    # card: starts at the very beginning of the file (no preceding newline)
    if ($content.StartsWith("card:")) { return "" }
    return $content
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
            # Content differs - use time_modified to determine who edited more recently.
            # This is simpler and more reliable than hash comparison:
            #   - Hash comparison breaks when MSE2 reformats text on save (false "both changed")
            #   - time_modified is set by MSE2 whenever a user actually edits a card
            #   - Format is "YYYY-MM-DD HH:MM:SS" which is lexicographically sortable
            $cardName  = Get-CardName $localCard $tc
            $localTM   = if ($localCard  -match "(?m)^\s*time_modified:\s*([^\r\n]+)") { $matches[1].Trim() } else { "" }
            $cloudTM   = if ($cloudCard  -match "(?m)^\s*time_modified:\s*([^\r\n]+)") { $matches[1].Trim() } else { "" }

            if ([string]::Compare($localTM, $cloudTM, [System.StringComparison]::Ordinal) -ge 0) {
                # Local is same age or newer -> local wins
                $mergedCards.Add($localCard) | Out-Null
                if ($localTM -ne $cloudTM) {
                    Write-Host "[Merge] Your edit wins ($localTM > $cloudTM): $cardName" -ForegroundColor Cyan
                }
            }
            else {
                # Cloud is strictly newer -> cloud wins
                $mergedCards.Add($cloudCard) | Out-Null
                Write-Host "[Merge] Friend's edit wins ($cloudTM > $localTM): $cardName" -ForegroundColor DarkCyan
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
Write-Host "[Merge] Merged result: $($mergedCards.Count) cards." -ForegroundColor DarkGray

# ===========================================================================
# SAFETY: Deduplicate merged cards by time_created before assembling output.
# Guards against any upstream path that inserted a card twice.
# ===========================================================================
$seenKeys = New-Object System.Collections.Generic.HashSet[string]
$dedupedCards = New-Object System.Collections.Generic.List[string]
foreach ($c in $mergedCards) {
    $key = if ($c -match "(?m)^\ttime_created: ([^\r\n]+)") { $matches[1].Trim() } else { "_notime_$($dedupedCards.Count)" }
    if ($seenKeys.Add($key)) { $dedupedCards.Add($c) | Out-Null }
}
if ($dedupedCards.Count -ne $mergedCards.Count) {
    Write-Host "[Merge] Deduplicated: removed $($mergedCards.Count - $dedupedCards.Count) duplicate card(s)." -ForegroundColor Yellow
    $mergedCards = $dedupedCards
}

$rawCardText   = $mergedCards -join ""
$cleanParts    = $rawCardText -split "(?m)^(?=keyword:|version_control:|apprentice_code:)"
$cleanCardText = ($cleanParts | Where-Object { $_ -ne "" -and $_ -notmatch "^(keyword|version_control|apprentice_code):" }) -join ""

# Bug 3 fix: preserve the version_control: and apprentice_code: trailing blocks
# that MSE2 appends at the very end of the set file (after all cards).
# Strategy: find the position of the last "card:" in cloudContent, take everything
# after that card block ends (i.e. past the first top-level non-card block boundary),
# and filter for version_control:/apprentice_code: entries only.
# This avoids false positives from any card whose body text contains these keywords.
$trailingMetaBlocks = ""
$lastCardPos = $cloudContent.LastIndexOf("`ncard:")
if ($lastCardPos -ge 0) {
    $afterLastCard = $cloudContent.Substring($lastCardPos)
    # Find where the trailing metadata starts (first top-level keyword:/version_control:/apprentice_code:)
    $trailMatch = [regex]::Match($afterLastCard, "(?m)^(version_control:|apprentice_code:)", [System.Text.RegularExpressions.RegexOptions]::Multiline)
    if ($trailMatch.Success) {
        $trailingMetaBlocks = $afterLastCard.Substring($trailMatch.Index)
    }
}

$mergedContent = $cloudHeaderNoKw + $mergedKwText + $cleanCardText + $trailingMetaBlocks

# ===========================================================================
# Temp-file swap: write merged zip without touching the live file
# ===========================================================================
$tempZipPath = [System.IO.Path]::GetTempFileName() + ".mse-set"

try {

# ===========================================================================
# IMAGE HANDLING
# ===========================================================================
# For each card in the merged result we know exactly which zip its TEXT came from
# (local backup vs cloud). Images must come from the SAME source as the card text
# so they stay in sync.
#
# Source rules (mirrors the merge pass):
#   Local-only card  → local zip
#   Cloud-only card  → cloud zip
#   Shared card      → whichever had the newer time_modified (local wins on tie)
#
# Collision: two cards from DIFFERENT sources reference the same image filename.
# We rename the local-source card's reference so the zip stays consistent.
# ===========================================================================

# Helper: extract all image field values from a card block
function Get-CardImageFiles {
    param([string]$cardText)
    $imgs = @()
    $cardText -split "\r?\n" | ForEach-Object {
        if ($_ -match '^\s*(?:image|image_2|mainframe_image|mainframe_image_2)\s*:\s*(\S+\.(?:png|jpg|jpeg|gif|bmp|tif|tiff))') {
            $imgs += $matches[1].Trim()
        }
    }
    return $imgs
}

# -- Step 1: determine which zip each merged card's images come from ----------
$cardSource = @{}   # time_created -> "local" | "cloud"
foreach ($card in $mergedCards) {
    $tc = if ($card -match "(?m)^\s*time_created:\s*([^\r\n]+)") { $matches[1].Trim() } else { $null }
    if (-not $tc) { continue }
    if (-not $cloudMap.Contains($tc)) {
        $cardSource[$tc] = "local"        # local-only new card
    } elseif (-not $localMap.Contains($tc)) {
        $cardSource[$tc] = "cloud"        # cloud-only new card
    } else {
        # Shared card — same time_modified comparison used in the merge pass
        $lTM = if ($localMap[$tc] -match "(?m)^\s*time_modified:\s*([^\r\n]+)") { $matches[1].Trim() } else { "" }
        $cTM = if ($cloudMap[$tc] -match "(?m)^\s*time_modified:\s*([^\r\n]+)") { $matches[1].Trim() } else { "" }
        $cardSource[$tc] = if ([string]::Compare($lTM, $cTM, [System.StringComparison]::Ordinal) -ge 0) { "local" } else { "cloud" }
    }
}

# -- Step 2: build imgFile -> list of {TC, Source} assignments ----------------
$imgAssign = @{}   # imgFile -> List of @{TC; Source}
foreach ($card in $mergedCards) {
    $tc = if ($card -match "(?m)^\s*time_created:\s*([^\r\n]+)") { $matches[1].Trim() } else { $null }
    if (-not $tc -or -not $cardSource.ContainsKey($tc)) { continue }
    $src = $cardSource[$tc]
    foreach ($img in (Get-CardImageFiles $card)) {
        if (-not $imgAssign.ContainsKey($img)) { $imgAssign[$img] = [System.Collections.Generic.List[hashtable]]::new() }
        $imgAssign[$img].Add(@{TC=$tc; Source=$src})
    }
}

# -- Step 3: open zips --------------------------------------------------------
$cloudZip = [System.IO.Compression.ZipFile]::OpenRead($CloudFile)
$localZip = [System.IO.Compression.ZipFile]::OpenRead($LocalBackup)
$dstZip   = [System.IO.Compression.ZipFile]::Open($tempZipPath, [System.IO.Compression.ZipArchiveMode]::Create)

$cloudImageMap = @{}
$localImageMap  = @{}
foreach ($entry in ($cloudZip.Entries | Where-Object { $_.Name -ne "set" })) { $cloudImageMap[$entry.FullName] = $entry }
foreach ($entry in ($localZip.Entries  | Where-Object { $_.Name -ne "set" })) { $localImageMap[$entry.FullName]  = $entry }

# -- Step 4: detect genuine collisions and rename local-source refs -----------
# A collision is when the SAME filename is needed by BOTH a cloud-source card
# AND a local-source card (they carry different image bytes for the same name).
$cardTextRenames = @{}   # tc -> @{ oldName -> newName }
$allUsedNames = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
foreach ($k in $cloudImageMap.Keys) { $allUsedNames.Add($k) | Out-Null }
foreach ($k in $localImageMap.Keys)  { $allUsedNames.Add($k) | Out-Null }

foreach ($imgName in @($imgAssign.Keys)) {
    $assignments = $imgAssign[$imgName]
    $hasCloud = ($assignments | Where-Object { $_.Source -eq "cloud" }).Count -gt 0
    $hasLocal = ($assignments | Where-Object { $_.Source -eq "local" }).Count -gt 0
    if (-not ($hasCloud -and $hasLocal)) { continue }   # no collision

    # Rename all local-source cards that reference this image
    foreach ($a in ($assignments | Where-Object { $_.Source -eq "local" })) {
        $tc = $a.TC
        $base = [System.IO.Path]::GetFileNameWithoutExtension($imgName)
        $ext  = [System.IO.Path]::GetExtension($imgName)
        $counter = 1
        do { $newName = "${base}_m${counter}${ext}"; $counter++ } while ($allUsedNames.Contains($newName))
        $allUsedNames.Add($newName) | Out-Null
        if (-not $cardTextRenames.ContainsKey($tc)) { $cardTextRenames[$tc] = @{} }
        $cardTextRenames[$tc][$imgName] = $newName
        Write-Host "[Merge] Image collision '$imgName' — local card ($tc) renamed to '$newName'" -ForegroundColor Yellow
    }
}

# -- Step 5: apply renames to card text and rebuild mergedContent -------------
if ($cardTextRenames.Count -gt 0) {
    $updatedCards = [System.Collections.Generic.List[string]]::new()
    foreach ($card in $mergedCards) {
        $tc = if ($card -match "(?m)^\s*time_created:\s*([^\r\n]+)") { $matches[1].Trim() } else { $null }
        if ($tc -and $cardTextRenames.ContainsKey($tc)) {
            foreach ($rename in $cardTextRenames[$tc].GetEnumerator()) {
                $card = $card -replace "(?m)^(\s*(?:image|image_2|mainframe_image|mainframe_image_2)\s*:\s*)$([regex]::Escape($rename.Key))", "`${1}$($rename.Value)"
            }
        }
        $updatedCards.Add($card)
    }
    $mergedCards = $updatedCards
    # Rebuild image assignments after renames
    $imgAssign = @{}
    foreach ($card in $mergedCards) {
        $tc = if ($card -match "(?m)^\s*time_created:\s*([^\r\n]+)") { $matches[1].Trim() } else { $null }
        if (-not $tc -or -not $cardSource.ContainsKey($tc)) { continue }
        $src = $cardSource[$tc]
        foreach ($img in (Get-CardImageFiles $card)) {
            if (-not $imgAssign.ContainsKey($img)) { $imgAssign[$img] = [System.Collections.Generic.List[hashtable]]::new() }
            $imgAssign[$img].Add(@{TC=$tc; Source=$src})
        }
    }
    # Rebuild mergedContent
    $rawCardText   = $mergedCards -join ""
    $cleanParts    = $rawCardText -split "(?m)^(?=keyword:|version_control:|apprentice_code:)"
    $cleanCardText = ($cleanParts | Where-Object { $_ -ne "" -and $_ -notmatch "^(keyword|version_control|apprentice_code):" }) -join ""
    $mergedContent = $cloudHeaderNoKw + $mergedKwText + $cleanCardText + $trailingMetaBlocks
    Write-Host "[Merge] Applied $($cardTextRenames.Count) image rename(s) to card text." -ForegroundColor Yellow
}

# -- Step 6: write "set" text entry -------------------------------------------
$setEntry  = $dstZip.CreateEntry("set", [System.IO.Compression.CompressionLevel]::Optimal)
$setStream = $setEntry.Open()
$writer    = New-Object System.IO.StreamWriter($setStream, [System.Text.Encoding]::UTF8)
$writer.Write($mergedContent)
$writer.Flush()
$writer.Dispose()

# -- Step 7: write image files from correct source zip ------------------------
$writtenNames = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)

# Write images that are referenced by cards in the merged set
foreach ($imgName in $imgAssign.Keys) {
    if ($writtenNames.Contains($imgName)) { continue }
    $assignments = $imgAssign[$imgName]
    # Source: if any card wants cloud bytes, use cloud (means cloud-only or cloud-winner card)
    # If ALL cards want local bytes, use local
    $useCloud = ($assignments | Where-Object { $_.Source -eq "cloud" }).Count -gt 0
    $srcMap = if ($useCloud) { $cloudImageMap } else { $localImageMap }
    $altMap = if ($useCloud) { $localImageMap  } else { $cloudImageMap  }
    $entry  = if ($srcMap.ContainsKey($imgName)) { $srcMap[$imgName] } elseif ($altMap.ContainsKey($imgName)) { $altMap[$imgName] } else { $null }
    if ($entry) {
        $dst = $dstZip.CreateEntry($imgName, [System.IO.Compression.CompressionLevel]::Optimal)
        $s = $entry.Open(); $d = $dst.Open(); $s.CopyTo($d); $s.Dispose(); $d.Dispose()
        $writtenNames.Add($imgName) | Out-Null
    }
}

# Also preserve any cloud images not referenced by any card (orphans — keep to avoid data loss)
foreach ($imgName in $cloudImageMap.Keys) {
    if (-not $writtenNames.Contains($imgName)) {
        $dst = $dstZip.CreateEntry($imgName, [System.IO.Compression.CompressionLevel]::Optimal)
        $s = $cloudImageMap[$imgName].Open(); $d = $dst.Open(); $s.CopyTo($d); $s.Dispose(); $d.Dispose()
        $writtenNames.Add($imgName) | Out-Null
    }
}
# And local images not referenced by any card (orphans from local — keep too)
foreach ($imgName in $localImageMap.Keys) {
    if (-not $writtenNames.Contains($imgName)) {
        $dst = $dstZip.CreateEntry($imgName, [System.IO.Compression.CompressionLevel]::Optimal)
        $s = $localImageMap[$imgName].Open(); $d = $dst.Open(); $s.CopyTo($d); $s.Dispose(); $d.Dispose()
        $writtenNames.Add($imgName) | Out-Null
    }
}

    $localZip.Dispose()
    $cloudZip.Dispose()
    $dstZip.Dispose()

    Copy-Item $tempZipPath $CloudFile -Force
    Write-Host "[Merge] Merge complete!" -ForegroundColor Green

    # Save last_known AFTER the merged zip is written to disk so next sync's
    # change-detection baseline reflects the actual merged result.
    Save-LastKnown -SetFilePath $CloudFile -KnownFile $lastKnownFile
}
catch {
    Write-Host "[Merge] Failed: $_" -ForegroundColor Red
}
finally {
    if (Test-Path $tempZipPath) { Remove-Item $tempZipPath -Force -ErrorAction SilentlyContinue }
}

