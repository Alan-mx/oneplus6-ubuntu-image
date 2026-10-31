#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="/workspace/oneplus6-image"
WORK="${BUILD_WORK_DIR:-$ROOT/work}"
CONFIG_FILE="${CONFIG_FILE:-$ROOT/config/build.env}"

# shellcheck disable=SC1091
# shellcheck source=scripts/orbital-auth.sh
source "$ROOT/scripts/orbital-auth.sh"

log() {
    printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2
}

fail() {
    log "ERROR: $*"
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

sha256() {
    sha256sum "$1" | awk '{print $1}'
}

require_sha256() {
    local path="$1"
    local expected="$2"
    local label="$3"

    [[ -f "$path" ]] || fail "$label not found: $path"
    [[ "$(sha256 "$path")" == "$expected" ]] \
        || fail "$label SHA-256 mismatch: $path"
}

download() {
    local url="$1"
    local output="$2"
    local expected="${3:-}"
    mkdir -p "$(dirname "$output")"
    if [[ -f "$output" ]]; then
        if [[ -z "$expected" || "$(sha256 "$output")" == "$expected" ]]; then
            return 0
        fi
        rm -f "$output"
    fi
    log "Downloading $url"
    curl --fail --location --retry 5 --retry-delay 3 --connect-timeout 30 \
        --output "$output.part" "$url"
    mv "$output.part" "$output"
    if [[ -n "$expected" && "$(sha256 "$output")" != "$expected" ]]; then
        fail "SHA-256 mismatch for $output"
    fi
}

chroot_run() {
    local rootfs="$1"
    shift
    PROOT_NO_SECCOMP=1 proot \
        -q /usr/bin/qemu-aarch64 \
        -r "$rootfs" \
        -b /dev \
        -b /proc \
        -b /sys \
        -b /etc/resolv.conf:/etc/resolv.conf \
        -w /root \
        /usr/bin/env \
        HOME=/root \
        LANG=C.UTF-8 \
        LC_ALL=C.UTF-8 \
        DEBIAN_FRONTEND=noninteractive \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        "$@"
}

sanitize_wcn3990_dtb() {
    local dtb="$1"
    [[ -f "$dtb" ]] || fail "DTB not found: $dtb"

    if fdtget "$dtb" /wcn3990-pmu pinctrl-0 >/dev/null 2>&1; then
        fdtput -d "$dtb" /wcn3990-pmu pinctrl-0
    fi
    if fdtget "$dtb" /wcn3990-pmu pinctrl-names >/dev/null 2>&1; then
        fdtput -d "$dtb" /wcn3990-pmu pinctrl-names
    fi

    if fdtget "$dtb" /wcn3990-pmu pinctrl-0 >/dev/null 2>&1 ||
       fdtget "$dtb" /wcn3990-pmu pinctrl-names >/dev/null 2>&1; then
        fail "failed to remove WCN3990 PMU pinctrl properties from DTB"
    fi
}

clean_build_tree() {
    case "$WORK" in
        /work|/workspace/oneplus6-image/work) ;;
        *) fail "unsafe work path: $WORK" ;;
    esac
    if [[ "${FRESH_BUILD:-0}" == "1" ]]; then
        find "$WORK" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
    fi
    mkdir -p "$WORK/rootfs-base" "$WORK/rootfs-orbital" \
        "$WORK/boot" "$WORK/apk-stage" "$WORK/validate"
    rm -f "$ROOT/out"/*.img
}

stub_systemd_command() {
    local rootfs="$1"
    local path="$2"
    local legacy="$rootfs$path.proot-real"

    if [[ ! -e "$rootfs$path" && -e "$legacy" ]]; then
        mv "$legacy" "$rootfs$path"
    fi
    rm -f "$legacy"
    [[ -e "$rootfs$path" ]] || return 0
    if ! chroot_run "$rootfs" /usr/bin/dpkg-divert --local --list | grep -qF "$path"; then
        chroot_run "$rootfs" /usr/bin/dpkg-divert --local --rename --add "$path" >/dev/null
    fi
    rm -f "$rootfs$path"
    printf '#!/bin/sh\nexit 0\n' > "$rootfs$path"
    chmod 0755 "$rootfs$path"
}

stub_systemd_sysusers() {
    local rootfs="$1"
    stub_systemd_command "$rootfs" /usr/bin/systemd-sysusers
    stub_systemd_command "$rootfs" /usr/bin/systemd-tmpfiles
}

restore_systemd_command() {
    local rootfs="$1"
    local path="$2"

    rm -f "$rootfs$path.proot-real"
    if chroot_run "$rootfs" /usr/bin/dpkg-divert --local --list | grep -qF "$path"; then
        rm -f "$rootfs$path"
        chroot_run "$rootfs" /usr/bin/dpkg-divert --local --rename --remove "$path" >/dev/null
    fi
    if [[ ! -e "$rootfs$path" && -e "$rootfs$path.distrib" ]]; then
        mv "$rootfs$path.distrib" "$rootfs$path"
    fi
}

restore_systemd_sysusers() {
    local rootfs="$1"
    restore_systemd_command "$rootfs" /usr/bin/systemd-tmpfiles
    restore_systemd_command "$rootfs" /usr/bin/systemd-sysusers
}

install_build_policy_rc() {
    local rootfs="$1"
    install -D -m 0755 "$ROOT/config/policy-rc.d" \
        "$rootfs/usr/sbin/policy-rc.d"
}

remove_build_policy_rc() {
    local rootfs="$1"
    rm -f "$rootfs/usr/sbin/policy-rc.d"
}

validate_config() {
    [[ -f "$CONFIG_FILE" ]] || fail "config not found: $CONFIG_FILE"
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    SSH_PUBLIC_KEY_FILE="${SSH_PUBLIC_KEY_FILE_OVERRIDE:-${SSH_PUBLIC_KEY_FILE:-}}"
    SSH_PASSWORD_FILE="${SSH_PASSWORD_FILE_OVERRIDE:-${SSH_PASSWORD_FILE:-}}"
    SSH_AUTH_MODE="${SSH_AUTH_MODE:-}"
    [[ "$DEVICE_ID" == "oneplus-enchilada" ]] || fail "device must be oneplus-enchilada"
    [[ "$UBUNTU_VERSION" == "26.04.1" ]] || fail "Ubuntu must be 26.04.1"
    [[ "$KERNEL_VERSION" == "7.1_rc1-r0" ]] || fail "kernel must be 7.1_rc1-r0"
    [[ "$KERNEL_RELEASE" == "7.1.0-rc1-sdm845" ]] || fail "unexpected kernel release"
    [[ "$ROOTFS_SIZE_MIB" -ge 3072 ]] || fail "bootstrap rootfs must be at least 3 GiB"
    [[ "$ROOTFS_BLOCK_SIZE" -eq 4096 ]] || fail "rootfs block size must be 4096"
    [[ -f "$APK_SHA256_LOCK" ]] || fail "APK SHA-256 lock not found: $APK_SHA256_LOCK"
    [[ -f "$UBUNTU_PACKAGE_LOCK" ]] \
        || fail "Ubuntu package lock not found: $UBUNTU_PACKAGE_LOCK"
    require_sha256 "$ROOT/inputs/boot/oneplus6-boot-gpu-fix.img" \
        "$BOOT_IMAGE_OVERRIDE_SHA256" "boot image override"
    require_sha256 "$ROOT/inputs/tqftpserv/tqftpserv" \
        "$TQFPSERV_SHA256" "tqftpserv"
    require_sha256 "$ROOT/inputs/pd-mapper/pd-mapper" \
        "$PD_MAPPER_SHA256" "pd-mapper"
    require_sha256 "$ROOT/inputs/rmtfs/rmtfs" \
        "$RMTFS_SHA256" "rmtfs"
    case "$SSH_AUTH_MODE" in
        fixed-password-file)
            [[ -s "$SSH_PASSWORD_FILE" ]] \
                || fail "SSH_PASSWORD_FILE is missing or empty: $SSH_PASSWORD_FILE"
            ;;
        public-key)
            [[ -f "$SSH_PUBLIC_KEY_FILE" ]] \
                || fail "SSH_PUBLIC_KEY_FILE is missing: $SSH_PUBLIC_KEY_FILE"
            ssh-keygen -lf "$SSH_PUBLIC_KEY_FILE" >/dev/null \
                || fail "invalid SSH public key: $SSH_PUBLIC_KEY_FILE"
            ;;
        *)
            fail "unsupported SSH_AUTH_MODE: $SSH_AUTH_MODE"
            ;;
    esac
    git -C "$ORBITAL_SOURCE_DIR" rev-parse HEAD >/dev/null || fail "Orbital source is not a git worktree"
    for cmd in curl tar gzip cpio sha256sum mke2fs dumpe2fs debugfs e2fsck img2simg mkbootimg \
        fdtget fdtput proot qemu-aarch64 useradd rsync cmake git jq openssl python3; do
        require_cmd "$cmd"
    done
}

write_apt_sources() {
    local rootfs="$1"
    local mirror="$2"

    rm -rf "$rootfs/etc/apt/sources.list.d"
    cat > "$rootfs/etc/apt/sources.list" <<EOF
deb $mirror $UBUNTU_CODENAME main restricted universe multiverse
deb $mirror $UBUNTU_CODENAME-updates main restricted universe multiverse
deb $mirror $UBUNTU_CODENAME-security main restricted universe multiverse
EOF
}

apk_lock_sha() {
    local filename="$1"
    awk -v filename="$filename" '$2 == filename { print $1; found=1 } END { exit !found }' \
        "$APK_SHA256_LOCK"
}

verify_apk_lock_set() {
    local resolved locked
    resolved="$(
        jq -r '.packages[].filename' \
            "$ROOT/state/apk-packages.json" \
            "$ROOT/state/apk-packages-alpine.json" | sort
    )"
    locked="$(awk 'NF >= 2 { print $2 }' "$APK_SHA256_LOCK" | sort)"
    if [[ "$resolved" != "$locked" ]]; then
        diff -u <(printf '%s\n' "$locked") <(printf '%s\n' "$resolved") || true
        fail "resolved APK set does not match $APK_SHA256_LOCK"
    fi
}

verify_apk_package() {
    local state_file="$1"
    local package="$2"
    local version="$3"

    jq -e --arg package "$package" --arg version "$version" \
        'any(.packages[]; .name == $package and .version == $version)' \
        "$state_file" >/dev/null \
        || fail "APK lock mismatch for $package: expected $version"
}

verify_ubuntu_package_lock() {
    local rootfs="$1"
    local actual="$WORK/ubuntu-packages-actual.tsv"

    dpkg-query --admindir="$rootfs/var/lib/dpkg" -W \
        -f='${Package}\t${Version}\t${Architecture}\n' \
        | LC_ALL=C sort > "$actual"
    if ! cmp -s "$UBUNTU_PACKAGE_LOCK" "$actual"; then
        diff -u "$UBUNTU_PACKAGE_LOCK" "$actual" || true
        fail "installed Ubuntu package set does not match $UBUNTU_PACKAGE_LOCK"
    fi
    cp "$actual" "$ROOT/state/ubuntu-packages.tsv"
}

install_locked_ubuntu_packages() {
    local rootfs="$1"
    local -a specs=()
    local package version _architecture

    while IFS=$'\t' read -r package version _architecture; do
        [[ -n "$package" && -n "$version" ]] || continue
        specs+=("$package=$version")
    done < "$UBUNTU_PACKAGE_LOCK"

    [[ "${#specs[@]}" -gt 0 ]] || fail "Ubuntu package lock is empty"
    chroot_run "$rootfs" apt-get \
        -o APT::Sandbox::User=root \
        -o Acquire::http::Timeout=60 \
        -o Acquire::Queue-Mode=access \
        -o Acquire::http::Pipeline-Depth=0 \
        -o Acquire::Retries=5 \
        -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold \
        install -y --no-install-recommends --allow-downgrades \
        "${specs[@]}"
}

write_initial_state() {
    mkdir -p "$ROOT/state" "$ROOT/logs" "$ROOT/out" "$ROOT/inputs"
    ORBITAL_COMMIT="$(git -C "$ORBITAL_SOURCE_DIR" rev-parse HEAD)"
    ORBITAL_DIFF_FILE="$ROOT/state/orbital.diff"
    git -C "$ORBITAL_SOURCE_DIR" diff --binary HEAD -- . > "$ORBITAL_DIFF_FILE"
    while IFS= read -r file; do
        git -C "$ORBITAL_SOURCE_DIR" diff --no-index --binary /dev/null "$file" >> "$ORBITAL_DIFF_FILE" || true
    done < <(git -C "$ORBITAL_SOURCE_DIR" ls-files --others --exclude-standard)
    ORBITAL_DIFF_SHA256="$(sha256 "$ORBITAL_DIFF_FILE")"
    if [[ "$SSH_AUTH_MODE" == "fixed-password-file" ]]; then
        SSH_KEY_FINGERPRINT="sha256:$(sha256 "$SSH_PASSWORD_FILE")"
    else
        SSH_KEY_FINGERPRINT="$(ssh-keygen -lf "$SSH_PUBLIC_KEY_FILE" | awk '{print $2}')"
    fi

    cat > "$ROOT/state/build-state.json" <<EOF
{
  "schema_version": 1,
  "phase": "prepare_rootfs",
  "orbital_commit": "$ORBITAL_COMMIT",
  "orbital_diff_sha256": "$ORBITAL_DIFF_SHA256",
  "ssh_auth_mode": "$SSH_AUTH_MODE",
  "ssh_key_fingerprint": "$SSH_KEY_FINGERPRINT"
}
EOF
}

write_final_state() {
    local finished_at
    finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    cat > "$ROOT/state/build-state.json" <<EOF
{
  "schema_version": 1,
  "phase": "complete",
  "release_version": $RELEASE_VERSION,
  "release_name": "$RELEASE_NAME",
  "finished_at": "$finished_at",
  "orbital_commit": "$ORBITAL_COMMIT",
  "orbital_diff_sha256": "$ORBITAL_DIFF_SHA256",
  "ssh_auth_mode": "$SSH_AUTH_MODE",
  "ssh_key_fingerprint": "$SSH_KEY_FINGERPRINT"
}
EOF
}

fetch_inputs() {
    local base="$ROOT/inputs/ubuntu/ubuntu-base-26.04.1-base-arm64.tar.gz"
    download "$UBUNTU_BASE_URL" "$base" "$UBUNTU_BASE_SHA256"
    local index="$ROOT/inputs/nura/APKINDEX.tar.gz"
    download "$NURA_REPO/$NURA_BRANCH/$NURA_ARCH/APKINDEX.tar.gz" \
        "$index" "$NURA_APKINDEX_SHA256"
    tar -xOf "$index" APKINDEX > "$WORK/APKINDEX"
    local alpine_index="$ROOT/inputs/alpine/APKINDEX.tar.gz"
    download "$ALPINE_REPO/APKINDEX.tar.gz" \
        "$alpine_index" "$ALPINE_APKINDEX_SHA256"
    tar -xOf "$alpine_index" APKINDEX > "$WORK/APKINDEX-alpine"

    python3 "$ROOT/scripts/resolve_apk.py" \
        --index "$WORK/APKINDEX" \
        --output "$ROOT/state/apk-packages.json" \
        --root "$KERNEL_PACKAGE" \
        --root "$DEVICE_PACKAGE" \
        --root "$FIRMWARE_PACKAGE" \
        --root "$ADRENO_FIRMWARE_PACKAGE" \
        --root "firmware-oneplus-sdm845-sensors" \
        --root "alsa-ucm-conf-sdm845" \
        --metadata "$DEVICE_PACKAGE"
    python3 "$ROOT/scripts/resolve_apk.py" \
        --index "$WORK/APKINDEX-alpine" \
        --output "$ROOT/state/apk-packages-alpine.json" \
        --root "$ATH10K_FIRMWARE_PACKAGE"

    verify_apk_lock_set
    verify_apk_package "$ROOT/state/apk-packages.json" \
        "$KERNEL_PACKAGE" "$KERNEL_VERSION"
    verify_apk_package "$ROOT/state/apk-packages.json" \
        "$DEVICE_PACKAGE" "$DEVICE_PACKAGE_VERSION"
    verify_apk_package "$ROOT/state/apk-packages.json" \
        "$FIRMWARE_PACKAGE" "$FIRMWARE_PACKAGE_VERSION"
    verify_apk_package "$ROOT/state/apk-packages.json" \
        "firmware-oneplus-sdm845-sensors" "$FIRMWARE_SENSORS_VERSION"
    verify_apk_package "$ROOT/state/apk-packages.json" \
        "$ADRENO_FIRMWARE_PACKAGE" "$ADRENO_FIRMWARE_VERSION"
    verify_apk_package "$ROOT/state/apk-packages.json" \
        "alsa-ucm-conf-sdm845" "$ALSA_UCM_VERSION"
    verify_apk_package "$ROOT/state/apk-packages-alpine.json" \
        "$ATH10K_FIRMWARE_PACKAGE" "$ATH10K_FIRMWARE_VERSION"

    : > "$ROOT/state/apk-sha256.txt"
    while IFS=$'\t' read -r _pkg _version filename _role; do
        local output="$ROOT/inputs/nura/$filename"
        local expected
        expected="$(apk_lock_sha "$filename")"
        download "$NURA_REPO/$NURA_BRANCH/$NURA_ARCH/$filename" \
            "$output" "$expected"
        printf '%s  %s\n' "$(sha256 "$output")" "$filename" >> "$ROOT/state/apk-sha256.txt"
    done < <(jq -r '.packages[] | [.name, .version, .filename, .role] | @tsv' "$ROOT/state/apk-packages.json")
    while IFS=$'\t' read -r _pkg _version filename _role; do
        local output="$ROOT/inputs/alpine/$filename"
        local expected
        expected="$(apk_lock_sha "$filename")"
        download "$ALPINE_REPO/$filename" "$output" "$expected"
        printf '%s  %s\n' "$(sha256 "$output")" "$filename" >> "$ROOT/state/apk-sha256.txt"
    done < <(jq -r '.packages[] | [.name, .version, .filename, .role] | @tsv' "$ROOT/state/apk-packages-alpine.json")
}

prepare_base_rootfs() {
    local rootfs="$WORK/rootfs-base"
    local base="$ROOT/inputs/ubuntu/ubuntu-base-26.04.1-base-arm64.tar.gz"
    if [[ ! -f "$rootfs/etc/os-release" ]]; then
        tar -xpf "$base" -C "$rootfs"
    fi

    write_apt_sources "$rootfs" "$UBUNTU_APT_BUILD_MIRROR"

    install -D -m 0644 "$ROOT/config/apt-protect-kernel" \
        "$rootfs/etc/apt/preferences.d/99-orbital-no-ubuntu-kernel"
    install -d -m 0755 \
        "$rootfs/etc/sudoers.d" \
        "$rootfs/etc/polkit-1/rules.d" \
        "$rootfs/etc/ssh/sshd_config.d" \
        "$rootfs/etc/udev/rules.d" \
        "$rootfs/etc/NetworkManager/system-connections" \
        "$rootfs/usr/local/sbin"
    rm -f "$rootfs/etc/sudoers.d/README" "$rootfs/etc/sudoers.d/README.dpkg-new"
    install_build_policy_rc "$rootfs"

    rm -f "$rootfs/etc/resolv.conf"
    cp /etc/resolv.conf "$rootfs/etc/resolv.conf"

    restore_systemd_sysusers "$rootfs"
    chroot_run "$rootfs" groupadd --system _chrony 2>/dev/null || true
    chroot_run "$rootfs" useradd --system --gid _chrony --home-dir /var/lib/chrony \
        --shell /usr/sbin/nologin _chrony 2>/dev/null || true
    if [[ -x "$rootfs/usr/bin/systemd-sysusers" ]]; then
        chroot_run "$rootfs" systemd-sysusers \
            basic.conf systemd-journal.conf systemd-network.conf chrony.conf \
            dbus.conf polkit.conf systemd-resolve.conf bluez.conf \
            openssh-server.conf pipewire.conf debian-udev.conf
    fi
    stub_systemd_sysusers "$rootfs"
    chroot_run "$rootfs" dpkg --configure -a
    chroot_run "$rootfs" apt-get \
        -o APT::Sandbox::User=root \
        -o Acquire::http::Timeout=60 \
        -o Acquire::Queue-Mode=access \
        -o Acquire::http::Pipeline-Depth=0 \
        -o Acquire::Retries=5 \
        update
    chroot_run "$rootfs" apt-get \
        -o APT::Sandbox::User=root \
        -o Acquire::http::Timeout=60 \
        -o Acquire::Queue-Mode=access \
        -o Acquire::http::Pipeline-Depth=0 \
        -o Acquire::Retries=5 \
        -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold \
        install -y --no-install-recommends \
        bash \
        bluez \
        busybox-static \
        ca-certificates \
        chrony \
        curl \
        dbus \
        dnsmasq-base \
        e2fsprogs \
        iproute2 \
        iputils-ping \
        iw \
        kmod \
        less \
        libdrm2 \
        libegl1 \
        libevdev2 \
        libgbm1 \
        libgles2 \
        libgl1 \
        libinput10 \
        locales \
        modemmanager \
        mobile-broadband-provider-info \
        nano \
        network-manager \
        openssh-client \
        openssh-server \
        pipewire \
        pipewire-pulse \
        procps \
        psmisc \
        qml6-module-qtquick \
        qml6-module-qtquick-controls \
        qml6-module-qtquick-layouts \
        qml6-module-qtquick-shapes \
        qml6-module-qtquick-window \
        qt6-base-dev \
        qt6-declarative-dev \
        qt6-qpa-plugins \
        qt6-svg-plugins \
        rfkill \
        rtkit \
        sudo \
        systemd \
        systemd-resolved \
        systemd-sysv \
        tzdata \
        unattended-upgrades \
        needrestart \
        usbutils \
        wireless-regdb \
        wireplumber \
        wpasupplicant
    restore_systemd_sysusers "$rootfs"
    install -D -m 0644 "$ROOT/config/99auto-upgrades-orbital" \
        "$rootfs/etc/apt/apt.conf.d/99auto-upgrades-orbital"
    install -D -m 0644 "$ROOT/config/99unattended-upgrades-orbital" \
        "$rootfs/etc/apt/apt.conf.d/99unattended-upgrades-orbital"
    chroot_run "$rootfs" apt-get clean
    dpkg-query --admindir="$rootfs/var/lib/dpkg" -W \
        -f='${Package}\t${Version}\t${Architecture}\n' > "$ROOT/state/ubuntu-packages.tsv"
}

extract_nura_inputs() {
    local stage="$WORK/apk-stage"
    rm -rf "$stage"
    mkdir -p "$stage"

    while read -r expected filename; do
        local apk name
        apk="$ROOT/inputs/nura/$filename"
        if [[ ! -f "$apk" ]]; then
            apk="$ROOT/inputs/alpine/$filename"
        fi
        require_sha256 "$apk" "$expected" "locked APK"
        name="$(basename "$apk" .apk)"
        mkdir -p "$stage/$name"
        tar --warning=no-unknown-keyword -xpf "$apk" -C "$stage/$name"
        rm -f "$stage/$name/.PKGINFO" "$stage/$name"/.SIGN*
    done < "$APK_SHA256_LOCK"

    local kernel_stage
    kernel_stage="$(find "$stage" -maxdepth 1 -type d -name "linux-postmarketos-qcom-sdm845-*" | head -n 1)"
    [[ -n "$kernel_stage" ]] || fail "kernel APK was not extracted"
    install -D -m 0644 "$kernel_stage/boot/vmlinuz" "$WORK/boot/vmlinuz"
    install -D -m 0644 "$kernel_stage/boot/dtbs/qcom/sdm845-oneplus-enchilada.dtb" \
        "$WORK/boot/sdm845-oneplus-enchilada.dtb"

    local device_stage
    device_stage="$(find "$stage" -maxdepth 1 -type d -name "device-oneplus-enchilada-*" | head -n 1)"
    [[ -n "$device_stage" ]] || fail "device APK was not extracted"
    install -D -m 0644 "$device_stage/usr/share/deviceinfo/device-oneplus-enchilada" \
        "$WORK/boot/deviceinfo"
    cat "$ROOT/config/deviceinfo.oneplus-enchilada" >> "$WORK/boot/deviceinfo"

    local rootfs="$WORK/rootfs-base"
    rm -rf "$rootfs/usr/lib/modules"
    mkdir -p "$rootfs/usr/lib/modules/$KERNEL_RELEASE" "$rootfs/usr/lib/firmware" "$rootfs/usr/share"
    while IFS= read -r modules; do
        rsync -a "$modules/" "$rootfs/usr/lib/modules/$KERNEL_RELEASE/"
    done < <(find "$stage" -type d -path '*/usr/lib/modules/7.1.0-rc1-sdm845' -print)
    rm -f "$rootfs/usr/lib/modules/$KERNEL_RELEASE/build" \
        "$rootfs/usr/lib/modules/$KERNEL_RELEASE/source"
    depmod -b "$rootfs" -a "$KERNEL_RELEASE"

    while IFS= read -r firmware; do
        rsync -a "$firmware/" "$rootfs/usr/lib/firmware/"
    done < <(find "$stage" -type d \
        \( -path '*/linux-firmware-ath10k*/usr/lib/firmware' \
        -o -path '*/linux-firmware-ath10k*/lib/firmware' \) -print)
    while IFS= read -r firmware; do
        rsync -a "$firmware/" "$rootfs/usr/lib/firmware/"
    done < <(find "$stage" -type d -path '*/usr/lib/firmware' \
        ! -path '*/linux-firmware-ath10k/*' -print)
    install -d "$rootfs/usr/lib/firmware/qca"
    ln -snf ../postmarketos/qca/crbtfw21.tlv \
        "$rootfs/usr/lib/firmware/qca/crbtfw21.tlv"
    ln -snf OnePlus/enchilada/crnv21.bin \
        "$rootfs/usr/lib/firmware/qca/crnv21.bin"
    [[ -f "$rootfs/usr/lib/firmware/qca/crbtfw21.tlv" ]] \
        || fail "WCN3990 firmware is missing: qca/crbtfw21.tlv"
    [[ -f "$rootfs/usr/lib/firmware/qca/crnv21.bin" ]] \
        || fail "WCN3990 board firmware is missing: qca/crnv21.bin"
    [[ -f "$rootfs/usr/lib/firmware/qcom/a630_sqe.fw" ]] \
        || fail "Adreno A630 SQE firmware is missing"
    [[ -f "$rootfs/usr/lib/firmware/qcom/a630_gmu.bin" ]] \
        || fail "Adreno A630 GMU firmware is missing"
    [[ -f "$rootfs/usr/lib/firmware/ath10k/WCN3990/hw1.0/board-2.bin" \
        || -f "$rootfs/usr/lib/firmware/ath10k/WCN3990/hw1.0/board-2.bin.zst" ]] \
        || fail "WCN3990 board firmware is missing"

    while IFS= read -r alsa; do
        mkdir -p "$rootfs/usr/share/alsa"
        rsync -a "$alsa/" "$rootfs/usr/share/alsa/"
    done < <(find "$stage" -type d -path '*/usr/share/alsa' -print)

    [[ -d "$rootfs/usr/lib/modules/$KERNEL_RELEASE" ]] || fail "kernel modules were not installed"
    [[ -f "$rootfs/usr/lib/modules/$KERNEL_RELEASE/modules.dep" ]] || fail "modules.dep missing"
}

