# 从零构建与升级流程：进度

日期：2026-10-31

| 切片 | 状态 | 验证证据 / 裁决 |
|---|---|---|
| 规格和设计确认 | 完成 | 用户已确认 spec 与 design；见 `spec.md`、`design.md`。 |
| T1 固定源码与 helper 来源 | 待开始 | |
| T2 Orbital 固定来源接入 | 待开始 | 用户确认先支持本地 dirty 工作树；公开可复现仍需 Orbital 适配成为远端提交。 |
| T3 rootfs 干净构建稳定性 | 待开始 | |
| T4 provenance manifest | 待开始 | |
| T5 Windows 构建接口和 Fresh 隔离 | 待开始 | |
| T6 显式升级接口 | 待开始 | |
| T7 静态验证与文档 | 待开始 | |
| T8 独立环境全量构建 | 待开始 | 用户选择先静态/脚本验证，再决定和执行完整 Docker 构建。 |

## 不可违反的边界

- 不清理或覆盖现有 `work/`、`state/`、`out/` 和 Docker volumes。
- 全量构建只能用临时克隆/目录与唯一的专用 Docker volume。
- 不提交、不推送、不刷写设备、不上传 Release。
- 公开构建必须拒绝 dirty 源码；本地开发构建只记录 dirty 和内容摘要。
- build state / manifest 禁止记录密码明文及可用于猜测密码的派生哈希。
