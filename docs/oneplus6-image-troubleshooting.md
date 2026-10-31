# OnePlus 6 Ubuntu Orbital 镜像问题与解决记录

本文汇总制作 OnePlus 6 `enchilada` Ubuntu 26.04.1 + Orbital 镜像时遇到的主要问题。
每一项都记录现象、原因、处理方式和验证结论，供后续修改内核、rootfs 或桌面时参考。

整理日期：2026-10-31。范围截至本地 V15 发布产物。本文总结的是本项目的代码、历史日志、
真机反馈和验收记录，不表示其他内核版本或其他手机一定有相同问题。本次整理没有重新刷机验收。

“已解决”表示本项目已有修复和后续使用证据；“已规避”表示采用了通过验证的替代路径；
“待验证”表示实现、推断或历史记录仍不足以证明最终行为。旧报告里的“等待真机验证”
保留作当时的记录，不应据此把所有项目都算作 V15 已完成的独立验收。

## 问题速查

| 问题 | 处理结果与边界 | 章节 |
| --- | --- | --- |
| initramfs 命令缺失、PID 1 退出 | 已解决；同样的救援 shell 提示也可能有其他原因 | 1 |
| 大 sparse 刷后 ext4 损坏 | 分段方案已规避；刷写链路的具体实现缺陷未完全定位 | 2 |
| Windows fastboot `bad_alloc` | 分段方案已规避 | 3 |
| 触摸、电量模块依赖缺失 | 已生成依赖并有后续使用反馈 | 4 |
| `wlan0` 不出现 | 补齐启动链后恢复；换版本仍需冷启动回归 | 5 |
| WiFi UI 没发起连接 | 本地源码已修复；Orbital 远端尚未包含全部适配 | 6 |
| 特定 AP 关联后提示缺密码 | 兼容 profile 已实测；不适用于所有网络 | 7 |
| USB 网络与 SSH 超时 | 已恢复；主机驱动、手机 gadget 和 SSH 分层检查 | 8 |
| GPU 软件渲染与卡顿 | 固件补齐及早期加载已有运行证据 | 9 |
| 背光写入 I/O error | 后续真机反馈硬件调光恢复 | 10 |
| 短按电源键直接关机 | logind 与桌面职责已调整；按键行为独立验收 | 11 |
| 早期花屏与企鹅消失 | 企鹅恢复；早期压缩画面精确根因未完全确认 | 12 |
| MAC、地址和 SSH 指纹变化 | 已说明各自来源；刷 rootfs 后指纹变化属预期 | 13 |
| DNS 与时间 | 网络校时已恢复；RTC 写入未解决 | 14 |
| 蓝牙无可用控制器 | 未解决；当前禁用服务自动启动 | 15 |
| 首次扩容与 repair boot | 自动扩容已验证；损坏分区不能靠重复扩容修复 | 16 |
| 初始密码和自动更新 | 策略已配置/验证；保留共享密码与未来更新风险说明 | 17 |
| 从零构建与版本升级 | 尚有本地输入、未提交源码和 proot 构建缺口 | 18 |
| SVG 图标、关机重启按钮 | 依赖和源码已有调整；缺少全项独立验收 | 19 |
| 用户会话服务与灭屏运行 | linger 已验证；音频、睡眠和功耗分别验收 | 20 |

## 先确认设备和产物

- OnePlus 6 的设备代号是 `enchilada`。
- OnePlus 6T 的设备代号是 `fajita`，不能直接使用本镜像。
- 目标根分区是 `/dev/sda17`，对应 fastboot 的 `userdata`。
- 启动链是 Android `boot.img` 中的 Linux 内核和 initramfs，再由 initramfs 切换到 Ubuntu rootfs。
- V15 使用 Ubuntu 26.04.1 ARM64、postmarketOS SDM845 内核 `7.1.0-rc1-sdm845`。

刷写前先确认：

```text
fastboot getvar product       -> sdm845
fastboot getvar current-slot  -> a 或 b
fastboot getvar slot-count    -> 2
```

`sdm845` 只能确认平台，不能区分一加 6 和 6T。还须核对真实机型、设备树和镜像适用范围。
`fastboot flash boot` 操作的是当前槽位，不能从槽位字母推断手机型号。

## 1. initramfs 缺少 BusyBox 命令导致启动崩溃

### 现象

内核可以识别 UFS 和 `/dev/sda17`，但随后出现：

```text
init: line 13: mount: not found
init: line 26: sleep: not found
Kernel panic - not syncing: Attempted to kill init
```

有些调试镜像不会立刻 panic，而是停在：