configure_runtime_services() {
    local rootfs="$1"

    write_apt_sources "$rootfs" "$UBUNTU_APT_MIRROR"
    install -D -m 0644 "$ROOT/config/orbital-release" \
        "$rootfs/etc/orbital-release"
    ln -snf /run/systemd/resolve/stub-resolv.conf "$rootfs/etc/resolv.conf"
    install -D -m 0644 "$ROOT/config/chrony-orbital.sources" \
        "$rootfs/etc/chrony/sources.d/orbital-ntp.sources"
    install -d -m 0755 "$rootfs/var/lib/systemd/linger"
    install -m 0644 /dev/null "$rootfs/var/lib/systemd/linger/$SSH_USER"

    chroot_run "$rootfs" systemctl enable \
        rtkit-daemon.service \
        systemd-resolved.service \
        apt-daily.timer \
        apt-daily-upgrade.timer
    chroot_run "$rootfs" systemctl --global enable \
        pipewire.service \
        pipewire-pulse.service \
        wireplumber.service
}

configure_base_system() {
    local rootfs="$WORK/rootfs-base"
    rm -f "$rootfs/etc/resolv.conf"
    cp /etc/resolv.conf "$rootfs/etc/resolv.conf"
    chroot_run "$rootfs" locale-gen en_US.UTF-8 zh_CN.UTF-8
    ln -snf "/usr/share/zoneinfo/$TIMEZONE" "$rootfs/etc/localtime"
    printf '%s\n' "$TIMEZONE" > "$rootfs/etc/timezone"
    printf '%s\n' "$HOSTNAME" > "$rootfs/etc/hostname"
    cat > "$rootfs/etc/hosts" <<EOF
127.0.0.1 localhost
127.0.1.1 $HOSTNAME
::1 localhost ip6-localhost ip6-loopback
EOF

    chroot_run "$rootfs" useradd --create-home --user-group --shell /bin/bash "$SSH_USER" 2>/dev/null || true
    chroot_run "$rootfs" usermod -aG audio,input,render,video,sudo "$SSH_USER"
    chroot_run "$rootfs" passwd -l root
    if [[ "$SSH_AUTH_MODE" == "fixed-password-file" ]]; then
        local ssh_password password_hash
        IFS= read -r ssh_password < "$SSH_PASSWORD_FILE" || true
        [[ -n "$ssh_password" ]] || fail "SSH password file is empty"
        password_hash="$(openssl passwd -6 "$ssh_password")"
        chroot_run "$rootfs" usermod -p "$password_hash" "$SSH_USER"
    else
        chroot_run "$rootfs" usermod -p '*' "$SSH_USER"
    fi

    local uid gid
    uid="$(chroot_run "$rootfs" id -u "$SSH_USER")"
    gid="$(chroot_run "$rootfs" id -g "$SSH_USER")"
    if [[ -n "$SSH_PUBLIC_KEY_FILE" && -f "$SSH_PUBLIC_KEY_FILE" ]]; then
        install -d -m 0700 -o "$uid" -g "$gid" "$rootfs/home/$SSH_USER/.ssh"
        install -m 0600 -o "$uid" -g "$gid" "$SSH_PUBLIC_KEY_FILE" \
            "$rootfs/home/$SSH_USER/.ssh/authorized_keys"
    else
        rm -rf "$rootfs/home/$SSH_USER/.ssh"
    fi

    install -m 0440 "$ROOT/config/sudoers-orbital" "$rootfs/etc/sudoers.d/90-orbital"
    install -D -m 0644 "$ROOT/config/orbital-polkit.rules" \
        "$rootfs/etc/polkit-1/rules.d/50-orbital.rules"
    install -D -m 0644 "$ROOT/config/orbital-udev.rules" \
        "$rootfs/etc/udev/rules.d/70-orbital-access.rules"
    install -D -m 0755 "$ROOT/config/orbital-wifi-mac" \
        "$rootfs/usr/local/sbin/orbital-wifi-mac"
    install -D -m 0644 "$ROOT/config/orbital-wifi-mac.service" \
        "$rootfs/etc/systemd/system/orbital-wifi-mac.service"
    install -D -m 0644 "$ROOT/config/90-orbital-wifi-mac.rules" \
        "$rootfs/etc/udev/rules.d/90-orbital-wifi-mac.rules"
    install -D -m 0755 "$ROOT/config/orbital-usb-gadget" \
        "$rootfs/usr/local/sbin/orbital-usb-gadget"
    install -D -m 0600 "$ROOT/config/orbital-usb.nmconnection" \
        "$rootfs/etc/NetworkManager/system-connections/orbital-usb.nmconnection"
    install -D -m 0644 "$ROOT/config/NetworkManager-orbital.conf" \
        "$rootfs/etc/NetworkManager/conf.d/50-orbital-usb-unmanaged.conf"
    install -D -m 0644 "$ROOT/config/orbital-usb-gadget.service" \
        "$rootfs/etc/systemd/system/orbital-usb-gadget.service"
    install -D -m 0755 "$ROOT/config/orbital-usb-network" \
        "$rootfs/usr/local/sbin/orbital-usb-network"
    install -D -m 0644 "$ROOT/config/orbital-usb-network.service" \
        "$rootfs/etc/systemd/system/orbital-usb-network.service"
    install -D -m 0644 "$ROOT/config/orbital-dnsmasq.conf" \
        "$rootfs/etc/orbital-dnsmasq.conf"
    install -D -m 0644 "$ROOT/config/logind-orbital.conf" \
        "$rootfs/etc/systemd/logind.conf.d/50-orbital-power.conf"
    install -D -m 0644 "$ROOT/config/modules-load-orbital.conf" \
        "$rootfs/etc/modules-load.d/orbital-wifi.conf"
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
    install -D -m 0755 "$ROOT/config/orbital-msm-modem-start" \
        "$rootfs/usr/local/sbin/orbital-msm-modem-start"
    install -D -m 0644 "$ROOT/config/ssh-host-keys.service" \
        "$rootfs/etc/systemd/system/ssh-host-keys.service"
    install -D -m 0644 "$ROOT/config/orbital-resize-rootfs.service" \
        "$rootfs/etc/systemd/system/orbital-resize-rootfs.service"
    install_orbital_password_controls "$rootfs" "$ROOT/config"
    if [[ "$SSH_AUTH_MODE" == "fixed-password-file" ]]; then
        mark_default_password_pending "$rootfs" "$SSH_USER" \
            || fail "failed to write default-password marker"
    else
        clear_default_password_pending "$rootfs"
    fi

    install -d "$rootfs/etc/ssh/sshd_config.d"
    local password_authentication="no"
    local pubkey_authentication="no"
    [[ "$SSH_AUTH_MODE" == "fixed-password-file" ]] && password_authentication="yes"
    [[ "$SSH_AUTH_MODE" == "public-key" ]] && pubkey_authentication="yes"
    cat > "$rootfs/etc/ssh/sshd_config.d/50-orbital.conf" <<EOF
PermitRootLogin no
PasswordAuthentication $password_authentication
KbdInteractiveAuthentication no
PubkeyAuthentication $pubkey_authentication
AllowUsers $SSH_USER
EOF
    rm -f "$rootfs/etc/ssh"/ssh_host_*

    cat > "$rootfs/etc/fstab" <<EOF
$ROOT_PARTITION / ext4 defaults,noatime,errors=remount-ro 0 1
EOF
    : > "$rootfs/etc/machine-id"
    install -d "$rootfs/var/lib/dbus"
    ln -snf /etc/machine-id "$rootfs/var/lib/dbus/machine-id"
    install -d "$rootfs/etc/update-manager"
    printf 'Prompt=never\n' > "$rootfs/etc/update-manager/release-upgrades"

    chroot_run "$rootfs" systemctl enable \
        NetworkManager.service \
        ModemManager.service \
        orbital-msm-modem.service \
        orbital-usb-gadget.service \
        orbital-usb-network.service \
        pd-mapper.service \
        rmtfs.service \
        orbital-resize-rootfs.service \
        orbital-default-password-check.path \
        ssh-host-keys.service \
        ssh.service \
        tqftpserv.service
    configure_runtime_services "$rootfs"
    chroot_run "$rootfs" systemctl disable bluetooth.service 2>/dev/null || true
    chroot_run "$rootfs" systemctl disable systemd-networkd.service 2>/dev/null || true
    chroot_run "$rootfs" systemctl set-default multi-user.target
}

