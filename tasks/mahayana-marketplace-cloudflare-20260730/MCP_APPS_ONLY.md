# 大乘小程序 MCP Apps 全量新架构

## 文档地位

本文件是任务 `mahayana-marketplace-cloudflare-20260730` 的最高优先级 MCP Apps、Host 与旧协议删除约束。运行位置、安装包和跨平台 Runtime Profile 以 `LOCAL_FIRST_MCP_APPS.md` 为最高优先级依据。

目标是把大乘小程序全部迁移到官方 MCP Apps，同时保留并强化本地安装、本地执行和独立运行能力。MCP Apps 不是云端运行要求；Server 可以由本地 stdio、移动端内嵌 Core、Web Local Agent 或可选远程无状态 HTTP 提供。

## 1. 唯一 UI 技术基线

采用官方 MCP Apps 稳定规范 `2026-01-26`：

- 扩展标识：`io.modelcontextprotocol/ui`；
- UI 资源：`ui://`；
- MIME：`text/html;profile=mcp-app`；
- Tool 通过 `_meta.ui.resourceUri` 关联 UI；
- View 与 Host 使用标准 MCP JSON-RPC over `postMessage`；
- Host 使用 AppBridge 或规范一致实现；
- iframe/WebView 必须 sandbox；
- CSP 必须按资源声明生成并执行；
- Tool visibility 区分 `model` 与 `app`；
- 支持 host context、display modes、resource teardown 和审计；
- Tool 返回有意义的 `content` 和 `structuredContent`。

## 2. 支持的 Runtime Profiles

### 桌面与 CLI 本地 Runtime

```text
MCP Apps Host
→ 启动已安装插件目录中的签名 CLI/runtime
→ MCP stdio
→ resources/read(ui://...)
→ AppBridge 渲染
```

要求：

- 本地 stdio 是桌面/CLI 本地能力型插件的首选；
- stdout 只输出 MCP JSON-RPC，日志走 stderr；
- Runtime 从已验证版本目录启动；
- 子进程环境和权限最小化；
- 可通过 `mahayana plugin run <id>` 在独立 MCP Apps Shell 中运行；
- 聊天内嵌和独立窗口使用相同 UI、Tool、权限与审计。

### 移动端内嵌 Runtime

移动插件安装 UI、manifest、Tool schema、工作流和静态资源；系统级能力由随大乘 App 发布的 Rust Mahayana Core/Flutter FFI Provider 提供。移动端不得默认下载执行任意第三方原生二进制。

### Web Local Agent

普通桌面浏览器通过 origin-bound、仅 loopback、短期配对授权的 Mahayana Local Agent 或浏览器 native messaging 调用本机 MCP Runtime。没有 Local Agent 时不得假装本地能力可用。

### 可选远程 Runtime

远程 Profile 如存在必须使用 SDK v2 无状态 HTTP。Cloudflare 推荐：

```text
agents/mcp/server createMcpHandler
@modelcontextprotocol/server 2.x factory
legacy: "reject"
```

local-only 插件不得被强制提供远程 endpoint。

## 3. 明确禁止的旧实现

生产代码、模板、部署、市场准入和验收中禁止：

- `createLegacyMcpHandler`；
- `McpAgent`；
- `@modelcontextprotocol/sdk` v1 server；
- `WorkerTransport`；
- MCP transport session store；
- `Mcp-Session-Id`；
- sticky session；
- HTTP GET/DELETE 管理 MCP 会话；
- 旧长期 session SSE；
- legacy production route；
- 旧 `mcp-2025-06-18` Host fallback；
- 大乘自定义 iframe ready/tool/result 消息方言；
- 为旧客户端保留兼容执行；
- 市场接受只含旧 MCP manifest 的新版本。

旧客户端收到：

```json
{
  "error": "MCP_APPS_HOST_UPGRADE_REQUIRED",
  "minimumHostVersion": "<required-version>",
  "documentation": "<upgrade-doc-url>"
}
```

## 4. 统一架构边界

```text
Cloudflare/Marketplace Control Plane
  ├── signed immutable package
  ├── identity/review/provenance/revocation
  └── optional remote edge profile

Installed Mahayana MCP App
  ├── ui:// MCP Apps View
  ├── runtime profiles
  ├── permissions
  └── local data/resources

Shared MCP Apps Host Core
  ├── AppBridge/sandbox/CSP
  ├── permission broker
  ├── runtime resolver
  └── Web/Desktop/Mobile/CLI adapters

Execution
  ├── desktop/CLI stdio
  ├── mobile in-process Mahayana Core
  ├── desktop web Local Agent
  └── optional remote stateless HTTP
```

