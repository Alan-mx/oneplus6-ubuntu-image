$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$askpass = Join-Path $root "state\ssh-askpass-orbital.cmd"
$env:SSH_ASKPASS = $askpass
$env:SSH_ASKPASS_REQUIRE = "force"
$env:DISPLAY = "localhost:0"

$remoteCommand = @'
echo ===dns===
readlink -f /etc/resolv.conf
resolvectl status | grep -A6 -E "Global|Link .*wlan0"
getent ahostsv4 ntp.ntsc.ac.cn | head -4
echo ===time===
timedatectl
chronyc sources -v
echo ===linger===
loginctl show-user orbital -p Linger
systemctl is-active rtkit-daemon.service
systemctl --user is-active pipewire.service pipewire-pulse.service wireplumber.service
echo ===gpu===
sudo dmesg | grep -E "a630_(sqe|gmu)|adreno_request_fw" | tail -20
echo ===bluetooth===
printf 'dt_max_speed_hex='
od -An -tx1 -v /proc/device-tree/soc@0/geniqup@8c0000/serial@898000/bluetooth/max-speed 2>/dev/null | tr -d ' \n'
echo
sudo btmgmt info 2>&1 | head -40
bluetoothctl show 2>&1
'@

& ssh -o StrictHostKeyChecking=no `
    -o UserKnownHostsFile=NUL `
    -o PreferredAuthentications=password `
    -o PubkeyAuthentication=no `
    -o NumberOfPasswordPrompts=1 `
    orbital@172.16.42.1 `
    $remoteCommand

exit $LASTEXITCODE
