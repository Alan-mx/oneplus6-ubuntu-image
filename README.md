# 一加 6 Ubuntu 26.04 Orbital 镜像

面向 OnePlus 6（`enchilada`）的 Ubuntu 26.04.1 ARM64 镜像项目。系统使用
postmarketOS 社区维护的 SDM845 内核，并可运行基于 Qt6 的 Orbital 桌面。

仓库同时提供可直接刷入的发布包、可复现的 Docker 快速构建流程，以及开发过程中
整理的故障排查和版本锁定记录。

> 仅适用于 OnePlus 6 `enchilada`，不适用于 OnePlus 6T `fajita`。

## 发布版本

当前公开版本为 **OnePlus 6 Ubuntu 26.04 Orbital**，GitHub Release 标签为 `v1`：

<https://github.com/Alan-mx/oneplus6-image/releases/tag/v1>

主要特性：

- Ubuntu 26.04.1 ARM64
- Linux `7.1.0-rc1-sdm845`
- Ubuntu 基础镜像和带 Orbital 桌面的完整镜像
- 首次启动自动把 rootfs 扩展到 `userdata` 分区
- USB 网络固定地址 `172.16.42.1`
- SSH 用户 `orbital`，初始密码 `123456`
- 禁止 root SSH，`orbital` 用户拥有免密 sudo
- 首次登录提示修改密码，并启用密码复杂度检查
- 仅自动安装安全更新

初始密码只适合私下分发。接入 WiFi、Tailscale 或其他网络前，应先登录并执行：

```bash
passwd
```

## 刷机

普通用户只需要下载：

```text
oneplus6-v1-segmented-flash.zip
```

Release 中还单独提供正常 boot、救援调试 boot、构建清单和 SHA-256 校验文件。

刷机步骤：

1. 解压 ZIP。
2. 手机进入 fastboot，连接电脑。
3. 确认 `fastboot devices` 能看到设备。
4. 在解压目录运行：

```powershell
pwsh -ExecutionPolicy Bypass -File .\flash.ps1
```

5. 按提示输入 `ERASE USERDATA`。

脚本会检查设备、boot 哈希、分卷范围、分卷大小和 SHA-256，然后按顺序刷入。
不要在分卷之间再次擦除 `userdata`。

首次启动会自动扩展根文件系统，可能需要等待一段时间，期间不要强制断电。

## 发布文件

| 文件 | 用途 |
| --- | --- |
| `oneplus6-v1-segmented-flash.zip` | 推荐刷机包，包含 boot、10 个 rootfs 分卷和刷机脚本 |
| `oneplus6-v1-boot.img` | 正常启动 boot，ZIP 中已包含，单独提供用于仅修复 boot |
| `oneplus6-v1-boot-rescue-debug.img` | 救援调试 boot，通过 USB RNDIS 提供诊断日志 |
| `oneplus6-v1-build-manifest.json` | 构建来源、包锁、验证结果和产物哈希 |
| `oneplus6-v1-SHA256SUMS.txt` | Release 资产 SHA-256 校验清单 |

救援调试 boot 启动后，诊断日志位于：

```text
http://172.16.42.1/diag.txt
```

救援 boot 只用于排障，不可作为日常启动镜像。

## 从源码构建

默认构建是快速组装流程：

- 从锁定的 postmarketOS APK 提取内核、模块和设备树
- 使用仓库中带 SHA-256 锁的预编译 boot 和 Qualcomm helper
- 编译 Orbital 桌面
- 生成 Ubuntu 基础镜像、Orbital 镜像和分段刷机包

不会编译内核或 Qualcomm helper。

### 环境

- Windows 10/11 x64
- Docker Desktop，使用 Linux containers
- PowerShell 7
- Git

当前主要验证平台是 Windows x64 + Docker Desktop。Linux x86_64 提供相同入口，
但尚未完成同等级的实机验证。

### 获取源码

两个仓库需要放在同一个父目录：

```powershell
git clone https://github.com/Alan-mx/oneplus6-image.git
git clone https://github.com/Alan-mx/Orbital.git
```

`oneplus6-image` 的 `config/source-revisions.lock.tsv` 固定了 Orbital 提交。
构建器会拒绝版本不匹配的 Orbital 工作树。

### 构建

```powershell
Set-Content -LiteralPath .\state\orbital-password.txt -Value '123456' -NoNewline
pwsh -File .\build.ps1 -CheckEnvironment
pwsh -File .\build.ps1 -Fresh -ReleaseBuild `
  -SshPasswordFile .\state\orbital-password.txt
```

`state/orbital-password.txt` 已被 Git 忽略。`-ReleaseBuild` 要求两个仓库都没有
未提交修改，构建成功后 manifest 会标记为公开可复现。

本地开发时去掉 `-ReleaseBuild`，允许记录 dirty 的 Orbital 工作树，但该构建不会
被标记为公开可复现。

默认输出位于：

```text
out/build-<run-id>/
```

构建结束后会自动运行 `verify-build.ps1`。也可以手动复验：

```powershell
pwsh -File .\verify-build.ps1 `
  -BuildRoot . `
  -OutputDirectory .\out\build-<run-id>
```

## 仓库结构

```text
config/      镜像参数、包锁、源码锁、systemd 和网络配置
inputs/      快速构建使用的预编译 boot 和 Qualcomm helper
scripts/     构建、打包、刷机、验证和测试脚本
docs/        使用说明、构建指南、故障记录和设计文档
build.ps1    Windows 完整构建入口
upgrade.ps1  上游版本检查和显式升级入口
verify-build.ps1  构建产物验证入口
```

`out/`、`work/`、`state/`、`logs/` 和本地密码文件不会进入 Git。

## 文档

- [文档导航](docs/README.md)
- [从克隆到构建、修改和升级](docs/building-from-clone.md)
- [升级构建输入](docs/upgrading-build-inputs.md)
- [版本与输入锁定规则](docs/release-locking.md)
- [故障排查与修复记录](docs/oneplus6-image-troubleshooting.md)

## 已知限制

- 仅支持 OnePlus 6 `enchilada`。
- 当前签名、刷写和实机验证主要针对 Windows fastboot 环境。
- 蓝牙控制器初始化问题尚未解决，正式镜像默认不启动蓝牙服务。
- PMIC RTC 在当前内核下不能可靠写回时间，联网后由 Chrony 校时。
- 单文件稀疏 rootfs 曾有 fastboot 写入损坏记录，发布刷机应使用分段 ZIP。

## 许可

本仓库原创代码使用 MIT 许可证。生成镜像中包含的第三方软件继续遵循各自许可证，
详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
