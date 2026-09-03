# 单一小程序、多构件 MCP App 发布模型

## 文档地位

本文件是任务 `mahayana-marketplace-cloudflare-20260730` 的最高优先级构件、安装和平台选择约束。

它建立在以下约束之上：

1. `MCP_APPS_ONLY.md`：统一 MCP Apps UI、Host、安全和旧协议删除；
2. `LOCAL_FIRST_MCP_APPS.md`：本地优先执行；
3. `LOCAL_WEB_MCP_RUNTIME.md`：移动端与 Web 端使用可热安装的本地网页/WASM Runtime。

核心结论：

> 一个小程序不是多个互不相关的平台版本，而是一个插件身份、一个语义版本、一个 MCP Tool 契约和一套 MCP Apps UI，在同一个签名 Release 中包含多个按平台选择的不可变构件。安装器只下载当前平台真正需要的构件。

## 1. 统一 Release 模型

以全球法布施 `io.mahayana.global-dharma@1.2.0` 为例：

```text
global-dharma 1.2.0 release
├── release-manifest.json
├── common/
│   ├── plugin.json
│   ├── tools.json
│   ├── permissions.json
│   ├── ui/
│   │   ├── index.html
│   │   ├── app.js
│   │   ├── styles.css
│   │   └── assets/
│   ├── skills/
│   └── workflows/
├── artifacts/
│   ├── native-macos-arm64/
│   │   └── global-dharma-cli
│   ├── native-macos-x64/
│   │   └── global-dharma-cli
│   ├── native-windows-x64/
│   │   └── global-dharma-cli.exe
│   ├── native-linux-x64/
│   │   └── global-dharma-cli
│   └── web-wasm/
│       ├── worker.js
│       ├── global_dharma.wasm
│       └── web-adapter.js
├── provenance.json
└── signatures/
```

`common/` 与每个 `artifact` 都有独立 SHA-256、大小、不可变下载 URL 和签名覆盖。父级 Release Manifest 对完整构件图签名。

不得要求移动端下载桌面二进制，也不得要求纯 CLI 环境下载不使用的 UI 大资源。

## 2. 只有一个插件身份和版本

以下信息跨平台保持一致：

- plugin ID；
- semantic version；
- publisher；
- Tool 名称；
- Tool input/output JSON Schema；
- Tool 语义、错误码和权限；
- `ui://` resource identity；
- MCP Apps extension；
- 数据模型版本；
- 发布签名、撤销和审核状态。

例如所有 Runtime 都实现：

```text
global-dharma.send
global-dharma.status
global-dharma.cancel
global-dharma.logs
```

桌面 CLI 和 WebAssembly 可以有不同内部实现，但不得出现同名 Tool 在不同平台行为不一致、参数不一致或权限含义不一致。

## 3. 构件清单

`release-manifest.json` 必须声明可选择构件：

```json
{
  "pluginId": "io.mahayana.global-dharma",
  "version": "1.2.0",
  "common": {
    "url": "https://.../common.tar.gz",
    "sha256": "<sha>",
    "contains": ["manifest", "tools", "ui", "skills", "workflows"]
  },
  "artifacts": [
    {
      "id": "native-macos-arm64",
      "runtime": "desktop-stdio",
      "os": "macos",
      "arch": "arm64",
      "transport": "stdio",
      "url": "https://.../native-macos-arm64.tar.gz",
      "sha256": "<sha>",
      "priority": 300
    },
    {
      "id": "web-wasm",
      "runtime": "local-web",
      "platforms": ["ios", "android", "web", "desktop-webview"],
      "transport": "message-port",
      "url": "https://.../web-wasm.tar.gz",
      "sha256": "<sha>",
      "priority": 250
    }
  ]
}
```

构件条件至少支持：

- platform；
- OS；
- CPU architecture；
- Host version；
- MCP Apps version；
- WebAssembly features；
- required capabilities；
- transport；
- sandbox requirements；
- optional/fallback status。

## 4. 平台安装选择

### 桌面 App

默认安装：

```text
common UI + 当前 OS/CPU 的 native CLI artifact
```

运行：

```text
MCP Apps UI
→ AppBridge
→ Desktop MCP Host
→ stdio
→ global-dharma-cli
```

桌面端不是“只有 CLI、没有 MCP App UI”。CLI 是业务 Runtime；界面仍可使用同一套本地 MCP Apps UI。CLI 也可以在无 UI 场景直接使用。

如果插件明确允许，可额外把 `web-wasm` 作为轻量 fallback，但本地 native Profile 可用时优先使用 native CLI。

### 纯 CLI 环境

默认只安装：

```text
common manifest/tools/skills + 当前 OS/CPU native CLI artifact
```

UI 可标记为非必需构件，避免无头服务器下载 UI 资源。

### iOS / Android