build_base_image() {
    local rootfs="$WORK/rootfs-base"
    local raw="$WORK/rootfs-ubuntu.raw"
    local sparse="$ROOT/out/oneplus6-rootfs-ubuntu.img"
    local bytes=$((ROOTFS_SIZE_MIB * 1024 * 1024))
    local used
    used="$(du -sb "$rootfs" | awk '{print $1}')"
    [[ "$used" -lt "$bytes" ]] || fail "base rootfs does not fit in $ROOTFS_SIZE_MIB MiB"
    remove_build_policy_rc "$rootfs"
    rm -f "$raw" "$sparse"
    truncate -s "$bytes" "$raw"
    mke2fs -q -F -t ext4 -b "$ROOTFS_BLOCK_SIZE" -I 256 \
        -E lazy_itable_init=0,lazy_journal_init=0 \
        -O ^64bit,^flex_bg,^metadata_csum,^metadata_csum_seed,^uninit_bg,^orphan_file \
        -L ORBITAL_BASE -d "$rootfs" "$raw"
    e2fsck -fy "$raw" > "$ROOT/state/e2fsck-base.log"
    img2simg "$raw" "$sparse" "$ROOTFS_BLOCK_SIZE"
}

build_orbital_rootfs() {
    local source="$WORK/rootfs-base"
    local target="$WORK/rootfs-orbital"
    local source_copy="$WORK/orbital-src"
    rm -rf "$target" "$source_copy"
    cp -a "$source" "$target"
    rsync -a --exclude '.git' --exclude 'build' "$ORBITAL_SOURCE_DIR/" "$source_copy/"
    rsync -a "$source_copy/" "$target/tmp/orbital-src/"

    write_apt_sources "$target" "$UBUNTU_APT_BUILD_MIRROR"
    install_build_policy_rc "$target"
    rm -f "$target/etc/resolv.conf"
    cp /etc/resolv.conf "$target/etc/resolv.conf"
    chroot_run "$target" apt-get \
        -o APT::Sandbox::User=root \
        -o Acquire::http::Timeout=60 \
        -o Acquire::Queue-Mode=access \
        -o Acquire::http::Pipeline-Depth=0 \
        -o Acquire::Retries=5 \
        update
    chroot_run "$target" apt-get \
        -o APT::Sandbox::User=root \
        -o Acquire::http::Timeout=60 \
        -o Acquire::Queue-Mode=access \
        -o Acquire::http::Pipeline-Depth=0 \
        -o Acquire::Retries=5 \
        -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold \
        install -y --no-install-recommends \
        build-essential \
        cmake \
        libdrm-dev \
        libegl-dev \
        libgl-dev \
        pkg-config \
        qt6-base-dev \
        qt6-declarative-dev
    chroot_run "$target" bash -lc \
        "cd /tmp/orbital-src && cmake -S . -B build -DCMAKE_BUILD_TYPE=$ORBITAL_BUILD_TYPE -DORBITAL_BUILD_PLUGINS=$ORBITAL_BUILD_PLUGINS && cmake --build build -j2"

    install -d "$target/opt/orbital"
    install -m 0755 "$target/tmp/orbital-src/build/Orbital" "$target/opt/orbital/Orbital"
    install -m 0755 "$target/tmp/orbital-src/scripts/run.sh" "$target/opt/orbital/run.sh"
    install -m 0644 "$target/tmp/orbital-src/scripts/device-profile.sh" "$target/opt/orbital/device-profile.sh"
    rm -rf "$target/tmp/orbital-src"
    chroot_run "$target" apt-get clean
    install_locked_ubuntu_packages "$target"
    remove_build_policy_rc "$target"
    verify_ubuntu_package_lock "$target"
    configure_runtime_services "$target"
    install -D -m 0644 "$ROOT/config/orbital.service" \
        "$target/etc/systemd/system/orbital.service"
    chroot_run "$target" systemctl enable orbital.service
    chroot_run "$target" systemctl disable getty@tty1.service 2>/dev/null || true
}

