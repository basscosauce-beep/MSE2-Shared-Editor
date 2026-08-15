
# ===========================================================================
# DedupManager.ps1  -  Delete Duplicates shared helpers
# Uses ConvertTo-Json / ConvertFrom-Json (avoids JavaScriptSerializer circular
# reference error with PSParameterizedProperty objects).
# ===========================================================================

Add-Type -AssemblyName System.IO.Compression.FileSystem

# ---------------------------------------------------------------------------
# Find all duplicate groups in the set text.
# Returns array of @{ TC; KeeperName; KeeperCreator; KeeperModified;
#                      KeeperBlock; Dupes=@(@{Name;Creator;TimeModified;Block;TC}) }
# Keeper = most recently time_modified copy.
# ---------------------------------------------------------------------------
function Find-DuplicateGroups([string]$setContent) {
    $groups = @()
    $cards  = $setContent -split "(?m)^(?=card:)" | Where-Object { $_ -match "^card:" }

    $byTc = @{}
    foreach ($c in $cards) {
        $tc = if ($c -match "(?m)^\s*time_created:\s*([^\r\n]+)") { $matches[1].Trim() } else { $null }
        if (-not $tc) { continue }
        if (-not $byTc.ContainsKey($tc)) { $byTc[$tc] = [System.Collections.Generic.List[string]]::new() }
        $byTc[$tc].Add($c)
    }

    foreach ($tc in $byTc.Keys) {
        if ($byTc[$tc].Count -lt 2) { continue }

        $sorted = $byTc[$tc] | Sort-Object {
            if ($_ -match "(?m)^\s*time_modified:\s*([^\r\n]+)") { $matches[1].Trim() } else { "" }
        } -Descending

        $keeper = @($sorted)[0]
        $dupes  = @($sorted) | Select-Object -Skip 1

        $kName    = if ($keeper -match "(?m)^\s*name:\s*([^\r\n]+)")     { $matches[1].Trim() } else { "(unnamed)" }
        $kCreator = if ($keeper -match "(?m)^\s*creator:\s*([^\r\n]+)")  { $matches[1].Trim() } else { "" }
        $kMod     = if ($keeper -match "(?m)^\s*time_modified:\s*([^\r\n]+)") { $matches[1].Trim() } else { "" }
        $kImg     = if ($keeper -match "(?m)^\s*image:\s*([^\r\n]+)")    { $matches[1].Trim() } else { "" }

        $dupeInfos = foreach ($d in $dupes) {
            $dName    = if ($d -match "(?m)^\s*name:\s*([^\r\n]+)")     { $matches[1].Trim() } else { "(unnamed)" }
            $dCreator = if ($d -match "(?m)^\s*creator:\s*([^\r\n]+)")  { $matches[1].Trim() } else { "" }
            $dMod     = if ($d -match "(?m)^\s*time_modified:\s*([^\r\n]+)") { $matches[1].Trim() } else { "" }
            $dImg     = if ($d -match "(?m)^\s*image:\s*([^\r\n]+)")    { $matches[1].Trim() } else { "" }
            @{ Name=$dName; Creator=$dCreator; TimeModified=$dMod; ImageFile=$dImg; Block=$d; TC=$tc }
        }

        $groups += @{
            TC             = $tc
            KeeperName     = $kName
            KeeperCreator  = $kCreator
            KeeperModified = $kMod
            KeeperImageFile= $kImg
            KeeperBlock    = $keeper
            Dupes          = $dupeInfos
        }
    }
    return $groups
}

# ---------------------------------------------------------------------------
# Write pending_dedup.json using ConvertTo-Json (no circular refs)
# ---------------------------------------------------------------------------
function Write-PendingDedup([string]$setDir, [string]$initiatedBy, $groups) {
    $groupData = [System.Collections.Generic.List[object]]::new()
    foreach ($g in $groups) {
        $dupeList = [System.Collections.Generic.List[object]]::new()
        foreach ($d in $g.Dupes) {
            $dupeList.Add([ordered]@{
                name          = [string]$d.Name
                creator       = [string]$d.Creator
                time_modified = [string]$d.TimeModified
            })
        }
        $groupData.Add([ordered]@{
            tc              = [string]$g.TC
            keeper_name     = [string]$g.KeeperName
            keeper_creator  = [string]$g.KeeperCreator
            keeper_modified = [string]$g.KeeperModified
            dupes           = $dupeList
        })
    }

    $data = [ordered]@{
        initiated_by    = [string]$initiatedBy
        initiated_at    = (Get-Date -Format "o")
        status          = "pending_approval"
        syncs_remaining = 3
        groups          = $groupData
        votes           = [ordered]@{ $initiatedBy = "yes" }
    }

    $data | ConvertTo-Json -Depth 10 -Compress |
        Set-Content -Path "$setDir\pending_dedup.json" -Encoding UTF8 -Force
}

