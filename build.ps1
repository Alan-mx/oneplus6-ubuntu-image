[CmdletBinding()]
param(
    [string]$Config = "config/build.env",
    [string]$SshPublicKey = "",
    [string]$SshPasswordFile = "",
    [string]$OrbitalSourcePath = "",
    [string]$OutputDirectory = "",
    [switch]$RefreshImages,
    [switch]$BootOnly,
    [switch]$Fresh,
    [switch]$NoCache,
    [switch]$CheckEnvironment,
    [switch]$ReleaseBuild
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$workspace = Split-Path -Parent $root
$rootName = Split-Path -Leaf $root
$containerRoot = "/workspace/$rootName"

function Get-RelativePathFrom {
    param([string]$BasePath, [string]$Path)
    $base = [System.IO.Path]::GetFullPath($BasePath).TrimEnd([char[]]@('\', '/'))
    $base += [System.IO.Path]::DirectorySeparatorChar
    $full = [System.IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($base, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside base directory: $Path"
    }
    return $full.Substring($base.Length)
}

function Invoke-DockerBuild {
    param([string[]]$Arguments)
    & docker @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Docker command failed with exit code $LASTEXITCODE"
    }
}

function Get-BuildConfigValue {
    param([string]$Name)
    $line = Get-Content -LiteralPath $configPath |
        Where-Object { $_ -match "^$([regex]::Escape($Name))=" } |
        Select-Object -First 1
    if (-not $line) {
        throw "Required build config value not found: $Name"
    }
    return (($line -split "=", 2)[1]).Trim().Trim('"')
}

$configPath = if ([System.IO.Path]::IsPathRooted($Config)) { $Config } else { Join-Path $root $Config }
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    throw "Config file not found: $configPath"
}

$selectedModes = @()
foreach ($mode in @($RefreshImages, $BootOnly, $CheckEnvironment)) {
    if ($mode) { $selectedModes += $true }
}
if ($selectedModes.Count -gt 1) {
    throw "Choose only one of RefreshImages, BootOnly, or CheckEnvironment."
}
if ($ReleaseBuild -and ($RefreshImages -or $BootOnly -or $CheckEnvironment)) {
    throw "ReleaseBuild applies only to a full image build."
}
if ($Fresh -and ($RefreshImages -or $BootOnly -or $CheckEnvironment)) {
    throw "Fresh applies only to a full image build."
}

$docker = Get-Command docker -ErrorAction SilentlyContinue
if (-not $docker) { throw "docker.exe not found" }
& docker info --format "{{.ServerVersion}}" *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Docker Desktop is not ready. Start it and run this script again." -ForegroundColor Yellow
    exit 1
}

if (-not $OrbitalSourcePath) {
    $candidate = Join-Path $workspace "Orbital"
    if (Test-Path -LiteralPath $candidate -PathType Container) {
        $OrbitalSourcePath = $candidate
    }
}
if (-not $OrbitalSourcePath -or -not (Test-Path -LiteralPath $OrbitalSourcePath -PathType Container)) {
    throw "Orbital source directory not found. Supply -OrbitalSourcePath with the local checkout."
}
$orbitalSource = (Resolve-Path -LiteralPath $OrbitalSourcePath).Path
$orbitalRelative = (Get-RelativePathFrom $workspace $orbitalSource).Replace('\', '/')
$containerOrbital = "/workspace/$orbitalRelative"

$lockPath = Join-Path $root "config\source-revisions.lock.tsv"
if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
    throw "Source revision lock not found: $lockPath"
}
$lockLines = Get-Content -LiteralPath $lockPath
foreach ($file in @(
    (Join-Path $root "config\apk-sha256.lock"),
    (Join-Path $root "config\ubuntu-packages.lock.tsv"),
    (Join-Path $root "config\builder-packages.lock.tsv"),
    (Join-Path $root "config\kernel-builder-packages.lock.tsv")
)) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Required lock file not found: $file" }
}

$expectedOrbital = ($lockLines | Where-Object { $_ -match '^orbital\t' } | ForEach-Object { ($_ -split "`t")[2] } | Select-Object -First 1)
$actualOrbital = (& git -C $orbitalSource rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $actualOrbital -ne $expectedOrbital) {
    throw "Orbital checkout does not match the locked commit. Expected $expectedOrbital, found $actualOrbital."
}

