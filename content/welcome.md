---
id: welcome
revision: '9'
---
欢迎使用 **ChatGPT 自动确认**。

它既能自动确认 ChatGPT 授权卡，也能编排可恢复的任务队列。`send_and_watch` 使用插件自己创建并拥有的 ChatGPT.app 实例；这个实例可以可见，也可以隐藏，但不会借用用户主窗口或 Work composer。插件只在真实 Chat 页面发送，并严格绑定自己的 profile、调试端口和 target。

每一轮都由插件创建新的工作 Chat。工作 Chat 只收到自然语言执行目标并返回自然结果；插件把这个结果连同原始目标交给另一个新的规划/验收 Chat，只有规划 Chat 才收到 `MAHAYANA_TASK_REPORT_V1` 模板。规划 Chat 用模板决定完成或把 `next_task` 安排给下一轮新的工作 Chat，插件递归串联，绝不把模板转发给工作 Chat。遇到授权卡时优先选择“允许本次会话”，界面不提供会话范围选项时自动点击卡片上的“允许”继续执行。

通用确认和任务队列使用插件自己的 ChatGPT 实例；运行状态如实报告为 `hidden-chat` 或 `visible`，可见并不代表失败。每个运行中的任务都绑定自己的 Chat/target，工作、规划、续作和验收都创建新的 Chat；旧 Chat 只读。重试、停止或取消时，插件只关闭精确识别出的自有 target/profile/process，不影响用户自己的 ChatGPT/Codex 实例。队列、会话引用和审计记录只保存在本机；辅助功能扫描仍只处理真正可见的授权卡。

现在可以在「账号」中添加最多 10 个 ChatGPT 账号。每个账号使用独立 profile、独立 CODEX_HOME 和 macOS Keychain 条目；任务入队时固定账号，之后切换默认账号只影响新任务。也可以生成只绑定 127.0.0.1、十分钟一次性的登录链接，确认后自动打开隔离登录窗口。

需要脱离本机长期运行时，可点「启动 6 小时 Action」。每个账号使用独立 GitHub Environment 和并发组；Runner 首轮读取 Environment Secret，之后优先恢复最近一次成功 smoke 产生的 AES-256-GCM 加密凭据构件。每 6 小时会为已注册账号运行短 smoke，成功后滚动保存最新 Codex auth.json 和 renderer Cookie；认证失败会暂停该账号，等待本机重新登录。不存在官方永久 ChatGPT 页面 Cookie，仍需按需重新登录。