build_orbital_image() {
    local rootfs="$WORK/rootfs-orbital"
    local raw="$WORK/rootfs-orbital.raw"
    local sparse="$ROOT/out/oneplus6-rootfs-orbital.img"
    local bytes=$((ROOTFS_SIZE_MIB * 1024 * 1024))
    local used
    used="$(du -sb "$rootfs" | awk '{print $1}')"
    [[ "$used" -lt "$bytes" ]] || fail "Orbital rootfs does not fit in $ROOTFS_SIZE_MIB MiB"
    rm -f "$raw" "$sparse"
    truncate -s "$bytes" "$raw"
    mke2fs -q -F -t ext4 -b "$ROOTFS_BLOCK_SIZE" -I 256 \
        -E lazy_itable_init=0,lazy_journal_init=0 \
        -O ^64bit,^flex_bg,^metadata_csum,^metadata_csum_seed,^uninit_bg,^orphan_file \
        -L ORBITAL_DESKTOP -d "$rootfs" "$raw"
    e2fsck -fy "$raw" > "$ROOT/state/e2fsck-orbital.log"
    img2simg "$raw" "$sparse" "$ROOTFS_BLOCK_SIZE"
}

build_initramfs() {
    local initroot="$WORK/initramfs-root"
    local sparse="$WORK/boot/initramfs.cpio"
    rm -rf "$initroot"
    mkdir -p "$initroot/bin" "$initroot/dev" "$initroot/proc" "$initroot/sys" "$initroot/newroot"
    install -m 0755 "$WORK/rootfs-base/bin/busybox" "$initroot/bin/busybox"
    for applet in sh mount sleep mkdir switch_root; do
        ln -s busybox "$initroot/bin/$applet"
    done
    install -D -m 0644 "$WORK/rootfs-base/usr/lib/firmware/qcom/a630_sqe.fw" \
        "$initroot/lib/firmware/qcom/a630_sqe.fw"
    install -D -m 0644 "$WORK/rootfs-base/usr/lib/firmware/qcom/a630_gmu.bin" \
        "$initroot/lib/firmware/qcom/a630_gmu.bin"
    install -D -m 0644 "$WORK/rootfs-base/usr/lib/firmware/qcom/sdm845/OnePlus/enchilada/a630_zap.mbn" \
        "$initroot/lib/firmware/qcom/sdm845/OnePlus/enchilada/a630_zap.mbn"
    install -m 0755 "$ROOT/config/initramfs-init" "$initroot/init"
    (
        cd "$initroot"
        find . -print0 | cpio --null -o --format=newc > "$sparse"
    )
    gzip -9 -c "$sparse" > "$WORK/boot/initramfs.cpio.gz"
    gzip -t "$WORK/boot/initramfs.cpio.gz"
}

