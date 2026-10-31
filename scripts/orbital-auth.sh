#!/usr/bin/env bash

ORBITAL_PASSWORD_POLICY_LINE="password requisite pam_pwquality.so retry=3"

install_orbital_password_controls() {
    local rootfs="$1"
    local config_dir="$2"
    local pam_file="$rootfs/etc/pam.d/common-password"
    local temporary="$pam_file.orbital.tmp"

    install -D -m 0755 "$config_dir/orbital-default-password-check" \
        "$rootfs/usr/local/sbin/orbital-default-password-check"
    install -D -m 0644 "$config_dir/orbital-default-password-check.service" \
        "$rootfs/etc/systemd/system/orbital-default-password-check.service"
    install -D -m 0644 "$config_dir/orbital-default-password-check.path" \
        "$rootfs/etc/systemd/system/orbital-default-password-check.path"
    install -D -m 0644 "$config_dir/90-orbital-default-password.sh" \
        "$rootfs/etc/profile.d/90-orbital-default-password.sh"
    install -D -m 0644 "$config_dir/pwquality-orbital.conf" \
        "$rootfs/etc/security/pwquality.conf.d/50-orbital.conf"
    install -d -m 0755 "$rootfs/var/lib/orbital"

    [ -f "$pam_file" ] || return 1
    awk -v policy="$ORBITAL_PASSWORD_POLICY_LINE" '
        $0 == policy {
            next
        }
        !inserted && /^password[[:space:]]/ && /pam_unix\.so/ {
            print policy
            inserted = 1
        }
        {
            print
        }
        END {
            exit !inserted
        }
    ' "$pam_file" > "$temporary" || {
        rm -f "$temporary"
        return 1
    }
    mv "$temporary" "$pam_file"
    chmod 0644 "$pam_file"
    grep -Fqx "$ORBITAL_PASSWORD_POLICY_LINE" "$pam_file"
}

orbital_password_fingerprint() {
    local rootfs="$1"
    local user="$2"
    local password_hash

    password_hash="$(
        awk -F: -v user="$user" '
            $1 == user {
                print $2
                found = 1
            }
            END {
                exit !found
            }
        ' "$rootfs/etc/shadow"
    )"
    if [ -z "$password_hash" ] || [ "${password_hash#\$}" = "$password_hash" ]; then
        return 1
    fi
    printf '%s' "$password_hash" | sha256sum | awk '{print $1}'
}

mark_default_password_pending() {
    local rootfs="$1"
    local user="$2"
    local marker="$rootfs/var/lib/orbital/default-password-pending"
    local temporary="$marker.tmp.$$"
    local fingerprint

    fingerprint="$(orbital_password_fingerprint "$rootfs" "$user")" || return 1
    install -d -m 0755 "$rootfs/var/lib/orbital"
    printf 'sha256:%s\n' "$fingerprint" > "$temporary"
    chmod 0644 "$temporary"
    chown 0:0 "$temporary"
    mv "$temporary" "$marker"
}

clear_default_password_pending() {
    local rootfs="$1"
    rm -f -- "$rootfs/var/lib/orbital/default-password-pending"
}

verify_orbital_password_controls() {
    local rootfs="$1"
    local mode="$2"

    test -x "$rootfs/usr/local/sbin/orbital-default-password-check"
    test -f "$rootfs/etc/systemd/system/orbital-default-password-check.service"
    test -f "$rootfs/etc/systemd/system/orbital-default-password-check.path"
    test -f "$rootfs/etc/profile.d/90-orbital-default-password.sh"
    test -f "$rootfs/etc/security/pwquality.conf.d/50-orbital.conf"
    test -n "$(find "$rootfs/usr/lib" -path '*/security/pam_pwquality.so' -print -quit)"
    grep -Fqx "$ORBITAL_PASSWORD_POLICY_LINE" \
        "$rootfs/etc/pam.d/common-password"
    test -L "$rootfs/etc/systemd/system/multi-user.target.wants/orbital-default-password-check.path"
    if [ "$mode" = "fixed-password-file" ]; then
        test -s "$rootfs/var/lib/orbital/default-password-pending"
    else
        test ! -e "$rootfs/var/lib/orbital/default-password-pending"
    fi
}