```text
can't access tty: Job control turned off
```

### 原因

initramfs 只复制了 `/bin/busybox`，没有建立 `mount`、`sleep`、`mkdir`、
`switch_root` 等 applet 链接。PID 1 执行 init 脚本时找不到这些命令，
`set -e` 使 init 退出，内核因此终止启动。

### 解决方式

在 initramfs 中建立指向 BusyBox 的链接，并显式设置 `PATH=/bin`：

```text
/bin/sh
/bin/mount
/bin/sleep
/bin/mkdir
/bin/switch_root
```

调试 initramfs 还需要 `ls`、`readlink`、`chroot` 等辅助命令。只修改
`boot.img` 即可，不需要重新制作 rootfs。

### 结论

已解决。以后修改 `config/initramfs-init` 后，必须检查最终 boot 镜像中
的 ramdisk，而不能只检查源码。

`can't access tty: Job control turned off` 只表示这个 shell 没有控制终端，
不是所有启动失败的共同根因。后期同样的提示还可能出现在 rootfs 损坏或挂载失败后。
必须往前找 `mount`、`switch_root`、ext4 或命令缺失的第一条错误。

## 2. 单个 sparse 镜像刷入后 ext4 损坏

### 现象

镜像在电脑上通过 `e2fsck -fn`，fastboot 也显示写入成功，但手机启动后出现：

```text
EXT4-fs error: block bitmap and bg descriptor inconsistent
invalid block bitmap
resize2fs: Permission denied to resize filesystem
```

根文件系统不能扩容，或者系统启动后出现文件交叉占用、`lost+found` 和服务异常。

### 原因

本次记录确认源 ext4 通过离线检查、sparse 往返转换一致，而刷后分区块与源数据不一致。
故障定位在刷写链路；尚未定位到 fastboot 客户端或 bootloader 内部的具体代码。
比较源镜像和手机分区后发现，部分 RAW 数据块在传输后变成全零或保留旧内容。
单个大 sparse 文件在本机链路上复现了问题。FILL 处理和传输分段是调查中的怀疑点，
不能把它们写成已经证实的唯一根因；已证实的结果是后述分段方案避开了故障。

### 解决方式

1. 刷写前执行 `fastboot erase userdata`，清除旧的 userdata 内容。
2. 将完整 sparse rootfs 分割为多个连续的小段。
3. 每段小于 512 MiB，段内只使用 `RAW` 和 `DONT_CARE` chunk。
4. 按顺序刷入全部段，并逐段校验 SHA-256。
5. 首次启动后验证扩容服务和内核 ext4 日志；完整 `e2fsck` 检查在分区卸载的救援环境执行。

当前公开 Release 推荐使用：

```text
oneplus6-v1-segmented-flash.zip
```

这不是把文件简单按字节切成十份。每个段都是独立有效的 Android sparse 文件，
有完整的逻辑大小信息，只有自己负责的连续区间用 RAW，其他区间用 DONT_CARE 表示。
只在刷第一个段之前擦除一次 `userdata`，不能在段与段之间再次擦除。
`scripts/make_sparse_segments.py` 生成段和 manifest，`scripts/flash-segments.ps1`
负责校验覆盖范围、大小、哈希和刷写顺序。

早期 10 GiB 逻辑镜像能启动，不意味着缩为 3.5 GiB 本身会导致损坏；镜像内容、
RAW/FILL 分布和刷写分段都会改变。应比较实际写入的块，而不是把逻辑容量当作根因。

### 结论

已通过真机验证。分段镜像刷入后根文件系统干净、扩容成功、systemd 失败单元为 0。
单文件 sparse 镜像仍保留用于开发和检查，不作为 OnePlus 6 的首选刷写方式。

分段包解压后约 3.5 GiB，是因为每段用 RAW 保存自己的区域，零块也占文件空间；
ZIP 可以压缩这些重复内容，所以当前公开 Release 分段 ZIP 约 512 MiB。解压大小不是手机内存占用。

刷 sparse 时曾看到：

```text
Warning: skip copying userdata image avb footer due to sparse image.
```

本项目在解锁设备上使用自制 Linux userdata，该提示本身不是 ext4 损坏证据。
也不能反过来从没有报错或全部 `OKAY` 推断数据正确，应继续完成文件系统验收。

## 3. 32 位 Windows fastboot 刷 RAW 镜像触发 bad_alloc

### 现象

执行大于 3 GiB 的 RAW 镜像刷写时，在出现 `Sending` 进度前直接退出：

```text
libc++abi: terminating due to uncaught exception of type std::bad_alloc
```

