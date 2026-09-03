# 参考资料

本文件保存市场、发布和更新安全设计依据。MCP Apps 与 Cloudflare runtime 的正式依据请优先阅读 `MCP_APPS_REFERENCES.md`。

## 1. 当前仓库

- 动态市场：`fabushi/web/src/handlers/marketplace.js`
- 动态市场测试：`fabushi/web/tests/marketplace.test.js`
- 官方内置市场：`.agents/plugins/marketplace.json`
- 公共发现：`frontend/apps/web/public/.well-known/mahayana/marketplace.json`
- Web 小程序 Host：`frontend/apps/web/src/app/miniapps/[id]/McpPluginApp.tsx`
- 大乘自定义 SDK：`frontend/packages/mcp-app-sdk/`
- Flutter 小程序模型：`fabushi/lib/models/mini_app_model.dart`
- Flutter registry：`fabushi/lib/services/mini_app_registry_service.dart`
- 本地插件发现：`fabushi/lib/services/codex_plugin_catalog_io.dart`

## 2. MCP Apps

- https://github.com/modelcontextprotocol/ext-apps
- https://github.com/modelcontextprotocol/ext-apps/blob/main/specification/2026-01-26/apps.mdx
- https://github.com/modelcontextprotocol/ext-apps/blob/main/docs/overview.md

采用：

- `io.modelcontextprotocol/ui`；
- `ui://`；
- `text/html;profile=mcp-app`；
- AppBridge；
- sandbox/CSP；
- model/app visibility；
- JSON-RPC over postMessage。

## 3. Cloudflare stateless MCP

- https://developers.cloudflare.com/agents/model-context-protocol/apis/handler-api/
- https://developers.cloudflare.com/agents/model-context-protocol/guides/migrate-to-mcp-sdk-v2/
- https://developers.cloudflare.com/agents/model-context-protocol/guides/remote-mcp-server/
- https://developers.cloudflare.com/workers/versions-and-deployments/

采用：

- `createMcpHandler`；
- `@modelcontextprotocol/server` SDK v2；
- production `legacy: "reject"`；
- 每请求 server factory；
- 显式业务状态；
- Host/Origin/OAuth 校验。

禁止使用 `createLegacyMcpHandler`、`McpAgent` 和 SDK v1 production server。

## 4. MCP Registry

- https://modelcontextprotocol.io/registry/about
- https://modelcontextprotocol.io/registry/faq
- https://modelcontextprotocol.io/registry/versioning

采用：Registry/Marketplace 负责身份、发现和可信元数据；运行与包字节可以由插件服务承载；版本元数据不可变。

## 5. npm Trusted Publishing 与 provenance

- https://docs.npmjs.com/cli/publish/
- https://docs.npmjs.com/trusted-publishers/
- https://docs.npmjs.com/generating-provenance-statements/
- https://docs.npmjs.com/viewing-package-provenance/

采用：`pluginId + version` 不可复用；GitHub Actions OIDC 短期发布凭证；provenance 绑定源码、commit、workflow 和构件。

## 6. VS Code、Slack、Forge

- https://code.visualstudio.com/api/working-with-extensions/publishing-extension
- https://api.slack.com/distribution/hosting
- https://developer.atlassian.com/developer-guide/cloud-app-hosting/

采用混合市场：中央控制平面 + 每插件独立运行平面；普通用户默认平台托管，高级用户可验证后自托管。

## 7. The Update Framework

- https://theupdateframework.github.io/specification/draft/
- https://theupdateframework.io/

采用：根信任、目标哈希和大小、元数据版本与过期、防回退、防冻结、密钥轮换和撤销。

## 8. 任务设计结论

```text
MCP Apps-only UI/runtime contract
+ Cloudflare stateless SDK v2
+ production legacy rejection
+ plugin stable identity
+ independent service boundary
+ immutable releases
+ central signed metadata
+ OIDC/provenance
+ CLI direct download and safe install
```

不得把 Cloudflare 文档更新时间误写为 MCP Apps 规范版本。当前任务正式采用 MCP Apps stable `2026-01-26`，Cloudflare runtime 使用实施时官方要求的精确 SDK v2 版本。

## 9. 本地优先与部署容量（2026-08-09 核验）

- GitHub 仓库限制：https://docs.github.com/en/repositories/creating-and-managing-repositories/repository-limits
- GitHub Pages 限制：https://docs.github.com/en/enterprise-cloud@latest/pages/getting-started-with-github-pages/github-pages-limits
- GitHub 方案与组织能力：https://docs.github.com/en/get-started/learning-about-github/githubs-plans
- Cloudflare Pages 限制：https://developers.cloudflare.com/pages/platform/limits/
- Cloudflare Pages Functions 计费：https://developers.cloudflare.com/pages/functions/pricing/
- Cloudflare Workers 限制：https://developers.cloudflare.com/workers/platform/limits/

采用：GitHub Free 组织可拥有不限量 public/private repositories 的套餐能力，但 GitHub 对单个账户/组织仍有 100,000 repositories 的产品上限，并在 50,000 后提示治理风险；因此不得把它设计成无上限存储。GitHub Pages 也有站点大小、带宽、构建频率和用途约束，且官方明确不允许将其作为在线业务、电子商务或商业 SaaS 的免费通用主机。

Cloudflare Pages Free 当前每账户最多 100 个 Pages projects；静态资源请求免费，Pages Functions 计入 Workers 配额。结论是：本地运行消除不必要的云成本，GitHub Pages 承担合规的公开纯静态项目，Cloudflare 承担确需远程动态能力的项目，并对两者实施容量水位和迁移机制。

## 10. Cloudflare OS 架构借鉴

- 仓库：https://github.com/cloudflare/cloudflare-os
- 本次评审固定 commit：`1cb5e3d9096589e38f3fcfaf3f2191aa95a4c592`
- License：Apache-2.0

借鉴其 Workspace 稳定身份、Blueprint 代码快照、source/instance 分离、能力授权、沙箱、provisional change、可恢复 action queue 和明确的人类审批；不照搬 Durable Objects、Dynamic Worker Facets 或每用户远程运行时。法布施以本地 Workspace/操作日志为低成本事实源，以 GitHub 为可选源码托管，以分级部署提供相近体验。
