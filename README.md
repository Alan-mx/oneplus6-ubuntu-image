# OnePlus 6 Ubuntu Orbital Image

Build system and release metadata for a OnePlus 6 `enchilada` Ubuntu 26.04 ARM64
image running the postmarketOS SDM845 kernel and the optional Orbital desktop.

## Current release

V15 is hardware-verified on OnePlus 6. It includes:

- Ubuntu 26.04.1 ARM64
- Linux `7.1.0-rc1-sdm845`
- Orbital desktop image and Ubuntu base image
- First-boot rootfs expansion to the userdata partition
- Fixed initial SSH credentials `orbital/123456`
- `pam_pwquality` enforcement for the replacement password
- Interactive login reminder until the initial password changes
- Security-only automatic updates

The fixed-password model is intended only for private distribution. The account
has passwordless sudo, so change the password before connecting the phone to
WiFi or Tailscale.

## Release artifacts

The recommended flash artifact is the segmented ZIP:

```text
oneplus6-v15-segmented-flash.zip
```

The single-file sparse rootfs images are retained for development but are not
the recommended OnePlus 6 fastboot path.

## Build

The Orbital desktop is maintained in a separate repository. Place its checkout
beside this repository at `../Orbital`, or update `ORBITAL_SOURCE_DIR` in
`config/build.env` before building.

Full build:

```powershell
pwsh -File .\build.ps1 `
  -Config config/build.env `
  -SshPasswordFile .\state\orbital-password.txt
```

Refresh runtime configuration and regenerate rootfs images:

```powershell
pwsh -File .\build.ps1 `
  -Config config/build.env `
  -RefreshImages `
  -SshPasswordFile .\state\orbital-password.txt
```

`state/orbital-password.txt` is local, ignored by Git, and must contain
the intended initial password.

The current `proot`-based clean build can hit an assertion while installing
systemd on some hosts. V15 release artifacts were produced from the verified V14
rootfs trees plus the V15 package and authentication changes. Replacing that
step with a native arm64 chroot remains required before claiming clean-build
reproducibility.

## License

Original repository code is MIT licensed. Generated images contain third-party
software under separate terms; see `THIRD_PARTY_NOTICES.md`.
