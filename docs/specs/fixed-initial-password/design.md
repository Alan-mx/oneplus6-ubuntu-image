# 私有分发版固定初始密码设计

## G3 第一部分：数据与状态设计

状态：已实现并在 OnePlus 6 上完成现场验证。

## 设计决定

- 复用现有构建密码文件机制，不新增首次启动随机密码和 HTTP 服务。
- 在镜像中安装待改密标记和登录提示。
- 使用 Ubuntu 标准 `pam_pwquality.so` 执行新密码规则。
- 包锁从 520 个包增加到 524 个包。
- 固定密码 `123456` 只通过本地 `state/orbital-password.txt` 或覆盖路径提供，
  不作为仓库默认配置。
- 两个 rootfs 使用完全相同的认证状态。

## 文件与状态

| 路径 | 权限 | 内容与生命周期 |
|---|---:|---|
| `/var/lib/orbital/default-password-pending` | `0644 root:root` | 标记仍在使用初始密码；改密成功后删除 |
| `/etc/profile.d/90-orbital-default-password.sh` | `0644 root:root` | 交互式登录时检查标记并显示提示 |
| `/etc/security/pwquality.conf.d/50-orbital.conf` | `0644 root:root` | 密码长度、字符类别和用户名检查 |
| `/etc/pam.d/common-password` | `0644 root:root` | `pam_unix.so` 前调用 `pam_pwquality.so` |
| `state/ssh-auth.txt` | 构建机本地 | 只记录 `mode=fixed-password`，不记录明文 |

## 状态与不变量

```text
default_password_pending
    -> password_changed
```

| 编号 | 不变量 |
|---|---|
| I1 | 标记存在时提示脚本显示改密警告，不阻塞 shell。 |
| I2 | 标记不存在时提示脚本不输出任何内容。 |
| I3 | `pam_pwquality.so` 不得把密码写入 journal 或应用日志。 |
| I4 | 改密失败时标记保持不变。 |
| I5 | 改密成功后标记原子删除。 |
| I6 | 静态镜像中可以存在 `123456` 的哈希，但公开 Git 默认配置不得包含真实密码。 |
| I7 | 不安装随机密码服务、USB 密码页面或强制改密相关 unit。 |

## 密码规则

- 新密码长度 `8..128`。
- 至少包含大写字母、小写字母、数字、符号中的两类。
- 不包含大小写不敏感的 `orbital`。
- `minlen = 8`、`minclass = 2`、`usercheck = 1`。
- PAM 失败时不修改密码，不回显密码。

## 构建模式

| 字段 | 值 |
|---|---|
| `SSH_AUTH_MODE` | `fixed-password-file` |
| `SSH_PASSWORD_FILE` | 本地文件，例如 `state/orbital-password.txt` |
| 默认配置中的密码 | 不允许写入 |
| 构建元数据 | `mode=fixed-password`，不记录明文 |

发布构建仍要求人工提供密码文件；仓库只提供占位说明，不内置 `123456`。

## 验收标准映射

| 验收标准 | 设计 |
|---|---|
| AC1、AC2 | 现有密码文件构建输入、I6 |
| AC3、AC4 | profile 提示脚本、I1 |
| AC5 | `pam_pwquality.so` 与 pwquality 配置 |
| AC6 | PAM 改密成功回调、I5 |
| AC7 | 不安装随机密码和 HTTP 服务 |
| AC8 | 保持现有 SSH、sudo 和运行服务配置 |
| AC9 | 构建元数据 `mode=fixed-password` |
| AC10 | 发布说明风险声明 |

## G3 第二部分：接口与实现任务

### 构建配置接口

| 字段 | 约束 | 使用方 |
|---|---|---|
| `SSH_AUTH_MODE` | 固定为 `fixed-password-file` | `validate_config`、构建、refresh |
| `SSH_PASSWORD_FILE` | 必须指向非空本地文件 | 账户密码哈希生成 |
| `SSH_PASSWORD_FILE_OVERRIDE` | 可覆盖本地密码文件路径 | 命令行/CI |

- `SSH_AUTH_MODE` 缺失或值未知时构建失败。
- `SSH_PASSWORD_FILE` 不存在或为空时构建失败。
- `SSH_PASSWORD_FILE` 内容不写入日志、状态文件或 Git。
- `state/ssh-auth.txt` 只记录 `mode=fixed-password-file`。

### 密码策略接口

新增 Ubuntu 包：

```text
libpam-pwquality  1.4.5-5build1
libpwquality1     1.4.5-5build1
libpwquality-common 1.4.5-5build1
libcrack2         2.9.6-5.2build3
```

新增配置：

```text
/etc/security/pwquality.conf.d/50-orbital.conf

minlen = 8
minclass = 2
usercheck = 1
```