$prebuiltInputs = @(
    @{
        Path = "inputs\boot\oneplus6-boot-gpu-fix.img"
        Lock = "BOOT_IMAGE_OVERRIDE_SHA256"
    },
    @{
        Path = "inputs\tqftpserv\tqftpserv"
        Lock = "TQFPSERV_SHA256"
    },
    @{
        Path = "inputs\pd-mapper\pd-mapper"
        Lock = "PD_MAPPER_SHA256"
    },
    @{
        Path = "inputs\rmtfs\rmtfs"
        Lock = "RMTFS_SHA256"
    }
)
foreach ($input in $prebuiltInputs) {
    $inputPath = Join-Path $root $input.Path
    if (-not (Test-Path -LiteralPath $inputPath -PathType Leaf)) {
        throw "Prebuilt build input not found: $inputPath"
    }
    $expectedHash = Get-BuildConfigValue $input.Lock
    $actualHash = (Get-FileHash -LiteralPath $inputPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $expectedHash.ToLowerInvariant()) {
        throw "Prebuilt build input SHA-256 mismatch: $($input.Path)"
    }
}

if ($ReleaseBuild) {
    $orbitalStatus = @(& git -C $orbitalSource status --porcelain=v1 --untracked-files=all)
    if ($LASTEXITCODE -ne 0 -or $orbitalStatus.Count -gt 0) {
        throw "ReleaseBuild requires a clean Orbital worktree. No build was started."
    }
    $repositoryStatus = @(& git -C $root status --porcelain=v1 --untracked-files=all)
    if ($LASTEXITCODE -ne 0 -or $repositoryStatus.Count -gt 0) {
        throw "ReleaseBuild requires a clean oneplus6-image worktree. No build was started."
    }
}

if ($CheckEnvironment) {
    Write-Host "Docker: ready"
    Write-Host "Config: $configPath"
    Write-Host "Orbital: $actualOrbital"
    Write-Host "Source rows: $($lockLines.Count - 1)"
    Write-Host "Check complete. No build, download, or device operation was performed."
    exit 0
}

