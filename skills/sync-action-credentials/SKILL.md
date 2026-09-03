---
name: sync-action-credentials
description: 从已经打开并登录的 ChatGPT 桌面应用 app:// renderer 通过 CDP 实时导出会话，验证桌面登录状态和本机 Codex 凭证，再安全同步到 GitHub Actions Secrets；可选择立即启动自动确认 Action。用户要求更新、刷新、重新保存或一键同步云端 ChatGPT 凭证时使用。
---

# 一键同步 Action 凭证

使用自动确认小程序的 `sync_actions_credentials` 命令完成同步；不要自行读取、打印或复制凭证明文。

## 流程

1. 已有打开且登录的桌面实例时，调用 `sync_actions_credentials`。需要同步后立即启动云端运行器时传入 `{ "start": true, "waitSeconds": 600 }`；只更新密钥时传入 `{ "start": false, "waitSeconds": 600 }`。
2. `sync_actions_credentials` 只复用已经打开的 ChatGPT 桌面应用 `app://-/index.html` renderer；找不到时必须失败，不得隐式打开其他实例。只有用户明确要求打开桌面应用并等待登录时才调用 `login_and_sync_actions`，且打开后仍必须使用完全相同的 `app://` + CDP 实时导出流程。
3. 不得提供或调用任何名为“web login”或“browser login”的兼容入口；不得新建、打开或依赖 `https://chatgpt.com` 网页 renderer，也不得使用外部浏览器。
4. 把 Codex 凭证与 ChatGPT Session 当作两个独立且都必需的凭证。不得因 `~/.codex/auth.json` 可用就推断 ChatGPT Session 已注入，也不得只凭桌面进程已启动或页面显示 Work 就判定验证成功。
5. 验证 `~/.codex/auth.json` 结构完整，并从当前桌面 renderer 的已认证状态取得非敏感账号标识；两边账号必须一致。任一凭证缺失、无法确认身份或身份不一致时立即失败，禁止上传或启动 Action。
6. 启动时没有 Chat composer、停在 Work、或显示 Codex/Work usage 页面，都只表示当前界面未进入真实 Chat，不表示 Chat 额度耗尽或 Session 缺失。必须通过顶部 `Chat/Work`、`聊天/工作` 或紧凑模式菜单执行一次真实的 `Work → Chat` 切换，再要求同时出现 Chat 输入框、ChatGPT 模型控件和可读取的 Chat 侧边栏；仅修改持久化模式值不算切换成功。
7. 真实 Chat 复验成功后，立即通过该桌面 renderer 的 CDP `Network.getAllCookies` 实时导出 Cookie，规范化后原子写入本机私有 `session-cookies.json`。禁止读取、复制或解密任何浏览器、Codex 或 ChatGPT 桌面资料库中的 Cookie 数据库。
8. 使用 `base64` 管道在同一次操作中同步 Codex 凭证和刚抓取的 ChatGPT Session；任何一项为空都必须失败。不得读取或上传本地任务队列状态，也不得复用未验证的旧 Cookie 文件。
9. Action 恢复后必须再次验证两类凭证均存在、账号一致，并完成真实 `Work → Chat` 切换与 composer 复验；失败时停止队列，不得把 Work usage 页面当作 Chat 页面继续重试。
10. 任务目标与任务文档只来自仓库内的 `tasks/actions-inbox.json`、`documentDirectory` 和 `specSources`。运行器启动后持续读取这些可动态更新的文件；不得用 Secret 固化任务定义。
11. 仅返回非敏感摘要：是否成功、仓库、写入的 Secret 名称、Cookie 数量、双凭证存在状态和账号已验证状态；绝不返回 token、Cookie、auth 文件内容、账号 ID 或 Base64 值。

## 目标 Secrets

- `CHATGPT_CODEX_AUTH_B64`
- `CHATGPT_SESSION_COOKIES_B64`
- 续跑状态加密密钥：`CHATGPT_AUTO_CONFIRM_STATE_KEY`（仅在不存在时生成）

## 安全边界

- 必须经过宿主的显式授权卡；skill 不绕过用户确认。
- 不读取 GitHub Secret 明文，也不在日志、聊天或错误信息中输出凭证。
- 每次命令都必须重新验证并实时导出当前桌面 app renderer；现有 `session-cookies.json` 只能作为成功导出后的输出，不能作为上传来源。
- 禁止使用 Cookie SQLite 数据库、`Codex Safe Storage`、`Chrome Safe Storage`、DPAPI 或其他本地密钥解密路径；不得回退到这类方式。
- 未登录时允许打开登录入口并等待用户完成登录；任一凭证缺失、账号无法比对或账号不一致时立即失败，禁止覆盖 GitHub Secret。
- 禁止把 Codex/Work usage 提示解释为普通 Chat 额度不足。若预期 Chat 可用，必须先执行真实的 Work → Chat 切换并验证 Chat composer；无法验证就停止。
- 每次只更新 `CHATGPT_CODEX_AUTH_B64` 和 `CHATGPT_SESSION_COOKIES_B64`；仅当不存在时生成 `CHATGPT_AUTO_CONFIRM_STATE_KEY`。
- 禁止创建或使用 `CHATGPT_AUTO_CONFIRM_INITIAL_STATE_B64`。首次运行必须从空执行状态开始并读取仓库任务文件；跨 Runner 续作只能使用显式 `previous_run_id` 对应的短期加密构件。
- 同步失败时只报告阶段性错误和下一步，不尝试把凭证写入普通文件、Issue、PR 或任务 prompt。
