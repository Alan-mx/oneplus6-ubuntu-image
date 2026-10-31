# pd-mapper arm64 helper

This binary is built for Ubuntu 26.04 arm64 from:

- qrtr `v1.2`, commit `b51ffaf22707b6000ecfb894c5b750f3bb7843b2`
- pd-mapper `v1.1`, commit `5ecd2fe926aca7abfe40724177f63b942cff3947`

Build environment:

```text
linux/arm64 buildpack-deps:bookworm
gcc 12.2.0
libqrtr compiled statically into pd-mapper
liblzma.so.5 loaded dynamically
```

The binary SHA-256 is:

```text
A93E84A355D70FA8EC4C7C992724CAC8B24C2269FD46ED6510A08E21DEB6883F
```
