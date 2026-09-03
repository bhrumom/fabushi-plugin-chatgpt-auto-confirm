# ChatGPT 自动确认小程序 IPC 改造需求文档 (PRD)

## 1. 背景与目标
在当前的大乘（Mahayana）小程序 `@mahayana/chatgpt-auto-confirm` 中，目前的自动确认实现是基于 macOS 的辅助功能 API（`AXUIElement` 的 `AXPress` 行为）。由于辅助功能需要显式的系统授权，且性能和窗口状态（例如窗口隐藏或多窗口）有些时候受限，需要提供一个更加底层、高效、且不改动 `ChatGPT.app` 的进程间通信（IPC）方案作为主通信路径。

### 核心目标：
- **IPC 为主路径**：通过进程间通信进入正在运行的 ChatGPT 内部。
- **后台自动确认**：无需可见 UI 激活或鼠标移动，即使窗口隐藏或独立快速聊天窗口也可工作。
- **允许一次自动确认**：一旦卡片包含允许一次（`allow_once`），自动提交 `allow`。
- **AXPress 为回退**：原有的辅助功能点击仅作为兼容回退。
- **不做敏感拦截**：不做敏感内容或 Token 拦截，且保护日志。
- **集成测试覆盖**：编写可重复的模拟集成测试。

---

## 2. 构思方案 (双通道 IPC 主路径实现方案)
因为不能修改 `ChatGPT.app` 的文件，我们设计了双通道进程间通信（Dual-Channel IPC）作为主路径，并保留 `AXPress` 辅助功能点击作为明确标注的兼容回退：

### 2.1 Unix Socket IPC (`~/.codex/ipc/ipc.sock`)
- **连接与握手**：连接 Unix 域套接字 `~/.codex/ipc/ipc.sock`，遵循 `UInt32` 小端长度前缀 + JSON-RPC 协议。
- **客户端注册**：发送带有 `type: "request"`、`requestId: "req-init-status"` 和 `method: "initialize"` 的报文进行注册：
  ```json
  {
    "type": "request",
    "requestId": "req-init-status",
    "method": "initialize",
    "params": {
      "clientType": "chatgpt-auto-confirm",
      "protocolVersion": "2025-06-18",
      "clientInfo": { "name": "chatgpt-auto-confirm", "version": "0.1.0" }
    }
  }
  ```
  通过反向分析与实测验证，`ChatGPT.app` 内部 `IpcRouter` 能够成功返回 `clientId`，处理本地 `item/permissions/requestApproval` 授权。

### 2.2 CDP WebSocket 桥接 (`http://127.0.0.1:<PORT>/json`)
- **云端卡片处理**：反向分析显示云端审批（`chatgpt-tool-approval` / `jit_plugin_data`）是经由 WebKit/Chromium 内部渲染并在 `FE(e)` 中调用 `pc(c, { conversationId, model, prompt, toolApproval: { action: "allow", targetMessageId } })` 提交。
- **无屏幕操控直接点击**：在后台通过 CDP WebSocket (`Runtime.evaluate`) 执行安全脱敏的 JS 检测与事件回调。直接触发 V8 JS 引擎内部卡片确认（"Allow once" / "允许一次"），无需屏幕操控、鼠标坐标、CGEvent 或页面可见，独立快速聊天窗口或隐藏窗口亦可完备工作。

### 2.3 AXPress 兼容回退
- 若 CDP 与 Unix Socket 均无法触达待处理卡片（如启动时未开启 CDP 调试端口且非本地权限报文），则回退为辅助功能 `AXPress` 操作。
- `AXPress` 只允许作用于当前前台 ChatGPT 窗口中由 macOS 标记为可见、且位于聚焦窗口范围内的授权按钮。禁止搜索或按下虚拟列表中不可见的旧会话元素，因为这会让 ChatGPT 恢复旧路由并打断用户正在输入的新会话。
- 后台窗口、隐藏会话和队列任务只通过 IPC 处理。任务队列与通用确认共用同一个 ChatGPT 实例，但队列只操作由 ChatGPT `show:false` 预热机制创建、从未显示且不获取焦点的独立 renderer；不得新开第二个实例，也不得以辅助功能操作替代隐藏页面隔离。

---

## 3. 任务分解与自动化回归验证 (Task List & Verification)
1. **编译与回归现存测试**：确保原有模块及基础协议无任何破坏。
2. **Swift 源码 IPC 改造**：在 `native/IPCAndCDP.swift` 及相关原生模块中完备集成 `UnixIPCClient` 与 `CDPClient`，支持双通道检查与确认。
3. **安全与隐私脱敏机制**：JS 注入逻辑通过 Hash 截断与严格匹配，对任意 API Token 与卡片敏感正文完全屏蔽。
4. **全自动化集成回归测试**：运行 `npm test` 验证包括 mock CDP + Mock Unix IPC 结合的主路径验证，15 项测试 100% 通过。
5. **实时验证报告**：针对本地真实 `~/.codex/ipc/ipc.sock` 运行 `status`，确认 `clientId` 分配及 `IPC 主路径` / `AXPress 兼容回退` 架构状态准确无误。
