
# ===========================================================================
# DedupManager.ps1
# Handles all logic for the Delete Duplicates feature:
#   - Finding duplicate cards in the set
#   - Writing/reading pending_dedup.json
#   - Applying dedup during sync (stripping dupes, saving vault)
#   - Vote recording
# ===========================================================================

Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.Web.Extensions

# ---------------------------------------------------------------------------
# Find all duplicate groups in the set text.
# Returns array of @{ Keeper=block; Dupes=@(block,...) }
# Keeper = most recently time_modified copy.
# ---------------------------------------------------------------------------
function Find-DuplicateGroups([string]$setContent) {
    $groups = @()
    $cards  = $setContent -split "(?m)^(?=card:)" | Where-Object { $_ -match "^card:" }

    # Group cards by time_created
    $byTc = @{}
    foreach ($c in $cards) {
        $tc = if ($c -match "(?m)^\s*time_created:\s*([^\r\n]+)") { $matches[1].Trim() } else { $null }
        if (-not $tc) { continue }
        if (-not $byTc.ContainsKey($tc)) { $byTc[$tc] = [System.Collections.Generic.List[string]]::new() }
        $byTc[$tc].Add($c)
    }

    foreach ($tc in $byTc.Keys) {
        if ($byTc[$tc].Count -lt 2) { continue }

        # Pick keeper: most recently time_modified
        $sorted = $byTc[$tc] | Sort-Object {
            $tm = if ($_ -match "(?m)^\s*time_modified:\s*([^\r\n]+)") { $matches[1].Trim() } else { "" }
            $tm
        } -Descending

        $keeper = @($sorted)[0]
        $dupes  = @($sorted) | Select-Object -Skip 1

        $kName = if ($keeper -match "(?m)^\s*name:\s*([^\r\n]+)") { $matches[1].Trim() } else { "(unnamed)" }
        $kCreator = if ($keeper -match "(?m)^\s*creator:\s*([^\r\n]+)") { $matches[1].Trim() } else { "" }
        $kMod = if ($keeper -match "(?m)^\s*time_modified:\s*([^\r\n]+)") { $matches[1].Trim() } else { "" }

        $dupeInfos = foreach ($d in $dupes) {
            $dName    = if ($d -match "(?m)^\s*name:\s*([^\r\n]+)") { $matches[1].Trim() } else { "(unnamed)" }
            $dCreator = if ($d -match "(?m)^\s*creator:\s*([^\r\n]+)") { $matches[1].Trim() } else { "" }
            $dMod     = if ($d -match "(?m)^\s*time_modified:\s*([^\r\n]+)") { $matches[1].Trim() } else { "" }
            @{ Name=$dName; Creator=$dCreator; TimeModified=$dMod; Block=$d; TC=$tc }
        }

        $groups += @{
            TC             = $tc
            KeeperName     = $kName
            KeeperCreator  = $kCreator
            KeeperModified = $kMod
            KeeperBlock    = $keeper
            Dupes          = $dupeInfos
        }
    }
    return $groups
}

# ---------------------------------------------------------------------------
# Write pending_dedup.json to the set directory
# ---------------------------------------------------------------------------
function Write-PendingDedup([string]$setDir, [string]$initiatedBy, $groups) {
    $jsSer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $jsSer.MaxJsonLength = 20MB

    $groupData = foreach ($g in $groups) {
        @{
            tc             = $g.TC
            keeper_name    = $g.KeeperName
            keeper_creator = $g.KeeperCreator
            keeper_modified= $g.KeeperModified
            dupes          = @($g.Dupes | ForEach-Object { @{
                name         = $_.Name
                creator      = $_.Creator
                time_modified= $_.TimeModified
            }})
        }
    }

    $data = @{
        initiated_by    = $initiatedBy
        initiated_at    = (Get-Date -Format "o")
        status          = "pending_approval"
        syncs_remaining = 3
        groups          = @($groupData)
        votes           = @{ $initiatedBy = "yes" }
    }

    $json = $jsSer.Serialize($data)
    Set-Content -Path "$setDir\pending_dedup.json" -Value $json -Encoding UTF8 -Force
}

# ---------------------------------------------------------------------------
# Read pending_dedup.json — returns $null if not found
# ---------------------------------------------------------------------------
function Read-PendingDedup([string]$setDir) {
    $path = "$setDir\pending_dedup.json"
    if (-not (Test-Path $path)) { return $null }
    try {
        $jsSer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $jsSer.MaxJsonLength = 20MB
        return $jsSer.DeserializeObject((Get-Content $path -Raw))
    } catch { return $null }
}

# ---------------------------------------------------------------------------
# Record a vote in pending_dedup.json
# vote = "yes" | "no"
# ---------------------------------------------------------------------------
function Set-DedupVote([string]$setDir, [string]$userName, [string]$vote) {
    $dedup = Read-PendingDedup $setDir
    if (-not $dedup) { return }

    if (-not $dedup.ContainsKey("votes")) { $dedup["votes"] = @{} }
    $dedup["votes"][$userName] = $vote

    if ($vote -eq "no") {
        $dedup["status"] = "cancelled"
    }

    $jsSer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $jsSer.MaxJsonLength = 20MB
    Set-Content -Path "$setDir\pending_dedup.json" -Value ($jsSer.Serialize($dedup)) -Encoding UTF8 -Force
}

