# OnePlus 6 V14 first-boot ext4 corruption

## Symptom

After flashing V14 and booting, `orbital-resize-rootfs.service` failed:

```text
resize2fs: /usr/sbin/resize2fs: Permission denied to resize filesystem
EXT4-fs warning: ext4_resize_begin: There are errors in the filesystem,
so online resizing is not allowed
```

The rootfs remained 3.4 GiB instead of expanding to the 110 GiB userdata
partition.

## Evidence

Kernel log:

```text
EXT4-fs error (device sda17): ext4_mb_generate_buddy:1317: group 16,
block bitmap and bg descriptor inconsistent: 14240 vs 32254 free clusters
```

The V14 source image passes `e2fsck -fn` and round-trips through `simg2img`
byte-for-byte. The first affected ext4 block is block 524288 at the 2 GiB
offset. Its SHA-256 differs between the source image and the flashed device:

```text
source image: 2fc54cee58422a83ce548a3fb1a5f9a4dafcfccc3fa78be1a69ecfc2be036d3d
device:       2f0bc7bfb66a2dc8a637d180696b7f0cbe1b3fe38852752f2e859c12861afb07
```

The sparse image contains a forced raw chunk covering blocks 524288-524289.
The source image is valid, but that block was not written correctly during the
fastboot transfer despite fastboot reporting success.

A second flash using the stock `img2simg` output, but without erasing userdata
first, failed in the same way across groups 16, 17, 18, 23, 24 and 27. The
sparse image covers every logical block with RAW or FILL chunks. The evidence
points to the bootloader/fastboot path not clearing stale userdata correctly
when FILL blocks are written over an existing filesystem.

The offline repair run confirmed broader write damage: `e2fsck` found
multiply-claimed blocks across several files, repaired the orphan lists,
connected disconnected directories to `/lost+found`, and corrected the group
summary counters. A second read-only pass completed with exit status 0 and
reported `REPAIR SUCCESS`.

## Latest verification after the rebuilt V14 image

The canonical V14 sparse image was unpacked again with the Android SDK
`simg2img`. The resulting ext4 image passes `e2fsck -fn` with exit status 0 and
reports a clean filesystem.

The source image and the installed phone were then compared at the ext4 group
27 block bitmap. The canonical sparse image stores it as a RAW chunk:

```text
sparse chunk 194: RAW
logical blocks:    884961-884962
source block hash: 7d5af105d5763defde0098fb2e2794f1d5dc59ace6eb1cadef0bafb4f9a17ea4
device block hash: ad7facb2586fc6e966c004d7d1d16b024f5805ff7cb47c7a85dabd8b48892ca7
```

The device block hash is the SHA-256 of an all-zero 4 KiB block. This is not a
normal live-filesystem modification: the source block contains the group 27
bitmap, while the device has no bitmap payload at the expected location.

After boot, the phone reports:

```text
EXT4-fs error (device sda17): ext4_validate_block_bitmap:432:
comm systemd: bg 27: block 884961: invalid block bitmap
```

`orbital-resize-rootfs.service` consequently fails with:

```text
resize2fs: /usr/sbin/resize2fs: Permission denied to resize filesystem
EXT4-fs warning: ext4_resize_begin: There are errors in the filesystem,
so online resizing is not allowed
```

Running `sudo resize2fs /dev/sda17` manually does not fix this. The service
already runs the same command; the failure is caused by the invalid ext4
metadata, not by a missing privilege or a missing invocation.

At the same time, the phone is not consuming 2.4 GiB of RAM. A fresh runtime
check reports approximately 647 MiB used and 6.7 GiB available. The root
filesystem reports about 1.7 GiB used and `du -x` reports about 1.6 GiB,
consistent with the installed package set and journal.

## Device verification after segmented flash

The 3.5 GiB ext4 raw image was split into ten sparse segments smaller than
512 MiB. Each segment used only `RAW` and `DONT_CARE` chunks; the device was
verified after flashing all ten segments in order.

```text
root device:            /dev/sda17
userdata size:          118112366592 bytes
root filesystem size:   109 GiB
ext4 block count:       28835840
ext4 state:             clean
resize service:         exit status 0 / success
failed systemd units:   0
ext4 errors in dmesg:   none
locked packages:        520
package set SHA-256:    7c08610d03127668970b2b29256a21fdc71e2443b847b0b89d7db2be436b09d9
memory used:            664 MiB
memory available:       6.7 GiB
```

This verifies that the V14 filesystem content and first-boot expansion are
valid. It also verifies that the segmented `RAW`/`DONT_CARE` transfer avoids
the corruption produced by the single sparse file on this fastboot path.

## Resolution

- Repaired the installed filesystem offline with `oneplus6-boot-repair-v14.img`.
- Rebuilt the share image with the Android SDK `img2simg` instead of the custom
  sparse encoder.
- Verified the `img2simg` output by converting it back to raw, comparing it
  byte-for-byte with the source raw image, and running `e2fsck -fn`.
- Kept the V14 repair boot in the release directory.

The stock sparse image remains the canonical build output, but it is not yet a
safe single-file distribution for this fastboot path. The segmented artifacts
under `out/v14-segmented-flash/` have been flashed and validated on the target
phone.

Because the first flash produced multiple cross-linked blocks, the repaired
rootfs is diagnostic only. Re-flash the canonical rootfs instead of publishing
or using the repaired filesystem as a release.

The required flash sequence is:

```text
fastboot flash boot oneplus6-boot.img
fastboot erase userdata
fastboot flash userdata oneplus6-rootfs-orbital.img
fastboot reboot
```

Do not omit `fastboot erase userdata`; otherwise stale blocks can survive and
the new ext4 filesystem may fail signature-independent consistency checks.
