# Fixed initial password implementation progress

| Task | Status | Evidence | Decisions |
|---|---|---|---|
| T1 configuration and build mode | verified | `config/build.env` sets `SSH_AUTH_MODE=fixed-password-file`; generated V15 rootfs verified | Unknown/missing mode fails closed |
| T2 password policy | verified | `pam_pwquality` installed; real non-root `passwd` accepted a compliant password and rejected weak/username passwords | Custom `pam_exec` token handling was rejected after real `passwd` simulation |
| T3 shadow fingerprint and path unit | verified | Marker present at first boot and automatically removed after the target-device password change | Marker stores SHA-256 of the shadow password field, not the password |
| T4 login prompt | unit verified | Interactive sourced-script test displays warning; ShellCheck passes | Non-interactive shells stay silent |
| T5 build integration | verified with recovered V14 trees | Controls installed in both rootfs; V15 images generated and device tested | Clean full build remains a separate build-environment follow-up |
| T6 refresh integration | verified | `refresh-images.sh` installed controls, refreshed fingerprints, rebuilt both images and updated V15 metadata | Enable path unit only after unit files exist |
| T7 static image verification | verified | Both rootfs hashes, marker fingerprints, pwquality module, PAM, path unit and package counts checked | V15 static record is `state/v15-static-verification.json` |
| T8 target-device verification | verified | Interactive SSH, reminder, weak-password rejection, strong-password change, marker cleanup and restored initial state verified | Device left at `orbital/123456` with pending marker |
| T9 documentation | complete | `docs/fixed-initial-password.md` | Public Release risk documented |

Release decision: this authentication change is built as V15 instead of
overwriting the hardware-tested V14 artifacts.

## Verification log

- 2026-10-31: `shellcheck` passed for authentication helper, checker, login prompt, and test script.
- 2026-10-31: Python policy compilation and build/refresh shell syntax passed.
- 2026-10-31: `PASS: orbital password controls (6 checks)` after switching to standard pwquality.
- 2026-10-31: 520-package lock expanded to 524 sorted packages.
- 2026-10-31: V15 rootfs trees verified: base `460` packages, Orbital `524` packages and exact lock match.
- 2026-10-31: Real non-root `passwd` test accepted a compliant password and rejected one-class/username passwords.
- 2026-10-31: Flashed V15 segmented image on OnePlus 6. Login, prompt, weak-password rejection, compliant password change and automatic marker cleanup all passed. Device restored to `123456` with marker pending.
- 2026-10-31: Full-from-scratch build hit a `proot` assertion while installing/upgrading systemd. V15 artifacts were produced by restoring the hardware-tested V14 rootfs trees from release images, installing the 4 locked pwquality packages with a native arm64 chroot, then rebuilding both images through refresh.

## Open verification

- Before publishing the build repository, replace the proot installation path with a native arm64 chroot build stage and repeat a clean full build.
