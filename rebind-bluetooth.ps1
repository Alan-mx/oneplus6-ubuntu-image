$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$askpass = Join-Path $root "state\ssh-askpass-orbital.cmd"
$env:SSH_ASKPASS = $askpass
$env:SSH_ASKPASS_REQUIRE = "force"
$env:DISPLAY = "localhost:0"

$remoteCommand = @'
set -u
sudo systemctl stop bluetooth
sudo sh -c 'echo serial0-0 > /sys/bus/serial/drivers/hci_uart_qca/unbind' 2>&1 || true
sudo sh -c 'echo wcn3990-pmu > /sys/bus/platform/drivers/pwrseq-qcom_wcn/unbind' 2>&1 || true
sleep 2
sudo sh -c 'echo wcn3990-pmu > /sys/bus/platform/drivers/pwrseq-qcom_wcn/bind' 2>&1 || true
sleep 2
sudo sh -c 'echo serial0-0 > /sys/bus/serial/drivers/hci_uart_qca/bind' 2>&1 || true
sleep 6
sudo systemctl start bluetooth
sleep 2
echo ===hci===
hciconfig -a 2>&1 | head -40
echo ===mgmt===
sudo btmgmt info 2>&1 | head -80
echo ===bluetoothctl===
bluetoothctl show 2>&1
echo ===wifi===
nmcli dev status
'@

& ssh -o StrictHostKeyChecking=no `
    -o UserKnownHostsFile=NUL `
    -o PreferredAuthentications=password `
    -o PubkeyAuthentication=no `
    -o NumberOfPasswordPrompts=1 `
    orbital@172.16.42.1 `
    $remoteCommand

exit $LASTEXITCODE