build_boot_image() {
    local kernel="$WORK/boot/vmlinuz"
    local dtb="$WORK/boot/sdm845-oneplus-enchilada.dtb"
    local initramfs="$WORK/boot/initramfs.cpio.gz"
    local kernel_dtb="$WORK/boot/vmlinuz-dtb"
    local override_unpacked="$WORK/boot/boot-override"
    local output="$ROOT/out/oneplus6-boot.img"
    local cmdline="console=ttyMSM0,115200 console=tty0 root=/dev/sda17 rootfstype=ext4 rootwait=10 loglevel=0 vt.global_cursor_default=0 systemd.show_status=1 systemd.log_level=info net.ifnames=0 rw"
    sanitize_wcn3990_dtb "$dtb"
    if [[ -n "${BOOT_IMAGE_OVERRIDE:-}" && -f "$BOOT_IMAGE_OVERRIDE" ]]; then
        log "Using prebuilt patched boot image: $BOOT_IMAGE_OVERRIDE"
        rm -rf "$override_unpacked"
        mkdir -p "$override_unpacked"
        unpack_bootimg --boot_img "$BOOT_IMAGE_OVERRIDE" \
            --out "$override_unpacked" >/dev/null
        rm -f "$output"
        mkbootimg \
            --header_version 0 \
            --kernel "$override_unpacked/kernel" \
            --ramdisk "$initramfs" \
            --base 0x00000000 \
            --kernel_offset 0x00008000 \
            --ramdisk_offset 0x01000000 \
            --second_offset 0x00f00000 \
            --tags_offset 0x00000100 \
            --pagesize 4096 \
            --cmdline "$cmdline" \
            -o "$output"
        return
    fi
    cat "$kernel" "$dtb" > "$kernel_dtb"
    rm -f "$output"
    mkbootimg \
        --header_version 0 \
        --kernel "$kernel_dtb" \
        --ramdisk "$initramfs" \
        --base 0x00000000 \
        --kernel_offset 0x00008000 \
        --ramdisk_offset 0x01000000 \
        --second_offset 0x00f00000 \
        --tags_offset 0x00000100 \
        --pagesize 4096 \
        --cmdline "$cmdline" \
        -o "$output"
}

