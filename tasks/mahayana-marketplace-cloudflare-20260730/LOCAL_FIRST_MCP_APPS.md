# 本地优先 MCP Apps：大乘小程序统一运行架构

## 文档地位

本文件是任务 `mahayana-marketplace-cloudflare-20260730` 的最高优先级运行时约束。

`MCP_APPS_ONLY.md` 负责规定 UI、Host、安全桥接和旧协议删除；本文件负责规定小程序如何安装到本地并在桌面、移动端和 Web 场景执行。其他文档中“所有插件必须把业务 Runtime 部署到 Cloudflare”的表述与本文件冲突时，以本文件为准。

核心结论：

> MCP Apps 是统一 UI 与 Host 通信标准，不是云端运行要求。大乘小程序默认采用本地优先执行；Cloudflare 负责市场、签名发布物、下载更新和可选远程能力，不强制承载每个插件的业务执行。

## 1. 一个小程序的统一组成

每个大乘小程序是一个可安装、签名、版本化的 MCP App 包：

```text
Mahayana MCP App package
├── .codex-plugin/plugin.json
├── .mcp.json
├── mahayana.runtime.json
├── mahayana.permissions.json
├── ui/
│   ├── index.html
│   ├── assets/
│   └── MCP Apps View code
├── runtime/
│   ├── cli/                  desktop/CLI local runtime
│   ├── workflows/            declarative local workflows
│   └── optional resources
├── skills/
├── provenance.json
└── signatures/
```

包中的 UI 必须是标准 MCP Apps：

- `io.modelcontextprotocol/ui`；
- `ui://` resource；
- `text/html;profile=mcp-app`；
- `_meta.ui.resourceUri`；
- AppBridge；
- sandbox 和 CSP；
- model/app tool visibility。

运行时可以是本地、远程或混合，但 UI 和工具契约保持同一套 MCP Apps 标准。

## 2. Runtime Profile

每个插件必须显式声明一个或多个 Runtime Profile，Host 按平台、权限和优先级选择。

```json
{
  "runtime": {
    "kind": "local-first-mcp-app",
    "profiles": [
      {
        "id": "desktop-stdio",
        "platforms": ["macos", "windows", "linux", "cli"],
        "transport": "stdio",
        "command": "./runtime/cli/mahayana-plugin",
        "args": ["mcp-serve"],
        "priority": 300
      },
      {
        "id": "mobile-embedded",
        "platforms": ["ios", "android"],
        "transport": "in-process",
        "provider": "mahayana-core",
        "requiredCapabilities": ["share.send", "local.queue", "local.database"],
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
}
```

可选远程 Profile：

```json
{
  "id": "remote-edge",
  "platforms": ["web", "mobile", "desktop", "cli"],
  "transport": "stateless-http",
  "url": "https://plugin.example.workers.dev/mcp",
  "legacy": false,
  "priority": 100
}
```

远程 Profile 只能作为插件明确声明的同步、协作、后台任务或降级能力，不能替代必须在用户设备上执行的本地工具。

## 3. 桌面端与 CLI

桌面端和 CLI 是本地小程序的完整能力平台。

### 启动方式

```text
安装签名插件包
→ Host 选择 desktop-stdio
→ 启动随包 Mahayana CLI/plugin runtime 子进程
→ 通过标准 MCP stdio 通信
→ resources/read 获取本地 ui:// resource
→ AppBridge 渲染本地 MCP App View
```

官方 MCP Apps 示例已经使用本地 stdio Server；因此本地 MCP Server 与 MCP Apps 完全兼容。

要求：

- Runtime 从已验证版本目录启动；
- command 不接受插件任意绝对路径；
- stdout 只传输 MCP JSON-RPC；
- stderr 用于本地日志；
- 子进程继承最小环境变量；
- 文件、浏览器自动化、系统命令、辅助功能等权限由 Host broker 授予；
- UI 不能直接执行本地命令，只能调用获准的 MCP Tool；
- 插件可由大乘桌面 Host 启动，也可通过 `mahayana plugin run <id>` 独立启动窗口。

### 独立运行

