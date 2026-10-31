# OnePlus 6 fixed initial password

## Credentials

This private-distribution image uses:

```text
username: orbital
initial password: 123456
```

The `orbital` account has passwordless sudo privileges. Anyone who can reach SSH
before the password is changed can obtain full root access.

Do not connect the phone to WiFi, Tailscale, or any untrusted network until the
initial password has been changed.

## Change the password

Log in over USB networking:

```bash
ssh orbital@172.16.42.1
```

Then change the password:

```bash
passwd
```

The new password must be 8-128 characters and contain at least two of:
letters, digits, or symbols. It must not contain `orbital`.

After a successful change, the pending-password marker is removed and future
interactive logins stop showing the warning.

## Recommended setup order

1. Flash the image.
2. Connect USB and log in as `orbital` with `123456`.
3. Run `passwd` and set a private password.
4. Reconnect SSH with the new password.
5. Configure WiFi.
6. Install and configure Tailscale.

## Verify password state

```bash
test -e /var/lib/orbital/default-password-pending && echo pending
systemctl status orbital-default-password-check.path --no-pager
```

When the marker is absent, `pending` is not printed.

## Distribution warning

This mode is intended only for private links and known users. A public GitHub
Release would expose the same initial password to every downloader and must use
the random first-login password design instead.
