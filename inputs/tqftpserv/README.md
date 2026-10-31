# tqftpserv arm64 helper

This binary is built for Ubuntu 26.04 arm64 from:

- qrtr `v1.2`, commit `b51ffaf22707b6000ecfb894c5b750f3bb7843b2`
- tqftpserv `v1.3`, commit `b31de6db4f31d09119293203d39636b827f16321`

Build environment:

```text
linux/arm64 buildpack-deps:bookworm
gcc 12.2.0
libqrtr compiled statically into tqftpserv
libzstd.so.1 and liblzma.so.5 loaded dynamically
```

The binary SHA-256 is:

```text
EDAD83F4FBD3A6EBA3712436127B223736E86A5CE4ECC612042F553DE530485B
```
