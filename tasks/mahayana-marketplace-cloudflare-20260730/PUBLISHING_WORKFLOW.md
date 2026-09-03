# 发布流程：MCP Apps-only 大乘小程序

> v12.2 纠偏：本文件只描述用户明确上线后的构建与发布阶段。生成代码时不得创建 GitHub 或 Cloudflare 资源。源码托管目标与网页运行目标必须分开建模；完整规则见 `LOCAL_GENERATION_GITHUB_DEPLOYMENT.md`。

## 1. 默认体验

```bash
mahayana plugin init
mahayana plugin run
mahayana plugin deploy
```

`init`、AI 生成、编辑和 `run` 都只操作本地 Workspace。`deploy` 才进入上线向导，先选择源码托管方，再由能力分类器建议运行目标：

```text
源码：官方 managed GitHub | 我的 GitHub
运行：仅本地 | GitHub Pages（合规公开静态） | Cloudflare（动态/生产） | 外部托管
```

平台负责模板、安全快照、构建、扫描、不可变包、签名、provenance 和审核。任何默认选择都不得代替用户对上传、公开可见性和首次部署的明确确认。

### 1.1 自动部署路由

| 项目能力 | 默认建议 | 强制条件 |
| --- | --- | --- |
| 不需要公开 URL | 仅本地 | 不创建远程运行资源 |
| 纯静态、无 Secret/服务端/API、用户同意公开且符合 GitHub Pages 政策 | GitHub Pages | public repo、静态导出、CSP 与大小/带宽门禁 |
| 动态 API、鉴权、实时、服务端 Secret、私有源码或 Pages 不适用 | Cloudflare | 受信任部署、配额、运行隔离与回滚 |
| 用户指定自己的基础设施 | 外部托管 | 所有权验证、健康检查、provenance |

GitHub Pages 不得用于 GitHub 明确排除的在线业务、电子商务或商业 SaaS 通用托管，也不得在 UI 中宣传为“无限”。

## 2. `plugin init`

只生成新架构：

```text
.codex-plugin/plugin.json
.mahayana/plugin.json
.mcp-app.json
ui/
runtime/
mahayana.permissions.json
mahayana.publish.json
.github/workflows/mahayana-plugin-release.yml
```

模板必须包含：

- `@modelcontextprotocol/server` SDK v2；
- `createMcpHandler`；
- `legacy: "reject"`；
- `@modelcontextprotocol/ext-apps`；
- `ui://` resource；
- `text/html;profile=mcp-app`；
- App/View code；
- CSP 和 tool visibility；
- text + structured result。

不得生成 legacy template 或长期发布 Token。

## 3. `plugin test`

至少执行：

- manifest/schema；
- SDK v2 import；
- stateless handler；
- legacy rejection；
- MCP Apps extension；
- `ui://` resource 和 MIME；
- AppBridge handshake；
- sandbox/CSP；
- model/app visibility；
- 权限清单；
- 包边界和路径安全；
- 本地安装与启动；
- browser smoke。

正式 release 在 Actions 中重新执行。

## 4. Stage

### 发布意图

CLI 提交 plugin ID、version、repository、workflow、commit 和 stage。市场返回 OIDC audience、nonce 和 expiry。

### GitHub Actions

最小权限：

```yaml
permissions:
  contents: read
  id-token: write
```

流程：

1. checkout 指定 commit；
2. 安装锁定版本依赖；
3. 运行 MCP Apps/SDK v2 conformance；
4. 构建 UI resources 和 Worker；
5. 扫描依赖、Secret、CSP 和权限；
6. 获取 OIDC token 并交换短期发布凭证；
7. 根据已确认的 deployment plan 选择 GitHub Pages、Cloudflare、外部托管或无远程运行目标；
8. 构建不可变 preview artifact，并只在目标需要时创建/更新运行资源；
9. 对远程 MCP 目标验证 `/mcp`，对静态目标验证静态导出、CSP、404/base path 与资源完整性；
10. 对远程 MCP 目标验证 legacy 请求被拒绝；
11. 读取并渲染 `ui://` resource；
12. 验证 AppBridge、sandbox、CSP 和 visibility；
13. 生成不可变 package/manifest/provenance；
14. 从实际发布目标重新获取并核对字节；
15. 提交 stage release 和证据包。

Stage 不得进入公开搜索。

## 5. Release