### 原因

使用的 Windows fastboot 是 32 位 x86 程序，无法稳定映射约 3.5 GiB 的 RAW 文件。
这和 sparse 镜像在手机端写入损坏是两个独立问题。

### 解决方式

- 如果另有来源可靠的 64 位客户端，可单独验证其大文件支持，但本次没有把换客户端作为发布方案；
- 本次实际验证的方式是直接使用小于 512 MiB 的分段 sparse ZIP；
- 不要把完整 RAW 文件直接交给旧的 32 位 fastboot。

### 结论

已规避。V15 发布包使用分段 sparse 镜像和 PowerShell 校验脚本。

## 4. 模块依赖未生成导致触摸、电量和 RNDIS 不工作

### 现象

- 桌面能显示，但触摸没有反应；
- 电量信息为空；
- 手机侧 USB gadget 的依赖模块也可能加载失败；
- 日志中出现 `Unknown symbol`；
- `modprobe` 看似执行，实际设备节点没有出现。

典型日志：

```text
bq27xxx_battery_i2c: Unknown symbol ...
qcom_battmgr: Unknown symbol ...
```

### 原因

把 postmarketOS 内核模块复制进 Ubuntu rootfs 后没有执行 `depmod`，导致
`modules.dep` 中的依赖为空。像 `rmi_i2c -> rmi_core`、
`bq27xxx_battery_i2c -> bq27xxx_battery`、`usb_f_rndis -> u_ether/libcomposite`
这样的依赖链没有被 `modprobe` 自动加载。

### 解决方式

模块复制完成后，对两个 rootfs 都执行：

```bash
depmod -b "$rootfs" -a 7.1.0-rc1-sdm845
```

重新生成 rootfs 后检查 `modules.dep` 和 `/sys/class/power_supply`、输入设备、
USB gadget 所需模块。

`uname -r` 必须与 `/lib/modules/<版本>` 一致。换内核时同时配套更新模块，
不能把另一内核的模块混入 rootfs，也不能仅凭“同属 SDM845”判断兼容。

### 结论

已解决。`build.sh` 和 `refresh-images.sh` 都包含 `depmod` 步骤。

## 5. WiFi 不出现：不是单一驱动问题

### 现象

内核模块已经加载：

```text
ath10k_snoc
ath10k_core
mac80211
cfg80211
pwrseq_qcom_wcn
```

但系统只有 `lo`、`usb0`、`sit0`，没有 `wlan0`，也扫描不到 WiFi。

### 原因

本次设备需要补齐的 Qualcomm 用户态和固件协作链路包括：

```text
tqftpserv + pd-mapper + rmtfs + remoteproc/MSS
                       -> WLFW QMI 可用 -> ath10k 初始化 -> wlan0
```

前三个服务并不是依次调用彼此的流水线；具体等待条件与排序见对应 systemd unit。

同时还遇到过以下缺失项：

- 内核请求的 `qca/crbtfw21.tlv` 没有标准路径；
- `qca/crnv21.bin` 没有指向 OnePlus 6 板级文件；
- 缺少 Alpine 的 `linux-firmware-ath10k`，其中包含 WCN3990 的 `board-2.bin` 和 `firmware-5.bin`；
- Ubuntu 不一定会因为 OF modalias 自动加载 `ath10k_snoc`；
- 设备树中的 WCN3990 pinctrl 配置会导致 `pwrseq` 绑定时出现 SPMI `-EPERM`；
- 只在系统启动完成后补启动服务太晚，远程处理器已经错过固件请求。

### 解决方式

1. 安装原生 ARM64 的 `tqftpserv`、`pd-mapper`、`rmtfs`。
2. 将三个服务固化进 rootfs，并按远程处理器设备节点排序启动。
3. 在 `modules-load.d` 中显式加载：

   ```text
   pwrseq_qcom_wcn
   ath10k_snoc
   ```

4. 建立固件路径：

   ```text
   qca/crbtfw21.tlv -> ../postmarketos/qca/crbtfw21.tlv
   qca/crnv21.bin   -> OnePlus/enchilada/crnv21.bin
   ```

5. 纳入 `linux-firmware-ath10k` 的 WCN3990 固件。
6. 在生成 boot 镜像时清理错误的 WCN3990 pinctrl 属性。
7. 冷启动验证 QRTR 服务 69、`wlan0` 和 WiFi 扫描。

### 结论

已在运行中验证：补齐 `rmtfs` 后 QRTR 出现 ATH10k WLAN 服务，`wlan0` 创建并能扫描。
最终镜像还必须做完整断电/冷启动验证，因为运行中手动启动服务不能完全代表开机顺序。

