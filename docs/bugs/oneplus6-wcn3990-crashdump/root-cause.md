# 一加 6 WCN3990 固件崩溃导致 Qualcomm CrashDump 根因报告

## 状态

- 崩溃现象：已在设备复现，定位到 WiFi 固件层。
- 自动恢复：已实测不可行。硬件看门狗能复位，但 bootloader 会停在 CrashDump Mode。
- 固件升级：已确认不可行，Ubuntu 最新 `linux-firmware` 中的 WCN3990 固件与本机字节一致。
- 缓解措施：已在设备关闭 WiFi 省电；建议优先 5G、路由器固定信道与带宽。

## 现象

设备作为常驻服务器运行，偶发整机死机，屏幕停在 `Qualcomm CrashDump Mode`，只能长按
电源键重启。用户观察到的规律是：**更换 WiFi 环境时更容易出现**，例如从公司网络切到
家里、再到另一个地点；同一地点多节点组网之间漫游也可能触发。

2026-11-21 的一次崩溃时间线（Beszel 采集数据，UTC）：

```text
01:55–02:01  CPU 3%，内存 39.7%，最高温度 38.3 °C，电量 90%，load 0.17
02:01:12     最后一条采集记录
02:05:22     恢复采集，内存 1.27 G（冷启动特征）
```

即崩溃前系统几乎空闲，排除过热、内存压力和负载因素。

## 直接证据

同一天开机后约 3 分钟，`ath10k_snoc` 记录到一次固件崩溃：

```text
10:07:01 wlan0: AP 82:89:07:xx:xx:xx changed bandwidth in beacon,
         new used config is 2412.000 MHz, width 1
10:07:01 ath10k_snoc 18800000.wifi: firmware crashed! (guid 4ce5437b-…)
10:07:04 ath10k_snoc 18800000.wifi: failed to start WMI vdev 0: -108
10:07:10 ath10k_snoc 18800000.wifi: device successfully recovered
10:07:13 ath10k_snoc 18800000.wifi: failed to install key for vdev 0 peer …: -110
10:07:16 wlan0: authenticate with 22:4f:7a:xx:xx:xx
10:07:50 wlan0: disconnect from AP 22:4f:7a:xx:xx:xx for new auth to 82:89:07:xx:xx:xx
10:07:53 ath10k_snoc 18800000.wifi: failed to install key for vdev 0 peer …: -110
```

关键点：

- `AP changed bandwidth in beacon` 与 `firmware crashed!` 在同一秒，触发点是射频参数变化。
- 崩溃后 `-108 (ESHUTDOWN)` 和 `-110 (ETIMEDOUT)` 是后果，不是原因。
- WCN3990 固件运行在 modem 子系统上，崩溃会连带复位：

```text
qcom-q6v5-mss 4080000.remoteproc: port failed halt
ipa 1e40000.ipa: received modem offline event
remoteproc3: stopped remote processor 4080000.remoteproc
```

- `fw_reset_stats` 中 `fw_crash_counter = 1`，与上述日志对应。
- 扫描显示同一 SSID 下存在三个 2.4G 节点（信道 1/6/11），设备在两个 BSSID 之间反复
  切换；每次切换都要重新安装密钥，正是崩溃路径。
- 开机日志出现 `ath10k: invalid MAC address; choosing random`，`permaddr` 是本地管理
  地址，说明驱动未读到真实 MAC，每次开机可能生成不同地址。这与崩溃无直接关系，但会
  让路由器把设备当作新客户端，增加一次完整认证流程。

## 排除项

| 候选原因 | 结论 |
| --- | --- |
| 过热 | 崩溃前最高 38.3 °C，排除 |
| OOM / 内存压力 | 内存 39.7%，swap 仅 4 MB，内核无 OOM 记录，排除 |
| 高负载 | load 0.17，CPU 3%，排除 |
| 断电 / 电池 | 电量 90%，排除 |
| 指纹模块硬件 | 本内核无指纹驱动，无 SPI 控制器，设备树无指纹节点，指纹未参与，排除 |

## 根因

WCN3990 是高通 WiFi/蓝牙二合一芯片，固件（`wlanmdsp.mbn`）加载到 SDM845 的 modem
子系统执行。当前固件为 `WLAN.HL.2.0-01387`，构建时间 2019-09-10，高通已停止更新。

在“断开旧 AP → 扫描 → 关联新 AP → 安装密钥 → 按新 AP 参数重配射频”这条路径上，
固件存在缺陷：AP 改变带宽或设备漫游时，固件崩溃并连带 modem 子系统复位。若恢复过程
失败，内核挂死，最终由硬件层复位进入 CrashDump Mode。

因此更换 WiFi 环境、跨节点漫游是主要触发场景，与信道数量本身无关。

## 已验证的缓解

设备侧已执行：

```bash
# 全局默认关闭 WiFi 省电
sudo cp /etc/NetworkManager/conf.d/default-wifi-powersave-on.conf{,.bak-20261121}
printf '[connection]\nwifi.powersave = 2\n' \
  | sudo tee /etc/NetworkManager/conf.d/default-wifi-powersave-on.conf

# 当前连接同样关闭
sudo nmcli connection modify "<ssid>" wifi.powersave 2
sudo iw dev wlan0 set power_save off
```

建议的现场做法：

- 优先连接 5G 独立 SSID，前提是信号不低于 -70 dBm 且该 SSID 只有一个 BSSID。
- 路由器关闭自动信道与自动带宽，固定信道和 20/40 MHz 带宽，减少 beacon 参数变化。
- 减少同一 SSID 的节点数量，或关闭 mesh 自动漫游。
- 换环境后若反复重连，先执行 `nmcli radio wifi off && sleep 5 && nmcli radio wifi on`，
  让固件干净重启，而不是在旧状态下边走边切。

## 不可行方案

**升级固件**：对比 Ubuntu `linux-firmware-qualcomm-wireless` 20260319 包，
`wlanmdsp.mbn` 与本机 `md5` 完全一致（`259b4f9e…`），`firmware-5.bin` 亦相同；
`board-2.bin` 虽有差异，但一加 6 使用的
`qmi-board-id=ff, chip-id=30214, variant=oneplus_sdm845mmm` 条目两版都存在，无实际收益。

**看门狗自动恢复**：实测设置 15 秒超时后停止喂狗，设备按时复位，但 bootloader 停在
CrashDump Mode，6 分钟内无法通过网络访问，最终仍需人工按电源。该平台的 bootloader
对异常复位一律进入 CrashDump，因此 `RuntimeWatchdogSec` 与 `kernel.panic` 都无法实现
无人值守自愈。另需注意本内核未启用 `CONFIG_WATCHDOG_SYSFS`，systemd 无法接管看门狗。

**升级内核**：`sdm845-mainline/linux` 的锁定提交已等于上游 HEAD
（`85f1df2a…`，`sdm845-7.1-rc1-r0`），暂无更新可换。即使升级，也无法改变固件缺陷，
最多尝试驱动侧恢复逻辑的改进。

## 后续方向

- 观察关闭省电后的 `fw_crash_counter` 增长频率，评估缓解效果。
- 长期方案是外接 USB 网卡走有线，绕开 WCN3990。
- 若上游内核对 ath10k 的恢复流程有修复，再评估重建 boot 验证。