# ---------------------------------------------------------------------------
# Apply dedup to a set file during sync.
# - Strips duplicate cards (keeps first occurrence of each time_created)
# - Saves removed cards to the local vault
# - Decrements syncs_remaining; removes json when done
# Returns $true if the set was modified.
# ---------------------------------------------------------------------------
function Apply-PendingDedup([string]$setFilePath, [string]$setDir, [string]$vaultDir) {
    $dedup = Read-PendingDedup $setDir
    if (-not $dedup) { return $false }

    $status = $dedup["status"]

    # Cancelled: just clean up the json, don't touch the set
    if ($status -eq "cancelled") {
        Remove-Item "$setDir\pending_dedup.json" -Force -ErrorAction SilentlyContinue
        Write-Host "[Dedup] Pending dedup was cancelled. No cards removed." -ForegroundColor Yellow
        return $false
    }

    # Only act if approved/pending (any non-cancelled, non-done status)
    if ($status -eq "done") { return $false }

    # Decrement sync counter
    $remaining = [int]$dedup["syncs_remaining"] - 1
    $dedup["syncs_remaining"] = $remaining

    if ($remaining -gt 0) {
        # Not time to purge yet — save updated counter and move on
        $jsSer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $jsSer.MaxJsonLength = 20MB
        Set-Content -Path "$setDir\pending_dedup.json" -Value ($jsSer.Serialize($dedup)) -Encoding UTF8 -Force
        Write-Host "[Dedup] Pending dedup: $remaining sync(s) until purge." -ForegroundColor DarkGray
        return $false
    }

    # Time to purge! Strip duplicates from the set file.
    Write-Host "[Dedup] Applying dedup: removing duplicate cards..." -ForegroundColor Yellow

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Add-Type -AssemblyName System.IO.Compression

    $z   = [System.IO.Compression.ZipFile]::OpenRead($setFilePath)
    $ent = $z.Entries | Where-Object { $_.Name -eq "set" } | Select-Object -First 1
    $sr  = New-Object System.IO.StreamReader($ent.Open(), [System.Text.Encoding]::UTF8)
    $txt = $sr.ReadToEnd(); $sr.Dispose()

    $parts  = $txt -split "(?m)^(?=card:)"
    $header = $parts[0]
    $cards  = $parts | Where-Object { $_ -match "^card:" }

    # Build set of time_created values we want to dedup
    $dedupTCs = New-Object System.Collections.Generic.HashSet[string]
    foreach ($g in $dedup["groups"]) { $dedupTCs.Add($g["tc"]) | Out-Null }

    # Keep first occurrence of each TC; vault the rest
    $seen    = New-Object System.Collections.Generic.HashSet[string]
    $removed = [System.Collections.Generic.List[string]]::new()
    $kept    = [System.Collections.Generic.List[string]]::new()

    foreach ($c in $cards) {
        $tc = if ($c -match "(?m)^\s*time_created:\s*([^\r\n]+)") { $matches[1].Trim() } else { $null }
        if ($tc -and $dedupTCs.Contains($tc) -and -not $seen.Add($tc)) {
            $removed.Add($c)
        } else {
            $kept.Add($c)
        }
    }

    # Save removed cards to vault
    if ($removed.Count -gt 0) {
        if (-not (Test-Path $vaultDir)) { New-Item -ItemType Directory -Path $vaultDir -Force | Out-Null }
        $stamp    = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
        $vaultFile = "$vaultDir\dedup_vault_$stamp.txt"
        Set-Content -Path $vaultFile -Value ($removed -join "`n---CARD-SEPARATOR---`n") -Encoding UTF8 -Force
        Write-Host "[Dedup] Vaulted $($removed.Count) removed card(s) to: $vaultFile" -ForegroundColor DarkGray

        # Clean up vault files older than 30 days
        Get-ChildItem $vaultDir -Filter "dedup_vault_*.txt" |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }

    $newTxt = $header + ($kept -join "")

    # Write back to zip (image entries unchanged)
    $tmp = [System.IO.Path]::GetTempFileName() + ".mse-set"
    $src = [System.IO.Compression.ZipFile]::OpenRead($setFilePath)
    $dst = [System.IO.Compression.ZipFile]::Open($tmp, [System.IO.Compression.ZipArchiveMode]::Create)
    $se  = $dst.CreateEntry("set", [System.IO.Compression.CompressionLevel]::Optimal)
    $sw  = New-Object System.IO.StreamWriter($se.Open(), [System.Text.Encoding]::UTF8)
    $sw.Write($newTxt); $sw.Flush(); $sw.Dispose()
    foreach ($img in ($src.Entries | Where-Object { $_.Name -ne "set" })) {
        $de = $dst.CreateEntry($img.FullName, [System.IO.Compression.CompressionLevel]::Optimal)
        $s = $img.Open(); $d = $de.Open(); $s.CopyTo($d); $s.Dispose(); $d.Dispose()
    }
    $src.Dispose(); $dst.Dispose()
    Copy-Item $tmp $setFilePath -Force
    Remove-Item $tmp -Force

    Write-Host "[Dedup] Removed $($removed.Count) duplicate card(s). Set now has $($kept.Count) cards." -ForegroundColor Green

    # Mark done and clean up
    $dedup["status"] = "done"
    Remove-Item "$setDir\pending_dedup.json" -Force -ErrorAction SilentlyContinue

    return $true
}