## 6. WiFi 能扫描但 Orbital 点击连接失败

### 现象

WiFi 列表正常，但点击网络、输入密码后没有连接请求，NetworkManager 日志中没有激活记录。

### 原因

QML 动态创建的连接页面回调引用了不存在的 `wifiPage`，运行时抛出：

```text
ReferenceError: wifiPage is not defined
```

回调中断后，后端的 `connectToWifi()` 根本没有执行。

### 解决方式

- 由 `WifiConnectPage` 直接调用后端连接接口；
- 父页面只负责设置待连接 SSID 和接收连接结果；
- 删除依赖动态对象 ID 的跨组件回调。

### 结论

修复已在本地 Orbital 源码中实现；旧报告仍停留在实施前状态，不能当作当前代码状态。
这些适配修改尚未提交到 Orbital 远端。验收要同时观察 QML 日志、NetworkManager 激活请求、
DHCP 和实际联网，不能用“按钮能点击”代替连接成功。

## 7. 某些 WPA 网络提示密码缺失

### 现象

Orbital 或 `nmcli` 报告：

```text
Secrets were required, but not provided
```

### 原因

本次特定 AP 的日志出现 `STA_REQ_ASSOC_WITHOUT_AUTH`，默认配置的关联失败后又要求认证信息；
相同密码改用 WPA/TKIP 后成功。因此该次故障不是简单的密码漏传。
但这条报错本身也可能真的表示没有提供密码或没有可交互的 secret agent，必须结合日志判断。

### 解决方式

针对该 AP 手动创建 NetworkManager profile，指定 AP 实际支持的协议，例如 WPA/TKIP：

```bash
sudo nmcli connection modify "SSID" \
  802-11-wireless-security.key-mgmt wpa-psk \
  802-11-wireless-security.proto wpa \
  802-11-wireless-security.pairwise tkip \
  802-11-wireless-security.group tkip \
  802-11-wireless-security.pmf disable
```

密码通过本机命令输入，不写进仓库文档。

### 结论

本次特定 AP 通过兼容配置完成了 DHCP、外网 Ping 和 HTTPS 访问，不能推广为所有同类报错的解法。
上面的命令假定 profile 已存在，不是新建连接的完整步骤。使用 WPA/TKIP 会降级保护，
只对确认需要的旧 AP 单独配置，不能改成所有网络的默认值。

## 8. USB RNDIS 能在救援镜像使用，正式镜像 SSH 超时

### 现象

救援镜像曾能提供 `172.16.42.1` 上的诊断 HTTP 页面，正式镜像 SSH 却超时；
Windows 设备管理器中还曾出现 RNDIS Code 28。诊断 HTTP 可访问不等于 SSH 服务已经存在。

### 原因

- Windows 侧缺少 RNDIS 兼容驱动绑定；
- 正常 rootfs 的 gadget 服务只写入 UDC，没有等待 `usb0` 出现并执行 `ip link set usb0 up`；
- NetworkManager 把 USB 网卡当成未管理设备时，固定地址和 DHCP 服务没有及时建立。

### 解决方式

- 使用复合 USB gadget 创建 RNDIS function；
- 等待 `/sys/class/net/usb0` 出现并执行 `ip link set usb0 up`；
- 固定手机端 `172.16.42.1/24`，通过 dnsmasq 提供 USB 侧 DHCP；
- Windows 应核对当前 gadget 的硬件 ID 和兼容 ID，再匹配系统 RNDIS 驱动；
- 通过救援镜像或本地屏幕验证 gadget 服务日志。

### 结论

已解决。`172.16.42.1` 是 USB 直连网络的手机端固定地址，不是 WiFi 地址。

救援 gadget 曾使用 `VID_0525&PID_A4A2`，当前正式配置使用 `VID_18D1&PID_D001`，
两者不能按同一个设备实例处理。历史兼容 ID 还出现过 CDC 类描述，因此仅凭 FriendlyName
为 RNDIS 不能保证驱动匹配；描述符不匹配时应检查 gadget，不要强制安装任意网卡驱动。
主机 Code 28 是驱动绑定问题，与手机侧 `depmod` 问题分别检查。

排查顺序为：设备枚举、驱动、主机 USB 网卡地址、手机 `usb0` 地址、最后检查 TCP 22 和 ssh 服务。
Windows 上可运行 `Get-NetAdapter`、`ipconfig /all`、`Test-NetConnection 172.16.42.1 -Port 22`。
若测试实际走的是 WLAN，就还没有走通 USB 网卡，继续重试 SSH 密码没有意义。

