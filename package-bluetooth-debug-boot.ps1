$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$workspace = Split-Path -Parent $root
$output = Join-Path $root "out\oneplus6-boot-bluetooth-debug.img"

$containerScript = @'
set -euo pipefail
K=/work/kernel-test-COxIQb
DTB=/work/boot/sdm845-oneplus-enchilada-bt-debug.dtb
cp /work/boot/sdm845-oneplus-enchilada.dtb "$DTB"
fdtput -t x "$DTB" /soc@0/geniqup@8c0000/serial@898000/bluetooth max-speed 0x1c200
test "$(fdtget -t x "$DTB" /soc@0/geniqup@8c0000/serial@898000/bluetooth max-speed)" = "1c200"
cp "$K/arch/arm64/boot/Image.gz" /work/boot/vmlinuz-dtb-bt-debug
dd if="$DTB" of=/work/boot/vmlinuz-dtb-bt-debug \
   oflag=append conv=notrunc status=none
mkbootimg \
    --header_version 0 \
    --kernel /work/boot/vmlinuz-dtb-bt-debug \
    --ramdisk /work/boot/initramfs.cpio.gz \
    --base 0x00000000 \
    --kernel_offset 0x00008000 \
    --ramdisk_offset 0x01000000 \
    --second_offset 0x00f00000 \
    --tags_offset 0x00000100 \
    --pagesize 4096 \
    --cmdline 'console=ttyMSM0,115200 console=tty0 root=/dev/sda17 rootfstype=ext4 rootwait=10 loglevel=0 vt.global_cursor_default=0 systemd.show_status=1 systemd.log_level=info net.ifnames=0 rw dyndbg="file drivers/bluetooth/hci_serdev.c +p; file drivers/bluetooth/hci_qca.c +p; file drivers/bluetooth/btqca.c +p; file net/bluetooth/hci_core.c +p; file net/bluetooth/hci_sync.c +p"' \
    -o /workspace/oneplus6-image/out/oneplus6-boot-bluetooth-debug.img
'@

& docker run --rm `
    -v "${workspace}:/workspace" `
    --mount "type=volume,src=oneplus6-image-work,dst=/work" `
    --entrypoint bash `
    oneplus6-image-builder:26.04 `
    -lc $containerScript

if ($LASTEXITCODE -ne 0) {
    throw "Failed to package the Bluetooth debug image"
}

Get-Item -LiteralPath $output | Select-Object FullName, Length, LastWriteTime
Get-FileHash -Algorithm SHA256 -LiteralPath $output
