# 固定初始密码实现进度

| 任务 | 状态 | 证据 | 决策 |
|---|---|---|---|
| T1 配置与构建模式 | 已验证 | `config/build.env` 设置 `SSH_AUTH_MODE=fixed-password-file`；生成的 V15 rootfs 已验证 | 未知或缺失模式必须失败关闭 |
| T2 密码策略 | 已验证 | 已安装 `pam_pwquality`；真实非 root `passwd` 接受合规密码，并拒绝弱密码和包含用户名的密码 | 在真实 `passwd` 测试后放弃自定义 `pam_exec` token 处理 |
| T3 shadow 指纹与 path unit | 已验证 | 首次启动存在标记，目标设备改密后自动删除 | 标记保存 shadow 密码字段的 SHA-256，不保存密码 |
| T4 登录提示 | 单元测试已验证 | 交互式 source 脚本测试会显示警告；ShellCheck 通过 | 非交互式 shell 保持静默 |
| T5 构建集成 | 使用恢复的 V14 文件树验证 | 两个 rootfs 均安装控制项；生成 V15 镜像并在设备测试 | 干净完整构建仍作为独立构建环境后续任务 |
| T6 刷新集成 | 已验证 | `refresh-images.sh` 安装控制项、更新指纹、重建两个镜像并更新 V15 元数据 | 仅在 unit 文件存在后启用 path unit |
| T7 静态镜像验证 | 已验证 | 检查两个 rootfs 哈希、标记指纹、pwquality 模块、PAM、path unit 和软件包数量 | V15 静态记录位于 `state/v15-static-verification.json` |
| T8 目标设备验证 | 已验证 | 验证交互式 SSH、提醒、弱密码拒绝、强密码修改、标记清理和初始状态恢复 | 设备恢复为 `orbital/123456`，并保留待改密标记 |
| T9 文档 | 已完成 | `docs/fixed-initial-password.md` | 已记录公开发布风险 |

发布决策：这项认证改动作为 V15 构建，而不是覆盖已经通过硬件验证的 V14 产物。

## 验证日志

- 2026-10-31：认证 helper、检查器、登录提示和测试脚本通过 `shellcheck`。
- 2026-10-31：Python 策略编译和构建/刷新 shell 语法检查通过。
- 2026-10-31：切换到标准 pwquality 后输出 `PASS: orbital password controls (6 checks)`。
- 2026-10-31：软件包锁从 520 个包扩展到 524 个排序包。
- 2026-10-31：验证 V15 rootfs 文件树：基础镜像 `460` 个包、Orbital 镜像 `524` 个包，且与锁完全一致。
- 2026-10-31：真实非 root `passwd` 测试接受合规密码，并拒绝单一类别或包含用户名的密码。
- 2026-10-31：在一加 6 上刷入 V15 分段镜像。登录、提醒、弱密码拒绝、合规改密和自动清理标记全部通过；设备恢复为 `123456` 并保留待改密标记。
- 2026-10-31：从零完整构建在安装/升级 systemd 时触发 `proot` 断言。V15 产物通过恢复已硬件验证的 V14 rootfs、使用原生 arm64 chroot 安装 4 个锁定的 pwquality 软件包，再刷新两个镜像生成。

## 待验证项

- 发布构建仓库前，应把 proot 安装路径替换为原生 arm64 chroot 构建阶段，并重新执行一次干净完整构建。