默认安装：

```text
common UI + web-wasm artifact
```

运行：

```text
本地 MCP Apps UI
→ AppBridge
→ Mobile MCP Host
→ MessagePort / Worker
→ local web runtime
→ WebAssembly + web adapter
```

移动端不下载桌面 CLI 二进制。网页、Worker、WASM 和允许的普通网络逻辑可随插件版本独立热更新。

### 普通 Web / PWA

默认安装或缓存：

```text
common UI + web-wasm artifact
```

使用 Service Worker、Cache Storage、IndexedDB 或 OPFS 保存；若浏览器清理存储，按签名 Release Manifest 恢复构件。

## 5. 同源代码，多目标编译

推荐把可共享业务核心写成 Rust：

```text
Rust shared core
├── cargo build --target native
│   └── global-dharma-cli
└── wasm build
    └── global_dharma.wasm
```

但不强制所有网页逻辑都进入 WASM。浏览器能力通常通过 `web-adapter.js` 提供：

- `fetch`；
- IndexedDB/OPFS；
- Web Crypto；
- Worker 生命周期；
- 浏览器网络和流式接口。

推荐边界：

```text
Rust/WASM：规则、队列状态机、数据验证、Tool 核心语义
JavaScript adapter：浏览器 API、网络、存储和 MessagePort
Native CLI adapter：stdio、系统存储、原生网络和后台生命周期
```

所有适配器必须通过相同 Tool Contract Test。

## 6. 全球法布施

全球法布施 Release 同时包含：

- 桌面原生 CLI 构件；
- 本地 MCP Apps UI；
- Web Worker + WebAssembly 构件；
- 相同 `send/status/cancel/logs` Tool Contract；
- 相同权限与状态迁移定义。

桌面安装：

```text
common + native-<os>-<arch>
```

移动/Web 安装：

```text
common + web-wasm
```

移动端用户点击“发送”或在对话框发送指令时，最终都调用本地 `global-dharma.send`。移动端 Host 把调用路由给本地 Worker/WASM；桌面 Host 把同一调用路由给本地 CLI。

如果发送逻辑需要普通 HTTPS API，Web Runtime 可直接在权限和域名 allowlist 内调用。长期 Secret 不得进入 WASM 或安装包，必须由 Host 提供短期授权句柄或受控网络代理。

## 7. 平台 Resolver

安装前：

1. 读取签名 Release Manifest；
2. 识别 Host platform、OS、architecture 和 capabilities；
3. 过滤不兼容构件；
4. 选择最高优先级 Runtime；
5. 计算最小下载集合；
6. 展示下载大小、执行位置和权限；
7. 下载并逐构件校验；
8. staging 验证；
9. 原子激活完整构件集合。

运行时不得临时下载未在当前已批准 Release 中声明的代码。

## 8. 更新、回滚和撤销

更新是一个 Release 的构件图原子切换：

```text
1.2.0 common + selected artifact
→ 下载 1.3.0 common + matching selected artifact
→ 分别校验全部 SHA/签名
→ Tool conformance smoke test
→ 数据迁移预检
→ 原子切换
```

禁止出现 UI 已更新到 `1.3.0`、CLI/WASM 仍为 `1.2.0` 的混合激活状态，除非 Release Manifest 明确声明并验证兼容范围。

回滚必须恢复同一 Release 对应的完整构件集合。撤销任一强制构件即撤销该平台上的整个 Release。

## 9. 非全平台插件

一个插件可以只提供部分构件。例如 ChatGPT 自动确认只提供桌面 native CLI：

```text
supported: macOS desktop
unsupported: iOS / Android / ordinary Web
```

市场和 Host 必须明确显示不支持，不得因为缺少 `web-wasm` 构件而伪造移动端执行。

因此“单一小程序、多构件”不等于每个小程序必须支持所有平台；它只要求所有受支持平台属于同一个插件身份、版本和 Tool 契约。

## 10. 市场与验收

市场必须验证：

- 父 Release Manifest 签名；
- 每个构件 SHA、大小、来源和不可变 URL；
- 构件条件不存在重叠歧义；
- 不会向平台下发不兼容二进制；
- native 与 web-wasm 实现通过同一 Tool Contract；
- selected-artifact 安装、升级、回滚和撤销；
- UI/Runtime 版本原子一致；
- 移动端只下载 common + web-wasm；
- 桌面只下载 common + 当前 OS/architecture native artifact；
- 无头 CLI 可跳过非必要 UI；
- 构件切换和执行位置可审计。

全球法布施验收必须证明同一 Release 和 Tool 契约在以下环境真实运行：

- macOS native CLI；
- Windows native CLI；
- Linux native CLI；
- iOS local WebView + WASM；
- Android local WebView + WASM；
- ordinary Web/PWA + WASM。
