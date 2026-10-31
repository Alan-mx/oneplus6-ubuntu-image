# Updating Build Inputs

The build locks exact source commits, binary-package hashes, installed Ubuntu
package versions, and Docker builder package versions. A newer upstream version
is a candidate only; changing one version field does not constitute a validated
upgrade.

## Source Revisions

Check current upstream default-branch heads and print the local lock digests:

```powershell
pwsh -File .\upgrade.ps1 -Check
```

This check is read-only. A remote `HEAD` difference is a review signal, not a
version recommendation; inspect the upstream release notes, device changes,
license, build requirements, and relevant issues before selecting a commit.

Apply one reviewed source commit by its full 40-character SHA and an explicit
version label:

```powershell
pwsh -File .\upgrade.ps1 `
  -Apply kernel `
  -Commit <full-commit-sha> `
  -Version <reviewed-version> `
  -SshPasswordFile .\state\orbital-password.txt
```

`-Apply` fetches the requested commit into a unique ignored directory under
`work/`, updates only that component's source-lock row, then runs a full
`-Fresh` image build and `verify-build.ps1`. It does not commit, push, create a
release, or flash a phone. If validation fails, the candidate lock, isolated
source checkout, logs, output, and Docker volume remain for diagnosis; the
candidate is not considered an accepted upgrade. Do not delete those artifacts
until the failure has been understood.

For `orbital`, also pass `-OrbitalSourcePath` when it is not at `../Orbital`.
The working tree is never reset or cleaned. Its `HEAD` must already equal the
requested commit; dirty non-ignored changes are still captured and make the
result a local development build rather than a public reproducibility claim.

## Package Locks

`upgrade.ps1 -Apply` updates only rows in `config/source-revisions.lock.tsv`.
Ubuntu/APK package locks and Docker builder package locks require a separate
review because package dependency changes can alter the complete ARM64 rootfs
and build environment:

1. Review the upstream package index/release and select explicit versions.
2. Update the relevant version/hash lock and builder lock in a dedicated change.
3. Build the Docker images with lock comparison enabled; do not use the
   `EXPORT_PACKAGE_LOCK=1` escape as the acceptance check.
4. Run a full isolated build and `verify-build.ps1`; inspect both ARM64 package
   TSVs and the build manifest before accepting the candidate.

Never treat automatic security updates configured inside the phone rootfs as a
replacement for rebuilding and verifying the locked image inputs. Kernel,
firmware, boot image and package-lock updates remain explicit maintenance work.

## Verification Limits

The clean-build acceptance platform is Windows x64 with Docker Desktop. A
successful Docker build verifies image structure, lock matches, provenance,
ZIP contents and checksums; it does not replace OnePlus 6 boot, display, touch,
Wi-Fi, USB networking, battery, or power testing. Linux x86_64 has a build
entry point but is not validated by this project run.