$runId = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ") + "-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
$effectiveOutputDirectory = $OutputDirectory
if (-not $effectiveOutputDirectory) {
    $effectiveOutputDirectory = Join-Path "out" "build-$runId"
}
$containerConfig = "$containerRoot/" + (Get-RelativePathFrom $root $configPath).Replace('\', '/')
$runTimestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$platform = if ([System.Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
    "windows-x64-docker-desktop"
} else {
    "linux-x86_64-docker"
}

$passwordEnv = @()
if ($SshPasswordFile) {
    $resolvedPassword = (Resolve-Path -LiteralPath $SshPasswordFile).Path
    $passwordRelative = (Get-RelativePathFrom $workspace $resolvedPassword).Replace('\', '/')
    $passwordEnv = @("-e", "SSH_PASSWORD_FILE_OVERRIDE=/workspace/$passwordRelative")
}
$keyEnv = @()
if ($SshPublicKey) {
    $resolvedKey = (Resolve-Path -LiteralPath $SshPublicKey).Path
    $keyRelative = (Get-RelativePathFrom $workspace $resolvedKey).Replace('\', '/')
    $keyEnv = @("-e", "SSH_PUBLIC_KEY_FILE_OVERRIDE=/workspace/$keyRelative")
}

$commonMounts = @("-v", "${workspace}:/workspace")
$workVolume = if ($Fresh) { "oneplus6-image-fresh-$runId" } else { "oneplus6-image-work" }
& docker volume create $workVolume *> $null
if ($LASTEXITCODE -ne 0) { throw "Unable to create or access Docker volume $workVolume" }
$volumeMount = @("--mount", "type=volume,src=$workVolume,dst=/work")

if ($RefreshImages -or $BootOnly) {
    $legacyVolume = "oneplus6-image-work"
    & docker volume create $legacyVolume *> $null
    if ($LASTEXITCODE -ne 0) { throw "Unable to access Docker volume $legacyVolume" }
    $tag = "oneplus6-image-builder:26.04.1"
    $dockerfile = Join-Path $root "Dockerfile"
    $buildArgs = @("build", "--pull", "-t", $tag, "-f", $dockerfile, $root)
    if ($NoCache) { $buildArgs = @("build", "--no-cache") + $buildArgs[1..($buildArgs.Count - 1)] }
    Invoke-DockerBuild $buildArgs
    $containerName = "oneplus6-image-special-$runId"
    $runArgs = @(
        "run", "--rm", "--name", $containerName,
        "-e", "BUILD_ROOT=$containerRoot",
        "-e", "CONFIG_FILE=$containerConfig",
        "-e", "BUILD_WORK_DIR=/work",
        "-v", "${workspace}:/workspace",
        "--mount", "type=volume,src=$legacyVolume,dst=/work",
        "-w", $containerRoot,
        "--entrypoint", "bash", $tag
    )
    $runArgs += $passwordEnv
    $runArgs += $keyEnv
    if ($RefreshImages) { $runArgs += "scripts/refresh-images.sh" }
    else { $runArgs += @("scripts/build.sh", "--boot-only") }
    & docker @runArgs
    exit $LASTEXITCODE
}

$outputPath = if ([System.IO.Path]::IsPathRooted($OutputDirectory)) {
    [System.IO.Path]::GetFullPath($effectiveOutputDirectory)
} else {
    [System.IO.Path]::GetFullPath((Join-Path $root $effectiveOutputDirectory))
}
$outputRelative = (Get-RelativePathFrom $root $outputPath).Replace('\', '/')
$containerOutput = "$containerRoot/$outputRelative"
$stateRelative = "state/$runId"
$containerState = "$containerRoot/$stateRelative"
$preparedRelative = "inputs/prepared/$runId"
$containerPrepared = "$containerRoot/$preparedRelative"
$inputRelative = if ($Fresh) { "inputs/fresh/$runId" } else { "inputs" }
$containerInput = "$containerRoot/$inputRelative"
$containerWork = "/work/$runId"
$volumeLabel = if ($Fresh) { "fresh isolated" } else { "isolated run directory" }

$rootTag = "oneplus6-image-builder:26.04.1"
$rootDockerfile = Join-Path $root "Dockerfile"
$rootBuildArgs = @("build", "--pull", "-t", $rootTag, "-f", $rootDockerfile, $root)
if ($NoCache) { $rootBuildArgs = @("build", "--no-cache") + $rootBuildArgs[1..($rootBuildArgs.Count - 1)] }
Invoke-DockerBuild $rootBuildArgs
$builderId = (& docker image inspect --format "{{.Id}}" $rootTag).Trim()
if ($LASTEXITCODE -ne 0) { throw "Unable to inspect image builder" }

$containerName = "oneplus6-image-build-$runId"
$runArgs = @(
    "run", "--rm", "--name", $containerName,
    "-e", "BUILD_ROOT=$containerRoot",
    "-e", "CONFIG_FILE=$containerConfig",
    "-e", "BUILD_WORK_DIR=$containerWork",
    "-e", "BUILD_STATE_DIR=$containerState",
    "-e", "BUILD_LOG_DIR=$containerRoot/logs/$runId",
    "-e", "BUILD_OUTPUT_DIR=$containerOutput",
    "-e", "BUILD_INPUT_DIR=$containerInput",
    "-e", "BUILD_PREPARED_INPUTS_DIR=$containerPrepared",
    "-e", "ORBITAL_SOURCE_DIR_OVERRIDE=$containerOrbital",
    "-e", "BUILD_PLATFORM=$platform",
    "-e", "BUILD_STARTED_AT=$runTimestamp",
    "-e", "BUILD_IMAGE_ID=$builderId",
    "-e", "FRESH_BUILD=$(if ($Fresh) { 1 } else { 0 })",
    "-e", "BUILD_MODE=quick",
    "-e", "BUILD_RELEASE=$(if ($ReleaseBuild) { 1 } else { 0 })",
    "-v", "${workspace}:/workspace"
) + $volumeMount + $passwordEnv + $keyEnv + @(
    "-w", $containerRoot,
    "--entrypoint", "bash", $rootTag,
    "scripts/build.sh"
)

Write-Host "Starting $volumeLabel build $runId..."
& docker @runArgs
$runExitCode = $LASTEXITCODE
if ($runExitCode -ne 0) {
    Write-Host "Build failed with exit code $runExitCode. The volume was retained: $workVolume" -ForegroundColor Red
    exit $runExitCode
}

& (Join-Path $root "verify-build.ps1") -BuildRoot $root -OutputDirectory $outputPath

Write-Host "Build complete. Artifacts: $outputPath"
Write-Host "Manifest: $(Join-Path $outputPath 'build-manifest.json')"
Write-Host "Docker volume retained: $workVolume"
