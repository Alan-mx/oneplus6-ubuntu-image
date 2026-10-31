# 从零构建与升级流程：需求澄清

日期：2026-10-31

## 已明确的目标

补齐 oneplus6-image 的构建流程，使其他使用者能够获取公开源码，在自己的电脑上通过 Docker 构建 OnePlus 6 的 boot、Ubuntu 基础 rootfs、Orbital 桌面 rootfs 及分段刷机 ZIP，并能修改配置、软件和桌面后重新打包。

设备范围沿用 OnePlus 6 enchilada，不因本次构建工作扩大到 OnePlus 6T 或其他手机。当前运行策略沿用已有配置：密码登录、初始密码 orbital/123456、不开启磁盘加密、蓝牙暂不恢复。

用户已明确要求补齐四项缺口：本地构建输入、Orbital 适配源码、从零构建验证、升级流程。当前任务未授权 commit、push、发布 Release 或刷写手机；本地实现与非破坏性验证可以继续，提交前另行询问。

## 已核对的现状

| 位置 | 证据 | 当前缺口 |
|---|---|---|
| scripts/build.sh: validate_config | 构建前要求 inputs/boot/oneplus6-boot-gpu-fix.img 和三个辅助程序存在且哈希匹配 | 空 inputs 无法开始完整构建 |
| scripts/build.sh: fetch_inputs | 能下载 Ubuntu base 和 APK；APKINDEX 的哈希也锁定 | 动态索引变动后不能假设原哈希仍可下载，需要可获取的固定输入与失败提示 |
| scripts/build.sh: chroot_run | 使用 proot 与 qemu-aarch64 | README 已披露 systemd 安装阶段的 proot assertion；不能把已有 V14 rootfs 当作从零验证 |
| scripts/build.sh: build_boot_image | 从本地 boot 覆盖输入提取内核并重打 ramdisk | 已有内核补丁没有自动从固定源码构建并接入完整流程 |
| kernel-patches/ | 已有 DSI 时钟、面板背光和 fbcon logo 三个补丁 | 需核对内核源码、配置、模块和 DTB 的一致性，不能只重打 boot |
| inputs/*/README.md | 三个辅助程序记录了源代码提交与构建环境；共享 qrtr v1.2 提交 | 这些 README 和程序在被忽略的 inputs 中，自动构建路径缺失 |
| ../Orbital | master 为 2e06f8b；13 个已跟踪文件有本地修改；另有 device-profile.sh 和测试未跟踪 | 远端提交不能代表当前适配代码；需要明确固定的源码与修改来源 |
| Dockerfile、config/*lock* | Docker 基础镜像摘要、直接包版本、最终包清单已锁定 | 版本锁不是永久可下载的存档，也不能替代首次完整构建 |
| build.ps1 | 工作路径固定为 /workspace/oneplus6-image，并复用 oneplus6-image-work 卷 | 干净验证需独立目录与卷，防止误用本机旧输入或改变现有工作产物 |
| 本机 Docker | 只读检查可访问 Docker Server 29.1.3 | 具备本地 Docker 验证入口，尚未代表干净构建通过 |

辅助程序已有源码记录：

- qrtr：b51ffaf22707b6000ecfb894c5b750f3bb7843b2。
- tqftpserv：b31de6db4f31d09119293203d39636b827f16321。
- pd-mapper：5ecd2fe926aca7abfe40724177f63b942cff3947。
- rmtfs：b30a3eb38f9af283f18dbd3c7755653efc52c094。

以上来源是本机已有记录，后续实现前仍须核验上游仓库和许可证。

## 需要确认的两项口径

| 编号 | 问题 | 建议默认答案 | 对工作的影响 |
|---|---|---|---|
| Q1 | 首批支持哪些构建主机？ | Windows x64 + Docker Desktop 为本机实测入口，同时提供 Linux x86_64 + Docker 的入口与前置检查；其他平台单独标注未验证 | 决定启动脚本、权限与文档范围；不能承诺没有实际测试的平台已验证 |
| Q2 | 可复现的验收标准是什么？ | 锁定源码、补丁和依赖，空缓存从零生成相同配置与功能的镜像，并记录每次产物哈希；暂不要求与历史 V15 的文件哈希完全相同 | 逐字节一致还需固定构建时间、文件系统 UUID、随机量及工具行为；历史 V15 来源也不是干净构建 |

用户于 2026-10-31 确认采用 Q1、Q2 的建议默认答案。

## 后续流程与验证边界

Q1、Q2 确认后产出带编号验收标准的规格，再按数据结构与入口设计推进实现。实施中先追溯输入来源与许可，再打通从零路径，最后做独立目录、独立 Docker 卷、无本地 inputs 的完整验证。

构建验证与真机验收分别记录。Docker 构建成功不等于手机启动、WiFi、背光、触摸、SSH 等均已真机通过；需要刷机时先准备可检查的产物和验证命令，再请用户执行。

## 用户回答

- Q1：确认默认答案。Windows x64 + Docker Desktop 为本机实测目标；Linux x86_64 提供入口但不宣称已验证。
- Q2：确认默认答案。要求锁定源码、补丁和依赖，干净环境产出功能一致的镜像并记录哈希；不要求逐字节复刻 V15。
