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

The troubleshooting history, fixes and remaining limitations are documented in
[the troubleshooting guide](docs/oneplus6-image-troubleshooting.md) (Chinese).

## Build

The Orbital desktop is maintained in a separate repository. Place its checkout
beside this repository at `../Orbital`, or provide `-OrbitalSourcePath`. Its
`HEAD` must match the `orbital` row in `config/source-revisions.lock.tsv`.
The four tested quick-build inputs are tracked under `inputs/` and checked
against SHA-256 values in `config/build.env` before a build starts.

Check Docker, source revisions and lock files without downloading or building:

```powershell
pwsh -File .\build.ps1 -CheckEnvironment
```

Build all three images and the segmented flashing ZIP in an isolated Docker
volume. The default path is a quick assembly: it extracts the locked
postmarketOS APK kernel, modules and DTB, reuses the prebuilt Qualcomm helpers
and boot image, and does not compile the kernel or helpers.

```powershell
pwsh -File .\build.ps1 `
  -Fresh `
  -SshPasswordFile .\state\orbital-password.txt
```

The script prints the unique output directory and retained Docker volume. It
never clears existing `inputs/`, `work/`, `state/`, `out/`, or Docker volumes.
The default output is `out/build-<run-id>`; each run gets its own `state/`,
prepared-input directory, log directory, and Docker work path. Pass
`-OutputDirectory` to choose a different empty output directory. The build
refuses to mix with or overwrite any files already in that directory.

`state/orbital-password.txt` is local, ignored by Git, and must contain the
intended initial password.

During development, the build snapshots tracked and non-ignored untracked
Orbital files at the start of the run. The manifest records its exact Git
commit, dirty flag, and snapshot SHA-256. Git-ignored files, including local
credentials and build outputs, are excluded. A dirty Orbital checkout is valid
for a local development build, but that build is explicitly not marked publicly
reproducible. `-ReleaseBuild` requires clean source worktrees and fails before
starting the build otherwise. The current local Orbital adaptation must become
a public commit before a clean public clone can reproduce it.

After a successful build, `verify-build.ps1` is run automatically. To verify a
previous output again:

```powershell
pwsh -File .\verify-build.ps1 `
  -BuildRoot . `
  -OutputDirectory out\build-<run-id>
```

See [the upgrade guide](docs/upgrading-build-inputs.md) before changing any
kernel, firmware, Ubuntu, postmarketOS, helper, or Orbital version lock.

For a complete clone-to-build, local Orbital modification, and upgrade workflow,
see [the Chinese build guide](docs/building-from-clone.md).

## License

Original repository code is MIT licensed. Generated images contain third-party
software under separate terms; see `THIRD_PARTY_NOTICES.md`.