## 9. GPU 未初始化导致桌面卡顿和 CPU 暴增

### 现象

点击桌面操作时卡顿，CPU 突然升高；日志出现：

```text
Direct firmware load for qcom/a630_sqe.fw failed with error -2
Running on a software rasterizer (LLVMpipe)
```

### 原因

缺少 Adreno A630 的 `a630_gmu.bin` 和 `a630_sqe.fw`，Qt/Mesa 退回 CPU 软件渲染。
另外，GPU 固件在 rootfs 挂载后才可见时，也会出现早期加载失败。

### 解决方式

- 安装 `firmware-qcom-adreno-a630` 及其 SQE 固件；
- 将关键 GPU 固件放入 initramfs；
- 在运行时检查：

  ```text
  loaded qcom/a630_sqe.fw from new location
  loaded qcom/a630_gmu.bin from new location
  ```

### 结论

已解决。V15 现场验证已经从 initramfs 加载 A630 固件。

“固件文件已经加载”与“每次桌面交互都已经确认硬件渲染”也应分别核对，
回归时同时检查 Orbital/Mesa 是否仍出现 LLVMpipe，以及进程 CPU 与帧率表现。

## 10. 亮度调节失败和 DSI 错误

### 现象

写入背光节点时出现：

```text
echo: I/O error
```

但 `brightness` 或 `actual_brightness` 可能仍显示新数值，导致界面状态和实际亮度不一致。

### 原因

Samsung `sofef00` 面板的 DSI 背光命令可能在 panel 未准备好时发送；6G DSI byte clock
没有取 PLL 可实现的值时，运行时重新设置时钟会干扰视频模式面板。

### 解决方式

- 应用 DSI byte clock rounding 修复；
- 面板未 `prepared` 时跳过背光 DCS 命令；
- 用户态只在硬件写失败后启用一次软件遮罩调光，并停止无休止重试；
- 修复后再次确认 `brightness` 和 `actual_brightness` 都变化且屏幕实际亮度改变。

### 结论

后续真机反馈确认：写入 `700` 返回 0，`brightness` 和 `actual_brightness` 均为 `700`，
实际亮度改变。这是硬件调光恢复的证据；读取节点数值本身不足以证明 DSI 命令发送成功。
软件遮罩只改变画面明暗，不等同于面板硬件调光或同等省电效果。

## 11. 电源键短按直接关机

### 现象

短按电源键直接关机，无法实现灭屏；长按也可能触发 systemd 默认动作。

### 原因

systemd-logind 默认 `HandlePowerKey=poweroff`，在 Orbital 处理输入前就执行了关机。

### 解决方式

添加 logind drop-in：

```ini
HandlePowerKey=ignore
HandlePowerKeyLongPress=ignore
```

再由 Orbital 自己处理电源键：短按灭屏/亮屏，长按重启桌面进程。

### 结论

已实现并纳入镜像。电源键的设备路径仍应通过输入设备自动发现验证。

## 12. 开机文字挤成一条线、企鹅不显示或第一屏花屏

### 现象

早期启动输出挤在屏幕中间一条横线，第一屏乱码或花屏；调整启动参数后又可能连 Linux 企鹅都消失。

### 原因

观察到早期 framebuffer 和 DRM 接管后画面表现不同，说明显示接管阶段需要分开排查。
现有归档没有足够的早期 framebuffer 几何和日志证据，无法确认“横向压缩”的唯一根因。
不能据此声称某个 DSI 或 panel 补丁已经单独解释了所有花屏。

### 解决方式

- 保留必要的 `console=ttyMSM0` 和 `console=tty0`，便于诊断；
- 保留 `kernel-patches/0003-fbcon-keep-boot-logo-with-quiet.patch`，使低 console loglevel 下仍允许显示 logo；
- 当前 boot 使用 `loglevel=0` 限制内核 console 输出，同时通过 `systemd.show_status=1` 显示用户态启动状态；
- 区分早期 framebuffer 和 DRM 接管阶段，分别记录画面与对应日志。

### 结论

后续用户反馈企鹅恢复显示。不是简单删除所有日志就算修复；调试时可以临时提高日志级别，
修改后要分别验证第一屏、第二屏及最终桌面。早期压缩画面的精确根因仍待补足证据。

## 13. 固定 USB 地址、WiFi 地址和 SSH host key

### 说明

- `172.16.42.1` 是 USB 网络服务固定的手机端地址；
- WiFi 地址由接入点 DHCP 分配，不能写死；
- WiFi MAC 从 persist 分区的 `wlan_mac.bin` 读取，再写入 `wlan0`；
- SSH host key 在每台设备首次启动时生成。