# ---------------------------------------------------------------------------
# Read pending_dedup.json - returns $null if not found
# ---------------------------------------------------------------------------
function Read-PendingDedup([string]$setDir) {
    $path = "$setDir\pending_dedup.json"
    if (-not (Test-Path $path)) { return $null }
    try { return (Get-Content $path -Raw -Encoding UTF8) | ConvertFrom-Json }
    catch { return $null }
}

# ---------------------------------------------------------------------------
# Record a vote ("yes" | "no") in pending_dedup.json
# ---------------------------------------------------------------------------
function Set-DedupVote([string]$setDir, [string]$userName, [string]$vote) {
    $dedup = Read-PendingDedup $setDir
    if (-not $dedup) { return }

    # ConvertFrom-Json gives PSCustomObject; add-member to mutate
    $votes = $dedup.votes
    if (-not $votes) {
        $dedup | Add-Member -MemberType NoteProperty -Name "votes" -Value ([pscustomobject]@{}) -Force
        $votes = $dedup.votes
    }
    $votes | Add-Member -MemberType NoteProperty -Name $userName -Value $vote -Force

    if ($vote -eq "no") {
        $dedup | Add-Member -MemberType NoteProperty -Name "status" -Value "cancelled" -Force
    }

    $dedup | ConvertTo-Json -Depth 10 -Compress |
        Set-Content -Path "$setDir\pending_dedup.json" -Encoding UTF8 -Force
}

# ---------------------------------------------------------------------------
# Apply pending dedup during sync (called from SyncNow.ps1).
# Strips duplicate cards, vaults removed blocks, decrements counter.
# Returns $true if the set was modified.
# ---------------------------------------------------------------------------
function Apply-PendingDedup([string]$setFilePath, [string]$setDir, [string]$vaultDir) {
    $dedup = Read-PendingDedup $setDir
    if (-not $dedup) { return $false }

    $status = $dedup.status

    if ($status -eq "cancelled") {
        Remove-Item "$setDir\pending_dedup.json" -Force -ErrorAction SilentlyContinue
        Write-Host "[Dedup] Pending dedup was cancelled. No cards removed." -ForegroundColor Yellow
        return $false
    }
    if ($status -eq "done") { return $false }

    $remaining = [int]$dedup.syncs_remaining - 1
    $dedup | Add-Member -MemberType NoteProperty -Name "syncs_remaining" -Value $remaining -Force

    if ($remaining -gt 0) {
        $dedup | ConvertTo-Json -Depth 10 -Compress |
            Set-Content -Path "$setDir\pending_dedup.json" -Encoding UTF8 -Force
        Write-Host "[Dedup] Pending dedup: $remaining sync(s) until purge." -ForegroundColor DarkGray
        return $false
    }

    # Time to purge
    Write-Host "[Dedup] Applying dedup - removing duplicate cards..." -ForegroundColor Yellow

    $z   = [System.IO.Compression.ZipFile]::OpenRead($setFilePath)
    $ent = $z.Entries | Where-Object { $_.Name -eq "set" } | Select-Object -First 1
    $sr  = New-Object System.IO.StreamReader($ent.Open(), [System.Text.Encoding]::UTF8)
    $txt = $sr.ReadToEnd(); $sr.Dispose()

    $parts  = $txt -split "(?m)^(?=card:)"
    $header = $parts[0]
    $cards  = $parts | Where-Object { $_ -match "^card:" }

    # Build set of time_created values targeted for dedup
    $dedupTCs = New-Object System.Collections.Generic.HashSet[string]
    foreach ($g in $dedup.groups) { $dedupTCs.Add($g.tc) | Out-Null }

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

    # Vault removed cards locally (not in git)
    if ($removed.Count -gt 0) {
        if (-not (Test-Path $vaultDir)) { New-Item -ItemType Directory -Path $vaultDir -Force | Out-Null }
        $stamp     = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
        $vaultFile = "$vaultDir\dedup_vault_$stamp.txt"
        $removed -join "`n---CARD-SEPARATOR---`n" | Set-Content -Path $vaultFile -Encoding UTF8 -Force
        Write-Host "[Dedup] Vaulted $($removed.Count) card(s) to: $vaultFile" -ForegroundColor DarkGray
        # Clean up vault files older than 30 days
        Get-ChildItem $vaultDir -Filter "dedup_vault_*.txt" |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }

    $newTxt = $header + ($kept -join "")

    # Write back to zip
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
    Write-Host "[Dedup] Removed $($removed.Count) duplicate(s). Set now has $($kept.Count) cards." -ForegroundColor Green

    $dedup | Add-Member -MemberType NoteProperty -Name "status" -Value "done" -Force
    Remove-Item "$setDir\pending_dedup.json" -Force -ErrorAction SilentlyContinue
    return $true
}
