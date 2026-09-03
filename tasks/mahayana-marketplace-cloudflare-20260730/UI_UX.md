# UI/UX：MCP Apps-only 小程序发布、市场与运行

> v12.2 纠偏：用户首先看到本地生成和运行体验；GitHub 与 Cloudflare 都不是生成前置条件。源码目标和网页运行目标必须分步说明，完整流程见 `LOCAL_GENERATION_GITHUB_DEPLOYMENT.md`。

## 0. AI 生成与首次上线

AI 生成/修改完成后默认显示：

```text
✓ 已保存到本地
[运行] [继续修改] [上线]
```

点击“上线”才展示：

```text
源码保存到哪里？
● 法布施托管（推荐，无需 GitHub 账号）
○ 我的 GitHub（GitHub 官方连接器）

网页运行
● 自动选择（显示 Pages / Cloudflare / 仅本地及原因）
○ 暂不部署网页
```

公开源码、启用 GitHub Pages、切换 owner 和提交市场审核分别需要明确同意。错误页首先确认“本地代码仍安全”，再给出重试、切换目标或继续本地。

## 1. 用户认知

用户看到的是“小程序”，不需要理解 MCP transport、Cloudflare Worker 或旧协议。所有小程序都使用同一种 MCP Apps 体验，不展示“旧版/新版运行模式”切换。

旧插件只能显示：

```text
该小程序使用已停止支持的运行格式。
请升级到 MCP Apps 版本后继续使用。
```

不提供“仍然运行”按钮。

## 2. 发布者 CLI

目标命令：

```bash
mahayana plugin init
mahayana plugin run
mahayana plugin deploy
mahayana plugin test
mahayana plugin publish --stage
mahayana plugin release
mahayana plugin status
mahayana plugin rollback <version>
mahayana plugin revoke <version>
```

### `plugin init`

只生成 MCP Apps 模板：

- SDK v2 server；
- `createMcpHandler`；
- `legacy: "reject"`；
- `ui://` resource；
- `text/html;profile=mcp-app`；
- View SDK；
- CSP；
- tool visibility；
- text/structured fallback；
- immutable release manifest。

不得提供“legacy MCP template”选项。

### `plugin test`

输出至少包括：

```text
✓ MCP SDK v2
✓ stateless Worker
✓ legacy requests rejected
✓ MCP Apps extension
✓ ui:// resource
✓ MIME profile
✓ AppBridge handshake
✓ sandbox and CSP
✓ model/app tool visibility
✓ text and structured result
✓ immutable package
```

失败必须指出文件、字段、resource URI 或 CSP 域名。

### `publish --stage`

显示：

```text
1/9 验证账号与插件身份
2/9 验证源码仓库与 GitHub OIDC（正式发布时）
3/9 构建 MCP App
4/9 扫描依赖和 Secret
5/9 按计划部署 GitHub Pages / Cloudflare / 外部目标（或跳过网页部署）
6/9 验证 legacy: reject
7/9 验证 ui://、AppBridge、sandbox 与 CSP
8/9 生成 provenance、SHA 和签名输入
9/9 创建待审核版本
```

## 3. 市场卡片

至少显示：

- 名称、完整 plugin ID、发布者；
- 版本和平台；
- `MCP App` 标识；
- 信任等级；
- 权限与外部域名摘要；
- 已安装/可升级/撤销/迁移要求状态。

未迁移版本显示 `migration_required`，不能安装或启动。

## 4. 插件详情

必须展示：

- MCP Apps 合规状态；
- SDK v2/stateless/legacy rejected；
- `ui://` resources；
- display modes；
- CSP 外部域名；
- model/app tool visibility；
- 权限；
- 源码、commit、workflow、Actions run；
- SHA、大小、签名和 provenance；
- 审核、撤销、回滚和安全公告。

## 5. MCP Apps Host 体验

### 加载

状态顺序：

```text
验证插件身份和版本
读取 MCP Apps resource
验证 MIME 和 CSP
建立 AppBridge
发送 host context
渲染 sandboxed View
```

不得直接把远程页面作为无约束 iframe 打开。

### Host context

向 View 提供最小必要信息：

- theme；
- locale；
- timezone；
- platform；
- viewport/display mode；
- 用户已授权能力。

不得注入 access token、Secret 或宿主内部对象。

### Display modes

- inline：默认；
- fullscreen：用户明确进入；
- picture-in-picture：仅插件声明且 Host 支持时；
- mode 切换由 Host 控制并可退出。

### Tool 调用

- model-visible 与 app-visible 分开展示；
- app-only 工具不进入模型工具列表；
- View 调用工具必须经过 Host；
- 写入、开放世界和破坏性操作显示确认；
- 拒绝时 View 收到标准错误，不静默失败。

### 外部链接

`ui/open-link` 显示目标域名和风险；不允许 View 自行顶层导航。

## 6. CSP 和权限反馈

CSP 拒绝时显示：

```text
该小程序尝试连接未声明域名：api.example.com
请求已阻止。请联系发布者更新并重新审核。
```

权限扩大升级时突出新增项，并允许保留旧版本。拒绝升级后不得留下半安装状态。

## 7. 旧客户端与旧插件

### 旧客户端

显示强制升级页面：

- 错误码 `MCP_APPS_HOST_UPGRADE_REQUIRED`；
- 当前版本；
- 最低支持版本；
- 升级入口；
- 不创建旧会话；
- 不执行工具。

### 旧插件

显示：

- `migration_required`；
- 可用的新版本；
- 发布者迁移文档；
- 升级或卸载按钮；
- 无“以兼容模式运行”。

## 8. 安装与运行

安装流程：

```text
获取签名元数据
验证 MCP Apps manifest
验证来源、权限和 CSP
直连下载安装包
校验 SHA 和大小
安全解包
原子安装
启动 stateless MCP App
验证 AppBridge 与 UI
```

只有 Tool、resource、AppBridge 和 View 健康检查均通过后才显示“安装成功”。

## 9. 发布者控制台

展示：

- MCP Apps conformance；
- SDK/handler 版本；
- legacy rejection 结果；
- ui resources 和 CSP；
- tool visibility；
- Cloudflare preview/production；
- immutable releases；
- provenance、扫描、审核和审计；
- 回滚、撤销和 blocked 状态。

## 10. 错误文案

必须可操作：

- `该版本不是 MCP App，无法发布。`
- `生产端点仍接受旧 MCP 请求；请设置 legacy: "reject"。`
- `未找到 ui:// resource。`
- `UI resource MIME 不是 text/html;profile=mcp-app。`
- `CSP 声明缺少实际访问域名。`
- `App-only 工具不能由模型调用。`
- `当前大乘版本不支持 MCP Apps，请升级。`
- `该旧插件不能在新运行时启动，请安装 MCP Apps 版本。`

## 11. 一致性

Web、桌面、移动和 CLI 必须共用：

- Host core；
- plugin ID/version；
- MCP Apps 合规状态；
- permissions/CSP/tool visibility；
- 安装、撤销和升级语义；
- 错误码和审计事件。
