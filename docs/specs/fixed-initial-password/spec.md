# 私有分发版固定初始密码规格

## 背景

镜像只通过私有链接分享给已知用户，预期接入个人 Tailscale 网络，不直接暴露
公网 SSH。用户确认所有设备使用固定初始密码 `123456`，首次登录后由用户自行
执行 `passwd` 修改。

该模式不适用于公开 GitHub Release 或无差别互联网分发。`orbital` 用户拥有免密
sudo 权限，在修改初始密码前，任何能访问 SSH 的人都可以取得完整 root 权限。

## 用户故事

- 作为镜像维护者，我希望镜像开箱即可用 `orbital/123456` 登录，不需要额外取密
  网页或首次启动服务。
- 作为设备使用者，我希望登录后看到明确提示，并自行执行 `passwd` 修改密码。
- 作为维护者，我希望用户改密后登录提示自动消失，避免长期打扰。

## 验收标准

- AC1：WHEN 使用私有分发配置构建 Ubuntu base 和 Orbital 两个 rootfs，THE SYSTEM
  SHALL 为 `orbital` 用户设置固定初始密码 `123456`。
- AC2：WHEN 检查公开 source 仓库和构建元数据，THE SYSTEM SHALL 不把 `123456`
  写入默认配置或提交为真实凭据；固定密码只由本地构建输入提供。
- AC3：WHEN 用户首次登录 `orbital`，THE SYSTEM SHALL 允许正常 shell 和远程
  命令，不得阻塞登录或强制进入改密流程。
- AC4：WHILE 用户尚未修改初始密码，THE SYSTEM SHALL 在交互式 SSH 登录时显示
  修改密码提示，并说明可执行 `passwd`。
- AC5：WHEN 用户执行 `passwd` 设置新密码，THE SYSTEM SHALL 要求长度为
  `8..128`，至少包含大写字母、小写字母、数字、符号中的两类，且不得包含
  `orbital`。
- AC6：WHEN 新密码修改成功，THE SYSTEM SHALL 删除待改密标记，使后续登录不再
  显示初始密码提示。
- AC7：WHEN 用户未修改初始密码，THE SYSTEM SHALL 不生成随机密码、不启动
  USB-only HTTP 页面、不启用强制改密。
- AC8：WHEN 使用固定密码模式，THE SYSTEM SHALL 保持 `root` SSH 登录禁用，
  `orbital` 的 sudo、自动安全更新和其他运行策略不变。
- AC9：WHEN 构建完成，THE SYSTEM SHALL 在构建元数据中记录
  `mode=fixed-password`，但不得记录密码明文。
- AC10：WHEN 发布说明生成，THE SYSTEM SHALL 明确标注“通用初始密码，接入网络前
  必须修改”，且不得将该镜像描述为公开安全默认配置。

## 状态流转

```text
default_password_pending
    | 用户执行 passwd 并成功修改
    v
password_changed
```

- 初始状态在构建时写入。
- 状态跨重启保存。
- 不提供强制改密或自动恢复密码。

## 数据与权限

| 数据 | 位置 | 权限 | 生命周期 |
|---|---|---|---|
| 初始密码哈希 | 系统用户数据库 | 系统账户数据库权限 | 直到用户改密 |
| 待改密标记 | `/var/lib/orbital/default-password-pending` | `0644 root:root` | 改密成功后删除 |
| 登录提示 | `/etc/profile.d/90-orbital-default-password.sh` | `0644 root:root` | 固定存在，由标记控制显示 |
| 本地构建密码文件 | 构建机 `state/` | 不进入 Git | 仅本地构建使用 |

## 非目标

- 不提供 USB-only 密码页面。
- 不生成随机初始密码。
- 不强制改密。
- 使用标准 `libpam-pwquality` 策略，锁定新增的 4 个 Ubuntu 软件包。
- 不改变 root SSH、sudo、安全更新或 Tailscale 策略。

## 验收测试

1. 使用本地密码文件 `123456` 构建两个 rootfs，确认 `orbital` 可以登录。
2. 检查静态镜像和 Git 工作区，确认仓库默认配置没有真实密码。
3. 首次 SSH 登录不阻塞，并显示改密提示。
4. 使用弱密码修改应失败，使用合规的新密码应成功。
5. 改密后标记文件消失，后续登录不再显示提示。
6. 重启后保持已改密状态，不恢复 `123456`。
7. 确认 `root` SSH 仍被禁用，未新增 HTTP 页面和随机密码服务。

## 风险声明

- 初始密码对所有下载者公开且相同。
- USB、WiFi 和 Tailscale 中任何可达 SSH 的用户都可能在改密前登录。
- GitHub Release 一旦公开，视为互联网公开分发，不再适用本规格。