### 反复刷写后的 SSH 警告

重新刷写 rootfs 后，首次启动重新生成 host key，Windows 可能提示：

```text
REMOTE HOST IDENTIFICATION HAS CHANGED
```

确认是自己刚重刷的 USB 直连设备并核对新指纹后，可在 Windows 执行：

```powershell
ssh-keygen -R 172.16.42.1
ssh orbital@172.16.42.1
```

仅刷 boot、rootfs 和 host key 文件都未变时，通常不需要清理。不要为省事全局关闭 host key 检查，
也不要把同一套 SSH 主机私钥打包给所有手机。

当前 MAC 脚本优先寻找 `persist` 分区标签，再回退 `/dev/sda2`，只读挂载后取 `Intf0MacAddress`。
这是每台设备的本地数据，不是把开发者手机的 WLAN MAC 写死到镜像。其他设备分区布局不符或
persist 数据缺失时必须明确报错，不能假设本机测试覆盖所有一加 6。

## 14. DNS、时间和 RTC

### 现象

手机每次启动 RTC 时间接近 1970 年；没有 WiFi 时 Chrony 无法同步。

### 原因

- PMIC RTC 在当前内核下可读但不可设置；
- 构建容器的 `/etc/resolv.conf` 曾被错误带入 rootfs；
- WiFi DNS 已进入 systemd-resolved，但静态 resolv.conf 没有指向 resolved stub。

### 解决方式

- 将 `/etc/resolv.conf` 链接到 `/run/systemd/resolve/stub-resolv.conf`；
- 启用 `systemd-resolved`；
- 保留 Chrony 的 `makestep`，网络恢复后自动校时；
- 不把 RTC 当作可靠的断电时钟。

### 结论

DNS 和网络校时已验证。RTC 硬件写入仍受当前内核/驱动限制，未宣称修复。

## 15. 蓝牙控制器无法注册

### 现象

能看到 `hci0` 和 QCA setup 日志，但：

```text
btmgmt info: Index list with 0 items
bluetoothctl show: No default controller available
```

### 已排查内容

- 固件路径存在；
- BlueZ 已启动；
- 停止 Bluetooth 后重新绑定 UART 和 WCN3990 电源序列仍不能恢复；
- 反复加载 `ath10k` 不会改变结果。

### 结论

蓝牙 HCI 初始化/管理接口可用性问题仍未解决；看到 `hci0` 不等于 BlueZ 已有可用控制器，
但也不能仅凭管理接口无 index 就断言 `hci_register_dev()` 从未执行。UART/QCA 初始化是调查方向，
不是已经定位到的唯一故障点。
后续应对 `hci_uart_setup()`、`qca_setup()`、`hci_register_dev()` 开启动态调试，不要继续猜测性修改 rootfs。

本次最终取舍是优先恢复 WiFi，当前构建禁用 `bluetooth.service` 的自动启动。
禁用 BlueZ 服务并不等同于删除所有蓝牙模块。不得为了试蓝牙在日常版本中反复解绑共享的
WCN3990 电源与串口，历史测试已出现 WiFi 回归。

## 16. rootfs 首次启动扩容

### 现象

镜像制作时只有约 3.5 GiB，刷入 userdata 后需要扩展到整个分区。

### 解决方式

安装 `orbital-resize-rootfs.service`，首次启动执行：

```bash
sudo resize2fs /dev/sda17
```

该服务在开机时执行，命令具备重复运行条件，不是要求用户每次刷两套镜像。
本次测试手机容量下根文件系统约 109 GiB；其他容量机型的数字会不同。
服务成功与文件系统完整性分别验收，完整检查须进入救援环境卸载分区后执行。
如果 ext4 元数据已经被 fastboot 写坏，手动执行 `resize2fs` 也不能修复；应重新擦除并刷入经过分段处理的镜像。

repair boot 是出现故障时用于离线检查和修复的救援产物，不是正常每次刷机都必须先刷一遍、
再刷正式 boot 的步骤。正常路径直接用已验证分段包；必须离线修复时，按救援日志确认操作已完成，
再恢复正式 boot。不能把一张旧修复镜像的停止/重启行为当作所有版本都自动处理的保证。

## 17. 固定初始密码和自动更新

### 当前策略

- SSH 用户为 `orbital`；
- 固定初始密码只用于私下分发；
- 账号有免密 sudo，首次登录后应立即执行 `passwd`；
- `pam_pwquality` 拒绝过弱或包含用户名的密码；
- 登录提示在密码改变后自动消失；
- unattended-upgrades 只允许 security origin，禁止自动重启。

