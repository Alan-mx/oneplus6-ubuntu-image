# 一加 6 发布锁定

## 版本

- 当前公开版本：OnePlus 6 Ubuntu 26.04 Orbital，标签 `v1`
- 内部硬件验证构建序列：V15
- 更早的可启动版本：`releases/v14/` 中的 V14
- V15 包含 524 个锁定软件包
- V14 包含 520 个锁定软件包
- V13 包含 506 个锁定软件包

## 锁定输入

- Docker 基础镜像：
  `ubuntu@sha256:0e73b71479e7bc5f006bca872e25c3cd680dc052a0116f90d63ae363537db0dd`
- Docker 直接安装包：版本固定在 `Dockerfile` 和 `Dockerfile.kernel` 中。
- Docker 最终解析包集合：固定在 `config/builder-packages.lock.tsv` 和
  `config/kernel-builder-packages.lock.tsv` 中。
- Ubuntu 基础 rootfs：URL 和 SHA-256 固定在 `config/build.env` 中。
- postmarketOS 与 Alpine APK 索引：SHA-256 固定在 `config/build.env` 中。
- postmarketOS 与 Alpine APK 文件：文件名和 SHA-256 固定在
  `config/apk-sha256.lock` 中。
- 内核、设备、固件和 ALSA 软件包版本：固定在 `config/build.env` 中。
- Boot 镜像和 Qualcomm helper：四个经过验证的快速构建输入存放在 `inputs/`，
  SHA-256 固定在 `config/build.env` 中。
- 最终 Ubuntu 软件包集合：每个包、版本和架构记录固定在
  `config/ubuntu-packages.lock.tsv` 中。
- 历史 V13 软件包集合：保留在 `state/ubuntu-packages-v13.lock.tsv` 中。
- Release 镜像哈希：记录在 `state/release-lock.json` 和 `out/SHA256SUMS.txt` 中。
- Sparse rootfs 镜像使用 Android SDK 的 `img2simg` 生成。
- 公开 Release 推荐使用经过验证的分段 ZIP，因为一加 6 的 fastboot 写入链路曾
  在单个大 sparse 镜像中损坏 raw 数据块。

如果解析后的 APK 集合、helper、boot 镜像或最终 Ubuntu 软件包集合与锁文件不一致，
构建会直接失败。这是有意设计：依赖漂移必须经过审查和测试，不能静默接受。

## 运行时 APT 源

构建过程使用清华 Ubuntu 镜像。写入手机的镜像在 `/etc/apt/sources.list` 中保留
可用的 Ubuntu 镜像地址，因此安全更新不会被冻结在构建时快照。

自动更新范围由 `config/99unattended-upgrades-orbital` 限制为安全更新源。
自动重启已关闭。

更新正在运行的 rootfs 不会修改 `out/` 中的 `.img` 文件。
重新刷入 rootfs 镜像会重置手机上的系统及其已安装软件包。

## 更新锁文件

1. 在一次性构建环境中应用并测试依赖变更。
2. 使用新的 rootfs 重启手机，执行运行时验收检查。
3. 导出经过验证的软件包集合：

   ```bash
   LC_ALL=C dpkg-query -W \
     -f='${Package}\t${Version}\t${Architecture}\n' \
     | LC_ALL=C sort
   ```

4. 只有 boot、SSH、WiFi、桌面、存储扩容和服务检查全部通过后，才能替换
   `config/ubuntu-packages.lock.tsv`。
5. 重新构建发布镜像并重新生成：

   ```text
   out/SHA256SUMS.txt
   state/release-lock.json
   state/verification.json
   state/e2fsck-release-v13.log
   state/ext4-release-v13.txt
   ```

绝不能为了让失败的构建通过而修改锁文件。