“独立运行”不是绕开 MCP Apps，而是启动一个轻量的大乘 MCP Apps Shell：

```text
mahayana plugin run global-dharma
  → Local Runtime Supervisor
  → MCP Apps Host Window
  → local stdio MCP Server
  → local ui:// View
```

同一 UI、Tool、权限和审计逻辑同时服务聊天内嵌模式与独立窗口模式。

## 4. 移动端

移动端不能照搬桌面“下载任意原生二进制并执行”的模型。iOS 和 Android 的平台安全与商店政策都对动态下载执行代码有严格限制。

因此移动端采用：

```text
MCP App UI + declarative plugin assets
        │
        ▼
大乘 App 内置 Mahayana Core（Rust/Flutter FFI）
        │
        ├── share.send
        ├── local.queue
        ├── local.database
        ├── notifications
        ├── account/session
        ├── approved network access
        └── platform-specific capabilities
```

插件安装包在移动端可以下载：

- MCP Apps HTML/CSS/JS 视图；
- manifest；
- Tool schema；
- 工作流和规则数据；
- Skills、模板、提示词和静态资源；
- 签名配置和权限声明。

移动端不得默认下载并执行第三方原生二进制。插件的本地能力通过预先随大乘 App 发布的 `mahayana-core` Capability Provider 实现。

如果某个新插件需要尚未存在的系统级能力：

- 先扩展大乘 Core 并通过 App Store/Play 更新发布；
- 插件随后声明并调用该 capability；
- 不通过插件包偷偷下载新的原生代码。

这让未来大量本地小程序可以安装，而不让每个插件携带一套不受控的移动端二进制。

## 5. Web 场景

必须区分两种“Web”：

### 5.1 大乘 App 内的本地 WebView

这是移动端和桌面端 App 的本地网页 UI：

- `ui://` resource 从已安装插件目录读取；
- WebView/iframe 在本机渲染；
- AppBridge 把 Tool 调用交给本机 Mahayana Core；
- 数据发送和本地数据库操作都在设备上执行。

该模式完全满足“通过本地网页运行，但能力在本地执行”。

### 5.2 普通浏览器中的公开 Web

普通网页不能直接启动任意本机 CLI。要调用本地能力，必须安装大乘 Local Agent/桌面应用或浏览器扩展。

推荐链路：

```text
Mahayana Web Host
→ origin-bound local bridge
→ 127.0.0.1 随机端口 / browser native messaging
→ Mahayana Local Agent
→ local MCP runtime
```

安全要求：

- 仅监听 loopback；
- 首次配对显示本地确认；
- 每个浏览器 origin 独立授权；
- 使用短期 challenge/token；
- 禁止通配 CORS；
- 验证 Host、Origin、插件 ID、用户和权限；
- 网页不能直接调用任意本地命令；
- 未安装 Local Agent 时显示“在大乘 App 中打开”或安装指引。

移动浏览器通常不能提供完整本地 CLI 能力；本地执行模式应深链打开大乘移动 App。

## 6. 全球法布施小程序

全球法布施应实现为 `local-first-mcp-app`。

### 桌面/CLI

- 安装包包含本地 Mahayana CLI Runtime；
- Host 通过 stdio 启动；
- 发送队列、账号状态、本地日志和数据准备都在本机；
- MCP App UI 展示状态、配置、进度和确认；
- 可独立窗口运行；
- Cloudflare 只负责市场元数据、安装包、更新和可选同步。

### 移动端

- UI 从本地插件包加载到 WebView；
- 发送能力由 App 内置 Rust Core 的 `share.send`、队列和账号能力提供；
- 插件只负责 MCP Tool 编排与 UI；
- 敏感数据不必上传到插件服务端。

### 普通 Web

- 桌面浏览器通过 Local Agent 调用本机 Runtime；
- 没有 Local Agent 时不能假装在服务端完成本地发送；
- 手机浏览器引导打开大乘 App。

## 7. ChatGPT 自动确认小程序

ChatGPT 自动确认依赖桌面 ChatGPT renderer、浏览器自动化、辅助功能或本机后台进程，因此它是明确的 `desktop-local-only` MCP App。

