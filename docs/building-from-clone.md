# 从源码构建、修改与升级

本文描述在 Windows x64 上从两个 Git 仓库开始，使用 Docker 生成 OnePlus 6
镜像、修改 Orbital 桌面并验证升级的流程。Linux x86_64 入口尚未完成同等级的
实机验证。

## 环境要求

- Windows 10/11 x64、Docker Desktop（Linux containers）和 PowerShell 7
- Git，以及足够存放源码、Docker 镜像、构建缓存和输出文件的磁盘空间
- 可访问 Ubuntu 软件源、postmarketOS 软件源及锁定源码仓库的网络

源码分成两个仓库，必须放在同一个父目录下：

```powershell
cd D:\workspace
git clone https://github.com/Alan-mx/oneplus6-image.git
git clone https://github.com/Alan-mx/Orbital.git
```

构建脚本默认查找 `..\Orbital`，也可以通过 `-OrbitalSourcePath` 指定其它位置。
仓库内已包含四个实机验证过的预编译输入：`oneplus6-boot-gpu-fix.img`、
`tqftpserv`、`pd-mapper` 和 `rmtfs`；构建前会校验它们在 `config/build.env`
中的 SHA-256。

## 锁定源码版本

镜像仓库的 `config/source-revisions.lock.tsv` 是唯一版本来源。首次构建前，让
Orbital 的 `HEAD` 与锁文件一致：

```powershell
cd D:\workspace\oneplus6-image
$row = Get-Content .\config\source-revisions.lock.tsv |
  Where-Object { $_ -match '^orbital\t' }
$orbitalCommit = ($row -split "`t")[2]
git -C ..\Orbital checkout $orbitalCommit
```

不要用未锁定的默认分支内容替代该提交。普通开发构建允许 Orbital 工作树带有
未提交修改；构建器会复制 tracked 和未忽略的 untracked 文件，并在 manifest
记录提交、dirty 标记和内容摘要。Git ignored 文件不会进入快照。

带有 dirty 源码的构建会标记 `publicly_reproducible=false`。它适合本机开发和
测试，但不能作为“公开源码可复现”的发布声明。公开发布必须先把 Orbital 修改
提交并推送，再更新镜像仓库的源码锁。

## 初始密码

当前分享版使用固定初始密码 `123456`，首次登录后应通过 `passwd` 修改。构建器
通过被 Git 忽略的本地文件读取密码：

```powershell
Set-Content -LiteralPath .\state\orbital-password.txt -Value '123456' -NoNewline
```

不要把该文件添加到 Git，也不要在日志或 issue 中粘贴真实密码。

## 构建全部产物

先做只读环境检查：

```powershell
pwsh -File .\build.ps1 -CheckEnvironment
```

再执行隔离的完整构建：

```powershell
pwsh -File .\build.ps1 `
  -Fresh `
  -SshPasswordFile .\state\orbital-password.txt
```

`-Fresh` 会为本次运行建立独立的 Docker volume、源码下载、prepared input、
state 和 `out/build-<run-id>` 输出目录，不会清空已有 `inputs`、`work`、`state`、
`out` 或旧 volume。默认快速组装会从锁定的 postmarketOS APK 提取内核、模块和
DTB，并复用 `inputs/tqftpserv`、`inputs/pd-mapper`、`inputs/rmtfs` 和
`inputs/boot/oneplus6-boot-gpu-fix.img`；不会编译内核或 helper。

构建完成后会自动运行 `verify-build.ps1`，检查锁定文件、ARM64 包集合、boot
参数、rootfs sparse 几何、分卷覆盖、ZIP 条目和全部 SHA-256。可以再次验证：

```powershell
pwsh -File .\verify-build.ps1 `
  -BuildRoot . `
  -OutputDirectory .\out\build-<run-id>
```

主要产物包括 Ubuntu 基础镜像、Orbital 镜像、`oneplus6-boot.img`、分卷目录、
分卷刷机 ZIP、`build-manifest.json` 和 `SHA256SUMS.txt`。Docker 验证不等于
OnePlus 6 实机验证，发布前仍应检查启动、显示、触摸、Wi-Fi、USB 网络、电池和
关机行为。

## 修改 Orbital

在 `D:\workspace\Orbital` 中完成修改、构建和本机测试后，再走发布流程：

```powershell
cd D:\workspace\Orbital
git status
git add <修改的源码文件>
git commit
git push
cd D:\workspace\oneplus6-image
```

更新锁文件必须显式提供完整 40 位提交 SHA 和版本标签：

```powershell
pwsh -File .\upgrade.ps1 -Apply orbital `
  -Commit <40-位提交SHA> `
  -Version <版本标签> `
  -SshPasswordFile .\state\orbital-password.txt
```

`upgrade.ps1` 会先确认 Orbital 工作树 `HEAD`、锁文件状态，再执行完整隔离构建
和产物验证。构建失败时不会把候选版本视为已验证；应保留输出、日志和 volume
定位问题。

## 查看上游更新

只读检查各锁定仓库的远端 `HEAD` 与本地锁文件摘要：

```powershell
pwsh -File .\upgrade.ps1 -Check
```

远端 `HEAD` 变化只是复核信号，不是自动升级建议。内核、Ubuntu、APK、Docker
builder 或 Orbital 版本变化都必须经过源码审查、锁文件更新、完整构建和实机
测试。包版本不能只改一个数字，因为依赖解析会改变完整 ARM64 包集合。

## 排查构建失败

失败时先保留脚本打印的 run id、输出目录和 Docker volume。常见位置：

- `out/build-<run-id>`：成功产物；失败时也可能是空的隔离输出目录
- `state/<run-id>`：构建状态和验证 JSON
- `logs/<run-id>`：构建日志
- `inputs/prepared/<run-id>`：源码锁和预编译 Qualcomm helper 快照
- `docker logs oneplus6-image-build-<run-id>`：rootfs 和镜像封装日志

不要通过删除旧 volume、改写已锁版本或跳过校验来解决失败。先根据容器日志修复
脚本，再用新的 `-Fresh` run id 重新构建。