### 注意事项

固定初始密码意味着任何能连到 SSH 的人都可尝试登录；由于账号有免密 sudo，改密前相当于暴露管理员入口。
本次用户选择保留 `orbital/123456` 并自行改密，这属于使用取舍，不是首次登录强制改密方案。
若公开分发，必须清楚说明这项风险；取消免密 sudo 本身也不能消除共享 SSH 密码的问题。

自动更新不会重写电脑上的 `.img`；重新刷 rootfs 则会覆盖设备上的已安装更新和个人配置。
镜像有 APT pin 阻止安装 Ubuntu 通用内核包，但这不代表用户态安全更新绝无兼容风险。
配置验证通过不等同于每个未来更新都已经真机测试；更新前保留可回退镜像，更新后检查服务。

## 18. 从零构建和升级的限制

### 当前构建方式

源码仓库保存构建脚本、锁文件、配置和内核补丁；Orbital 桌面源码在旁边的独立仓库。
其中 Ubuntu base 和 APK 有下载及校验逻辑；boot 覆盖镜像、`tqftpserv`、`pd-mapper`、`rmtfs`
则要求预先存在于本地 `inputs/`，尚无完整的自动获取/编译入口。Orbital 适配也仍有本地未提交修改。
因此不能承诺别人仅克隆当前 Git 就能构建与 V15 一致的结果。

### 已知限制

当前 proot/qemu 构建环境在部分主机上安装或升级 systemd 时会触发 proot assertion。
V15 是从已验证的 V14 rootfs 恢复后安装锁定的软件包，再重新生成镜像，不能声称已经完成全新机器的完全可复现构建。
恢复的两棵 rootfs 分别记录为基础系统 460 包、Orbital 524 包；不要把两个镜像的软件包数量混用。

版本、包清单、APK 索引、辅助二进制和 boot 都有锁定。仅改 `UBUNTU_VERSION` 或内核版本字符串
会遇到脚本校验和实际输入不一致；应同步更新下载来源、模块、固件、补丁及锁文件，验证后再接受新版本。

## 19. SVG 图片不显示、关机重启按钮无效

### 现象与分层

桌面只剩可点击的圆框或图标空白，说明点击区域存在，不能据此认定图片资源也正常。
图标使用 QML 中的 `qrc:/MyDesktop/Backend/assets/*.svg`，既要验证资源打包路径，
也要验证 Qt SVG 的运行时支持。

### 当前实现和验证方式

构建已安装 `qt6-svg-plugins`，V15 包锁包含该包和 `libqt6svg6`。用 Orbital journal 检查
资源找不到、image provider 或格式插件错误，并在真机逐项查看图标。本地已有相应依赖，
但归档中缺少本轮逐图标截图验收，不能把所有空白图标都统一归因为插件缺失。

原桌面关机接口直接以普通用户调用 `reboot`/`poweroff`，不能依赖存在交互式授权代理。
本地修复只允许 `reboot` 和 `poweroff` 两种操作，通过 `sudo -n systemctl --no-block`
提交请求，避免 GUI 等待认证或阻塞。该方式依赖本镜像的 sudo 策略；其他发行版应重新设计授权。

`startDetached()` 成功只证明子进程启动，不等于手机已成功关机。最终验收必须观察关机/重启结果，
失败时查看 journal，而不是只看按钮响应。当前源码实现存在，不能据此补写缺失的独立真机验收结果。

## 20. 用户服务随 SSH 退出、灭屏与服务器运行

PipeWire/WirePlumber 曾随 SSH 用户会话反复启动停止，且日志报 RTKit 服务不存在。
本次处理是启用 `orbital` 用户 linger，安装 RTKit，并全局启用 PipeWire、PipeWire-Pulse
和 WirePlumber 用户单元。已有运行记录确认这些服务可在不依赖 SSH 会话的情况下保持 active。

这个结果只证明用户会话服务运行，不等于扬声器、麦克风和蓝牙音频已全部验收。
声音设备树还曾出现 `MultiMedia1: error getting cpu dai name` 延迟探测记录，音频完整性须单独测试。

Orbital 灭屏会隐藏渲染窗口并尝试控制背光/触摸，目的是减少绘制，不等同于进入系统 suspend。
服务器工作方式下应实际测试灭屏后的 SSH、网络和后台任务，而不能从“屏幕黑了”推断服务已停。
目前 logind 配置只接管电源键，不代表系统所有睡眠入口都被全局禁用，也没有完成续航或功耗测量。

