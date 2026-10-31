# Third-party notices

The MIT license in `LICENSE` applies only to original build scripts,
configuration and documentation in this repository.

It does not relicense software distributed inside the generated phone image or
release archive. The image contains third-party components with separate
licenses, including:

- Ubuntu 26.04 ARM64 packages, under the licenses declared by each package.
- The Linux kernel used by postmarketOS for Qualcomm SDM845, including GPL
  obligations and the patches retained in `kernel-patches/`.
- postmarketOS device, firmware and ALSA packages.
- Qualcomm and OnePlus firmware binaries, under their upstream redistribution
  terms.
- Qt 6 and other runtime libraries, under their respective licenses.
- Orbital, which is distributed separately under its own MIT license.

The final release ZIP SHA-256 identifies the exact binary artifact. Source
versions and package locks are retained in `config/`, `docs/` and the upstream
links recorded by the build scripts.
