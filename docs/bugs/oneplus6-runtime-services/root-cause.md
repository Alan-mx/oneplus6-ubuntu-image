# OnePlus 6 runtime services root-cause report

## Status

- DNS and system time: verified on device. `/etc/resolv.conf` uses the
  systemd-resolved stub, DNS resolution works, and Chrony stepped the clock to
  2026-10-30.
- GPU firmware startup race: verified on device. A630 SQE and GMU firmware load
  at 0.72 seconds from the initramfs.
- PipeWire/RTKit: verified on device. Linger is enabled and PipeWire,
  PipeWire-Pulse, WirePlumber and RTKit are active without relying on an SSH
  user session.
- Bluetooth: controller/firmware are detected, but HCI registration remains incomplete. A full WCN3990 power/Serial rebind was tested and did not recover the controller. Root cause is below the board power-sequencing layer and still requires HCI UART driver tracing; no speculative fix applied.

## DNS and time

Runtime evidence:

```text
Local time: Fri 1970-01-02 07:20:56 CST
System clock synchronized: no
chronyc sources: empty
/etc/resolv.conf: nameserver 192.168.65.7
```

The Docker build-time `resolv.conf` leaked into the device image. WiFi DNS from
NetworkManager is available in systemd-resolved, but `/etc/resolv.conf` is a
foreign static file and does not use it. Chrony therefore cannot resolve its
NTP sources.

Fix:

- Replace `/etc/resolv.conf` with `/run/systemd/resolve/stub-resolv.conf`.
- Enable `systemd-resolved.service`.
- Keep Chrony's existing `makestep 1 3` behavior.

## GPU firmware race

Runtime evidence:

```text
[0.637125] msm_dpu: failed to load a630_sqe.fw
[8.052707] msm_dpu: loaded qcom/a630_sqe.fw from new location
```

Orbital starts before the rootfs becomes available to the firmware loader.
The GPU initially misses its firmware and only retries after userspace mounts
the rootfs.

Fix:

- Include `qcom/a630_sqe.fw` and `qcom/a630_gmu.bin` in the initramfs.
- Repack the tested kernel with the updated initramfs.

## PipeWire and RTKit

Runtime evidence:

- PipeWire and WirePlumber repeatedly start and stop with transient SSH user
  sessions.
- PipeWire reports `RTKit error: ... ServiceUnknown`.
- Audio devices are visible while an SSH user session is active.

Fix:

- Enable lingering for the `orbital` user.
- Install and enable `rtkit-daemon.service`.
- Enable the PipeWire, PipeWire-Pulse and WirePlumber user units globally.

## Bluetooth

Runtime evidence:

```text
Bluetooth: hci0: QCA setup on UART is completed
hci0: DOWN RAW
hciconfig hci0 up: Operation not supported
btmgmt info: Index list with 0 items
bluetoothctl show: No default controller available
```

Firmware paths and QCA setup complete, but the HCI device is never registered
with the kernel management interface. A full WCN3990 power/Serial rebind was
tested and produced the same result:

```text
hci0: DOWN RAW
btmgmt info: Index list with 0 items
bluetoothctl show: No default controller available
```

This rules out a simple missing power sequence or late BlueZ startup. The next
step is HCI UART dynamic-debug tracing around `hci_uart_setup()`, `qca_setup()`
and `hci_register_dev()`.

## Verification criteria

- `resolvectl status` uses the wlan0 DNS server and `getent` resolves public
  hostnames.
- `timedatectl` reports `System clock synchronized: yes` after network access.
- `chronyc sources` contains reachable sources.
- The boot console reports no initial A630 firmware failure.
- `loginctl show-user orbital -p Linger` reports `yes`.
- PipeWire/WirePlumber remain active without an SSH session.
- Bluetooth is only marked fixed after `btmgmt info` lists index 0 and
  `bluetoothctl show` reports a controller.

## RTC limitation

The PMIC RTC device is readable but not settable:

```text
busybox hwclock -w
hwclock: RTC_SET_TIME: No such device
```

System time is therefore restored by Chrony after WiFi becomes available. A
hardware-backed pre-network clock is not available through this kernel RTC
driver.