`mahayana plugin release`：

1. 选择已验证 stage；
2. 展示版本不可复用；
3. 展示权限、CSP 和 tool visibility diff；
4. 提交审核；
5. 审核确认 MCP Apps、SDK v2、stateless 和 legacy rejected；
6. 签署版本元数据；
7. production deployment 指向该 Worker version；
8. 更新 `latest` 指针；
9. 从干净环境执行市场、下载、安装和 MCP Apps Host smoke；
10. 写审计和 production history。

Production 不重新构建，只提升已验证的不可变 stage。

## 6. 托管运行目标

### 6.1 GitHub Pages

- 仅接收静态导出产物；不得携带服务端 Secret、写 API 或动态 MCP 服务；
- GitHub Free 组织的 Pages 路径要求公开仓库，因此必须单独取得公开源码/站点与许可证确认；
- 发布到 `/<repo>/` 时必须验证 `basePath`、资产 URL、SPA fallback、404、CSP 和缓存；
- 记录 Pages deployment、commit、artifact digest 和最终 URL；
- 触发仓库/站点/带宽/构建软硬限制时自动停止新建并给出 Cloudflare、外部托管或仅本地选项。

### 6.2 Cloudflare

Cloudflare 保留为动态、鉴权、API、实时和其他 Pages 不适用项目的生产运行平面。免费 Pages 每账户项目数有限，禁止把“每个生成项目都创建一个 Pages 项目”作为默认架构。

启动阶段只为确需远程动态运行的已审核项目创建独立服务，并设置平台配额；项目量接近账户限制前，必须完成共享控制面/受控多租户或 Workers for Platforms 的成本评审，不得靠更多隐藏账户规避限制。

每次发布创建 version/deployment，不为每个版本创建永久新项目。平台凭证只存在于受保护环境，不下发给发布者、不写日志、定期轮换。

## 7. 自托管

```bash
mahayana plugin publish --self-hosted https://plugin.example.workers.dev
```

要求：

- 所有权 challenge；
- Cloudflare HTTPS；
- SDK v2 `createMcpHandler`；
- `legacy:"reject"`；
- MCP Apps resources；
- 不可变包；
- provenance；
- 相同审核和签名。

市场必须真实探测 endpoint，不能只相信 manifest。

## 8. 版本与不可变路径

```text
/mahayana/releases/<version>/<sha>/plugin.tar.gz
/mahayana/releases/<version>/<sha>/plugin.json
/mahayana/releases/<version>/<sha>/provenance.json
```

- version 唯一；
- 同路径字节不可变化；
- `latest` 只指向 production；
- 回滚只切 deployment；
- 撤销不删除审计。

不允许非 semver 旧格式作为新发布。

## 9. 发布证据包

```text
release-receipt.json
plugin.json
mcp-app-manifest.json
ui-resources.json
csp-report.json
tool-visibility.json
legacy-rejection.json
permissions.json
provenance.json
package.sha256
scan-summary.json
host-smoke.json
external-host-smoke.json
deployment-summary.json
```

收据记录 plugin/version、repository ID/commit/workflow/run、source target、hosting provider、provider deployment ID/URL、immutable artifact SHA/size、MCP Apps/SDK 版本、signature、review 和 smoke results。没有远程运行目标时显式记录 `hostingProvider=none`，不得伪造 Cloudflare 字段。

## 10. 回滚与撤销

- 只能回滚到已批准的 MCP Apps release；
- 不能回滚到旧 runtime；
- 撤销版本不能新安装或升级；
- blocked 插件不能启动；
- production smoke 失败时回滚到上一 MCP Apps-only deployment。

## 11. 旧插件

旧插件只进入迁移 inventory：

- 不可 stage；
- 不可 release；
- 不可 production；
- 不可安装或启动；
- 发布者必须重新构建 MCP Apps 版本。

## 12. 禁止做法

- legacy template 或 handler；
- SDK v1 server；
- MCP session ID/store；
- 自定义 iframe bridge；
- 生产兼容 lane；
- 普通用户配置平台 Cloudflare Token；
- 长期市场写 Token；
- 测试账号代替 OIDC；
- 同版本覆盖；
- 每版本永久新 Worker；
- R2 分发包或静态资源；
- 市场代理全部下载字节；
- 未验证就提升 production；
- 只有 SHA、没有签名和 provenance。
