# OnePlus 6 prebuilt boot image

`oneplus6-boot-gpu-fix.img` is the hardware-tested quick-build boot image for
the OnePlus 6 `enchilada`.

It is based on the postmarketOS SDM845 kernel locked in
`config/source-revisions.lock.tsv` and includes the tested initramfs changes for
display initialization, A630 GPU firmware loading, boot splash behavior, and
switching to the Ubuntu ext4 root filesystem. The quick build copies this image
unchanged and does not rebuild the kernel or initramfs.

SHA-256:

```text
0C5E907D8F9A342523F8EE883C2FB925A5E70B6F6B97CA81980ECB53FC0A87DC
```
