# Fabushi 全平台持续发布任务

本目录是 `full-platform-release-live-runner-20260831` 的权威任务规范。执行 Chat 每轮开始时必须读取本目录全部文件、`.mahayana-project-email.json` 及其 Gmail 线程，并以 `ACCEPTANCE.md` 为唯一完成门禁。

任务不是一次状态检查，而是由本机 chatgpt-auto-confirm 原生队列持续实现、验证、修复和发布。未经真实产物、真实安装、真实远控与 GitHub Actions 证据，不得声明完成。

“对比运行状态”指同时检查队列拥有的隐藏 ChatGPT 实例当前会话是否真的存在模型/工具活动，以及 chatgpt-auto-confirm 队列、round、报告、Runner 和 GitHub Actions 反馈是否与该会话一致。健康时继续任务；异常时修复插件并恢复同一任务状态。
