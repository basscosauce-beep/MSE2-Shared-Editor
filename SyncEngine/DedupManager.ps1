
# ===========================================================================
# DedupManager.ps1  -  Delete Duplicates shared helpers
# ===========================================================================

Add-Type -AssemblyName System.IO.Compression.FileSystem

# ---------------------------------------------------------------------------
# Find all duplicate groups. Returns an array of groups, each with:
#   TC          - shared time_created value
#   CardName    - display name (from first copy found)
#   AllCopies   - ALL copies sorted newest-first, each is:
#                 @{ Name; Creator; TimeModified; ImageFile; Block; SlotIndex }
#   DefaultKeepSlot - index of the most-recently-modified copy (default selection)
# ---------------------------------------------------------------------------
function Find-DuplicateGroups([string]$setContent) {
    $groups = [System.Collections.Generic.List[object]]::new()
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

        # Sort newest-first so slot 0 = most recently modified (default keep)
        $sorted = @($byTc[$tc] | Sort-Object {
            if ($_ -match "(?m)^\s*time_modified:\s*([^\r\n]+)") { $matches[1].Trim() } else { "" }
        } -Descending)

        $allCopies = [System.Collections.Generic.List[object]]::new()
        for ($i = 0; $i -lt $sorted.Count; $i++) {
            $c = $sorted[$i]
            $allCopies.Add(@{
                SlotIndex    = $i
                Name         = if ($c -match "(?m)^\s*name:\s*([^\r\n]+)")         { $matches[1].Trim() } else { "(unnamed)" }
                Creator      = if ($c -match "(?m)^\s*creator:\s*([^\r\n]+)")      { $matches[1].Trim() } else { "" }
                TimeModified = if ($c -match "(?m)^\s*time_modified:\s*([^\r\n]+)"){ $matches[1].Trim() } else { "" }
                ImageFile    = if ($c -match "(?m)^\s*image:\s*([^\r\n]+)")        { $matches[1].Trim() } else { "" }
                Block        = $c
            })
        }

        $cardName = $allCopies[0].Name

        $groups.Add(@{
            TC               = $tc
            CardName         = $cardName
            AllCopies        = $allCopies
            DefaultKeepSlot  = 0   # newest = keep by default
        })
    }
    return @($groups)
}

# ---------------------------------------------------------------------------
# Write pending_dedup.json
# groups should each have: TC, CardName, AllCopies[], ChosenKeepSlot
# ---------------------------------------------------------------------------
function Write-PendingDedup([string]$setDir, [string]$initiatedBy, $groups) {
    $groupData = [System.Collections.Generic.List[object]]::new()
    foreach ($g in $groups) {
        $copies = [System.Collections.Generic.List[object]]::new()
        foreach ($c in $g.AllCopies) {
            $copies.Add([ordered]@{
                slot          = [int]$c.SlotIndex
                name          = [string]$c.Name
                creator       = [string]$c.Creator
                time_modified = [string]$c.TimeModified
            })
        }
        $groupData.Add([ordered]@{
            tc               = [string]$g.TC
            card_name        = [string]$g.CardName
            chosen_keep_slot = [int]($g.ChosenKeepSlot)
            copies           = $copies
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
# Read pending_dedup.json
# ---------------------------------------------------------------------------
function Read-PendingDedup([string]$setDir) {
    $path = "$setDir\pending_dedup.json"
    if (-not (Test-Path $path)) { return $null }
    try { return (Get-Content $path -Raw -Encoding UTF8) | ConvertFrom-Json }
    catch { return $null }
}

# ---------------------------------------------------------------------------
# Record a vote
# ---------------------------------------------------------------------------
function Set-DedupVote([string]$setDir, [string]$userName, [string]$vote) {
    $dedup = Read-PendingDedup $setDir
    if (-not $dedup) { return }
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
# Apply pending dedup during sync.
# For each group, keeps only the copy at chosen_keep_slot; removes the rest.
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

    Write-Host "[Dedup] Applying dedup - removing duplicate cards..." -ForegroundColor Yellow

    # Build a map: tc -> chosen_keep_slot
    $keepSlotMap = @{}
    foreach ($g in $dedup.groups) {
        $keepSlotMap[$g.tc] = [int]$g.chosen_keep_slot
    }

    $z   = [System.IO.Compression.ZipFile]::OpenRead($setFilePath)
    $ent = $z.Entries | Where-Object { $_.Name -eq "set" } | Select-Object -First 1
    $sr  = New-Object System.IO.StreamReader($ent.Open(), [System.Text.Encoding]::UTF8)
    $txt = $sr.ReadToEnd(); $sr.Dispose()

    $parts  = $txt -split "(?m)^(?=card:)"
    $header = $parts[0]
    $cards  = @($parts | Where-Object { $_ -match "^card:" })

    # For each TC group: sort the copies newest-first, keep only chosen_keep_slot index
    $tcCopies = @{}
    foreach ($c in $cards) {
        $tc = if ($c -match "(?m)^\s*time_created:\s*([^\r\n]+)") { $matches[1].Trim() } else { $null }
        if ($tc -and $keepSlotMap.ContainsKey($tc)) {
            if (-not $tcCopies.ContainsKey($tc)) { $tcCopies[$tc] = [System.Collections.Generic.List[string]]::new() }
            $tcCopies[$tc].Add($c)
        }
    }

    $dedupTCs  = New-Object System.Collections.Generic.HashSet[string]
    $keepBlocks = New-Object System.Collections.Generic.HashSet[string]  # exact block strings to keep

    foreach ($tc in $keepSlotMap.Keys) {
        $dedupTCs.Add($tc) | Out-Null
        if ($tcCopies.ContainsKey($tc)) {
            $sorted = @($tcCopies[$tc] | Sort-Object {
                if ($_ -match "(?m)^\s*time_modified:\s*([^\r\n]+)") { $matches[1].Trim() } else { "" }
            } -Descending)
            $slot = $keepSlotMap[$tc]
            if ($slot -lt $sorted.Count) {
                $keepBlocks.Add($sorted[$slot]) | Out-Null
            } else {
                $keepBlocks.Add($sorted[0]) | Out-Null  # fallback to newest
            }
        }
    }

    $seenTCs = New-Object System.Collections.Generic.HashSet[string]
    $removed = [System.Collections.Generic.List[string]]::new()
    $kept    = [System.Collections.Generic.List[string]]::new()

    foreach ($c in $cards) {
        $tc = if ($c -match "(?m)^\s*time_created:\s*([^\r\n]+)") { $matches[1].Trim() } else { $null }
        if ($tc -and $dedupTCs.Contains($tc)) {
            if ($keepBlocks.Contains($c) -and $seenTCs.Add($tc)) {
                $kept.Add($c)   # This is the chosen keeper
            } else {
                $removed.Add($c)
            }
        } else {
            $kept.Add($c)   # Not a dup group - always keep
        }
    }

    # Vault removed cards
    if ($removed.Count -gt 0) {
        if (-not (Test-Path $vaultDir)) { New-Item -ItemType Directory -Path $vaultDir -Force | Out-Null }
        $stamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
        $removed -join "`n---CARD-SEPARATOR---`n" | Set-Content -Path "$vaultDir\dedup_vault_$stamp.txt" -Encoding UTF8 -Force
        Write-Host "[Dedup] Vaulted $($removed.Count) card(s) to dedup_vault_$stamp.txt" -ForegroundColor DarkGray
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
