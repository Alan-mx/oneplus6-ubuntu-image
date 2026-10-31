# OnePlus 6 Segmented Flash Package

This package targets the OnePlus 6 (`enchilada`, fastboot product `sdm845`).
It contains the boot image, the Orbital Ubuntu rootfs in Android sparse
segments, checksum metadata, and a PowerShell flashing script.

Flashing erases the phone's entire `userdata` partition. Back up any data you
need before continuing. Unlocking and flashing are the user's responsibility.

On Windows, extract the complete ZIP, open PowerShell in the extracted folder,
and run:

```powershell
pwsh -File .\flash.ps1 -Fastboot C:\path\to\platform-tools\fastboot.exe
```

The script validates all local files before contacting fastboot, checks that
exactly one `sdm845` device is connected, and asks for `ERASE USERDATA` before
writing. To validate the package without a connected phone, run:

```powershell
pwsh -File .\flash.ps1 -ValidateOnly
```

The package is generated from the current build and is not tied to a historical
boot-image hash. `release.json` records the boot and segment-manifest hashes.
