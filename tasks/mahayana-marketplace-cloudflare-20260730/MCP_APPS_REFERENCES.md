# MCP Apps 与 Cloudflare 无状态 MCP 官方资料

本文件只列实施时允许作为协议事实依据的官方资料。不得继续引用不存在或未正式发布的 MCP 版本号。

## 1. MCP Apps 官方规范

官方仓库：

- https://github.com/modelcontextprotocol/ext-apps

稳定规范：

- https://github.com/modelcontextprotocol/ext-apps/blob/main/specification/2026-01-26/apps.mdx

官方概览：

- https://github.com/modelcontextprotocol/ext-apps/blob/main/docs/overview.md

当前确认事实：

- MCP Apps 是核心 MCP 的正式扩展；
- 稳定规范版本为 `2026-01-26`；
- 扩展标识为 `io.modelcontextprotocol/ui`；
- UI resource 使用 `ui://`；
- MIME 为 `text/html;profile=mcp-app`；
- View 与 Host 通过 MCP JSON-RPC over `postMessage` 通信；
- Host 必须 sandbox iframe 并执行声明式 CSP；
- Tool visibility 区分 `model` 与 `app`；
- Tool 必须提供有意义的文本/结构化结果，UI 是同一新标准内的丰富呈现。

SDK 包：

- `@modelcontextprotocol/ext-apps`
- `@modelcontextprotocol/ext-apps/react`
- `@modelcontextprotocol/ext-apps/app-bridge`
- `@modelcontextprotocol/ext-apps/server`

实施时锁定已验证的精确版本，并记录升级依据。

## 2. Cloudflare MCP handler

官方文档：

- https://developers.cloudflare.com/agents/model-context-protocol/apis/handler-api/
- https://developers.cloudflare.com/agents/model-context-protocol/guides/migrate-to-mcp-sdk-v2/
- https://developers.cloudflare.com/agents/model-context-protocol/guides/remote-mcp-server/

当前确认事实：

- `createMcpHandler` 来自 `agents/mcp/server`；
- 使用 `@modelcontextprotocol/server` SDK v2 server factory；
- `McpAgent` 已弃用并 feature-frozen；
- `createLegacyMcpHandler` 只用于临时迁移；
- `legacy` 选项支持 `"stateless" | "reject"`；
- 大乘生产必须设置 `legacy: "reject"`；
- handler 每个请求创建独立 server；
- 应用数据可以放在 D1、KV、Durable Object 或其他持久层，但不能作为 MCP session；
- 浏览器 Origin、Host 和 OAuth 仍需单独验证；
- 实施时使用 Cloudflare 文档要求的精确 MCP SDK 版本。

参考配置：

```ts
const handler = createMcpHandler(createServer, {
  route: "/mcp",
  legacy: "reject",
  responseMode: "json",
  allowedHostnames: ["plugin.example.com"],
  allowedOriginHostnames: ["app.mahayana.example"],
});
```

## 3. 当前大乘代码审计入口

- Web 小程序宿主：`frontend/apps/web/src/app/miniapps/[id]/McpPluginApp.tsx`
- 大乘自定义 SDK：`frontend/packages/mcp-app-sdk/`
- Flutter 小程序模型：`fabushi/lib/models/mini_app_model.dart`
- Flutter registry：`fabushi/lib/services/mini_app_registry_service.dart`
- 本地插件发现：`fabushi/lib/services/codex_plugin_catalog_io.dart`
- 市场发布接口：`fabushi/web/src/handlers/marketplace.js`

实施开始时必须重新搜索并删除生产用途中的：

- `mcp-2025-06-18`
- `Mcp-Session-Id`
- `createLegacyMcpHandler`
- `McpAgent`
- `WorkerTransport`
- SDK v1 server imports
- GET/DELETE MCP session routes
- 自定义 iframe bridge 消息

## 4. 版本事实校正

不得把 Cloudflare 文档在 2026 年 7 月的 SDK/handler 更新日期误写成 MCP Apps 规范版本。任务采用的正式组合是：

```text
MCP Apps stable specification: 2026-01-26
Cloudflare stateless MCP handler: current SDK v2 implementation
Production legacy mode: reject
```

若官方后续发布新的稳定 MCP Apps 规范，实施 Action 必须先记录差异、更新任务版本并重新审核，不能静默切换。