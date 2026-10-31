[CmdletBinding()]
param(
    [string]$Config = "config/build.env",
    [string]$SshPublicKey = "",
    [string]$SshPasswordFile = "",
    [switch]$RefreshImages,
    [switch]$BootOnly,
    [switch]$Fresh,
    [switch]$NoCache
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$workspace = Split-Path -Parent $root

function Get-RelativePathFrom {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $base = [System.IO.Path]::GetFullPath($BasePath).TrimEnd([char[]]@('\', '/'))
    $base = $base + [System.IO.Path]::DirectorySeparatorChar
    $full = [System.IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($base, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside base directory: $Path"
    }
    return $full.Substring($base.Length)
}

$configPath = if ([System.IO.Path]::IsPathRooted($Config)) {
    $Config
} else {
    Join-Path $root $Config
}

if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    throw "Config file not found: $configPath"
}

$docker = Get-Command docker -ErrorAction SilentlyContinue
if (-not $docker) {
    throw "docker.exe not found"
}

& docker info --format "{{.ServerVersion}}" *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Docker Desktop is not ready. Start it and run this script again." -ForegroundColor Yellow
    exit 1
}

$tag = "oneplus6-image-builder:26.04"
$buildArgs = @("build", "--pull", "-t", $tag, "-f", (Join-Path $root "Dockerfile"), $root)
if ($NoCache) {
    $buildArgs = @("build", "--no-cache") + $buildArgs[1..($buildArgs.Count - 1)]
}

& docker @buildArgs
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

$containerConfig = "/workspace/oneplus6-image/" + (Get-RelativePathFrom $root $configPath).Replace("\", "/")
$mount = "${workspace}:/workspace"
$containerName = "oneplus6-image-build"
$existingContainer = & docker ps -a --filter "name=^/$containerName$" --format "{{.Names}}"
if ($existingContainer -contains $containerName) {
    & docker rm -f $containerName *> $null
}
& docker volume create oneplus6-image-work *> $null
if ($LASTEXITCODE -ne 0) {
    throw "Unable to create Docker work volume"
}
$keyEnv = @()
if ($SshPublicKey) {
    $resolvedKey = (Resolve-Path -LiteralPath $SshPublicKey).Path
    $relativeKey = (Get-RelativePathFrom $workspace $resolvedKey).Replace("\", "/")
    if ($relativeKey.StartsWith("..")) {
        throw "SSH public key must be under $workspace"
    }
    $keyEnv = @("-e", "SSH_PUBLIC_KEY_FILE_OVERRIDE=/workspace/$relativeKey")
}

$passwordEnv = @()
if ($SshPasswordFile) {
    $resolvedPasswordFile = (Resolve-Path -LiteralPath $SshPasswordFile).Path
    $relativePasswordFile = (Get-RelativePathFrom $workspace $resolvedPasswordFile).Replace("\", "/")
    if ($relativePasswordFile.StartsWith("..")) {
        throw "SSH password file must be under $workspace"
    }
    $passwordEnv = @(
        "-e",
        "SSH_PASSWORD_FILE_OVERRIDE=/workspace/$relativePasswordFile"
    )
}

$runArgs = @(
    "run", "--rm", "--name", $containerName,
    "-e", "CONFIG_FILE=$containerConfig",
    "-e", "BUILD_WORK_DIR=/work"
)
if ($Fresh) {
    $runArgs += @("-e", "FRESH_BUILD=1")
}
$runArgs += $keyEnv
$runArgs += $passwordEnv
$runArgs += @(
    "-v", $mount,
    "--mount", "type=volume,src=oneplus6-image-work,dst=/work",
    "-w", "/workspace/oneplus6-image"
)
if ($RefreshImages -and $BootOnly) {
    throw "RefreshImages and BootOnly cannot be used together"
}

if ($RefreshImages) {
    $runArgs += @("--entrypoint", "bash", $tag, "scripts/refresh-images.sh")
} elseif ($BootOnly) {
    $runArgs += @("--entrypoint", "bash", $tag, "scripts/build.sh", "--boot-only")
} else {
    $runArgs += $tag
}

Write-Host "Starting build container..."
& docker @runArgs
$runExitCode = $LASTEXITCODE
if ($runExitCode -ne 0) {
    Write-Host "Build container exited with code $runExitCode" -ForegroundColor Red
}

exit $runExitCode
