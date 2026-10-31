# OnePlus 6 raw userdata flash fails in 32-bit Windows fastboot

## Symptom

Flashing the 3.5 GiB uncompressed ext4 test image terminates before fastboot
prints its first `Sending` line:

```text
fastboot.exe flash userdata oneplus6-rootfs-orbital-v14-raw-test.raw
libc++abi: terminating due to uncaught exception of type std::bad_alloc:
std::bad_alloc
```

## Evidence

The installed client is platform-tools 37.0.1. Its PE header identifies the
executable as 32-bit x86:

```text
Machine:      0x014C
Architecture: x86
```

The raw image is:

```text
size:   3,758,096,384 bytes
format: uncompressed ext4
sparse: false
```

The phone is still available in fastboot mode:

```text
product:               sdm845
current-slot:          b
max-download-size:     805306368 bytes
partition-size:userdata: 0x1B800BB000
partition-type:userdata: ext4
```

The crash occurs before fastboot prints any `Sending 'userdata'` progress line.
This indicates that the client fails while preparing or mapping the oversized
raw input, before starting the fastboot transfer.

## Root cause

The Google Windows fastboot client supplied with platform-tools 37.0.1 is a
32-bit x86 executable. The uncompressed raw image is 3.5 GiB, which exceeds the
practical user-mode address space available to that process. Loading or mapping
the raw image raises `std::bad_alloc`.

This is separate from the earlier sparse image corruption. The sparse V14
image is accepted by the 32-bit client because the sparse file itself is
1.5 GiB.

## Impact

- This failed command did not reach its first `Sending` stage, so it did not
  successfully write the raw image.
- The phone remains in fastboot mode and its partitions are not covered by an
  AVB footer.
- If `fastboot erase userdata` was already executed, the installed root filesystem
  must not be treated as bootable until a valid rootfs is flashed.

## Verification plan

Test one variable at a time:

1. Generate contiguous sparse segments smaller than 512 MiB.
2. Keep the sparse logical size equal to the full 3.5 GiB rootfs, and represent
   all data outside the current segment with `DONT_CARE` chunks.
3. Do not emit FILL chunks; each segment contains RAW data only for its own
   contiguous range.
4. Verify each segment's sparse structure and file size before flashing.
5. Erase `userdata`, flash all segments in order with the official 32-bit
   client, then boot and verify ext4 health and online expansion.

This removes the oversized raw allocation and also tests the bootloader without
FILL chunks.

## Verification result

The segmented test was completed successfully on the OnePlus 6:

```text
root filesystem:       109 GiB
ext4 state:            clean
resize service:        exit status 0
failed systemd units:  0
locked packages:       520
package set SHA-256:   7c08610d03127668970b2b29256a21fdc71e2443b847b0b89d7db2be436b09d9
```

The machine-readable verification record is
`state/v14-segmented-flash-device-verification.json`.
