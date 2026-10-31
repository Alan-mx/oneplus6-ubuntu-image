#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="/workspace/oneplus6-image"
WORK="${BUILD_WORK_DIR:-/work}"
CONFIG_FILE="${CONFIG_FILE:-$ROOT/config/build.env}"

# shellcheck disable=SC1090
source "$CONFIG_FILE"

STAGE="$WORK/runtime-fix-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"

for package in \
    "firmware-qcom-adreno-a630-20260110-r1.apk" \
    "firmware-qcom-adreno-a630-sqe-20260110-r1.apk"; do
    package_stage="$STAGE/${package%.apk}"
    mkdir -p "$package_stage"
    tar --warning=no-unknown-keyword -xpf "$ROOT/inputs/nura/$package" -C "$package_stage"
done

ath10k_stage="$STAGE/linux-firmware-ath10k"
mkdir -p "$ath10k_stage"
tar --warning=no-unknown-keyword -xpf \
    "$ROOT/inputs/alpine/linux-firmware-ath10k-20260916-r0.apk" \
    -C "$ath10k_stage"

for rootfs in "$WORK/rootfs-base" "$WORK/rootfs-orbital"; do
    while IFS= read -r firmware; do
        rsync -a "$firmware/" "$rootfs/usr/lib/firmware/"
    done < <(find "$STAGE" -type d \
        \( -path '*/linux-firmware-ath10k*/usr/lib/firmware' \
        -o -path '*/linux-firmware-ath10k*/lib/firmware' \) -print)
    while IFS= read -r firmware; do
        rsync -a "$firmware/" "$rootfs/usr/lib/firmware/"
    done < <(find "$STAGE" -type d -path '*/usr/lib/firmware' \
        ! -path '*/linux-firmware-ath10k/*' -print)

    install -d "$rootfs/usr/lib/firmware/qca"
    ln -snf ../postmarketos/qca/crbtfw21.tlv \
        "$rootfs/usr/lib/firmware/qca/crbtfw21.tlv"
    ln -snf OnePlus/enchilada/crnv21.bin \
        "$rootfs/usr/lib/firmware/qca/crnv21.bin"
    [ -f "$rootfs/usr/lib/firmware/ath10k/WCN3990/hw1.0/board-2.bin.zst" ] || {
        echo "WCN3990 board-2.bin.zst is missing" >&2
        exit 1
    }

    install -D -m 0644 "$ROOT/config/logind-orbital.conf" \
        "$rootfs/etc/systemd/logind.conf.d/50-orbital-power.conf"
    install -D -m 0644 "$ROOT/config/modules-load-orbital.conf" \
        "$rootfs/etc/modules-load.d/orbital-wifi.conf"
    install -D -m 0755 "$ROOT/config/orbital-usb-gadget" \
        "$rootfs/usr/local/sbin/orbital-usb-gadget"
    install -D -m 0644 "$ROOT/config/orbital-usb-gadget.service" \
        "$rootfs/etc/systemd/system/orbital-usb-gadget.service"
    install -D -m 0644 "$ROOT/config/NetworkManager-orbital.conf" \
        "$rootfs/etc/NetworkManager/conf.d/50-orbital-usb-unmanaged.conf"
    install -D -m 0755 "$ROOT/config/orbital-usb-network" \
        "$rootfs/usr/local/sbin/orbital-usb-network"
    install -D -m 0644 "$ROOT/config/orbital-usb-network.service" \
        "$rootfs/etc/systemd/system/orbital-usb-network.service"
    install -D -m 0644 "$ROOT/config/orbital-dnsmasq.conf" \
        "$rootfs/etc/orbital-dnsmasq.conf"
    ln -snf /etc/systemd/system/orbital-usb-network.service \
        "$rootfs/etc/systemd/system/multi-user.target.wants/orbital-usb-network.service"

    depmod -b "$rootfs" -a "$KERNEL_RELEASE"
done

rm -rf "$STAGE"

bash "$ROOT/scripts/refresh-images.sh"
