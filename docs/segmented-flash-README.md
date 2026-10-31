# 一加 6 分段刷机包

本刷机包适用于 OnePlus 6（`enchilada`，fastboot product 为 `sdm845`）。
压缩包包含 boot 镜像、按 Android sparse 格式分段的 Orbital Ubuntu rootfs、
校验元数据和 PowerShell 刷机脚本。

刷机会清空手机的全部 `userdata` 分区。继续操作前请备份需要保留的数据。
解锁和刷机由使用者自行承担责任。

在 Windows 上解压完整 ZIP，在解压目录打开 PowerShell，然后运行：

```powershell
pwsh -File .\flash.ps1 -Fastboot C:\path\to\platform-tools\fastboot.exe
```

脚本会在调用 fastboot 前验证全部本地文件，确认只连接了一台 `sdm845` 设备，
并在写入前要求输入 `ERASE USERDATA` 确认。

如果只想检查刷机包、不连接手机，可以运行：

```powershell
pwsh -File .\flash.ps1 -ValidateOnly
```

刷机包由当前构建生成，不依赖历史 boot 镜像哈希。`release.json` 记录 boot 和
分段 manifest 的哈希。
