# 从零构建与升级流程：设计

需求名：clean-build-reproducibility ｜ 日期：2026-10-31 ｜ 状态：已确认，接口设计与实现中

## 方案概述

复用现有包锁、镜像结构验证和分段 ZIP 清单；新增源码 revision lock 与每次成功构建的 build manifest。数据库不适用，本功能不新增数据库表。

Orbital 以公开仓库的固定 Git submodule/gitlink revision 接入，不复制整份源码到镜像仓库。内核和 Qualcomm helper 的上游地址、精确 commit 与版本放入跟踪的源码锁。成功产物的 build manifest 记录本次实际使用的 source revisions、锁文件摘要、验证结果及输出摘要。

开发构建允许本地修改，但 manifest 必须记录 dirty 状态与 diff/tree digest；面向分享的 release build 要求所有依赖源码为干净、可公开检出的固定 revision。不能把本地未提交的 Orbital 修改说成公众已可复现。

## 复用清单

| 能力 | 现有结构 | 复用方式 |
|---|---|---|
| 发行版和设备参数 | config/build.env | 保留 release version、设备、镜像大小、仓库地址等构建参数；移除被源码构建取代的预编译 boot/helper hash 参数 |
| postmarketOS / Alpine 二进制包锁 | config/apk-sha256.lock、state/apk-packages*.json | 保留 APK 解析结果与逐文件 hash 校验 |
| Ubuntu ARM64 软件集合锁 | config/ubuntu-packages.lock.tsv | 保留 package/version/architecture 集合，升级时显式审核更新 |
| Docker 构建环境 | Dockerfile、Dockerfile.kernel、对应 builder package TSV | 保留版本固定的基础镜像与工具包集合 |
| boot/rootfs 结构验证 | scripts/verify_images.py、state/verification.json | 扩展并汇总结果，不另造 sparse/boot 验证格式 |
| 分段 sparse 清单 | scripts/make_sparse_segments.py 产出的 manifest.json | 原样作为 ZIP 分段来源，并将其摘要纳入最终构建清单 |
| ZIP 内容与校验 | scripts/package_segmented_release.py、SHA256SUMS.txt | 复用分段、校验和归档结构；去掉 V14 固定 boot hash 限制，改为与本次构建 manifest 交叉验证 |
| 当前执行阶段 | state/build-state.json | 只保留本地执行状态；移除 SSH 密码 SHA 等凭据派生信息 |
| 历史发布记录 | state/release-lock.json | 保留为历史 release 对照，不用作当前通用构建的可变状态文件 |

## 第一步：数据结构设计

### 1. 源码锁

新增跟踪文件 config/source-revisions.lock.tsv。使用 TSV 与现有 package lock 风格一致，UTF-8、LF、固定列顺序，不保存本机路径。

| 列 | 类型 | 约束 | 说明 |
|---|---|---|---|
| component | string | 必填、唯一 | kernel、qrtr、tqftpserv、pd-mapper、rmtfs 等构建组件 |
| repository | HTTPS URL | 必填 | 可公开读取的上游 Git 地址 |
| commit | 40 位 Git SHA-1 | 必填 | 不允许 branch、tag 或 latest 作为实际锁值 |
| version | string | 必填 | 人类可读上游版本，与 commit 同时记录 |
| license | SPDX identifier | 必填 | 仅记录经源码 LICENSE 文件核对的许可证标识 |

Orbital 的 repository + exact commit 由 .gitmodules 与 superproject gitlink 共同表达，不在 TSV 重复一份。内核适配继续放在 kernel-patches/，对每个 patch 由 manifest 记录路径、SHA-256 和应用顺序。APK binary package 输入仍由现有 apk-sha256.lock 约束；若未来不再使用包仓库里的版本，需先调整 spec/lock 方案，不能默默回退到无锁下载。

### 2. 构建 provenance manifest

每次成功构建生成 out/build-manifest.json，UTF-8 JSON，schema_version 初始为 1。它是本次产物的自描述记录，验证失败时不得生成 status=verified 的 manifest，也不得覆盖之前成功的 manifest。