## 5. Host 全量迁移

Web、桌面、移动和 CLI 必须统一为共享 MCP Apps Host Core，至少实现：

- MCP Apps extension capability；
- AppBridge；
- `ui/initialize` 和 initialized 通知；
- `tools/call`、`resources/read`、`notifications/message`；
- `ui/open-link`、`ui/resource-teardown`；
- theme、locale、timezone、platform、viewport；
- inline、fullscreen、picture-in-picture；
- model/app visibility；
- sandbox、CSP、Origin、导航和下载策略；
- 权限确认和审计；
- 版本化 UI resource cache；
- Runtime Resolver 和执行位置提示。

`ui/initialize` 是 MCP Apps View 与 Host 的标准握手，不等于旧 MCP transport session 初始化。

必须删除旧 session client、长期 GET/SSE listener、DELETE session、自定义 iframe schema 和旧 hostApiVersion fallback。

## 6. 插件全量迁移

所有官方插件和验收插件必须：

1. Tool 注册 `_meta.ui.resourceUri`；
2. 注册对应 `ui://` resource；
3. 使用 `text/html;profile=mcp-app`；
4. View 使用官方 MCP Apps SDK；
5. 通过 Host/AppBridge 调用 Tool；
6. 最小 CSP；
7. 正确区分 app-only/model-only Tool；
8. 返回文本和结构化结果；
9. 声明 Runtime Profiles、平台、权限和执行位置；
10. 不发布旧 bridge runtime。

未迁移版本标记 `migration_required`，不能进入 `community`、`verified`、`official` 或 production，也不能被新 Host 执行。

## 7. 市场准入契约

正式版本必须声明：

```json
{
  "runtime": {
    "kind": "local-only | local-first | hybrid | remote-only",
    "profiles": [],
    "legacy": false,
    "extension": "io.modelcontextprotocol/ui"
  },
  "ui": {
    "resources": ["ui://io.mahayana.publisher.plugin/main"],
    "mimeTypes": ["text/html;profile=mcp-app"],
    "displayModes": ["inline", "fullscreen"]
  }
}
```

市场按 Profile 验证：

- desktop stdio conformance；
- mobile embedded capability contract；
- Web Local Agent loopback security；
- remote SDK v2/stateless/legacy rejection（仅存在远程 Profile 时）；
- UI resource、MIME、CSP、visibility、权限、签名和不可变发布物。

拒绝：旧 SDK、无 `ui://`、自定义 bridge、依赖 MCP Session ID、过宽 CSP、未声明本地能力或 production 远程入口允许 legacy。

## 8. 业务状态与长任务

业务状态使用显式 `taskId`、`draftId`、`workspaceId`、`deviceId`、resource URI 或本地数据库主键。可以使用本地数据库、D1、KV、Durable Object、Queue 或 Workflow，但不得用于恢复旧 MCP transport session。

需要用户输入时使用显式无状态多轮请求和完整性保护的 `requestState`；长任务使用明确 task/workflow 生命周期。

## 9. 硬切换策略

1. 建共享 MCP Apps Host Core 和 Runtime Resolver；
2. 建本地安装、Supervisor、移动 Capability Provider 和 Web Local Agent；
3. 迁移全球法布施、ChatGPT 自动确认及全部官方插件；
4. 新模板和市场只接受 MCP Apps Runtime Profiles；
5. 完成桌面、移动、Web、CLI 与必要 Cloudflare 验收；
6. 一次性切换 production；
7. 删除旧 SDK、旧 session、旧 bridge、旧 route 和旧测试；
8. 旧客户端只返回升级错误。

不允许运行旧 MCP 协议的双栈，但允许同一新 MCP App 声明多个新 Runtime Profile。

## 10. 完成定义

- 所有官方小程序均为可安装 MCP Apps；
- 全球法布施在桌面 stdio、移动嵌入式和 Web Local Agent 场景真实运行；
- ChatGPT 自动确认在桌面本机运行，移动/Web 仅控制配对桌面；
- 新插件模板支持 local-only/local-first/hybrid/remote-only；
- 已安装插件可独立窗口运行；
- Cloudflare 中断不影响已安装 local-only 插件基础启动；
- 市场不强制本地插件提供远程 endpoint；
- 新 Host 不包含旧 session transport；
- 自定义 iframe bridge 和旧运行路由已删除；
- GitHub Actions、真实安装包和跨平台运行证据完整。