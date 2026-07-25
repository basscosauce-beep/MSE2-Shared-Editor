# FillCreators.ps1
# Retroactively assigns the "By" column for any cards missing a creator,
# using git commit history to match who committed each card based on timestamps.

param(
    [string]$RepoDir,
    [string]$GitCmd,
    [array]$CredBypass
)

$setFile = Get-ChildItem "$RepoDir\Shared-Set" -Recurse -Filter "*.mse-set" | Select-Object -First 1
if (-not $setFile) { return }

Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression

# --- Read the "set" text file from inside the .mse-set zip ---
function Read-SetEntry($zipPath) {
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
        $entry = $zip.Entries | Where-Object { $_.Name -eq "set" }
        if (-not $entry) { $zip.Dispose(); return $null }
        $reader = New-Object System.IO.StreamReader($entry.Open(), [System.Text.Encoding]::UTF8)
        $content = $reader.ReadToEnd()
        $reader.Dispose(); $zip.Dispose()
        return $content
    } catch { return $null }
}

$content = Read-SetEntry $setFile.FullName
if (-not $content) { return }

# --- Check if any cards are missing a creator ---
$cardBlocks = $content -split "(?m)^(?=card:)"
$hasEmpty = $cardBlocks | Where-Object { $_ -match "^card:" -and $_ -notmatch "(?m)^\tcreator: \S" }
if (-not $hasEmpty) { return }  # All cards already have creators

Write-Host "[By Column] Found $($hasEmpty.Count) cards without creator. Resolving from git history..." -ForegroundColor Yellow

# --- Get git log: commit timestamps + author names (use local user.name, not GitHub username) ---
$relPath = $setFile.FullName.Replace("$RepoDir\", "").Replace("\", "/")
# %an = author name as configured in git config user.name at commit time
$rawLog = (& $GitCmd -C $RepoDir log --format="%ai|%an" -- "$relPath" 2>$null) | Where-Object { $_ -ne "" }

if (-not $rawLog) {
    $rawLog = (& $GitCmd -C $RepoDir log --format="%ai|%an" 2>$null) | Where-Object { $_ -ne "" }
}
if (-not $rawLog) { return }

$commits = $rawLog | ForEach-Object {
    $p = $_ -split "\|", 2
    try { [PSCustomObject]@{ Date = [DateTime]::Parse($p[0].Trim()); Author = $p[1].Trim() } }
    catch { $null }
} | Where-Object { $_ } | Sort-Object Date

if (-not $commits) { return }

# Filter out bot/installer names
$realCommits = $commits | Where-Object { $_.Author -notmatch "^(Install|MSE Shared|Anonymous|basscosauce-beep)$" }
if (-not $realCommits) { $realCommits = $commits }


# --- For each card block, assign a creator based on nearest commit time ---
$anyUpdated = $false
$newBlocks = foreach ($block in $cardBlocks) {
    if ($block -match "^card:" -and $block -notmatch "(?m)^\tcreator: \S") {
        if ($block -match "time_created: (\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})") {
            try {
                $cardTime = [DateTime]::Parse($matches[1])

                # Find the commit with the smallest time difference (using real names only)
                $bestAuthor = $realCommits[-1].Author
                $bestDiff   = [double]::MaxValue
                foreach ($c in $realCommits) {
                    $diff = [Math]::Abs(($c.Date.ToUniversalTime() - $cardTime.ToUniversalTime()).TotalMinutes)
                    if ($diff -lt $bestDiff) { $bestDiff = $diff; $bestAuthor = $c.Author }
                }

                if ($bestAuthor) {
                    # Insert creator field right after time_modified
                    $block = $block -replace "(?m)(^\ttime_modified: .+$)", "`$1`n`tcreator: $bestAuthor"
                    Write-Host "  → Assigned '$bestAuthor' to card at $($matches[1])" -ForegroundColor Cyan
                    $anyUpdated = $true
                }
            } catch {}
        }
    }
    $block
}

if (-not $anyUpdated) { return }

$newContent = $newBlocks -join ""

# --- Temp-file swap to avoid file lock issues ---
$tempZipPath = [System.IO.Path]::GetTempFileName() + ".mse-set"
try {
    $srcZip = [System.IO.Compression.ZipFile]::OpenRead($setFile.FullName)
    $dstZip = [System.IO.Compression.ZipFile]::Open($tempZipPath, [System.IO.Compression.ZipArchiveMode]::Create)

    # Write updated "set" entry
    $setEntry = $dstZip.CreateEntry("set", [System.IO.Compression.CompressionLevel]::Optimal)
    $setStream = $setEntry.Open()
    $writer = New-Object System.IO.StreamWriter($setStream, [System.Text.Encoding]::UTF8)
    $writer.Write($newContent)
    $writer.Flush(); $writer.Dispose()

    # Copy all image entries unchanged
    foreach ($imgEntry in ($srcZip.Entries | Where-Object { $_.Name -ne "set" })) {
        $dstEntry = $dstZip.CreateEntry($imgEntry.FullName, [System.IO.Compression.CompressionLevel]::Optimal)
        $s = $imgEntry.Open(); $d = $dstEntry.Open()
        $s.CopyTo($d); $s.Dispose(); $d.Dispose()
    }
    $srcZip.Dispose(); $dstZip.Dispose()

    Copy-Item $tempZipPath $setFile.FullName -Force
    Write-Host "[By Column] Creator attribution complete!" -ForegroundColor Green
} catch {
    Write-Host "[By Column] Could not update set file: $_" -ForegroundColor Red
} finally {
    if (Test-Path $tempZipPath) { Remove-Item $tempZipPath -Force -ErrorAction SilentlyContinue }
}