| 对象/字段 | 类型 | 必填 | 内容 |
|---|---|---:|---|
| schema_version | integer | 是 | manifest 格式版本 |
| status | enum | 是 | 完整验证通过时为 verified；失败只写在本机 build state/log，不发布成功 manifest |
| release | object | 是 | release name/version、device id、Ubuntu version、kernel release |
| build | object | 是 | UTC started/finished 时间、builder image digest、构建平台、clean/dirty source 模式 |
| sources | array | 是 | 每个源码组件的 repository、version、commit、tree clean 状态；patch 路径和 SHA |
| locks | array | 是 | 锁文件相对路径与 SHA-256：build config、source revisions、APK lock、Ubuntu package lock、builder package locks |
| packages | object | 是 | 最终 ARM64 package TSV 相对路径、SHA-256、条目数量；需分别覆盖 base 与 Orbital rootfs |
| validations | object | 是 | boot header/root 参数、DTB 对应、sparse 格式/逻辑大小、最终 package lock、segment manifest 和 ZIP integrity 的通过状态 |
| artifacts | array | 是 | boot、base rootfs、Orbital rootfs、每个 segment、segmented ZIP 的相对路径、文件大小与 SHA-256 |

manifest 不包含 SSH 密码、公钥私钥内容、密码 hash/fingerprint、无线密码或用户绝对路径。若开发构建的源码树 dirty，只记录 dirty=true、可追溯的 patch/tree digest 和明确的 non-release 标记；release mode 必须拒绝 dirty 源码。

### 3. 现有结构迁移边界

- 保留 state/verification.json 作为镜像结构验证的详细报告；build-manifest 只汇总其结果并记录文件摘要。
- 保留分段 ZIP 内现有 manifest.json 和 SHA256SUMS.txt。最终 build-manifest.json 在 ZIP 外并列输出，并记录 ZIP 与分段清单的摘要；不让 ZIP 引用最终 build manifest 的 hash，避免循环校验。
- 保留 ignored state/ 与 work/ 作为本机中间态；任何用户密码文件继续位于 ignored state/。
- out/ 只放成功镜像、分享 ZIP、SHA256SUMS 和机器可读 build manifest。
- config/source-revisions.lock.tsv 只追踪源码来源；Ubuntu/APK 的 package locks 继续由原结构维护，避免形成两份权威版本值。

### AC 对应

| 验收标准 | 数据结构承接 |
|---|---|
| AC1 | artifacts 记录预期三种镜像与 segmented ZIP |
| AC2 | source-revisions.lock.tsv、现有 APK lock、source/patch hashes |
| AC3 | Orbital gitlink revision、sources 与 dirty/tree state |
| AC4 | packages 两套最终清单、锁文件摘要和 validation 状态 |
| AC5 | validations、artifacts、segment manifest digest |
| AC6 | build-state 与 manifest 明确禁止任何密码 hash/fingerprint |
| AC7 | 版本锁文件、锁文件 hash 与 provenance 关联 |
| AC8 | build.platform 字段和文档口径 |

## 第二步：接口清单

这里的接口是本地构建工具的命令/参数契约，不新增网络 API。

