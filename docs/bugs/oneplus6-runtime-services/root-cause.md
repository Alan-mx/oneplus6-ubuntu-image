# 一加 6 运行时服务根因报告

## 状态

- DNS 和系统时间：已在设备验证。`/etc/resolv.conf` 使用 systemd-resolved stub，
  DNS 解析正常，Chrony 已将时间校正到 2026-10-30。
- GPU 固件启动竞态：已在设备验证。A630 SQE 和 GMU 固件在 0.72 秒时从 initramfs
  加载。
- PipeWire/RTKit：已在设备验证。Linger 已启用，PipeWire、PipeWire-Pulse、
  WirePlumber 和 RTKit 不依赖 SSH 用户会话即可保持运行。
- 蓝牙：控制器和固件可以被检测到，但 HCI 注册仍不完整。完整重绑 WCN3990 电源和
  串口后仍无法恢复。根因位于板级电源时序层以下，还需要跟踪 HCI UART 驱动；
  未应用猜测性修复。

## DNS 和时间

运行时证据：

```text
Local time: Fri 1970-01-02 07:20:56 CST
System clock synchronized: no
chronyc sources: empty
/etc/resolv.conf: nameserver 192.168.65.7
```

Docker 构建时使用的 `resolv.conf` 泄漏到了设备镜像。NetworkManager 获取的 WiFi DNS
已经进入 systemd-resolved，但 `/etc/resolv.conf` 仍是外部静态文件，没有使用该服务，
导致 Chrony 无法解析 NTP 源。

修复：

- 将 `/etc/resolv.conf` 改为指向 `/run/systemd/resolve/stub-resolv.conf`。
- 启用 `systemd-resolved.service`。
- 保留 Chrony 原有的 `makestep 1 3` 行为。

## GPU 固件竞态

运行时证据：

```text
[0.637125] msm_dpu: failed to load a630_sqe.fw
[8.052707] msm_dpu: loaded qcom/a630_sqe.fw from new location
```

Orbital 在 rootfs 对固件加载器可见之前启动。GPU 第一次加载固件失败，直到用户态
挂载 rootfs 后才重试成功。

修复：

- 将 `qcom/a630_sqe.fw` 和 `qcom/a630_gmu.bin` 放入 initramfs。
- 使用更新后的 initramfs 重新打包已经验证的内核。

## PipeWire 和 RTKit

运行时证据：

- PipeWire 和 WirePlumber 会随临时 SSH 用户会话反复启动和停止。
- PipeWire 报告 `RTKit error: ... ServiceUnknown`。
- 只有 SSH 用户会话存在时才能看到音频设备。

修复：

- 为 `orbital` 用户启用 linger。
- 安装并启用 `rtkit-daemon.service`。
- 全局启用 PipeWire、PipeWire-Pulse 和 WirePlumber 用户 unit。

## 蓝牙

运行时证据：

```text
Bluetooth: hci0: QCA setup on UART is completed
hci0: DOWN RAW
hciconfig hci0 up: Operation not supported
btmgmt info: Index list with 0 items
bluetoothctl show: No default controller available
```

固件路径和 QCA 初始化已经完成，但 HCI 设备没有注册到内核管理接口。完整重绑 WCN3990
电源和串口后结果相同：

```text
hci0: DOWN RAW
btmgmt info: Index list with 0 items
bluetoothctl show: No default controller available
```

这排除了简单的电源时序缺失或 BlueZ 启动过晚。下一步应围绕 `hci_uart_setup()`、
`qca_setup()` 和 `hci_register_dev()` 打开 HCI UART 动态调试。

## 验证标准

- `resolvectl status` 使用 wlan0 的 DNS 服务器，`getent` 能解析公网主机名。
- 联网后 `timedatectl` 显示 `System clock synchronized: yes`。
- `chronyc sources` 中存在可达时间源。
- 启动控制台不再出现初始 A630 固件加载失败。
- `loginctl show-user orbital -p Linger` 输出 `yes`。
- 没有 SSH 会话时 PipeWire/WirePlumber 仍保持运行。
- 只有 `btmgmt info` 列出 index 0，并且 `bluetoothctl show` 能看到控制器，才能
  把蓝牙标记为已修复。

## RTC 限制

PMIC RTC 可以读取，但不能设置：

```text
busybox hwclock -w
hwclock: RTC_SET_TIME: No such device
```

因此系统时间只能在 WiFi 可用后由 Chrony 恢复。当前内核的 RTC 驱动无法提供联网前
可靠的硬件时钟。
