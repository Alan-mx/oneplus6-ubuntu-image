#!/bin/sh
# shellcheck disable=SC2317

case $- in
    *i*)
        ;;
    *)
        return 0 2>/dev/null || exit 0
        ;;
esac

if [ "${USER:-}" != "orbital" ]; then
    return 0 2>/dev/null || exit 0
fi

ORBITAL_DEFAULT_PASSWORD_MARKER="${ORBITAL_DEFAULT_PASSWORD_MARKER:-/var/lib/orbital/default-password-pending}"
if [ ! -e "$ORBITAL_DEFAULT_PASSWORD_MARKER" ]; then
    return 0 2>/dev/null || exit 0
fi

cat <<'EOF'

==============================================================================
This image uses the shared initial password "123456".
Change it before connecting the phone to WiFi or Tailscale:

    passwd

This warning disappears after the password is changed.
==============================================================================

EOF