| # | 接口 | 职责 | 输入 | 输出/失败行为 |
|---|---|---|---|---|
| I1 | pwsh -File build.ps1 -Config config/build.env -SshPasswordFile <file> | 执行完整构建 | 配置、密码文件、Docker Desktop | 生成 boot、两个 rootfs、分段 ZIP、哈希和 provenance；任一输入校验失败即非零退出 |
| I2 | pwsh -File build.ps1 -Fresh ... | 清理专用 Docker 工作卷后从零构建 | 同 I1；只作用于当前构建卷 | 不读取旧 work/state/out 作为输入；保留仓库已有文件，不做破坏性清理 |
| I3 | pwsh -File build.ps1 -PrepareInputs | 下载/构建固定输入并校验 | source lock、APK/Ubuntu lock、Docker | 输入进入 ignored inputs；源、版本或哈希不匹配即非零退出 |
| I4 | pwsh -File build.ps1 -CheckEnvironment | 检查 Docker、平台、源码和锁文件前置条件 | 无或配置路径 | 输出可读诊断和机器可读检查结果；不下载、不改设备 |
| I5 | pwsh -File build.ps1 -RefreshImages ... | 在已存在、已验证 rootfs tree 上刷新配置并重打镜像 | 当前工作状态和锁文件 | 保留现有刷新语义；不冒充 clean build |
| I6 | pwsh -File upgrade.ps1 -Check | 检测上游/锁文件变更并列出受影响输入 | source lock、package locks、构建配置 | 只读输出变更摘要；不自动改锁文件 |
| I7 | pwsh -File upgrade.ps1 -Apply <component> | 在显式组件范围内更新来源锁和下载输入 | 组件名、目标 commit/version | 更新前要求校验，更新后要求完整构建验证；失败非零退出 |
| I8 | pwsh -File verify-build.ps1 -BuildRoot <dir> | 校验静态产物、manifest、ZIP 和锁文件 | 构建输出目录 | 通过返回 0；证据不足或校验不一致返回非零 |

容器内脚本接口：

| 接口 | 职责 |
|---|---|
| scripts/prepare-inputs.sh | 按锁文件准备 Ubuntu/APK/源码/helper 输入 |
| scripts/build.sh --prepare-only | 容器内只准备输入 |
| scripts/build.sh --check-only | 容器内只做前置检查 |
| scripts/build.sh | 完整构建并写出 provenance |
| scripts/build.sh --boot-only | 保留现有 boot-only 语义，不替代完整构建 |

接口约束：

- 默认构建必须从锁文件准备输入；本地 inputs/ 只作为已校验缓存，不是必需的人工输入。
- -Fresh 只允许删除专用 Docker volume，不删除用户工作树。
- upgrade.ps1 -Apply 不执行 Git commit、push、Release 上传或手机刷写。
- 构建产物统一位于 out/，验证报告位于 out/build-manifest.json 和 state/。

## 实现任务清单

- [ ] T1 固定源码与 helper 来源：新增 source lock、输入准备脚本和 Docker 构建依赖。
- [ ] T2 Orbital 来源接入：将适配代码固定为公开可追踪 revision，并使构建自动获取。
- [ ] T3 rootfs 构建稳定性：处理 clean build 的 systemd/proot assertion，保留失败上下文。
- [ ] T4 完整产物 provenance：生成 build manifest，汇总镜像、包锁、分段和源码摘要。
- [ ] T5 Windows 构建接口：实现 PrepareInputs、CheckEnvironment、Fresh 和独立卷验证。
- [ ] T6 升级接口：实现只读检查、显式组件更新和锁文件漂移保护。
- [ ] T7 静态验证与文档：实现 verify-build.ps1，补齐 README、升级文档和测试。
- [ ] T8 干净构建验证：独立目录、独立卷、无旧 inputs/work/state/out 执行完整构建并记录证据。

## 风险与回滚

- 风险：公开可复现依赖 Orbital 适配先成为远端公开 commit；在用户确认并完成提交/推送之前，只能验证本地树，不能满足公开克隆验收。
- 风险：当前有 dirty 工作树和被忽略的构建输入；试验必须使用独立临时克隆和 Docker volume，禁止对现有 work/state/out 做清理。
- 回滚：本设计新增配置/metadata，不改历史发布文件；如格式不合适，删除新 lock/manifest reader 并恢复既有构建状态输出，不需要迁移或还原数据库。

## 交付前自检

- AC1-AC8 均已映射到数据结构。
- 没有新增数据库、SQL 或可变历史 release lock。
- 数据结构与命令接口均已映射到 AC1-AC8；接口不新增数据库或远程 API。
- 密码内容和密码派生 hash 均不进入公开或本地构建 metadata。
