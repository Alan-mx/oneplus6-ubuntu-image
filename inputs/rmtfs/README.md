# rmtfs arm64 helper

This binary is built for Ubuntu 26.04 arm64 from:

- qrtr `v1.2`, commit `b51ffaf22707b6000ecfb894c5b750f3bb7843b2`
- rmtfs `v1.3`, commit `b30a3eb38f9af283f18dbd3c7755653efc52c094`

Build environment:

```text
linux/arm64 buildpack-deps:bookworm
gcc 12.2.0
libqrtr compiled statically into rmtfs
libudev.so.1 loaded dynamically
```

The binary SHA-256 is:

```text
FE2486B9D2297B12CE960C73A607D3B16834A0D7283871CEEC703DB026D74E39
```
