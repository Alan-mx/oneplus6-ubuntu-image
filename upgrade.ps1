[CmdletBinding()]
param(
    [switch]$Check,
    [string]$Apply = "",
    [string]$Commit = "",
    [string]$Version = "",
    [string]$OrbitalSourcePath = "",
    [string]$SshPasswordFile = ""
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$lockPath = Join-Path $root "config\source-revisions.lock.tsv"
if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) { throw "Source lock not found: $lockPath" }
if (($Check -and $Apply) -or (-not $Check -and -not $Apply)) {
    throw "Choose exactly one mode: -Check or -Apply <component>."
}

$rows = @(Get-Content -LiteralPath $lockPath | Select-Object -Skip 1 | ForEach-Object {
    $columns = $_ -split "`t", 5
    if ($columns.Count -ne 5) { throw "Malformed source lock row: $_" }
    [pscustomobject]@{
        Component = $columns[0]
        Repository = $columns[1]
        Commit = $columns[2]
        Version = $columns[3]
        License = $columns[4]
    }
})

if ($Check) {
    foreach ($row in $rows) {
        $remote = @(& git ls-remote --symref $row.Repository HEAD 2>$null)
        if ($LASTEXITCODE -ne 0) {
            Write-Host "$($row.Component): remote check unavailable; locked $($row.Version) $($row.Commit)"
            continue
        }
        $head = ($remote | Where-Object { $_ -match '^[0-9a-f]{40}\s+HEAD$' } | Select-Object -First 1) -replace '\s+HEAD$', ''
        $state = if ($head -and $head -ne $row.Commit) { "remote HEAD differs" } else { "at remote HEAD" }
        Write-Host "$($row.Component): $state; locked $($row.Version) $($row.Commit); remote $head"
    }
    foreach ($lock in @(
        "config\build.env", "config\apk-sha256.lock", "config\ubuntu-packages.lock.tsv",
        "config\builder-packages.lock.tsv", "config\kernel-builder-packages.lock.tsv"
    )) {
        $path = Join-Path $root $lock
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        Write-Host "lock $($lock.Replace('\', '/')) sha256=$hash"
    }
    Write-Host "Check is read-only. A differing remote HEAD is a review signal, not an automatic upgrade recommendation."
    exit 0
}

if ($Apply -notmatch '^[a-z][a-z0-9-]*$') { throw "Invalid component name: $Apply" }
if ($Commit -notmatch '^[0-9a-f]{40}$') { throw "-Commit must be an exact 40-character Git commit SHA." }
if (-not $Version -or $Version -match '[`r`n`t]') { throw "-Version is required and cannot contain tabs or line breaks." }
$rowIndex = -1
for ($index = 0; $index -lt $rows.Count; $index++) {
    if ($rows[$index].Component -ceq $Apply) { $rowIndex = $index; break }
}
if ($rowIndex -lt 0) { throw "Unknown locked source component: $Apply" }
$row = $rows[$rowIndex]

$git = Get-Command git -ErrorAction SilentlyContinue
if (-not $git) { throw "git is required." }
$lockStatus = @(& git -C $root status --porcelain=v1 -- config/source-revisions.lock.tsv)
if ($LASTEXITCODE -ne 0 -or $lockStatus.Count -gt 0) {
    throw "Refusing to replace a dirty source lock. Preserve or commit its existing changes first."
}

$runId = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ") + "-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
$candidate = Join-Path $root "work\upgrade-$Apply-$runId"
New-Item -ItemType Directory -Path $candidate -Force | Out-Null
& git -c init.defaultBranch=main init $candidate | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Unable to initialize isolated source verification directory: $candidate" }
& git -C $candidate remote add origin $row.Repository
if ($LASTEXITCODE -ne 0) { throw "Unable to set source remote." }
& git -C $candidate fetch --depth 1 origin $Commit
if ($LASTEXITCODE -ne 0) { throw "Unable to fetch requested commit. Candidate files retained at $candidate" }
$resolved = (& git -C $candidate rev-parse FETCH_HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $resolved -cne $Commit) { throw "Fetched commit does not match the requested SHA." }

if ($Apply -eq "orbital") {
    if (-not $OrbitalSourcePath) { $OrbitalSourcePath = Join-Path (Split-Path -Parent $root) "Orbital" }
    if (-not (Test-Path -LiteralPath $OrbitalSourcePath -PathType Container)) { throw "Orbital source not found: $OrbitalSourcePath" }
    $orbitalHead = (& git -C $OrbitalSourcePath rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $orbitalHead -cne $Commit) {
        throw "Orbital worktree HEAD must already equal requested commit. It will not be reset or cleaned."
    }
}

$updatedRows = @()
foreach ($item in $rows) {
    if ($item.Component -ceq $Apply) {
        $updatedRows += "$($item.Component)`t$($item.Repository)`t$Commit`t$Version`t$($item.License)"
    } else {
        $updatedRows += "$($item.Component)`t$($item.Repository)`t$($item.Commit)`t$($item.Version)`t$($item.License)"
    }
}
$lockText = "component`trepository`tcommit`tversion`tlicense`n" + ($updatedRows -join "`n") + "`n"
$temporaryLock = "$lockPath.$runId.tmp"
[System.IO.File]::WriteAllText($temporaryLock, $lockText, [System.Text.UTF8Encoding]::new($false))
if (Test-Path -LiteralPath $lockPath -PathType Leaf) {
    $lockStatus = @(& git -C $root status --porcelain=v1 -- config/source-revisions.lock.tsv)
    if ($LASTEXITCODE -ne 0 -or $lockStatus.Count -gt 0) {
        Remove-Item -LiteralPath $temporaryLock -Force
        throw "Source lock changed during upgrade preparation; retained the existing lock."
    }
}
Move-Item -LiteralPath $temporaryLock -Destination $lockPath

$output = Join-Path "out" "upgrades\$Apply-$runId"
$buildArgs = @("-NoProfile", "-File", (Join-Path $root "build.ps1"), "-Fresh", "-OutputDirectory", $output)
if ($OrbitalSourcePath) { $buildArgs += @("-OrbitalSourcePath", $OrbitalSourcePath) }
if ($SshPasswordFile) { $buildArgs += @("-SshPasswordFile", $SshPasswordFile) }
& (Get-Command pwsh).Source @buildArgs
$buildExit = $LASTEXITCODE
if ($buildExit -ne 0) {
    throw "Candidate lock remains in place but is not validated. Build exit code $buildExit; outputs and isolated source retained."
}

& (Get-Command pwsh).Source -NoProfile -File (Join-Path $root "verify-build.ps1") `
    -BuildRoot $root -OutputDirectory $output
if ($LASTEXITCODE -ne 0) { throw "Candidate build did not pass verify-build.ps1." }
Write-Host "Upgrade candidate passed the full build and artifact verification: $output"