```json
{
  "runtime": {
    "kind": "local-first-mcp-app",
    "profiles": [
      {
        "id": "desktop-stdio",
        "platforms": ["macos", "windows", "linux"],
        "transport": "stdio",
        "requiredCapabilities": [
          "desktop.accessibility",
          "browser.automation",
          "local.background-process"
        ]
      }
    ]
  }
}
```

移动端和 Web 可以：

- 查看本机或已配对桌面的状态；
- 向已配对桌面提交任务；
- 查看日志和审批结果。

但真正的自动确认必须在拥有目标 ChatGPT 实例的桌面设备上执行，不能声称在手机或纯云端完成。

## 8. Host Runtime Resolver

Host 按以下顺序选择 Runtime：

```text
1. 已安装且平台匹配的本地 Profile
2. 当前 App 内可提供的 embedded capability Profile
3. 已配对的 Local Agent Profile
4. 插件明确允许的 remote-edge Profile
5. 无可用 Profile → 显示平台不支持/需要安装配套运行时
```

本地优先意味着只要本地 Profile 可用，就不能静默切换到远程 Profile。

用户必须能看到当前执行位置：

```text
本机执行
大乘移动内核执行
已配对设备执行
云端执行
```

## 9. 市场和发布模型

所有已发布插件仍通过市场和发布清单声明的受信任 artifact provider 获得（现有 Cloudflare 分发可继续保留）：

- 签名版本元数据；
- 不可变安装包 URL；
- SHA-256、大小和 provenance；
- 权限、Runtime Profile 和平台支持；
- 撤销、封禁、升级和回滚状态。

但市场不得要求本地型插件提供远程 MCP endpoint。

市场分类：

```text
local-only
local-first
hybrid
remote-only
```

准入验证分别执行：

- local stdio conformance；
- embedded capability contract；
- local-agent loopback security；
- remote stateless HTTP conformance（仅有远程 Profile 时）；
- MCP Apps UI、CSP、权限、签名和安装安全。

## 10. 权限模型

统一权限清单至少覆盖：

```text
local.filesystem
local.database
local.background-process
desktop.accessibility
browser.automation
share.send
network.domains
secrets.named
notifications
paired-device.control
```

规则：

- 默认拒绝；
- 安装时展示；
- 首次实际使用高风险能力时再次确认；
- 权限扩大必须重新确认；
- App View 只能调用声明为 app-visible 且已授权的 Tool；
- 每个插件的数据目录、Secret 和 Local Agent token 隔离。

## 11. 验收要求

至少完成：

### 全球法布施

- 桌面安装并通过 stdio 本地运行；
- 独立窗口启动；
- 本地 UI resource 渲染；
- 本机发送能力真实执行；
- 移动端通过嵌入式 Mahayana Core 执行同一 Tool 契约；
- 普通 Web 通过 Local Agent 执行；
- 断网状态下仍能打开 UI 和查看本地队列；
- 未授权发送时拒绝。

### ChatGPT 自动确认

- 桌面安装并启动本地后台 Runtime；
- MCP App UI 控制启动、停止、任务和日志；
- 自动确认真实作用于本机 ChatGPT 实例；
- 移动/Web 不错误地在本地运行桌面专属能力；
- 通过配对桌面查看和控制时明确显示执行设备。

### 通用

- 同一个插件包声明多个 Runtime Profile；
- Runtime Resolver 选择正确；
- 本地 Profile 可用时不静默走云端；
- 本地包签名、哈希、权限和原子安装通过；
- 卸载停止后台进程并清理授权；
- 旧版本回滚不破坏本地数据；
- Cloudflare 中断不影响已安装本地小程序的基础启动。

## 12. 非目标与禁止项

- 不把 MCP Apps 等同于 Cloudflare Runtime；
- 不强制 local-only 插件建设远程 MCP endpoint；
- 不让普通网页未经本地代理直接执行本机命令；
- 不在移动端下载执行任意第三方原生二进制；
- 不把敏感本地发送数据强制上传到插件云端；
- 不为兼容本地能力恢复旧 MCP Session 协议；
- 不允许 UI 绕开 Host permission broker。
