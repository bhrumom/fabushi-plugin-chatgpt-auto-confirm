# 技术设计：本地优先 MCP Apps 大乘小程序系统

## 1. 总体架构

```text
                     大乘市场与可信发布控制平面
┌────────────────────────────────────────────────────────────┐
│ Identity / Review / OIDC / Provenance / Signing / Update  │
│ Runtime Profiles / Permissions / Revocation / Rollback    │
└─────────────────────────────┬──────────────────────────────┘
                              │ signed immutable package
                              ▼
┌────────────────────────────────────────────────────────────┐
│ 本地安装的 Mahayana MCP App                                │
│ ui:// resources / manifests / skills / runtime profiles   │
└─────────────────────────────┬──────────────────────────────┘
                              ▼
┌────────────────────────────────────────────────────────────┐
│ 共享 MCP Apps Host Core                                    │
│ AppBridge / sandbox / CSP / permission broker             │
│ runtime resolver / local data isolation / audit           │
└───────┬─────────────────┬──────────────────┬───────────────┘
        │                 │                  │
        ▼                 ▼                  ▼
 desktop/CLI stdio   mobile in-process   Web Local Agent
 local CLI runtime   Mahayana Rust Core  loopback/native msg
        │                 │                  │
        └─────────────────┴──────────────────┘
                    optional remote-edge
             createMcpHandler + SDK v2 + legacy reject
```

MCP Apps 统一 UI 与 Host 通信；Runtime 可以本地或远程。默认本地优先。

## 2. 安装包格式

```text
<plugin>/
├── .codex-plugin/plugin.json
├── .mcp.json
├── mahayana.runtime.json
├── mahayana.permissions.json
├── ui/
├── runtime/
│   ├── cli/
│   ├── workflows/
│   └── resources/
├── skills/
├── provenance.json
└── signatures/
```

要求：

- UI resource 与 Runtime 可独立版本化但必须同一 release 签名；
- package manifest 声明 Runtime Profiles、平台和优先级；
- 本地二进制按平台/架构列出并校验哈希；
- 移动端 Profile 不能引用下载的任意原生二进制；
- 所有资源从已验证版本目录读取。

## 3. MCP Apps Host Core

共享核心负责：

- `io.modelcontextprotocol/ui` capability；
- `ui://` resource discovery/read/cache；
- AppBridge；
- `ui/initialize`、tool input/result、open-link、teardown；
- sandbox、CSP、Origin、导航、下载策略；
- model/app Tool visibility；
- Runtime Resolver；
- 权限 broker；
- local data directory；
- process lifecycle；
- execution-location UI；
- audit events。

平台 Adapter：

- Desktop：原生窗口/WebView、stdio process supervisor；
- CLI：headless Host 或独立 App Shell；
- Mobile：Flutter WebView + Rust Core FFI；
- Web：browser Host + Local Agent connector。

## 4. Runtime Resolver

输入：

- 当前平台；
- 已安装 Profile；
- Host capabilities；
- 用户授权；
- Local Agent 配对状态；
- 网络状态；
- 插件策略。

选择顺序：

```text
desktop/CLI local stdio
→ mobile embedded Mahayana Core
→ paired Local Agent
→ explicitly allowed remote-edge
→ unsupported
```

规则：

- 本地 Profile 可用时不得静默选择远程；
- Profile 切换必须写审计；
- 用户可禁止 remote fallback；
- UI 显示“本机/移动内核/配对设备/云端”；
- local-only 不允许 remote fallback。

## 5. 桌面 stdio Runtime

现有插件已经以 `.mcp.json` 声明 `type: stdio` 并调用随包 CLI，应保留并升级为标准 MCP Apps。

生命周期：

```text
install
→ verify executable/hash/platform
→ spawn with minimal environment
→ MCP stdio initialize/capability negotiation
→ tools/resources
→ AppBridge View
→ graceful stop/forced cleanup
```

安全：

- command 必须位于版本目录并在 manifest 中签名；
- 禁止任意 shell 拼接；
- 工作目录固定为插件目录；
- Secret 通过按需 broker 注入；
- stdout 仅 MCP；
- stderr 日志脱敏；
- 后台进程 PID、版本、权限和状态可审计；
- 卸载和撤销必须停止进程。

## 6. 独立 App Shell

`mahayana plugin run <id>` 启动轻量 MCP Apps Host 窗口：

- 不需要进入聊天；
- 使用同一 Host Core；
- 连接同一本地 Runtime；
- 共享插件数据和权限；
- 支持托盘、后台运行和深链；
- 关闭窗口不一定终止后台任务，由插件生命周期策略决定。

## 7. 移动端内嵌 Core

移动端 Runtime 由大乘 App 内置 Rust Core 实现，插件只安装 MCP Apps UI、声明式逻辑与资源。

建议 Capability Provider 接口：

```text
share.send
share.prepare
local.queue.create
local.queue.status
local.database.query
notifications.schedule
network.fetchApproved
account.getSession
files.readScoped
pairedDevice.call
```

实现：