rebuild_boot_only() {
    validate_config
    build_initramfs
    build_boot_image
    python3 "$ROOT/scripts/verify_images.py" \
        --boot "$ROOT/out/oneplus6-boot.img" \
        --dtb "$WORK/boot/sdm845-oneplus-enchilada.dtb" \
        --base-sparse "$ROOT/out/oneplus6-rootfs-ubuntu.img" \
        --orbital-sparse "$ROOT/out/oneplus6-rootfs-orbital.img" \
        --expected-size "$((ROOTFS_SIZE_MIB * 1024 * 1024))" \
        --output "$ROOT/state/verification.json"
    log "Boot image rebuilt"
    ls -lh "$ROOT/out"/oneplus6-boot.img
}

verify_outputs() {
    local bytes=$((ROOTFS_SIZE_MIB * 1024 * 1024))
    test -d "$WORK/rootfs-base/usr/lib/modules/$KERNEL_RELEASE"
    test -d "$WORK/rootfs-orbital/usr/lib/modules/$KERNEL_RELEASE"
    test -x "$WORK/rootfs-orbital/opt/orbital/Orbital"
    test ! -e "$WORK/rootfs-base/opt/orbital"
    test -f "$WORK/initramfs-root/lib/firmware/qcom/a630_sqe.fw"
    test -f "$WORK/initramfs-root/lib/firmware/qcom/a630_gmu.bin"
    test -f "$WORK/initramfs-root/lib/firmware/qcom/sdm845/OnePlus/enchilada/a630_zap.mbn"
    file "$WORK/rootfs-orbital/opt/orbital/Orbital" | grep -q 'ARM aarch64'
    for rootfs in "$WORK/rootfs-base" "$WORK/rootfs-orbital"; do
        test -x "$rootfs/usr/bin/tqftpserv"
        test -x "$rootfs/usr/bin/pd-mapper"
        test -x "$rootfs/usr/bin/rmtfs"
        test -f "$rootfs/etc/systemd/system/tqftpserv.service"
        test -f "$rootfs/etc/systemd/system/pd-mapper.service"
        test -f "$rootfs/etc/systemd/system/rmtfs.service"
        test -f "$rootfs/etc/systemd/system/orbital-msm-modem.service"
        test -L "$rootfs/etc/resolv.conf"
        test -f "$rootfs/etc/chrony/sources.d/orbital-ntp.sources"
        test -f "$rootfs/etc/orbital-release"
        test ! -e "$rootfs/usr/sbin/policy-rc.d"
        verify_orbital_password_controls "$rootfs" "$SSH_AUTH_MODE"
        test -f "$rootfs/var/lib/systemd/linger/$SSH_USER"
        test -L "$rootfs/etc/systemd/system/multi-user.target.wants/rtkit-daemon.service"
        test -L "$rootfs/etc/systemd/user/default.target.wants/pipewire.service"
        test -L "$rootfs/etc/systemd/user/default.target.wants/pipewire-pulse.service"
        test -L "$rootfs/etc/systemd/user/pipewire.service.wants/wireplumber.service"
        test -L "$rootfs/etc/systemd/system/multi-user.target.wants/tqftpserv.service"
        test -L "$rootfs/etc/systemd/system/multi-user.target.wants/pd-mapper.service"
        test -L "$rootfs/etc/systemd/system/multi-user.target.wants/rmtfs.service"
        test -L "$rootfs/etc/systemd/system/multi-user.target.wants/orbital-msm-modem.service"
        file "$rootfs/usr/bin/tqftpserv" | grep -q 'ARM aarch64'
        file "$rootfs/usr/bin/pd-mapper" | grep -q 'ARM aarch64'
        file "$rootfs/usr/bin/rmtfs" | grep -q 'ARM aarch64'
    done
    debugfs -R 'cat /usr/lib/os-release' "$WORK/rootfs-ubuntu.raw" > "$ROOT/state/base-os-release.txt"
    debugfs -R 'cat /usr/lib/os-release' "$WORK/rootfs-orbital.raw" > "$ROOT/state/orbital-os-release.txt"
    python3 "$ROOT/scripts/verify_images.py" \
        --boot "$ROOT/out/oneplus6-boot.img" \
        --dtb "$WORK/boot/sdm845-oneplus-enchilada.dtb" \
        --base-sparse "$ROOT/out/oneplus6-rootfs-ubuntu.img" \
        --orbital-sparse "$ROOT/out/oneplus6-rootfs-orbital.img" \
        --expected-size "$bytes" \
        --output "$ROOT/state/verification.json"
    printf 'base_modules=%s\norbital_modules=%s\n' \
        "$(sha256 "$WORK/rootfs-base/usr/lib/modules/$KERNEL_RELEASE/modules.dep")" \
        "$(sha256 "$WORK/rootfs-orbital/usr/lib/modules/$KERNEL_RELEASE/modules.dep")" \
        > "$ROOT/state/module-consistency.txt"
    printf 'tqftpserv=%s\n' \
        "$(sha256 "$WORK/rootfs-base/usr/bin/tqftpserv")" \
        > "$ROOT/state/tqftpserv-consistency.txt"
    printf 'pd-mapper=%s\n' \
        "$(sha256 "$WORK/rootfs-base/usr/bin/pd-mapper")" \
        > "$ROOT/state/pd-mapper-consistency.txt"
    printf 'rmtfs=%s\n' \
        "$(sha256 "$WORK/rootfs-base/usr/bin/rmtfs")" \
        > "$ROOT/state/rmtfs-consistency.txt"
}

main() {
    validate_config
    clean_build_tree
    write_initial_state
    fetch_inputs
    prepare_base_rootfs
    extract_nura_inputs
    configure_base_system
    build_base_image
    build_orbital_rootfs
    build_orbital_image
    build_initramfs
    build_boot_image
    verify_outputs
    write_final_state
    log "Build complete"
    ls -lh "$ROOT/out"/*.img
}

case "${1:-}" in
    --boot-only)
        rebuild_boot_only
        ;;
    "")
        main "$@"
        ;;
    *)
        fail "unknown argument: $1"
        ;;
esac
