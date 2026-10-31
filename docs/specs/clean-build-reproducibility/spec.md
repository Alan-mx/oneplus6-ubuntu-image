# 从零构建与升级流程：规格

需求名：clean-build-reproducibility ｜ 日期：2026-10-31 ｜ 状态：已确认

用户于 2026-10-31 确认本规格。后续数据结构与接口设计分别确认。

## 背景与目标

当前 V15 成品可刷，但全新克隆缺少本机 inputs，Orbital 适配尚未形成可固定版本的源码输入，rootfs 首次安装仍可能遇到 proot assertion，且版本升级步骤没有完整的可重复流程。

目标是让使用者在 Windows x64 + Docker Desktop 上从空克隆构建 OnePlus 6 的三种镜像和分段刷机 ZIP，并能在明确锁定、审核和验证之后升级依赖。Linux x86_64 提供构建入口，但本轮不承诺实测。复现目标是锁定输入后生成相同配置与功能的产物并记录哈希，不承诺不同构建之间字节完全相同。

## 用户故事

作为 OnePlus 6 镜像维护者或使用者，我希望在干净克隆中通过有文档的 Docker 命令下载或构建所有固定输入，生成基础系统、Orbital 系统、启动镜像和分段刷机 ZIP，以便修改软件、配置或桌面并验证自己的镜像，而不依赖维护者电脑上的缓存和手工步骤。

## 验收标准

- AC1: WHEN 使用者按文档克隆仓库、准备本地初始 SSH 密码文件并在 Windows x64 启动 Docker Desktop 后，THE SYSTEM SHALL 通过一条文档化命令在空工作目录和无旧构建卷条件下构建 boot、Ubuntu rootfs、Orbital rootfs 与推荐分段刷机 ZIP。
- AC2: WHEN 构建准备内核、设备文件、固件、Orbital 源码和 Qualcomm 辅助程序时，THE SYSTEM SHALL 从固定版本或提交号的来源自动获取或构建它们，并在使用前校验完整性；不得要求用户自行复制被 Git 忽略的 inputs 文件。
- AC3: WHEN Orbital 桌面参与构建时，THE SYSTEM SHALL 使用可追溯到公开远端仓库的固定源码版本，纳入 OnePlus 6 适配，并在构建元数据记录精确提交号和适配补丁或树状态。
- AC4: WHEN 从 Ubuntu ARM64 base 开始安装 V15 锁定的系统包时，THE SYSTEM SHALL 在 Windows x64 + Docker Desktop 完成干净构建，不触发当前 proot assertion，并验证最终 ARM64 包集合与仓库锁文件一致。
- AC5: WHEN 镜像和刷机 ZIP 构建完成时，THE SYSTEM SHALL 验证镜像结构、目标设备、逻辑大小、分段清单和包锁，并在 out/ 生成含产物 SHA-256 与源码/锁文件标识的机器可读清单。
- AC6: IF 构建元数据记录 SSH 验证信息，THEN THE SYSTEM SHALL 不写入明文密码，也不写入可用于猜测密码的密码哈希；密码文件保持在本地忽略路径。
- AC7: WHEN 维护者按升级文档变更 Ubuntu、postmarketOS/Alpine、内核、固件、Orbital 或辅助程序版本时，THE SYSTEM SHALL 提供逐项更新来源、版本、哈希/提交锁及重新生成包锁的步骤，并要求升级验证通过前拒绝静默接受锁文件漂移。
- AC8: WHEN 文档描述 Windows 与 Linux 构建方式时，THE SYSTEM SHALL 标明 Windows x64 + Docker Desktop 是本轮实测平台，并明确 Linux x86_64 仅提供入口和前置条件、尚无本轮验证证据。

## 字段口径

| 字段 | 类型 | 必填 | 默认 | 说明 |
|---|---|---:|---|---|
| source revision | Git commit SHA | 是 | 锁文件指定值 | Orbital 与可构建内核/辅助程序的精确版本 |
| source patch digest | SHA-256 | 有补丁时必填 | 无 | OnePlus 6 适配补丁集合 |
| package lock | 包名、版本、架构三元组列表 | 是 | 仓库跟踪的锁 | 决定 rootfs 软件集合，升级须显式更新 |
| artifact digest | SHA-256 | 是 | 本次构建输出 | boot、两个 rootfs、分段 ZIP 及分段文件 |
| SSH password | 本地文件内容 | 本地构建必填 | 沿用当前 123456 约定 | 不进入 Git；不写入公开产物元数据 |
| build platform | 枚举 | 是 | windows-x64-docker-desktop | Linux x86_64 记录为未验收平台 |

## 状态流转

| 当前状态 | 目标状态 | 触发条件 |
|---|---|---|
| 未准备 | 输入已锁定 | 固定来源获取成功且版本/哈希校验通过 |
| 输入已锁定 | 构建中 | 在干净工作目录执行构建命令 |
| 构建中 | 构建通过 | 镜像、包集合、ZIP 和哈希清单校验通过 |
| 构建中 | 构建失败 | 下载、校验、安装、打包或验证失败；保留清晰错误上下文且不覆盖已有发布产物 |
| 构建通过 | 升级候选 | 维护者显式修改版本或锁文件 |
| 升级候选 | 升级通过 | 干净构建与静态验收通过；真机验收独立记录 |

## 权限与安全边界

| 操作 | 角色 | 范围 |
|---|---|---|
| 编辑源码、设备配置和依赖锁 | 镜像维护者 | 本地工作树 |
| 下载固定输入并执行 Docker 构建 | 使用者/维护者 | 本地 Docker、工作目录和忽略的构建状态目录 |
| 修改首次 SSH 密码 | 镜像使用者 | 自己生成的镜像和设备 |
| commit、push、创建 Release、刷写手机 | 用户 | 本轮不由自动流程执行；完成后单独确认 |

## 非目标

- 不要求不同主机输出逐字节相同，也不要求与历史 V15 哈希一致。
- 不承诺 Linux、macOS、ARM 主机或非 Docker Desktop 平台通过实测。
- Docker 构建通过不等同于手机真机启动、WiFi、触摸、显示、背光、SSH、功耗或续航验收。
- 不自动刷写设备，不提交或推送 Git，不上传 GitHub Release。
- 不改变 OnePlus 6 设备范围、初始账户和密码策略、磁盘加密策略或蓝牙取舍。
- 不让安全更新自动替换固定的手机内核，也不引入自动重启策略。

## 影响面

- 涉及模块：oneplus6-image 的 Windows/Linux 构建入口、Docker 构建环境、scripts/build.sh、config 锁文件、Orbital 源码接入、输出验证、README 与升级文档；可能涉及 Orbital 仓库适配源码。
- 涉及数据：Git 提交、补丁 SHA-256、APK/Ubuntu 包锁、构建元数据 JSON、各输出 SHA-256；不涉及数据库。
- 关联端：Windows x64 + Docker Desktop 本轮必须验证；Linux x86_64 只提供入口并标注未验证。

## 验证说明

完整构建在临时干净克隆或独立工作目录、独立 Docker 卷中执行；开始时不得含 inputs、work、state 或 out。不得清理或覆盖当前工作树里的已有构建状态和发布产物。

为满足 AC3，Orbital 适配需先成为可公开检出的固定提交或补丁输入。未推送的本地改动不能描述为公众克隆可用；本地代码准备完成后仍须单独确认 Git 提交/推送。
