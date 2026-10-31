#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="/workspace/oneplus6-image"
WORK="${BUILD_WORK_DIR:-/work}"
CONFIG_FILE="${CONFIG_FILE:-$ROOT/config/build.env}"

# shellcheck disable=SC1090
source "$CONFIG_FILE"

# shellcheck disable=SC1091
# shellcheck source=scripts/orbital-auth.sh
source "$ROOT/scripts/orbital-auth.sh"

sha256() {
    sha256sum "$1" | awk '{print $1}'
}

require_sha256() {
    local path="$1"
    local expected="$2"
    local label="$3"

    [[ -f "$path" ]] || {
        echo "$label not found: $path" >&2
        exit 1
    }
    [[ "$(sha256 "$path")" == "$expected" ]] || {
        echo "$label SHA-256 mismatch: $path" >&2
        exit 1
    }
}

verify_ubuntu_package_lock() {
    local rootfs="$1"
    local actual="$WORK/ubuntu-packages-actual.tsv"

    dpkg-query --admindir="$rootfs/var/lib/dpkg" -W \
        -f='${Package}\t${Version}\t${Architecture}\n' \
        | LC_ALL=C sort > "$actual"
    if ! cmp -s "$UBUNTU_PACKAGE_LOCK" "$actual"; then
        diff -u "$UBUNTU_PACKAGE_LOCK" "$actual" || true
        echo "installed Ubuntu package set does not match $UBUNTU_PACKAGE_LOCK" >&2
        exit 1
    fi
    cp "$actual" "$ROOT/state/ubuntu-packages.tsv"
}

SSH_PUBLIC_KEY_FILE="${SSH_PUBLIC_KEY_FILE_OVERRIDE:-${SSH_PUBLIC_KEY_FILE:-}}"
SSH_PASSWORD_FILE="${SSH_PASSWORD_FILE_OVERRIDE:-${SSH_PASSWORD_FILE:-}}"
SSH_AUTH_MODE="${SSH_AUTH_MODE:-}"

password_hash=""
if [[ "$SSH_AUTH_MODE" == "fixed-password-file" &&
      -n "$SSH_PASSWORD_FILE" && -s "$SSH_PASSWORD_FILE" ]]; then
    ssh_password=""
    IFS= read -r ssh_password < "$SSH_PASSWORD_FILE" || true
    [[ -n "$ssh_password" ]] || {
        echo "SSH password file is empty: $SSH_PASSWORD_FILE" >&2
        exit 2
    }
    password_hash="$(openssl passwd -6 "$ssh_password")"
elif [[ "$SSH_AUTH_MODE" == "public-key" &&
        -n "$SSH_PUBLIC_KEY_FILE" && -f "$SSH_PUBLIC_KEY_FILE" ]]; then
    ssh-keygen -lf "$SSH_PUBLIC_KEY_FILE" >/dev/null
else
    echo "Invalid SSH_AUTH_MODE or missing SSH authentication input: $SSH_AUTH_MODE" >&2
    exit 2
fi

run_in_rootfs() {
    local rootfs="$1"
    shift
    PROOT_NO_SECCOMP=1 proot \
        -q /usr/bin/qemu-aarch64 \
        -r "$rootfs" \
        -b /dev \
        -b /proc \
        -b /sys \
        -w / \
        "$@"
}