- Flutter 通过 FFI 调用 Rust Core；
- Core 暴露 MCP Tool adapter；
- Host 与 Core 可使用 in-process transport，但保持同一 JSON-RPC Tool/Resource 语义；
- 每个插件独立 data root、Secret namespace 和权限；
- 下载包不得注入新的原生动态库。

## 8. Web Local Agent

### 连接方式

```text
Web MCP Apps Host
→ pairing challenge
→ http://127.0.0.1:<random>/mcp or browser native messaging
→ Mahayana Local Agent
→ local Runtime Supervisor
```

安全：

- 只监听 loopback；
- 随机端口或注册 native host；
- origin allowlist，不允许 `*` CORS；
- 用户在本机确认配对；
- 短期 token 与设备密钥；
- 校验 origin、插件 ID、用户、Profile 和权限；
- 防 DNS rebinding、CSRF、恶意网页扫描和端口劫持；
- 连接断开时撤销临时授权。

移动浏览器无 Local Agent 时深链大乘 App。

## 9. 可选 Remote Edge Profile

只有声明 remote-edge 的插件才部署业务 MCP Runtime：

```ts
createMcpHandler(createServer, {
  route: "/mcp",
  legacy: "reject",
  responseMode: "json"
})
```

要求：

- SDK v2；
- 无旧 Session；
- 显式业务状态；
- 每请求独立 server；
- Origin/Host/OAuth scope 验证；
- 不替代必须本地执行的 Tool。

Cloudflare 仍可托管市场页面、不可变包和更新元数据，即使插件没有远程 Runtime。

## 10. Runtime Manifest

示例：

```json
{
  "schemaVersion": 1,
  "kind": "local-first",
  "extension": "io.modelcontextprotocol/ui",
  "profiles": [
    {
      "id": "desktop-stdio",
      "platforms": ["macos-arm64", "macos-x64", "windows-x64", "linux-x64"],
      "transport": "stdio",
      "command": "runtime/cli/mahayana-plugin",
      "args": ["--plugin", "global-dharma", "mcp-serve"],
      "priority": 300
    },
    {
      "id": "mobile-embedded",
      "platforms": ["ios", "android"],
      "transport": "in-process",
      "provider": "mahayana-core",
      "requiredCapabilities": ["share.send", "local.queue"],
      "priority": 250
    },
    {
      "id": "web-local-agent",
      "platforms": ["web-desktop"],
      "transport": "loopback-http",
      "requiresCompanion": true,
      "priority": 200
    }
  ]
}
```

## 11. 市场准入

市场签名元数据新增：

- runtime kind；
- profiles；
- platform/architecture；
- executable hashes；
- required capabilities；
- local data policy；
- background policy；
- remote fallback policy；
- minimum Host/Core version；
- UI resources/CSP/visibility。

验证矩阵：

- stdio conformance 与 process cleanup；
- mobile capability contract；
- Web Local Agent pairing/security；
- remote stateless conformance（如存在）；
- MCP Apps UI；
- package signature/hash/provenance；
- permission diff；
- install/upgrade/rollback/uninstall。

## 12. 全球法布施映射

```text
Desktop/CLI:
local stdio Runtime → local send queue/account/logs

Mobile App:
local MCP App UI → Mahayana Core share.send/local.queue

Desktop Web:
MCP App UI → Local Agent → local Runtime
```

基础 UI、配置和队列查看应可离线；真正发送按目标平台网络状态执行。

## 13. ChatGPT 自动确认映射

```text
Desktop only:
MCP App UI → local stdio Runtime → local ChatGPT renderer/accessibility

Mobile/Web:
MCP App UI → paired-device control → selected desktop Runtime
```

必须显示执行设备。没有配对桌面时不显示虚假的可执行状态。

## 14. 本地数据与升级

目录：

```text
plugins/<pluginId>/
├── versions/<version>/<sha>/
├── current
├── data/
├── logs/
└── runtime-state.json
```

- 版本目录不可变；
- data 与版本分离；
- 升级前执行显式数据迁移；
- 失败回滚 current；
- 后台 Runtime 切换前停止旧版本；
- 撤销版本禁止新启动；
- 卸载按用户选择保留或删除数据。

## 15. 旧实现删除

仍必须删除：

```text
Mcp-Session-Id
旧 GET/SSE/DELETE session
SDK v1 server
createLegacyMcpHandler
McpAgent
WorkerTransport
custom iframe bridge
mcp-2025-06-18 fallback
```

本地 stdio 是标准 MCP transport，不属于旧 Session 兼容层。

## 16. 实施顺序

1. 定义 Runtime Manifest/Profile schema；
2. 建共享 Host Core 和 Resolver；
3. 建 desktop stdio Supervisor 与独立 App Shell；
4. 建 mobile Mahayana Core capability adapter；
5. 建 Web Local Agent 与配对协议；
6. 迁移全球法布施；
7. 迁移 ChatGPT 自动确认；
8. 迁移其他官方插件；
9. 更新市场、发布器、模板和安装器；
10. 完成跨平台 E2E；
11. 硬切换并删除旧实现。