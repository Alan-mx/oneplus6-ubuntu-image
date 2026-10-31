#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="/workspace/oneplus6-image"
CHECKER="$ROOT/config/orbital-default-password-check"
HELPER="$ROOT/scripts/orbital-auth.sh"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT

# shellcheck source=scripts/orbital-auth.sh
source "$HELPER"

marker="$temporary/default-password-pending"
shadow="$temporary/shadow"
# shellcheck disable=SC2016
printf 'sha256:%s\n' \
    "$(printf '%s' '$6$initial$hash' | sha256sum | awk '{print $1}')" > "$marker"
# shellcheck disable=SC2016
printf 'orbital:%s:20000:0:99999:7:::\n' '$6$initial$hash' > "$shadow"

MARKER_FILE="$marker" SHADOW_FILE="$shadow" PASSWORD_USER=orbital \
    sh "$CHECKER"
test -e "$marker"

# shellcheck disable=SC2016
printf 'orbital:%s:20000:0:99999:7:::\n' '$6$changed$hash' > "$shadow"
MARKER_FILE="$marker" SHADOW_FILE="$shadow" PASSWORD_USER=orbital \
    sh "$CHECKER" >/dev/null
test ! -e "$marker"

rootfs="$temporary/rootfs"
mkdir -p \
    "$rootfs/etc/pam.d" \
    "$rootfs/etc/systemd/system/multi-user.target.wants" \
    "$rootfs/usr/lib/aarch64-linux-gnu/security" \
    "$rootfs/var/lib"
cat > "$rootfs/etc/pam.d/common-password" <<'EOF'
# fixture
password	[success=1 default=ignore]	pam_unix.so obscure yescrypt
password	requisite			pam_deny.so
password	required			pam_permit.so
EOF
# shellcheck disable=SC2016
printf 'orbital:%s:20000:0:99999:7:::\n' '$6$initial$hash' \
    > "$rootfs/etc/shadow"
touch "$rootfs/usr/lib/aarch64-linux-gnu/security/pam_pwquality.so"
install_orbital_password_controls "$rootfs" "$ROOT/config"
ln -s /etc/systemd/system/orbital-default-password-check.path \
    "$rootfs/etc/systemd/system/multi-user.target.wants/orbital-default-password-check.path"
mark_default_password_pending "$rootfs" orbital
verify_orbital_password_controls "$rootfs" fixed-password-file
grep -Fqx "$ORBITAL_PASSWORD_POLICY_LINE" \
    "$rootfs/etc/pam.d/common-password"
grep -Fqx "minlen = 8" \
    "$rootfs/etc/security/pwquality.conf.d/50-orbital.conf"
grep -Fqx "minclass = 2" \
    "$rootfs/etc/security/pwquality.conf.d/50-orbital.conf"
grep -Fqx "dictcheck = 0" \
    "$rootfs/etc/security/pwquality.conf.d/50-orbital.conf"
test "$(stat -c '%a' "$rootfs/var/lib/orbital/default-password-pending")" = "644"
clear_default_password_pending "$rootfs"
test ! -e "$rootfs/var/lib/orbital/default-password-pending"

printf 'sha256:%064d\n' 0 > "$marker"
prompt="$(
    USER=orbital ORBITAL_DEFAULT_PASSWORD_MARKER="$marker" \
        sh -ic ". '$ROOT/config/90-orbital-default-password.sh'" 2>/dev/null
)"
printf '%s\n' "$prompt" | grep -Fq "shared initial password"

echo "PASS: orbital password controls (6 checks)"
