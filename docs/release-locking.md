# OnePlus 6 release locking

## Releases

- Current release: V15 in `out/` and `releases/v15/`.
- Previous bootable release: V14 in `releases/v14/`.
- V15 contains 524 locked packages.
- V14 contains 520 locked packages.
- V13 contains 506 locked packages.

## Locked inputs

- Docker base: `ubuntu@sha256:0e73b71479e7bc5f006bca872e25c3cd680dc052a0116f90d63ae363537db0dd`
- Docker direct packages: versions are pinned in `Dockerfile` and
  `Dockerfile.kernel`.
- Docker resolved package sets: pinned in `config/builder-packages.lock.tsv`
  and `config/kernel-builder-packages.lock.tsv`.
- Ubuntu base rootfs: URL and SHA-256 are pinned in `config/build.env`.
- postmarketOS and Alpine APK indexes: SHA-256 is pinned in `config/build.env`.
- postmarketOS and Alpine APK files: filenames and SHA-256 values are pinned in
  `config/apk-sha256.lock`.
- Kernel, device, firmware and ALSA package versions: pinned in
  `config/build.env`.
- Boot image override and Qualcomm helper binaries: the four tested quick-build
  inputs are tracked under `inputs/` and their SHA-256 values are pinned in
  `config/build.env`.
- Final Ubuntu package set: every package/version/architecture row is pinned in
  `config/ubuntu-packages.lock.tsv`.
- Historical V13 package set: retained in
  `state/ubuntu-packages-v13.lock.tsv`.
- Final release image hashes: recorded in `state/release-lock.json` and
  `out/SHA256SUMS.txt`.
- Sparse rootfs images are generated with the Android SDK `img2simg` tool.
- The recommended V15 flash artifact is the validated segmented ZIP because the
  OnePlus 6 fastboot path corrupted a raw chunk in a large single sparse image.

The build fails when a resolved APK set, helper binary, boot image, or final
Ubuntu package set does not match its lock. This is intentional: dependency
drift must be reviewed and tested instead of being accepted silently.

## Runtime APT source

Build operations use the Tsinghua Ubuntu mirror. The image written to the phone
keeps a live Ubuntu mirror in `/etc/apt/sources.list`, so security updates are
not frozen to a build-time snapshot.

Automatic updates are restricted to the security origins by
`config/99unattended-upgrades-orbital`. Automatic reboot is disabled.

Updating the running rootfs does not modify the `.img` files in `out/`.
Re-flashing a rootfs image resets the live rootfs and its installed packages.

## Updating a lock

1. Apply and test the dependency change in a disposable build.
2. Reboot the phone with the new rootfs and run the runtime acceptance checks.
3. Export the verified package set with:

   ```bash
   LC_ALL=C dpkg-query -W \
     -f='${Package}\t${Version}\t${Architecture}\n' \
     | LC_ALL=C sort
   ```

4. Replace `config/ubuntu-packages.lock.tsv` only after the boot, SSH, WiFi,
   desktop, storage expansion, and service checks pass.
5. Rebuild the release images and regenerate:

   ```text
   out/SHA256SUMS.txt
   state/release-lock.json
   state/verification.json
   state/e2fsck-release-v13.log
   state/ext4-release-v13.txt
   ```

Never update a lock only to make a failed build pass.