install_qualcomm_helpers() {
    local rootfs
    require_sha256 "$ROOT/inputs/tqftpserv/tqftpserv" \
        "$TQFPSERV_SHA256" "tqftpserv"
    require_sha256 "$ROOT/inputs/pd-mapper/pd-mapper" \
        "$PD_MAPPER_SHA256" "pd-mapper"
    require_sha256 "$ROOT/inputs/rmtfs/rmtfs" \
        "$RMTFS_SHA256" "rmtfs"
    for rootfs in "$WORK/rootfs-base" "$WORK/rootfs-orbital"; do
        [[ -d "$rootfs" ]] || continue
        install -D -m 0755 "$ROOT/inputs/tqftpserv/tqftpserv" \
            "$rootfs/usr/bin/tqftpserv"
        install -D -m 0644 "$ROOT/config/tqftpserv.service" \
            "$rootfs/etc/systemd/system/tqftpserv.service"
        install -D -m 0755 "$ROOT/inputs/pd-mapper/pd-mapper" \
            "$rootfs/usr/bin/pd-mapper"
        install -D -m 0644 "$ROOT/config/pd-mapper.service" \
            "$rootfs/etc/systemd/system/pd-mapper.service"
        install -D -m 0755 "$ROOT/config/orbital-remoteproc-wait" \
            "$rootfs/usr/local/sbin/orbital-remoteproc-wait"
        install -D -m 0755 "$ROOT/inputs/rmtfs/rmtfs" \
            "$rootfs/usr/bin/rmtfs"
        install -D -m 0644 "$ROOT/config/rmtfs.service" \
            "$rootfs/etc/systemd/system/rmtfs.service"
        install -D -m 0755 "$ROOT/config/orbital-rmtfs-wait" \
            "$rootfs/usr/local/sbin/orbital-rmtfs-wait"
        install -D -m 0644 "$ROOT/config/orbital-msm-modem.service" \
            "$rootfs/etc/systemd/system/orbital-msm-modem.service"
        install -D -m 0644 "$ROOT/config/orbital-resize-rootfs.service" \
            "$rootfs/etc/systemd/system/orbital-resize-rootfs.service"
        install -D -m 0755 "$ROOT/config/orbital-wifi-mac" \
            "$rootfs/usr/local/sbin/orbital-wifi-mac"
        install -D -m 0644 "$ROOT/config/orbital-wifi-mac.service" \
            "$rootfs/etc/systemd/system/orbital-wifi-mac.service"
        install -D -m 0644 "$ROOT/config/90-orbital-wifi-mac.rules" \
            "$rootfs/etc/udev/rules.d/90-orbital-wifi-mac.rules"
        run_in_rootfs "$rootfs" systemctl disable bluetooth.service 2>/dev/null || true
        install -D -m 0755 "$ROOT/config/orbital-msm-modem-start" \
            "$rootfs/usr/local/sbin/orbital-msm-modem-start"
        rm -f "$rootfs/etc/systemd/system/systemd-backlight@backlight:ae94000.dsi.0.service"
        install -d "$rootfs/etc/systemd/system/multi-user.target.wants"
        ln -snf /etc/systemd/system/tqftpserv.service \
            "$rootfs/etc/systemd/system/multi-user.target.wants/tqftpserv.service"
        ln -snf /etc/systemd/system/pd-mapper.service \
            "$rootfs/etc/systemd/system/multi-user.target.wants/pd-mapper.service"
        ln -snf /etc/systemd/system/rmtfs.service \
            "$rootfs/etc/systemd/system/multi-user.target.wants/rmtfs.service"
        ln -snf /etc/systemd/system/orbital-msm-modem.service \
            "$rootfs/etc/systemd/system/multi-user.target.wants/orbital-msm-modem.service"
        ln -snf /etc/systemd/system/orbital-resize-rootfs.service \
            "$rootfs/etc/systemd/system/multi-user.target.wants/orbital-resize-rootfs.service"
        install -D -m 0644 "$ROOT/config/99auto-upgrades-orbital" \
            "$rootfs/etc/apt/apt.conf.d/99auto-upgrades-orbital"
        install -D -m 0644 "$ROOT/config/99unattended-upgrades-orbital" \
            "$rootfs/etc/apt/apt.conf.d/99unattended-upgrades-orbital"
        # shellcheck disable=SC2016
        if ! run_in_rootfs "$rootfs" dpkg-query -W -f='${Status}' unattended-upgrades \
            2>/dev/null | grep -q "install ok installed"; then
            echo "unattended-upgrades is missing from $rootfs" >&2
            exit 1
        fi
        run_in_rootfs "$rootfs" systemctl enable \
            apt-daily.timer apt-daily-upgrade.timer
    done
}

configure_runtime_services() {
    local rootfs="$1"

    install -D -m 0644 "$ROOT/config/orbital-release" \
        "$rootfs/etc/orbital-release"
    ln -snf /run/systemd/resolve/stub-resolv.conf "$rootfs/etc/resolv.conf"
    install -D -m 0644 "$ROOT/config/chrony-orbital.sources" \
        "$rootfs/etc/chrony/sources.d/orbital-ntp.sources"
    install -d -m 0755 "$rootfs/var/lib/systemd/linger"
    install -m 0644 /dev/null "$rootfs/var/lib/systemd/linger/$SSH_USER"

    run_in_rootfs "$rootfs" systemctl enable systemd-resolved.service
    # shellcheck disable=SC2016
    if ! run_in_rootfs "$rootfs" dpkg-query -W -f='${Status}' rtkit 2>/dev/null \
        | grep -q "install ok installed"; then
        echo "rtkit is missing from $rootfs; run a full build first" >&2
        exit 1
    fi
    run_in_rootfs "$rootfs" systemctl enable rtkit-daemon.service
    run_in_rootfs "$rootfs" systemctl --global enable \
        pipewire.service \
        pipewire-pulse.service \
        wireplumber.service
}

configure_auth() {
    local rootfs="$1"
    local password_authentication="no"
    local pubkey_authentication="no"

    install_orbital_password_controls "$rootfs" "$ROOT/config"
    run_in_rootfs "$rootfs" systemctl enable orbital-default-password-check.path
    if [[ "$SSH_AUTH_MODE" == "fixed-password-file" ]]; then
        password_authentication="yes"
        run_in_rootfs "$rootfs" /usr/sbin/usermod -p "$password_hash" "$SSH_USER"
        rm -rf "$rootfs/home/$SSH_USER/.ssh"
        mark_default_password_pending "$rootfs" "$SSH_USER"
    else
        local uid gid
        uid="$(awk -F: -v user="$SSH_USER" '$1 == user {print $3}' "$rootfs/etc/passwd")"
        gid="$(awk -F: -v user="$SSH_USER" '$1 == user {print $4}' "$rootfs/etc/passwd")"
        pubkey_authentication="yes"
        install -d -m 0700 -o "$uid" -g "$gid" "$rootfs/home/$SSH_USER/.ssh"
        install -m 0600 -o "$uid" -g "$gid" "$SSH_PUBLIC_KEY_FILE" \
            "$rootfs/home/$SSH_USER/.ssh/authorized_keys"
        clear_default_password_pending "$rootfs"
    fi

    cat > "$rootfs/etc/ssh/sshd_config.d/50-orbital.conf" <<EOF
PermitRootLogin no
PasswordAuthentication $password_authentication
KbdInteractiveAuthentication no
PubkeyAuthentication $pubkey_authentication
AllowUsers $SSH_USER
EOF
}

