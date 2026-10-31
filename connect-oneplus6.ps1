param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemoteCommand
)

$ErrorActionPreference = "Stop"
$hostName = "172.16.42.1"
$knownHosts = Join-Path $HOME ".ssh\known_hosts"

if (Test-Path -LiteralPath $knownHosts) {
    & ssh-keygen -R $hostName -f $knownHosts | Out-Null
}

$sshArgs = @(
    "-o", "StrictHostKeyChecking=accept-new",
    "orbital@$hostName"
)
if ($RemoteCommand.Count -gt 0) {
    $sshArgs += ($RemoteCommand -join " ")
}

& ssh @sshArgs
exit $LASTEXITCODE
