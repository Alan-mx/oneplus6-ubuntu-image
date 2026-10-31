# 一加 6 固定初始密码

## 登录凭据

这个仅用于私下分发的镜像使用：

```text
用户名：orbital
初始密码：123456
```

`orbital` 账号拥有免密 sudo 权限。修改初始密码之前，任何能够连接到 SSH 的人
都可以获得完整 root 权限。

修改初始密码前，不要把手机连接到 WiFi、Tailscale 或其他不可信网络。

## 修改密码

通过 USB 网络登录：

```bash
ssh orbital@172.16.42.1
```

然后修改密码：

```bash
passwd
```

新密码长度必须为 8 到 128 个字符，并且至少包含以下两类字符：

- 字母
- 数字
- 符号

新密码不能包含 `orbital`。

修改成功后，待改密标记会被删除，后续交互式登录不再显示密码警告。

## 推荐设置顺序

1. 刷入镜像。
2. 连接 USB，使用 `orbital` 和 `123456` 登录。
3. 执行 `passwd`，设置自己的密码。
4. 使用新密码重新连接 SSH。
5. 配置 WiFi。
6. 安装并配置 Tailscale。

## 验证密码状态

```bash
test -e /var/lib/orbital/default-password-pending && echo pending
systemctl status orbital-default-password-check.path --no-pager
```

如果标记文件已经不存在，命令不会输出 `pending`。

## 分发警告

固定初始密码只适用于私有链接和已知用户。公开 GitHub Release 如果使用相同密码，
所有下载者都会得到同一个初始凭据，因此公开版本应改用首次登录随机密码方案。