`minclass = 2` 要求大写字母、小写字母、数字、符号中至少出现两类；
`usercheck = 1` 拒绝包含用户名 `orbital`。

### 新增脚本接口

#### `/usr/local/sbin/orbital-default-password-check`

```text
输入：
  /var/lib/orbital/default-password-pending
  /etc/shadow

输出：
  journal             仅输出结构化结果和通用错误

退出码：
  0                 标记不存在、密码未变或已完成状态协调
  1                 shadow 或标记格式错误
```

职责：

- 标记不存在时直接成功返回。
- 从标记读取 `sha256:<fingerprint>`。
- 计算 `orbital` shadow 密码字段的 SHA-256 指纹。
- 指纹一致时保留标记。
- 指纹不同时原子删除标记文件。
- 不输出 shadow 原文或密码哈希。

### systemd 接口

#### `orbital-default-password-check.path`

```ini
[Path]
PathChanged=/etc/shadow
Unit=orbital-default-password-check.service
```

- 构建时启用。
- `/etc/shadow` 变化时启动检查服务。
- 不包含定时器，不使用网络。

#### `orbital-default-password-check.service`

```ini
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/orbital-default-password-check
```

- 以 root 运行。
- 无网络访问。
- 失败只影响提示清理，不影响 SSH 登录。

### PAM 接口

在 `/etc/pam.d/common-password` 的原 `pam_unix.so` 行之前插入：

```text
password requisite pam_pwquality.so retry=3
```

- 策略模块失败时停止密码修改。
- 策略成功后继续原有 `pam_unix.so obscure yescrypt`。
- 不修改 PAM 的 success jump 数，不插入改密后回调。
- 改密完成由 shadow path unit 独立识别。

### 登录提示接口

#### `/etc/profile.d/90-orbital-default-password.sh`

```text
触发：
  交互式登录 shell

条件：
  当前用户为 orbital
  且 /var/lib/orbital/default-password-pending 存在

输出：
  一段固定改密提示，包含 passwd 命令
  不输出密码明文、密码哈希或 sudo 内容
```

- 提示不阻塞 shell。
- 非交互 `ssh host command` 不要求显示提示。
- 标记不存在时不产生任何输出。

### 构建与刷新函数

| 函数/位置 | 职责 |
|---|---|
| `build.sh:validate_config` | 校验 `SSH_AUTH_MODE` 和本地密码文件 |
| `build.sh:configure_base_system` | 安装 pwquality 配置、提示和 path/service |
| `build.sh:configure_runtime_services` | 启用 default-password path unit |
| `build.sh:verify_outputs` | 校验 PAM 行、脚本权限、unit 和标记 |
| `refresh-images.sh:configure_auth` | 更新密码后重新生成标记指纹 |
| `refresh-images.sh:configure_runtime_services` | 与完整构建保持相同 unit 状态 |
| `scripts/build.sh` 收尾 | 写 `mode=fixed-password-file`，不写明文 |

标记文件内容格式：

```text
sha256:<64 lowercase hex characters>
```

指纹计算对象是 `/etc/shadow` 中 `orbital` 的第二个字段，不包含用户名、
`/etc/shadow` 其他字段或影子文件换行符。

### 文档接口

- `docs/fixed-initial-password.md` 说明默认账号、初始密码风险、改密命令和网络接入
  顺序。
- 发布 README 首屏必须声明：
  - 初始密码为通用值。
  - 接入 WiFi 或 Tailscale 前先修改密码。
  - 不适合公开互联网发布。
- 旧的随机密码规格保持“已废弃”，不得被构建脚本引用。

### 实现任务清单

| 任务 | 验收标准 |
|---|---|
| T1 配置校验与构建模式 | AC1、AC2、AC9 |
| T2 标准 pwquality 包、配置及 PAM 集成 | AC5 |
| T3 指纹标记和检查服务 | AC6 |
| T4 登录提示脚本 | AC3、AC4 |
| T5 完整构建集成 | AC1、AC7、AC9 |
| T6 refresh 集成 | AC1、AC6 |
| T7 静态镜像验证 | AC2、AC7、AC8 |
| T8 固定密码表现场验证 | AC3、AC4、AC5、AC6、AC8 |
| T9 发布文档和风险声明 | AC10 |

### 验收标准覆盖自检

| 验收标准 | 对应任务 |
|---|---|
| AC1 | T1、T5 |
| AC2 | T1、T7 |
| AC3 | T4、T8 |
| AC4 | T4、T8 |
| AC5 | T2、T8 |
| AC6 | T3、T6、T8 |
| AC7 | T5、T7 |
| AC8 | T7、T8 |
| AC9 | T1、T5 |
| AC10 | T9 |

所有 AC 均有任务对应，无遗漏。
