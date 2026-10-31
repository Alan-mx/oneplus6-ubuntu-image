[CmdletBinding()]
param(
    [string]$Fastboot = "D:\Backup\Downloads\platform-tools-latest-windows\platform-tools\fastboot.exe",
    [switch]$ValidateOnly
)

$ErrorActionPreference = "Stop"
$packageManifest = Join-Path $PSScriptRoot "manifest.json"
if (Test-Path -LiteralPath $packageManifest -PathType Leaf) {
    $manifestPath = $packageManifest
    $bootImage = Join-Path $PSScriptRoot "oneplus6-boot.img"
} else {
    $root = Split-Path -Parent $PSScriptRoot
    $manifestPath = Join-Path $root "out\v15-segmented-flash\manifest.json"
    $bootImage = Join-Path $root "out\oneplus6-boot.img"
}
$expectedBootSha256 = "215f7bd5fd5deb7a3257dba893ce9eaad514ef1d29e346580852a7d8db3948b5"

if (-not (Test-Path -LiteralPath $Fastboot -PathType Leaf)) {
    throw "fastboot.exe not found: $Fastboot"
}
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "segment manifest not found: $manifestPath"
}
if (-not (Test-Path -LiteralPath $bootImage -PathType Leaf)) {
    throw "boot image not found: $bootImage"
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$segmentDirectory = Split-Path -Parent $manifestPath
$bootHash = (Get-FileHash -LiteralPath $bootImage -Algorithm SHA256).Hash.ToLowerInvariant()
if ($bootHash -ne $expectedBootSha256) {
    throw "Boot image SHA-256 mismatch: $bootImage"
}

$segments = @($manifest.segments)
if ($segments.Count -eq 0) {
    throw "Manifest contains no segments"
}
if (@($manifest.format.chunk_types) -join "," -ne "RAW,DONT_CARE") {
    throw "Manifest contains unsupported sparse chunk types"
}

$expectedStartBlock = [long]0
foreach ($segment in $segments) {
    if ([long]$segment.start_block -ne $expectedStartBlock) {
        throw "Segment coverage is not contiguous at part $($segment.part)"
    }
    $expectedStartBlock += [long]$segment.block_count
    if ([long]$segment.file_size_bytes -gt 512MB) {
        throw "Segment exceeds the 512 MiB safety limit: $($segment.file)"
    }

    $segmentPath = Join-Path $segmentDirectory $segment.file
    if (-not (Test-Path -LiteralPath $segmentPath -PathType Leaf)) {
        throw "segment not found: $segmentPath"
    }
    $item = Get-Item -LiteralPath $segmentPath
    if ($item.Length -ne $segment.file_size_bytes) {
        throw "segment size mismatch: $segmentPath"
    }
    $hash = (Get-FileHash -LiteralPath $segmentPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -ne $segment.sha256) {
        throw "segment SHA-256 mismatch: $segmentPath"
    }
}
if ($expectedStartBlock -ne [long]$manifest.format.total_blocks) {
    throw "Segments do not cover the complete logical image"
}

if ($ValidateOnly) {
    Write-Host "Validated boot image and $($segments.Count) V15 sparse segments."
    exit 0
}

$deviceOutput = & $Fastboot devices 2>&1
$devicesExitCode = $LASTEXITCODE
$deviceLines = @($deviceOutput | ForEach-Object { "$_" } | Where-Object { $_ -match "\sfastboot$" })
if ($devicesExitCode -ne 0) {
    throw "fastboot devices failed"
}
if ($deviceLines.Count -ne 1) {
    throw "Expected exactly one fastboot device, found $($deviceLines.Count)"
}

Write-Host "Device: $($deviceLines[0])"
Write-Host "Flashing boot image..."
& $Fastboot flash boot $bootImage
if ($LASTEXITCODE -ne 0) {
    throw "Boot image flash failed"
}

Write-Host "Erasing userdata..."
& $Fastboot erase userdata
if ($LASTEXITCODE -ne 0) {
    throw "userdata erase failed"
}

$total = $segments.Count
foreach ($segment in $segments) {
    Write-Host "Flashing segment $($segment.part)/$total..."
    $segmentPath = Join-Path $segmentDirectory $segment.file
    & $Fastboot flash userdata $segmentPath
    if ($LASTEXITCODE -ne 0) {
        throw "Segment $($segment.part)/$total failed"
    }
}

Write-Host "All segments flashed. Rebooting..."
& $Fastboot reboot
if ($LASTEXITCODE -ne 0) {
    throw "fastboot reboot failed"
}
