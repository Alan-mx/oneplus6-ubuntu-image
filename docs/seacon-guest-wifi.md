# OnePlus 6 连接 SEACON GUEST

## 当前状态

2026-10-30 已在 OnePlus 6 上实测：

- WiFi 密码：由用户本地提供，不写入仓库
- 连接方式：WPA-PSK + TKIP
- 连接状态：成功
- 获取地址：`192.168.130.246/24`
- 网关：`192.168.130.1`
- DNS：`223.5.5.5`
- 外网 Ping：正常
- HTTPS 请求：返回 `200`

## 重新刷写 rootfs 后的连接命令

重新刷写 `oneplus6-rootfs-orbital.img` 后，WiFi 配置会丢失。通过 USB
网络登录手机：

```bash
ssh orbital@172.16.42.1
```

然后在手机终端执行：

```bash
sudo nmcli radio wifi on
sudo nmcli device wifi rescan
sleep 8

sudo nmcli connection delete id "SEACON GUEST" 2>/dev/null || true

sudo nmcli connection add \
  type wifi \
  con-name "SEACON GUEST" \
  ifname wlan0 \
  ssid "SEACON GUEST" \
  connection.autoconnect no

sudo nmcli connection modify "SEACON GUEST" \
  802-11-wireless-security.key-mgmt wpa-psk \
  802-11-wireless-security.psk "<WIFI_PASSWORD>" \
  802-11-wireless-security.proto wpa \
  802-11-wireless-security.pairwise tkip \
  802-11-wireless-security.group tkip \
  802-11-wireless-security.pmf disable \
  802-11-wireless-security.auth-alg open \
  connection.autoconnect yes

sudo nmcli connection up id "SEACON GUEST"
```

## 验证连接

```bash
nmcli -f DEVICE,TYPE,STATE,CONNECTION device status
nmcli -f GENERAL.STATE,GENERAL.CONNECTION,IP4.ADDRESS,IP4.GATEWAY,IP4.DNS device show wlan0
ip -4 addr show wlan0
ping -c 3 223.5.5.5
curl -4 -sS -o /dev/null \
  -w 'http_code=%{http_code} connect=%{time_connect}s total=%{time_total}s\n' \
  --connect-timeout 10 --max-time 20 https://connect.qq.com
```

连接成功时，设备状态应包含：

```text
wlan0  wifi  connected  SEACON GUEST
```

## 为什么需要单独配置

`SEACON GUEST` 同时广播 WPA1 和 WPA2。默认自动协商会在 WPA2 关联阶段失败，
日志中可以看到：

```text
reason=9
STA_REQ_ASSOC_WITHOUT_AUTH
```

关联超时后，NetworkManager 会要求重新输入密码。Orbital 调用的 `nmcli`
没有交互式认证代理，因此最终显示：

```text
Secrets were required, but not provided
```

这并不表示密码缺失。实测用户提供的密码是正确的，强制使用该 AP 同样支持的
WPA1/TKIP 后可以完成四次握手、DHCP 和外网访问。

## 不要使用默认连接命令

不要执行：

```bash
sudo nmcli device wifi connect "SEACON GUEST" password "<WIFI_PASSWORD>"
```

该命令会重新生成默认的 WPA2 配置，可能再次触发上述关联失败。如果误用了该
命令，重新执行“重新刷写 rootfs 后的连接命令”中的删除和创建步骤。

## 配置保存与安全说明

- 配置保存在 rootfs 的 NetworkManager 系统连接中。
- `connection.autoconnect=yes`，正常重启后会自动连接。
- 重新刷写 rootfs 或在 Orbital 中忘记该网络后，需要重新执行本文命令。
- 只重新刷写 `boot`、不刷写 `rootfs` 时，WiFi 配置不受影响。
- WPA1/TKIP 属于旧协议，安全性和速率上限低于 WPA2/CCMP，只用于兼容当前 AP。
- 如果 AP 修复了 WPA2 配置，应删除本配置并恢复使用 WPA2/CCMP。
