[CmdletBinding()]
param(
    [string]$Fastboot = "fastboot",
    [switch]$ValidateOnly
)

$ErrorActionPreference = "Stop"
$packageRoot = $PSScriptRoot
$releasePath = Join-Path $packageRoot "release.json"
$manifestPath = Join-Path $packageRoot "manifest.json"

foreach ($path in @($releasePath, $manifestPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required package file not found: $path. Extract the complete ZIP first."
    }
}

$release = Get-Content -LiteralPath $releasePath -Raw | ConvertFrom-Json
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($release.schema_version -ne 1 -or $release.device_id -ne "oneplus-enchilada") {
    throw "Unsupported release metadata or device target."
}
if ((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne
    $release.rootfs_segment_manifest.sha256.ToLowerInvariant()) {
    throw "Sparse segment manifest SHA-256 mismatch."
}

$bootImage = Join-Path $packageRoot $release.boot_image.file
if (-not (Test-Path -LiteralPath $bootImage -PathType Leaf)) {
    throw "Boot image not found: $bootImage"
}
if ((Get-FileHash -LiteralPath $bootImage -Algorithm SHA256).Hash.ToLowerInvariant() -ne
    $release.boot_image.sha256.ToLowerInvariant()) {
    throw "Boot image SHA-256 mismatch."
}
if (@($manifest.format.chunk_types) -join "," -ne "RAW,DONT_CARE") {
    throw "Manifest contains unsupported sparse chunk types."
}

$expectedStartBlock = [long]0
foreach ($segment in @($manifest.segments)) {
    if ([long]$segment.start_block -ne $expectedStartBlock) {
        throw "Segment coverage is not contiguous at part $($segment.part)."
    }
    $expectedStartBlock += [long]$segment.block_count
    if ([long]$segment.file_size_bytes -gt 512MB) {
        throw "Segment exceeds the 512 MiB safety limit: $($segment.file)"
    }

    $segmentPath = Join-Path $packageRoot $segment.file
    if (-not (Test-Path -LiteralPath $segmentPath -PathType Leaf)) {
        throw "Segment not found: $segmentPath"
    }
    $item = Get-Item -LiteralPath $segmentPath
    if ($item.Length -ne $segment.file_size_bytes) {
        throw "Segment size mismatch: $segmentPath"
    }
    $hash = (Get-FileHash -LiteralPath $segmentPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -ne $segment.sha256.ToLowerInvariant()) {
        throw "Segment SHA-256 mismatch: $segmentPath"
    }
}
if (@($manifest.segments).Count -eq 0 -or
    $expectedStartBlock -ne [long]$manifest.format.total_blocks) {
    throw "Segments do not cover the complete logical rootfs."
}

if ($ValidateOnly) {
    Write-Host "Validated boot image and $(@($manifest.segments).Count) sparse segments."
    exit 0
}

if (-not (Get-Command $Fastboot -ErrorAction SilentlyContinue)) {
    throw "fastboot executable not found: $Fastboot"
}
$deviceOutput = & $Fastboot devices 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "fastboot devices failed."
}
$deviceLines = @($deviceOutput | ForEach-Object { "$_" } | Where-Object { $_ -match "\sfastboot$" })
if ($deviceLines.Count -ne 1) {
    throw "Expected exactly one fastboot device, found $($deviceLines.Count)."
}
$productOutput = & $Fastboot getvar product 2>&1
if ($LASTEXITCODE -ne 0 -or ($productOutput -join "`n") -notmatch "product:\s*sdm845") {
    throw "Fastboot target is not the expected OnePlus 6 (sdm845)."
}

Write-Warning "Flashing will erase all userdata on the connected phone. Back up anything important."
$confirmation = Read-Host "Type ERASE USERDATA to continue"
if ($confirmation -cne "ERASE USERDATA") {
    throw "Flash cancelled."
}

Write-Host "Flashing boot image..."
& $Fastboot flash boot $bootImage
if ($LASTEXITCODE -ne 0) { throw "Boot image flash failed." }

Write-Host "Erasing userdata..."
& $Fastboot erase userdata
if ($LASTEXITCODE -ne 0) { throw "userdata erase failed." }

$segments = @($manifest.segments)
for ($index = 0; $index -lt $segments.Count; $index++) {
    $segmentPath = Join-Path $packageRoot $segments[$index].file
    Write-Host "Flashing rootfs segment $($index + 1)/$($segments.Count)..."
    & $Fastboot flash userdata $segmentPath
    if ($LASTEXITCODE -ne 0) { throw "Rootfs segment $($index + 1) failed." }
}

Write-Host "Flashing complete. Rebooting..."
& $Fastboot reboot
if ($LASTEXITCODE -ne 0) { throw "fastboot reboot failed." }