build_image() {
    local rootfs="$1"
    local label="$2"
    local sparse="$3"
    local raw="$WORK/${label}.raw"

    configure_runtime_services "$rootfs"
    configure_auth "$rootfs"
    rm -f "$rootfs/usr/sbin/policy-rc.d"
    rm -f "$raw" "$sparse"
    truncate -s "$((ROOTFS_SIZE_MIB * 1024 * 1024))" "$raw"
    mke2fs -q -F -t ext4 -b "$ROOTFS_BLOCK_SIZE" -I 256 \
        -E lazy_itable_init=0,lazy_journal_init=0 \
        -O ^64bit,^flex_bg,^metadata_csum,^metadata_csum_seed,^uninit_bg,^orphan_file \
        -L "$label" -d "$rootfs" "$raw"
    e2fsck -fy "$raw" > "$ROOT/state/e2fsck-${label}-final.log"
    e2fsck -fn "$raw" > "$ROOT/state/e2fsck-${label}-check.log"
    img2simg "$raw" "$sparse" "$ROOTFS_BLOCK_SIZE"
}

depmod -b "$WORK/rootfs-base" -a "$KERNEL_RELEASE"
depmod -b "$WORK/rootfs-orbital" -a "$KERNEL_RELEASE"
install_qualcomm_helpers

build_image "$WORK/rootfs-base" ORBITAL_BASE "$ROOT/out/oneplus6-rootfs-ubuntu.img"
verify_ubuntu_package_lock "$WORK/rootfs-orbital"
build_image "$WORK/rootfs-orbital" ORBITAL_DESKTOP "$ROOT/out/oneplus6-rootfs-orbital.img"

verify_dtb_args=()
if [[ -f "$WORK/boot/sdm845-oneplus-enchilada.dtb" ]]; then
    verify_dtb_args=(--dtb "$WORK/boot/sdm845-oneplus-enchilada.dtb")
fi
python3 "$ROOT/scripts/verify_images.py" \
    --boot "$ROOT/out/oneplus6-boot.img" \
    "${verify_dtb_args[@]}" \
    --base-sparse "$ROOT/out/oneplus6-rootfs-ubuntu.img" \
    --orbital-sparse "$ROOT/out/oneplus6-rootfs-orbital.img" \
    --expected-size "$((ROOTFS_SIZE_MIB * 1024 * 1024))" \
    --output "$ROOT/state/verification.json"

printf 'tqftpserv=%s\n' \
    "$(sha256 "$WORK/rootfs-base/usr/bin/tqftpserv")" \
    > "$ROOT/state/tqftpserv-consistency.txt"
printf 'pd-mapper=%s\n' \
    "$(sha256 "$WORK/rootfs-base/usr/bin/pd-mapper")" \
    > "$ROOT/state/pd-mapper-consistency.txt"
printf 'rmtfs=%s\n' \
    "$(sha256 "$WORK/rootfs-base/usr/bin/rmtfs")" \
    > "$ROOT/state/rmtfs-consistency.txt"
if [[ "$SSH_AUTH_MODE" == "fixed-password-file" ]]; then
    printf 'mode=fixed-password-file\nuser=%s\n' \
        "$SSH_USER" > "$ROOT/state/ssh-auth.txt"
    echo "Images refreshed with password authentication for $SSH_USER"
else
    printf 'mode=public-key\nuser=%s\n' \
        "$SSH_USER" > "$ROOT/state/ssh-auth.txt"
    echo "Images refreshed with SSH public key authentication"
fi

finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [[ -f "$ROOT/state/build-state.json" ]]; then
    jq \
        --argjson release_version "$RELEASE_VERSION" \
        --arg release_name "$RELEASE_NAME" \
        --arg finished_at "$finished_at" \
        --arg ssh_auth_mode "$SSH_AUTH_MODE" \
        '
            .phase = "complete"
            | .release_version = $release_version
            | .release_name = $release_name
            | .finished_at = $finished_at
            | .ssh_auth_mode = $ssh_auth_mode
            | del(.ssh_key_fingerprint)
        ' "$ROOT/state/build-state.json" > "$ROOT/state/build-state.json.tmp"
    mv "$ROOT/state/build-state.json.tmp" "$ROOT/state/build-state.json"
fi
