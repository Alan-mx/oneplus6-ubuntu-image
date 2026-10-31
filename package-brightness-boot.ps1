$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$workspace = Split-Path -Parent $root
$output = Join-Path $root "out\oneplus6-boot-brightness-test.img"

$containerScript = @'
set -euo pipefail
K=/work/kernel-test-COxIQb
cp "$K/arch/arm64/boot/Image.gz" /work/boot/vmlinuz-dtb-brightness-test
dd if=/work/boot/sdm845-oneplus-enchilada.dtb \
   of=/work/boot/vmlinuz-dtb-brightness-test \
   oflag=append conv=notrunc status=none
mkbootimg \
    --header_version 0 \
    --kernel /work/boot/vmlinuz-dtb-brightness-test \
    --ramdisk /work/boot/initramfs.cpio.gz \
    --base 0x00000000 \
    --kernel_offset 0x00008000 \
    --ramdisk_offset 0x01000000 \
    --second_offset 0x00f00000 \
    --tags_offset 0x00000100 \
    --pagesize 4096 \
    --cmdline "console=ttyMSM0,115200 earlycon=tty0 earlyprintk root=/dev/sda17 rootfstype=ext4 rootwait=10 loglevel=7 net.ifnames=0 rw" \
    -o /workspace/oneplus6-image/out/oneplus6-boot-brightness-test.img
'@

& docker run --rm `
    -v "${workspace}:/workspace" `
    --mount "type=volume,src=oneplus6-image-work,dst=/work" `
    --entrypoint bash `
    oneplus6-image-builder:26.04 `
    -lc $containerScript

if ($LASTEXITCODE -ne 0) {
    throw "Failed to package the brightness test boot image"
}

Get-Item -LiteralPath $output | Select-Object FullName, Length, LastWriteTime
Get-FileHash -Algorithm SHA256 -LiteralPath $output
