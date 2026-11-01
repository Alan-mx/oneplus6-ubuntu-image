# Windows 驱动、Bootloader 解锁与刷机

本文适用于 OnePlus 6 `enchilada`。本项目的镜像不能用于 OnePlus 6T
`fajita`，但零售版 6T 的开发者选项、解锁和 fastboot 流程基本相似。T-Mobile
等运营商定制版 6T 可能禁止直接执行 OEM 解锁，必须先完成运营商规定的网络锁
解除和官方解锁流程；不要把下文命令当作运营商版的绕过方法。

## 下载地址

- [Android SDK Platform-Tools 官方下载](https://developer.android.google.cn/tools/releases/platform-tools?hl=zh-cn)
- [Google USB Driver 官方下载](https://developer.android.google.cn/studio/run/win-usb?hl=zh-cn)
- [本项目 Release](https://github.com/Alan-mx/oneplus6-ubuntu-image/releases/tag/v1)
- [参考：Fastboot 驱动安装记录](https://www.cnblogs.com/beidaxmf/p/17898827.html)

platform-tools 只包含 `adb`、`fastboot` 等工具，不包含 Google USB Driver。
fastboot 在设备管理器中显示为未知设备时，需要另外安装 fastboot 驱动。

建议解压 platform-tools 后，在解压目录打开 PowerShell，确认工具可用：

```powershell
.\adb.exe version
.\fastboot.exe --version
```

下面命令中的 `fastboot` 假设 platform-tools 已经加入 `PATH`。如果没有加入，
请把命令改成 `.\fastboot.exe`，并在刷机脚本中显式传入 fastboot 的完整路径：

```powershell
pwsh -File .\flash.ps1 `
  -Fastboot C:\path\to\platform-tools\fastboot.exe
```

## 安装 Fastboot 驱动

### 1. 检查 fastboot 连接

手机进入 bootloader/fastboot 后连接电脑，运行：

```powershell
fastboot devices
```

正常时应看到类似：

```text
5789f942        fastboot
```

如果持续显示 `waiting for any device` 或列表为空，先检查 USB 线、USB 端口和
设备管理器。

### 2. 在设备管理器中安装驱动

1. 按 `Win + X`，打开“设备管理器”。
2. 展开“其他设备”或“Android Device”。
3. 找到带黄色感叹号的手机设备，右键选择“更新驱动程序”。
4. 选择“浏览我的电脑以查找驱动程序”。
5. 选择“让我从计算机上的可用驱动程序列表中选取”。
6. 如果列表中有 `Android Bootloader Interface`，选择它并安装。
7. 如果没有，点击“从磁盘安装”，选择 Google USB Driver 解压目录中的
   `android_winusb.inf`，然后选择 `Android Bootloader Interface`。

安装完成后重新运行：

```powershell
fastboot devices
```

仍然不识别时，可以尝试：

- 更换 USB 数据线，避免只能充电的线。
- 使用主板后置 USB 接口。
- 关闭其他正在占用设备的 adb/fastboot 程序。
- 重新进入 bootloader。
- 确认设备管理器中没有新的未知设备。

也可以先列出 Windows 当前识别到的相关设备：

```powershell
Get-PnpDevice -PresentOnly |
  Where-Object { $_.FriendlyName -match 'Android|Bootloader|Fastboot' } |
  Format-Table Status, Class, FriendlyName, InstanceId -AutoSize
```

设备状态应为 `OK`。如果仍显示 `Error` 或带有黄色感叹号，说明驱动尚未正确绑定。

## 启动后的 RNDIS 驱动

正式系统启动后，USB 网络会使用 RNDIS。手机端固定地址为：

```text
172.16.42.1
```

Windows 通常会自动安装 RNDIS 驱动。如果设备管理器出现带黄色感叹号的
`Remote NDIS based Internet Sharing Device`，或者网络适配器中没有对应设备，
可手动指定 Microsoft 自带驱动。

### 手动安装 RNDIS

1. 按 `Win + X`，选择“设备管理器”。
2. 展开“网络适配器”或“其他设备”。
3. 找到名称包含 `Remote NDIS`、`RNDIS` 或 `Internet Sharing` 的设备。
4. 右键选择“更新驱动程序”。
5. 选择“浏览我的电脑以查找驱动程序”。
6. 选择“让我从计算机上的可用驱动程序列表中选取”。
7. 在列表中选择 `Microsoft Remote NDIS Compatible Device`，点击“下一步”。
8. 安装完成后，重新拔插 USB。

如果列表中没有 `Microsoft Remote NDIS Compatible Device`：

1. 点击“从磁盘安装”。
2. 在下面两个位置查找 `rndiscmp.inf` 或 `rndismp.inf`：

   ```text
   C:\Windows\System32\DriverStore\FileRepository\rndiscmp.inf_*
   C:\Windows\System32\DriverStore\FileRepository\rndismp.inf_*
   C:\Windows\INF\rndiscmp.inf
   C:\Windows\INF\rndismp.inf
   ```

   `*` 表示随 Windows 版本变化的目录后缀。Windows 10/11 常见文件名是
   `rndiscmp.inf`；旧版 Windows 或部分参考资料使用 `rndismp.inf`。

3. 选择实际存在的 INF 文件。
4. 返回驱动列表，选择 `Microsoft Remote NDIS Compatible Device` 并安装。

注意不要把 RNDIS 强制安装成 Google ADB/Fastboot 驱动，它是网络适配器驱动。

### 检查 USB 网络

安装完成后运行：

```powershell
Get-NetAdapter
ipconfig /all
Test-NetConnection 172.16.42.1 -Port 22
```

正常情况下 Windows 会通过 DHCP 获得 `172.16.42.x` 地址。

设备管理器中对应的网络适配器应显示类似：

```text
Remote NDIS Compatible Device
```

状态不能是黄色感叹号、代码 28 或“该设备的驱动程序未被安装”。

如果适配器存在但地址是 `169.254.x.x`，可以临时设置静态地址：

```text
IP 地址：172.16.42.2
子网掩码：255.255.255.0
默认网关：留空
```

然后测试：

```powershell
ping 172.16.42.1
ssh orbital@172.16.42.1
```

重新刷入 rootfs 后，SSH host key 会重新生成。确认是自己刚刷写的设备后，可以执行：

```powershell
ssh-keygen -R 172.16.42.1
```

## 解锁 Bootloader

解锁会清空手机数据，包括照片、应用数据和内部存储。先备份，并确保电量充足。

### 1. 启用开发者选项

1. 打开“设置” → “关于手机”。
2. 连续点击“版本号”约 7 次，直到提示已进入开发者模式。
3. 返回“设置” → “系统” → “开发者选项”。
4. 打开“OEM 解锁”。
5. 如果系统提供“高级重启”，一并打开。

不同 OxygenOS 版本的菜单名称可能略有差异。

### 2. 进入 bootloader

优先使用系统菜单或 adb：

```powershell
adb devices
adb reboot bootloader
```

也可以在启用“高级重启”后，长按电源键，选择“重启” → “引导加载器”。

手机完全关机时，常见按键方式为：

```text
按住音量加 + 电源键，出现一加标志后松开
```

如果该组合无法进入，可以尝试：

```text
按住音量加 + 音量减 + 电源键
```

进入后，手机屏幕通常会显示 `FASTBOOT MODE` 或 bootloader 菜单。

### 3. 执行解锁

确认电脑识别到设备：

```powershell
fastboot devices
fastboot getvar product
```

SDM845 平台通常显示：

```text
product: sdm845
```

`sdm845` 只能确认芯片平台，不能区分 OnePlus 6 和 OnePlus 6T。刷入本项目的
镜像前，必须根据手机外观、型号信息和开机界面确认它是 OnePlus 6
`enchilada`。

执行：

```powershell
fastboot oem unlock
```

部分系统或 bootloader 版本可能使用：

```powershell
fastboot flashing unlock
```

以设备屏幕实际提示为准。手机通常会要求使用音量键选择 `UNLOCK THE BOOTLOADER`
或类似选项，再按电源键确认。

解锁完成后手机会恢复出厂状态。重新开机、完成初始设置后，可在开发者选项中
确认 OEM 解锁状态已经改变。

运营商定制版 OnePlus 6T 如果无法打开“OEM 解锁”，或命令提示权限不足，应停止
操作并先完成运营商官方解锁流程。不要尝试来路不明的解锁工具或绕过脚本。

## 刷入 Ubuntu 镜像

1. 下载 `oneplus6-v1-segmented-flash.zip`。
2. 解压完整 ZIP。
3. 手机进入 fastboot，连接电脑。
4. 在解压目录打开 PowerShell。
5. 先只验证本地刷机包：

   ```powershell
   .\flash.ps1 -ValidateOnly
   ```

6. 刷入系统：

   ```powershell
   pwsh -File .\flash.ps1 `
     -Fastboot C:\path\to\platform-tools\fastboot.exe
   ```

7. 按提示输入：

   ```text
   ERASE USERDATA
   ```

脚本会验证 boot、分卷覆盖范围、文件大小和 SHA-256，然后按顺序刷入。
不要使用单个 `oneplus6-rootfs-orbital.img` 代替分段包。

刷写完成后手机会自动重启。首次启动会扩展 rootfs 到整个 `userdata` 分区，
可能需要等待一段时间，期间不要强制断电。

## 常见问题

### `fastboot waiting for any device`

通常是 Windows 没有正确绑定 `Android Bootloader Interface`。按本文重新安装
fastboot 驱动，并确认 `fastboot devices` 能看到设备。

### RNDIS 显示黄色感叹号或代码 28

按本文手动选择 `Microsoft Remote NDIS Compatible Device`。不要安装成 ADB 驱动。

### 能 ping 通但不能 SSH

确认使用的是 `orbital@172.16.42.1`，初始密码为 `123456`。如果刚重新刷写，
先执行 `ssh-keygen -R 172.16.42.1` 清理旧 host key。

### 首次启动一直停在启动阶段

先确认刷入的是分段 ZIP，而不是单文件 sparse rootfs。再通过救援调试 boot
读取诊断日志：

```text
http://172.16.42.1/diag.txt
```

救援调试 boot 只用于排障，不能作为日常启动镜像。
