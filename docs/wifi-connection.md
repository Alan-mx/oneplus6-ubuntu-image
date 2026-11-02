# OnePlus 6 WiFi 连接与兼容性排障

本文适用于 OnePlus 6（`enchilada`）上的 Ubuntu 26.04.1 + NetworkManager
环境。推荐通过 USB 网络登录后操作：

```bash
ssh orbital@172.16.42.1
```

Orbital 桌面也提供 WiFi 页面；遇到旧协议 AP、界面连接失败或需要批量排障时，
可以按本文使用 `nmcli` 直接配置。

> 文档中的 `<SSID>`、`<PASSWORD>` 均为占位符。不要把真实 SSID、WiFi 密码、
> NetworkManager keyfile 或 SSH 私钥提交到仓库。

## 常规 WiFi（WPA2/WPA3）

先确认无线设备已启用并完成扫描：

```bash
sudo nmcli radio wifi on
sudo nmcli device wifi rescan
nmcli -f DEVICE,TYPE,STATE,CONNECTION device status
nmcli -f SSID,SIGNAL,SECURITY device wifi list
```

连接常规 WPA2/WPA3 网络：

```bash
sudo nmcli device wifi connect "<SSID>" password "<PASSWORD>"
```

如果已经保存过该网络，直接启用配置：

```bash
sudo nmcli connection up id "<SSID>"
```

验证连接状态、地址、网关和 DNS：

```bash
nmcli -f DEVICE,TYPE,STATE,CONNECTION device status
nmcli -f GENERAL.STATE,GENERAL.CONNECTION,IP4.ADDRESS,IP4.GATEWAY,IP4.DNS \
  device show wlan0
ip -4 addr show wlan0
ip route
```

有默认路由后，测试网关、DNS 和 HTTPS：

```bash
GW=$(ip route | awk '/^default/ {print $3; exit}')
ping -c 3 "$GW"
ping -c 3 223.5.5.5
curl -4 -sS -o /dev/null \
  -w 'http_code=%{http_code} connect=%{time_connect}s total=%{time_total}s\n' \
  --connect-timeout 10 --max-time 20 https://connect.qq.com
```

## 兼容旧 AP：强制 WPA1/TKIP

部分 AP 同时广播 WPA1 和 WPA2。NetworkManager 默认按 WPA2 关联时可能失败，
日志中出现：

```text
reason=9
STA_REQ_ASSOC_WITHOUT_AUTH
```

随后可能提示重新输入密码，最终报：

```text
Secrets were required, but not provided
```

这不一定表示密码错误。若该 AP 确实支持 WPA1/TKIP，可以强制使用这套旧协议。
下面用变量避免密码直接出现在 shell 历史中：

```bash
SSID='<SSID>'
read -rsp 'WiFi password: ' PSK; echo

sudo nmcli connection delete id "$SSID" 2>/dev/null || true

sudo nmcli connection add \
  type wifi \
  con-name "$SSID" \
  ifname wlan0 \
  ssid "$SSID" \
  connection.autoconnect no

sudo nmcli connection modify "$SSID" \
  802-11-wireless-security.key-mgmt wpa-psk \
  802-11-wireless-security.psk "$PSK" \
  802-11-wireless-security.proto wpa \
  802-11-wireless-security.pairwise tkip \
  802-11-wireless-security.group tkip \
  802-11-wireless-security.pmf disable \
  802-11-wireless-security.auth-alg open \
  connection.autoconnect yes

sudo nmcli connection up id "$SSID"
```

连接成功时，设备状态应包含：

```text
wlan0  wifi  connected  <SSID>
```

WPA1/TKIP 属于旧协议，安全性和速率上限都低于 WPA2/CCMP。只在 AP 确实需要兼容
时使用；AP 修复为 WPA2/CCMP 后，应删除旧配置并重新按常规方式连接：

```bash
sudo nmcli connection delete id "<SSID>"
sudo nmcli device wifi connect "<SSID>" password "<PASSWORD>"
```

## 连接后校时

本镜像的 PMIC RTC 不能可靠写回时间，重启后可能回到接近 1970 年的时间。连上
WiFi 后应启用 Chrony：

```bash
sudo systemctl enable --now chrony
chronyc tracking
timedatectl
```

确认 `System clock synchronized: yes` 后，再执行 `apt`、HTTPS 请求或依赖证书
校验的操作。

## 常见问题

| 现象 | 检查 | 处理 |
| --- | --- | --- |
| 没有 `wlan0` | `nmcli dev status`、`rfkill list`、`sudo dmesg \| grep -Ei 'ath10k\|wlan0\|firmware'` | 确认无线未被 rfkill 禁用；冷启动后复查；参考 [故障排查与修复记录](oneplus6-image-troubleshooting.md) |
| 能扫描但连接失败 | `sudo journalctl -u NetworkManager -b --no-pager \| tail -100` | 若出现 `reason=9` / `STA_REQ_ASSOC_WITHOUT_AUTH`，按“兼容旧 AP”处理 |
| 连接后没有外网 | `ip route`、`resolvectl status`、`ping <网关>` | 先确认默认路由和 DNS；再检查是否需要门户认证或上游网络限制 |
| WiFi 地址变化 | `nmcli device show wlan0` | WiFi 地址由 DHCP 分配；远程管理优先使用 USB 固定地址 `172.16.42.1` |
| 重刷 rootfs 后配置丢失 | `nmcli connection show` | 重新执行本文连接步骤；只重刷 boot 不会丢失 WiFi 配置 |
| MAC 地址变化 | `sudo dmesg \| grep -i 'invalid MAC address'` | 镜像会尝试使用 persist 分区的 `wlan_mac.bin`；无效时可能回退到随机 MAC，属已知现象 |

## 配置持久化与安全

- `connection.autoconnect=yes` 会让已保存网络在开机后自动连接。
- NetworkManager 的系统连接配置通常位于 `/etc/NetworkManager/system-connections/`，
  仅 root 可读；不要把这些 keyfile 提交到 Git。
- `orbital` 用户拥有免密 sudo，任何能登录 SSH 的人实际上都等同于 root。接入
  不可信 WiFi 前，应先修改初始密码，最好改用 SSH 公钥并关闭密码登录。
- 本仓库是公开仓库，文档和示例中不要写入真实 SSID、密码、私钥或设备序列号。

## 实测兼容案例

2026-10-30 在 OnePlus 6 + Ubuntu 26.04.1 上验证过以下兼容场景：

- AP：`SEACON GUEST`，同时广播 WPA1/WPA2。
- 处理：按“兼容旧 AP”强制 WPA-PSK + TKIP 后连接成功。
- 获取地址：`192.168.130.246/24`，网关 `192.168.130.1`，DNS `223.5.5.5`。
- 外网 Ping 和 HTTPS 请求均正常。

该案例只用于说明混合协议 AP 的排障路径，不应把 SSID、密码或 DHCP 地址写成
默认配置。
