# 升级构建输入

构建系统会锁定精确的源码提交、二进制包哈希、已安装 Ubuntu 软件包版本和
Docker 构建器软件包版本。上游出现新版本只代表它可以成为候选，修改一个版本字段
并不等于完成了经过验证的升级。

## 源码版本

检查各上游默认分支当前的 HEAD，并输出本地锁文件摘要：

```powershell
pwsh -File .\upgrade.ps1 -Check
```

该检查只读。远端 `HEAD` 与本地不同只是需要复核的信号，不代表推荐升级；选择提交前
应查看上游发布说明、设备相关改动、许可证、构建要求和相关 issue。

选择一个经过审查的源码提交时，必须提供完整 40 位 SHA 和明确的版本标签：

```powershell
pwsh -File .\upgrade.ps1 `
  -Apply kernel `
  -Commit <full-commit-sha> `
  -Version <reviewed-version> `
  -SshPasswordFile .\state\orbital-password.txt
```

`-Apply` 会把目标提交获取到 `work/` 下唯一的忽略目录，只更新对应组件的源码锁行，
然后执行完整的 `-Fresh` 镜像构建和 `verify-build.ps1`。它不会提交、推送、创建
Release 或刷写手机。验证失败时，候选锁文件、隔离源码、日志、输出和 Docker volume
都会保留用于诊断；候选版本不能视为已接受的升级，理解失败原因前不要删除这些材料。

升级 `orbital` 时，如果 Orbital 不在 `../Orbital`，还需要传入
`-OrbitalSourcePath`。脚本不会重置或清理工作树；工作树 `HEAD` 必须已经等于目标
提交。未提交但未被 Git 忽略的改动仍会被记录，并使结果成为本地开发构建，不能声明
为公开可复现构建。

## 软件包锁

`upgrade.ps1 -Apply` 只更新 `config/source-revisions.lock.tsv` 中的对应行。
Ubuntu/APK 软件包锁和 Docker 构建器软件包锁必须单独审查，因为软件包依赖变化可能
改变完整的 ARM64 rootfs 和构建环境：

1. 查看上游软件包索引或发布信息，选择明确版本。
2. 在独立变更中更新版本/哈希锁和构建器锁。
3. 启用锁文件比较后构建 Docker 镜像；不能把 `EXPORT_PACKAGE_LOCK=1` 的跳过检查
   当作验收通过。
4. 执行完整隔离构建和 `verify-build.ps1`；接受候选版本前检查两份 ARM64 软件包
   TSV 和构建 manifest。

手机 rootfs 内配置的自动安全更新不能替代重新构建和验证锁定输入。内核、固件、
boot 镜像和软件包锁更新仍然是必须显式执行的维护工作。

## 验证边界

干净构建的验收入口是 Windows x64 + Docker Desktop。Docker 构建成功可以验证镜像
结构、锁文件匹配、来源记录、ZIP 内容和校验值，但不能替代一加 6 的启动、显示、
触摸、Wi-Fi、USB 网络、电池和电源测试。项目提供 Linux x86_64 构建入口，但尚未
在对应环境完成同等级验证。
