[CmdletBinding()]
param(
    [string]$BuildRoot = $PSScriptRoot,
    [string]$OutputDirectory = ""
)

$ErrorActionPreference = "Stop"
$repoRoot = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $BuildRoot).Path)
$manifestPath = $null

if ($OutputDirectory) {
    $outputPath = if ([System.IO.Path]::IsPathRooted($OutputDirectory)) {
        [System.IO.Path]::GetFullPath($OutputDirectory)
    } else {
        [System.IO.Path]::GetFullPath((Join-Path $repoRoot $OutputDirectory))
    }
    $manifestPath = Join-Path $outputPath "build-manifest.json"
} else {
    $legacy = Join-Path $repoRoot "out\build-manifest.json"
    if (Test-Path -LiteralPath $legacy -PathType Leaf) {
        $manifestPath = $legacy
    } else {
        $candidates = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot "out") `
            -Filter "build-manifest.json" -File -Recurse -ErrorAction SilentlyContinue)
        if ($candidates.Count -ne 1) {
            throw "Expected exactly one out/**/build-manifest.json; pass -OutputDirectory explicitly. Found $($candidates.Count)."
        }
        $manifestPath = $candidates[0].FullName
    }
    $outputPath = Split-Path -Parent $manifestPath
}

if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Build manifest not found: $manifestPath"
}
if (-not (Test-Path -LiteralPath (Join-Path $repoRoot "config\source-revisions.lock.tsv") -PathType Leaf)) {
    throw "BuildRoot must be the oneplus6-image repository: $repoRoot"
}

function Get-ContainedFile {
    param([string]$Base, [string]$RelativePath)
    if ([System.IO.Path]::IsPathRooted($RelativePath)) {
        throw "Manifest path must be relative: $RelativePath"
    }
    $baseFull = [System.IO.Path]::GetFullPath($Base).TrimEnd([char[]]@('\', '/'))
    $full = [System.IO.Path]::GetFullPath((Join-Path $baseFull ($RelativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar))))
    $prefix = $baseFull + [System.IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Manifest path escapes its root: $RelativePath"
    }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        throw "Manifest file not found: $full"
    }
    return $full
}

function Get-StreamSha256 {
    param([System.IO.Stream]$Stream)
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([Convert]::ToHexString($algorithm.ComputeHash($Stream))).ToLowerInvariant()
    } finally {
        $algorithm.Dispose()
    }
}

function Read-ZipText {
    param([System.IO.Compression.ZipArchive]$Archive, [string]$Name)
    $entry = $Archive.GetEntry($Name)
    if (-not $entry) { throw "ZIP entry missing: $Name" }
    $stream = $entry.Open()
    try {
        $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8, $true)
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally {
        $stream.Dispose()
    }
}

function Get-ZipEntryHash {
    param([System.IO.Compression.ZipArchiveEntry]$Entry)
    $stream = $Entry.Open()
    try { return Get-StreamSha256 $stream } finally { $stream.Dispose() }
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($manifest.schema_version -ne 1 -or $manifest.status -ne "verified") {
    throw "Unsupported or unverified build manifest."
}
$manifestText = Get-Content -LiteralPath $manifestPath -Raw
if ($manifestText -match '(?i)ssh_password|password_hash|password_sha256|ssh_key_fingerprint') {
    throw "Build manifest contains a forbidden credential field."
}
if ($manifest.release.device_id -ne "oneplus-enchilada") {
    throw "Manifest targets an unexpected device: $($manifest.release.device_id)"
}
$dirtySource = [bool]$manifest.build.oneplus6_image_dirty
foreach ($source in @($manifest.sources)) {
    $dirtySource = $dirtySource -or [bool]$source.dirty
}
if ($dirtySource -and $manifest.build.publicly_reproducible) {
    throw "Manifest claims public reproducibility despite recording dirty sources."
}
if ($manifest.build.release_build -and $dirtySource) {
    throw "A release build manifest must not contain dirty sources."
}

foreach ($lock in @($manifest.locks)) {
    $path = Get-ContainedFile $repoRoot $lock.path
    $digest = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($digest -ne $lock.sha256.ToLowerInvariant()) {
        throw "Lock digest mismatch: $($lock.path)"
    }
}

$ubuntuLock = Get-Content -LiteralPath (Join-Path $repoRoot "config\ubuntu-packages.lock.tsv")
foreach ($name in @("base", "orbital")) {
    $packageSet = $manifest.packages.$name
    $packagePath = Get-ContainedFile $repoRoot $packageSet.path
    $actual = @(Get-Content -LiteralPath $packagePath)
    if ($actual.Count -ne $ubuntuLock.Count -or
        [string]::Join("`n", $actual) -ne [string]::Join("`n", $ubuntuLock)) {
        throw "$name ARM64 package set does not match the package lock."
    }
    $digest = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($digest -ne $packageSet.sha256.ToLowerInvariant() -or $actual.Count -ne $packageSet.count) {
        throw "$name ARM64 package set metadata mismatch."
    }
}

$artifactByName = @{}
foreach ($artifact in @($manifest.artifacts)) {
    $path = Get-ContainedFile $repoRoot $artifact.path
    $item = Get-Item -LiteralPath $path
    if ([long]$item.Length -ne [long]$artifact.size_bytes) {
        throw "Artifact size mismatch: $($artifact.path)"
    }
    $digest = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($digest -ne $artifact.sha256.ToLowerInvariant()) {
        throw "Artifact SHA-256 mismatch: $($artifact.path)"
    }
    $artifactByName[$artifact.path] = $path
}

$sumsPath = Join-Path $outputPath "SHA256SUMS.txt"
if (-not (Test-Path -LiteralPath $sumsPath -PathType Leaf)) { throw "SHA256SUMS.txt is missing." }
$sumEntries = @{}
foreach ($line in Get-Content -LiteralPath $sumsPath) {
    if ($line -notmatch '^([0-9a-fA-F]{64})  (.+)$') { throw "Malformed SHA256SUMS line: $line" }
    $sumEntries[$Matches[2]] = $Matches[1].ToLowerInvariant()
}
foreach ($artifact in @($manifest.artifacts | Where-Object { $_.path -ne (([System.IO.Path]::GetRelativePath($repoRoot, $sumsPath)).Replace('\', '/')) })) {
    $name = [System.IO.Path]::GetRelativePath($outputPath, (Get-ContainedFile $repoRoot $artifact.path)).Replace('\', '/')
    if (-not $sumEntries.ContainsKey($name) -or $sumEntries[$name] -ne $artifact.sha256.ToLowerInvariant()) {
        throw "SHA256SUMS entry missing or mismatched: $name"
    }
}

$zipArtifact = @($manifest.artifacts | Where-Object { $_.path -like "*/oneplus6-segmented-flash.zip" })
if ($zipArtifact.Count -ne 1) { throw "Manifest must contain exactly one segmented flash ZIP." }
$zipPath = Get-ContainedFile $repoRoot $zipArtifact[0].path
$zipArchive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
try {
    $badEntry = $zipArchive.Entries | Where-Object {
        $entry = $_
        try { $stream = $entry.Open(); $stream.CopyTo([System.IO.Stream]::Null); $stream.Dispose(); $false }
        catch { $true }
    } | Select-Object -First 1
    if ($badEntry) { throw "ZIP integrity check failed at $($badEntry.FullName)." }

    $releaseEntry = @($zipArchive.Entries | Where-Object { $_.FullName -match '^[^/]+/release\.json$' })
    $segmentManifestEntry = @($zipArchive.Entries | Where-Object { $_.FullName -match '^[^/]+/manifest\.json$' })
    $checksumsEntry = @($zipArchive.Entries | Where-Object { $_.FullName -match '^[^/]+/SHA256SUMS\.txt$' })
    if ($releaseEntry.Count -ne 1 -or $segmentManifestEntry.Count -ne 1 -or $checksumsEntry.Count -ne 1) {
        throw "Segmented ZIP is missing unique release metadata."
    }
    $release = Read-ZipText $zipArchive $releaseEntry[0].FullName | ConvertFrom-Json
    $segments = Read-ZipText $zipArchive $segmentManifestEntry[0].FullName | ConvertFrom-Json
    if ($release.device_id -ne "oneplus-enchilada" -or $release.schema_version -ne 1) {
        throw "Segmented ZIP targets an unsupported device."
    }
    if ((Get-ZipEntryHash $segmentManifestEntry[0]) -ne $release.rootfs_segment_manifest.sha256.ToLowerInvariant()) {
        throw "ZIP segment manifest digest does not match release.json."
    }
    $bootEntry = $zipArchive.GetEntry("$($releaseEntry[0].FullName.Split('/')[0])/$($release.boot_image.file)")
    if (-not $bootEntry -or (Get-ZipEntryHash $bootEntry) -ne $release.boot_image.sha256.ToLowerInvariant()) {
        throw "ZIP boot image is missing or has a digest mismatch."
    }
    if (@($segments.format.chunk_types) -join "," -ne "RAW,DONT_CARE") {
        throw "Segment manifest contains unsupported sparse chunk types."
    }
    $nextBlock = [long]0
    foreach ($segment in @($segments.segments)) {
        if ([long]$segment.start_block -ne $nextBlock -or [long]$segment.file_size_bytes -gt 512MB) {
            throw "Invalid segment range or size: $($segment.file)"
        }
        $nextBlock += [long]$segment.block_count
        $entry = $zipArchive.GetEntry("$($releaseEntry[0].FullName.Split('/')[0])/$($segment.file)")
        if (-not $entry -or $entry.Length -ne [long]$segment.file_size_bytes -or
            (Get-ZipEntryHash $entry) -ne $segment.sha256.ToLowerInvariant()) {
            throw "ZIP sparse segment mismatch: $($segment.file)"
        }
    }
    if ($nextBlock -ne [long]$segments.format.total_blocks -or @($segments.segments).Count -eq 0) {
        throw "Sparse segments do not cover the declared logical image."
    }

    $packageRoot = $releaseEntry[0].FullName.Split('/')[0]
    $zipSumsText = Read-ZipText $zipArchive $checksumsEntry[0].FullName
    foreach ($line in $zipSumsText -split "`r?`n" | Where-Object { $_ }) {
        if ($line -notmatch '^([0-9a-fA-F]{64})  (.+)$') { throw "Malformed ZIP checksum line." }
        $entry = $zipArchive.GetEntry("$packageRoot/$($Matches[2])")
        if (-not $entry -or (Get-ZipEntryHash $entry) -ne $Matches[1].ToLowerInvariant()) {
            throw "ZIP checksum mismatch for $($Matches[2])."
        }
    }
} finally {
    $zipArchive.Dispose()
}

Write-Host "Verified $($manifest.artifacts.Count) artifacts and segmented ZIP."
Write-Host "Manifest: $manifestPath"