### 修改版本的正确顺序

1. 修改源码、配置或 Orbital。
2. 更新对应版本和 SHA-256 锁文件。
3. 在临时 rootfs 中构建并做静态检查。
4. 生成分段 sparse 镜像。
5. 在真实 OnePlus 6 上冷启动验证 boot、触摸、显示、GPU、WiFi、USB SSH、扩容和 systemd。
6. 记录新的镜像哈希、软件包锁和设备验证结果。
7. 最后再制作 Release ZIP。

## 常用验证清单

```bash
uname -a
systemctl --failed
findmnt /
df -h /
ip -br link
nmcli dev status
nmcli dev wifi list
systemctl is-active tqftpserv pd-mapper rmtfs
systemctl is-active orbital-usb-gadget orbital-usb-network
cat /sys/class/backlight/ae94000.dsi.0/brightness
cat /sys/class/backlight/ae94000.dsi.0/actual_brightness
sudo dmesg | grep -Ei 'ext4|ath10k|wcn3990|qmi|qrtr|firmware|drm|dsi|rndis'
```

文件系统完整检查请在救援系统中、确认 `/dev/sda17` 未挂载后再执行：

```bash
findmnt -S /dev/sda17
# 上一条不应显示任何挂载；若有输出，先停止并正确卸载，再检查。
sudo e2fsck -fn /dev/sda17
```

在线根文件系统仍在变化时，`e2fsck -n` 结果也不能作为可靠的完整性验收。
修复型 `e2fsck` 更不得在已挂载分区上运行。

发布前至少确认：

- 分段 ZIP 和每个段的 SHA-256 正确；
- `userdata` 已擦除后按顺序刷写；
- 根文件系统扩容成功；
- `systemctl --failed` 没有失败单元；
- `wlan0` 能出现并扫描；
- USB SSH 能连接；
- 没有把 WiFi 密码、私钥、host key 或本地状态文件提交到 Git。

## 验收边界与经验

V15 验收 JSON 记录了初始 SSH 登录、改密提示、密码策略、标记清理、约 109 GiB 根分区、
扩容成功、无失败 systemd 单元、524 包锁和当时约 668 MiB 内存使用。该记录的 `wlan0`
状态是 `disconnected`，不应写成它同时证明了 V15 当次联网验收。

触摸、电量、WiFi 连接、亮度和企鹅显示还有此前聊天和真机反馈支持，但证据来自不同阶段，
未来正式发布应在同一次冷启动上补齐全项检查。蓝牙、RTC 写入、早期花屏精确根因、
音频完整性及干净环境从零构建仍需后续工作。

经验是先按层定位，再验证最终产物：

- 内核识别到磁盘不代表 initramfs 的命令齐全。
- `lsmod` 有模块不代表固件、依赖和用户态协作服务已经工作。
- `fastboot OKAY` 不代表目标块与源镜像一致。
- `systemctl active` 不代表设备功能完成验收。
- 运行中手动修好不代表下次冷启动顺序正确。
- 源码留有补丁不代表自动构建已实际应用；当前 boot 覆盖输入尤其需要追溯来源。
- 救援修复能辅助定位，不应把修过大量交叉块的文件系统当成干净发布基线。

## 证据索引

以下是整理时读取的原始材料。未提交的内部报告和本地状态文件不一定随公开仓库分发，
本文已保留主要现象、结论和限制，独立阅读不依赖它们。

| 材料 | 本地位置或仓库相对路径 |
| --- | --- |
| 启动、模块、GPU/电源、WiFi、QML 历史根因报告 | Orbital 仓库 `docs/bugs/oneplus6-*/root-cause.md` |
| fastboot RAW 内存不足 | 本仓库 `docs/bugs/oneplus6-fastboot-x86-raw-oom/root-cause.md` |
| 刷后 ext4 元数据不一致与分段验证 | 本仓库 `docs/bugs/oneplus6-v14-flash-corruption/root-cause.md` |
| DNS、RTC、GPU 早期固件、用户服务、蓝牙 | 本仓库 `docs/bugs/oneplus6-runtime-services/root-cause.md` |
| proot 失败与恢复 V14 的 V15 制作过程 | 本仓库 `docs/specs/fixed-initial-password/progress.md` |
| 当前设备配置、服务、包锁及构建实现 | 本仓库 `config/`、`scripts/`、`kernel-patches/` |
| V15 实机验收记录 | `releases/v15/v15-device-verification.json` |
| 分段 ZIP 解包、哈希和结构校验记录 | `releases/v15/v15-segmented-zip-verification.json` |
