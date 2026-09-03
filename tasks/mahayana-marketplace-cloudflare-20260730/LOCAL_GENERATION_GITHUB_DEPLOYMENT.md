# 本地生成、双 GitHub 源码托管与分级上线架构

任务：`mahayana-marketplace-cloudflare-20260730`

架构版本：`v12.2`

核验日期：`2026-08-09`

状态：本任务关于本地生成、GitHub 托管、GitHub Pages、Cloudflare 和成本治理的最高优先级规范。

若本文与旧文档中的“生成即上传”“先连接 GitHub 才能生成”“所有项目默认创建 Cloudflare 项目”“managed 用户仓库进入 `bhrumom`”或“GitHub Pages/组织仓库无限”冲突，以本文为准。

## 1. 最终决策

1. AI 生成代码的第一事实源是用户设备上的本地 Workspace；生成、编辑、预览和本地运行不依赖 GitHub、Cloudflare 或网络。
2. 只有用户明确执行“上线”，平台才冻结一个安全源码快照并创建远程资源。
3. 源码上线有两条平等路径：
   - `managed-github`：平台 GitHub App/API 写入独立 managed user apps 组织；用户不需要 GitHub 账号。
   - `user-github`：官方 GitHub MCP/连接器以用户授权身份写入用户明确选择的 owner/repository；平台不保存用户 GitHub 凭证。
4. 源码托管和网页运行是两个独立选择。GitHub 仓库创建成功不等于网页已部署，网页已部署也不等于已经进入市场。
5. GitHub Pages 是符合条件的公开纯静态项目的优先低成本目标，不是无限资源，也不是在线业务、电子商务或商业 SaaS 的通用免费主机。
6. Cloudflare 现有能力保留，承担动态、鉴权、API、实时、私有或其他 Pages 不适用的线上运行；不再为每个生成项目默认创建 Pages/Worker。
7. `bhrumom` 只保存平台和官方产品源码。用户作品即使由平台代管，也必须进入独立的 managed user apps 组织，不能继承官方身份或签名信任。
8. 用户随时可以导出、迁移到自己的 GitHub 或改用外部托管；平台托管是可退出的保管服务，不是所有权锁定。

## 2. 先纠正三个容量假设

### 2.1 GitHub 组织仓库不是无限

GitHub Free 的套餐描述允许组织创建不限量 public/private repositories，但 GitHub 的仓库限制文档规定单个账户/组织最多 `100,000` 个 repositories，并在 `50,000` 后提示管理和性能影响。GitHub 还建议集成尽量把用户生成的数据保存在用户自己的账户，而不是无限集中在一个账户。

因此本方案：

- 不宣称“无限仓库”或“永远零成本”；
- 每个 managed repo 都有 owner、容量和生命周期记录；
- 在可配置水位触发分片，建议首个预警不晚于 40,000，硬停止不晚于平台安全水位；
- 使用 `managedOrgId + repositoryId` 定位，不把可变化的 owner/name 当主键；
- 从第一天提供“迁移到我的 GitHub”和完整源码导出。

### 2.2 GitHub Pages 不是通用 SaaS 主机

GitHub Pages 官方限制包括站点大小、带宽、构建频率和用途约束，并明确不允许将 Pages 作为在线业务、电子商务或商业 SaaS 的免费通用主机。GitHub Free 组织的 Pages 只适用于公开仓库。

因此 Pages 只有在以下条件全部成立时可用：

- 构建结果为纯静态 HTML/CSS/JS/assets；
- 不需要服务端 Secret、API、持久连接、定时任务或私有运行环境；
- 用户明确同意对应仓库和站点公开，并选择/确认许可证；
- 用途通过 GitHub Pages policy gate，不属于被排除的商业托管用途；
- site/repository/build/bandwidth 等容量门禁通过；
- base path、404、SPA fallback、CSP、资源完整性和自定义域名均通过自动验收。

任一条件不成立，UI 必须解释原因并推荐 Cloudflare、外部托管或继续仅本地，不能暗中修改可见性。

### 2.3 Cloudflare Pages 的 100 项目限制属实

Cloudflare Pages Free 当前每账户最多 100 个 Pages projects，常规不提高；Pages Functions 请求计入 Workers 配额。静态资源请求虽免费，但项目、构建、文件和运行配额仍然存在。

因此：

- 保留已有 Cloudflare 项目和发布兼容性；
- 禁止“每个生成的小程序自动创建一个 Pages project”；
- 只有用户明确上线且能力分类需要远程动态运行时才消费 Cloudflare 资源；
- 接近水位时，已上线项目优先，暂停新建并提供其他目标；
- 真正需要大规模任意代码隔离时，再以实际收入/用量评审 Workers for Platforms，而不是提前承担固定成本或用多个隐藏账户绕限额。

权威链接保存在 `REFERENCES.md`，实施时仍须以官方最新政策和 API 返回为准。

## 3. 产品对象必须解耦

一个用户项目不是一个 GitHub URL，也不是一个 Cloudflare project。最小实体关系为：

```text
LocalWorkspace (第一事实源)
  ├─ SourceSnapshot 0..n（不可变发布快照）
  ├─ SourceBinding 0..n（managed GitHub / user GitHub）
  ├─ Build 0..n（由精确 snapshot 产生）
  ├─ WebDeployment 0..n（Pages / Cloudflare / external / none）
  ├─ MarketplaceRelease 0..n
  └─ Installation 0..n（本地按平台安装/运行）
```

必须分别记录：

```ts
type SourceProvider = "local" | "github";
type SourceActor = "user" | "platform";
type SourceTransport = "local-fs" | "github-mcp" | "github-app-api";
type SourceCustody = "device" | "platform-managed" | "user-owned";

type HostingProvider =
  | "none"
  | "github-pages"
  | "cloudflare-pages"
  | "cloudflare-workers"
  | "external";

type RuntimeProfile =
  | "local-native"
  | "local-web-wasm"
  | "web-static"
  | "remote-edge";
```

`MCP` 是 AI 操作 GitHub 的 transport，不是 source provider。`repositoryOwner` 是 GitHub 上的托管主体，不等于作品作者、市场 publisher 或官方身份。

身份模型至少包含：

```ts
interface MiniAppIdentity {
  appId: string;
  pluginId: string;
  authorSubjectId: string;
  sourceHost: "local" | "github";
  sourceCustody: SourceCustody;
  repositoryId?: number;
  repositoryOwner?: string;
  repositoryName?: string;
  publisherSubjectId?: string;
  officialStatus: "official" | "community" | "unverified";
  lineageId: string;
}
```

禁止通过 `owner === "bhrumom"`、仓库名、部署域名或签名主体推断作者。managed 用户作品必须显示“用户作品 · 法布施代管源码”，不得显示“法布施官方应用”。

## 4. 本地 Workspace：默认且可靠的产品核心

### 4.1 生命周期

```text
create → persist → reopen → edit → preview/run → snapshot → explicit publish
```

每次 AI 修改先生成 provisional diff，用户/Host 接受后原子写入 Workspace；拒绝或失败可回退到前一快照。任何远程错误都不能破坏当前本地可运行版本。

### 4.2 本地元数据

```json
{
  "schemaVersion": 1,
  "localProjectId": "local_01H...",
  "appId": "app_01H...",
  "pluginId": "local.mahayana.01H...",
  "displayName": "我的小程序",
  "workspaceRevision": 17,
  "acceptedTreeHash": "sha256:...",
  "syncState": "local-only",
  "lastSourceBindingId": null,
  "lastWebDeploymentId": null
}
```

真实 `workspacePath` 只保存在设备端平台沙箱，不进入市场、遥测、GitHub metadata 或公开 API。桌面、iOS、Android、Web/PWA 的底层存储可以不同，但语义和迁移测试必须一致。

### 4.3 低成本操作日志

借鉴 Cloudflare OS 的可恢复 action queue，但首期不引入 Durable Objects/Yjs 远程常驻成本。设备端保存有界操作日志：

```text
pending → claimed → applying → applied | rejected | failed | outcome-unknown
```

- 在执行有副作用的远程 I/O 前先持久化 claim 和 idempotency key；
- 明确失败可安全重试；
- `outcome-unknown` 不得盲目重试建仓/发布，必须先 reconcile GitHub/部署商状态；
- 保留最近成功快照和有界审计记录，旧记录按策略压缩而不是无限增长；
- 多设备协作以后可升级为 CRDT/Yjs，v12 首期以单设备 revision + 三方 compare/merge 为准。

## 5. 上线是两阶段明确同意

### 5.1 第一步：生成本地发布计划

点击“上线”后先在本地执行安全分析，不创建远程资源：

- 冻结 deterministic source snapshot；
- 生成文件清单、tree hash、archive sha256；
- 扫描 Secret、PII、`.env`、Cookie、数据库、聊天记录、缓存和构建产物；
- 分析静态/动态能力、网络权限、数据写入、认证和外部连接；
- 计算可用 source targets 和 hosting targets；
- 展示公开性、许可证、费用/配额风险、最终 owner 和预计 URL。

### 5.2 第二步：用户确认后执行

确认页必须把以下项目分开显示：

```text
源码保存到：法布施托管 GitHub / 我的 GitHub
仓库可见性：private / public
网页运行：不部署 / GitHub Pages / Cloudflare / 外部托管
市场状态：不发布 / 提交审核
```

首次上传、private→public、首次 Pages、首次 Cloudflare、owner 变化和市场发布分别是需要审计的同意事件。一个“上线”按钮可以提供顺畅的一键流程，但后台不能把这些事实压成一个不可解释的布尔值。

## 6. 官方 managed GitHub 路径

### 6.1 信任域

- 官方平台源码组织：`bhrumom`，只放官方代码；
- managed 用户源码组织：配置项 `managedUserAppsOwner`，建议首个组织形如 `mahayana-hosted-01`；
- 后续分片组织：`mahayana-hosted-02` 等，由容量路由器选择；
- 所有 managed 用户仓库默认 `private`，公开必须二次确认；
- 组织名称是配置和迁移数据，不得散落硬编码。

### 6.2 控制面

```text
confirmed local snapshot
→ Fabushi session/authz
→ idempotent deployment intent
→ server recomputes manifest/hash and scans
→ short-lived GitHub App installation token
→ create/reconcile repository in managed org
→ initial commit bound to exact snapshot
→ bootstrap ruleset/CODEOWNERS/workflows
→ untrusted validation build
→ trusted release/deploy only after gates
```

禁止使用组织 PAT、个人 Token 或下发到客户端的可写凭证。GitHub App 权限按操作拆分；installation token 短期、最小 repo scope、日志脱敏。

### 6.3 仓库规则

- 命名：`miniapp-<safe-slug>-<publicId>`，不得包含邮箱、手机号、真实姓名等 PII；
- 主键：GitHub `repositoryId`，owner/name 只是当前 locator；
- 默认分支受保护，禁止用户代码直接获得 production environment、签名或组织管理权限；
- Fork/PR 使用无 Secret、只读、隔离的 `pull_request` CI；
- trusted release 使用平台控制的 reusable workflow、受保护 ref、OIDC、SBOM、attestation 和 provenance；
- repo bootstrap 必须幂等，缺任一安全策略即不可标记 ready；
- 用户账户删除和仓库删除解耦，删除/转移必须独立确认并可审计。

### 6.4 容量与退出

每个组织记录 `repositoryCount`、Actions 用量、artifact/storage、API rate、abuse signal 和归档状态。达到预警水位后只向有容量的新 shard 建仓；达到安全停止水位时 fail closed，但本地功能继续可用。

用户可以随时：

- 下载可验证源码归档；
- 通过连接器迁移到自己的 GitHub；
- 转移/镜像 Git history，并尽可能迁移 Issues/PR/Releases；
- 保留 `lineageId`、旧 repositoryId、迁移方式和 source commit 连续性。

## 7. 用户自己的 GitHub 路径

流程：

```text
confirmed local snapshot
→ 用户选择 GitHub 官方连接器
→ 用户明确选择 owner/repository/visibility
→ AI 经 GitHub MCP 在授权范围内创建或更新 repo
→ 返回 repositoryId/commit/treeHash
→ Fabushi 只登记非敏感来源事实
```

强制边界：

- 用户 access token、refresh token、connector secret 不进入 Fabushi API、日志、数据库、analytics 或 repo；
- 多 owner 时没有显式选择必须阻断，不能猜测个人账户或组织；
- 曾连接过 GitHub 不构成新项目上传同意；
- 连接器断开、权限不足或取消时保留本地项目，并允许改走 managed GitHub；
- 远程出现未知提交时先 compare/fetch/merge/rebase，禁止强推覆盖；
- 用户 repo 的 Actions、Pages 和第三方部署费用/限制由确认页如实说明。

## 8. 部署路由器

### 8.1 可判定策略

部署计划输出必须包含可解释的 policy result：

```json
{
  "hostingProvider": "github-pages",
  "runtimeProfile": "web-static",
  "eligible": true,
  "reasons": ["static-export", "no-server-secret", "public-consent"],
  "limitsSnapshotAt": "2026-08-09",
  "fallbacks": ["cloudflare-pages", "none"]
}
```

决策矩阵：

| 条件 | 目标 | 说明 |
| --- | --- | --- |
| 不需要公开网页 | `none` | 市场安装包和本地 Runtime 已能使用 |
| 公开纯静态、政策合规 | `github-pages` | 优先低成本；不是容量承诺 |
| 私有静态或 Pages 不合规 | `cloudflare-pages` / `external` / `none` | 受账户项目配额约束 |
| 动态 API、认证、实时、Server Secret | `cloudflare-workers` / `external` | 必须隔离执行和最小权限 |
| 任意不受信任服务端代码 | 隔离 Cloudflare 项目或外部托管 | 禁止放入共享高权限进程 |

分类器不确定时 fail closed，并让用户选择“继续本地”或经过解释的托管目标。

### 8.2 Cloudflare 的低成本保留方式

1. 已存在的合法 Cloudflare deployments 不迁移、不破坏。
2. 新项目默认不消费 Cloudflare；先判断是否根本不需要远程 Runtime。
3. 纯静态且合规的公开项目优先 Pages。
4. 仅配置/声明驱动、不会执行任意用户服务端代码的场景可复用现有共享控制面，但必须租户隔离、签名 artifact、按 appId 授权。
5. 任意用户服务端代码必须进入独立隔离边界；免费配额内实行数量/构建门禁，超过后评审 Workers for Platforms 或让用户选择外部托管。
6. 禁止为了省钱把不同用户的不受信任代码放进同一个拥有平台 Secret 的 Worker。

### 8.3 稳定产品 URL

用户看到稳定入口，例如 `https://apps.fabushi.com/a/<appId>`。它是轻量 launch manifest/redirect，不是代码事实源，内部可指向 GitHub Pages、Cloudflare 或外部 URL。迁移部署商不改变 appId、市场 identity 或用户收藏链接。

## 9. API 与状态机

### 9.1 创建部署意图

```http
POST /v2/miniapps/deployment-intents
Authorization: Bearer <fabushi-session>
Idempotency-Key: <device-generated-uuid>
```

```json
{
  "localProjectId": "local_01H...",
  "sourceSnapshotSha256": "sha256:...",
  "sourceTarget": "managed-github",
  "repositoryVisibility": "private",
  "hostingPreference": "auto",
  "marketplaceIntent": "not-now"
}
```

服务端返回 policy plan、需要的同意项和一次性上传能力；在确认前不得建仓或部署。上传后服务端重算文件清单/hash，不能只相信客户端声明。

### 9.2 确认执行

```http
POST /v2/miniapps/deployment-intents/<intentId>/confirm
```

```json
{
  "acceptedPlanVersion": 3,
  "consents": ["upload-source", "managed-custody"],
  "expectedSourceSnapshotSha256": "sha256:..."
}
```

返回至少分开包含 `sourceBinding`、`build`、`webDeployment` 和 `marketplaceRelease`；不得只返回含糊的 `deployed=true`。

### 9.3 正交状态机

```text
workspace: local-ready | dirty | snapshotting | snapshot-ready | conflict
source:    none | consented | syncing | hosted | diverged | failed | outcome-unknown
build:     none | queued | validating | passed | failed
hosting:   none | queued | deploying | deployed | failed | rolled-back
market:    none | review | listed | installable | suspended | revoked
```

聚合 UI 可以显示“正在上线 3/5”，但每一步必须能展开查看事实、失败原因、重试方式和目标 provider。

## 10. 供应链与运行安全

- 发布快照采用 allowlist + denylist + Secret/PII scanner，并限制 symlink、path traversal、文件数、单文件和总大小；
- 客户端 hash 只用于快速比对，服务端和 trusted builder 均重新计算；
- 不受信任 PR/build job 无 Secret、只读、隔离；禁止 `pull_request_target` checkout/执行 Fork 代码；
- privileged deploy job 只消费已验证、按 digest 固定的 artifact，不执行刚下载的任意用户脚本；
- trusted reusable workflow、OIDC claims、repositoryId、commit、tree hash、SBOM、attestation、manifest 和最终 deployment receipt 全链绑定；
- connector 和外部服务通过 capability broker 暴露最小资源；读操作与写操作分离，写操作支持 human approval；
- UI/HTML 在 sandboxed iframe/WebView 中运行，CSP、Origin、网络 allowlist、Tool visibility 与 teardown 强制执行；
- marketplace source、official badge 和签名身份不能由仓库 owner 或 manifest 自报；
- 仓库创建、可见性变化、发布、回滚、转移、删除和 capability grant 全部写不可变审计事件。

## 11. 吸收 Cloudflare OS 的精华

本任务参考 `cloudflare/cloudflare-os@1cb5e3d9096589e38f3fcfaf3f2191aa95a4c592`（Apache-2.0），借鉴产品和控制面思想，不复制其高成本运行拓扑。

| Cloudflare OS 优点 | 法布施低成本实现 |
| --- | --- |
| Workspace 是稳定协作单元 | 本地 Workspace + `localProjectId/appId` |
| Blueprint 保存代码快照和 binding requirements，不含凭证/聊天/实例数据 | `SourceSnapshot` + permission/binding manifest + Secret denylist |
| source 与安装实例分离 | GitHub source binding 与 local installation 分离；每实例自有数据/凭证 |
| provisional code change 可接受/拒绝/回退 | AI diff → user/Host accept → 原子本地 revision |
| capability-based Gatekeeper | connector capability broker；资源级授权、可撤销、写操作审批 |
| sandboxed iframe、无 ambient access | MCP Apps sandbox/CSP/Origin/network allowlist |
| durable action queue 先持久化再 I/O | 本地 journal + server idempotency + reconcile unknown outcome |
| dirty flag 和失败重试 | workspace/source/build/hosting 正交状态与可恢复任务 |
| 版本化协作与 merge/revert | 首期 revision/snapshot/three-way merge；需要时再引入 CRDT |

明确不采用：每用户 Durable Object、每 App Dynamic Worker Facet、为保持体验而常驻的付费云运行时。相同体验通过本地持久化、即时预览、后台异步部署、可恢复队列和稳定入口实现。

## 12. 用户体验

### 12.1 生成完成

```text
✓ 已保存到本地
[运行] [继续修改] [上线]
```

不展示“尚未连接 GitHub”的错误，因为 GitHub 不是本地生成前置条件。

### 12.2 上线向导

默认推荐“法布施托管”，但明确展示：

```text
源码保存
● 法布施托管（无需 GitHub 账号）
○ 我的 GitHub（使用 GitHub 官方连接器）

网页运行
● 自动选择：当前项目建议 GitHub Pages
  原因：纯静态、无服务端 Secret；需要公开仓库并确认许可证
○ 仅保存源码，暂不部署网页
```

对于动态 App：

```text
自动选择：Cloudflare
原因：使用服务端 API / 登录 / Secret，GitHub Pages 无法安全运行
预计：消耗 1 个受管运行项目配额
```

### 12.3 异步进度与错误恢复

```text
1/5 本地快照完成
2/5 源码仓库已创建
3/5 安全构建通过
4/5 网页部署完成
5/5 市场发布（未选择）
```

- 关闭页面后任务继续，重开可恢复进度；
- 错误说明发生在哪一层，并提供安全重试/换目标/继续本地；
- 永远先显示“本地代码安全”，避免用户把部署失败理解为作品丢失；
- 完成页显示真实 repo owner/name、repositoryId、commit、hosting provider、URL、可见性和费用/配额归属。

### 12.4 体验指标

- 本地保存确认不等待网络，目标 p95 `< 300 ms`（在支持设备上）；
- 点击上线后 p95 `< 2 s` 返回已持久化 intent 和可恢复进度页，不同步等待远程构建；
- 重复点击/网络重试不得产生重复 repo 或 deployment；
- 任何失败场景都至少保留一个完整本地源码副本；
- 100% 的远程动作可从 UI 追溯到用户同意、snapshot hash 和 provider receipt。

## 13. 成本、容量与滥用治理

最低成本来自“不创建不需要的云资源”，不是假设供应商无限免费：

- 本地每次修改不触发 Actions 或远程部署；
- 只有显式上线才上传一次去重快照；同 hash 重用安全分析和构建结果；
- public repo 的 GitHub-hosted standard runner 按 GitHub 当前政策使用，private repo 的 included minutes/存储必须计量，不能笼统记为 0；
- 构建并发、每用户 repo 数、每日发布次数、artifact 保留期、Cloudflare 动态项目数均可配置；
- 静态合规项目优先 Pages，动态项目才消费 Cloudflare；
- inactive 项目先通知后归档/休眠；删除必须明确确认并提供恢复窗口；
- 限额只阻断新的远程副作用，不阻断本地查看、导出和继续编辑；
- 记录 `userId/appId/deploymentId/provider/usage/costEstimate`，建立预算水位、异常建仓和构建风暴告警；
- 禁止恶意内容、钓鱼、矿工、代理滥用和供应链攻击，policy/abuse gate 在建仓和部署前后执行。

## 14. 分阶段落地

1. T01：先落身份模型与 managed org 信任边界，消除 `owner == official` 推断。
2. T02：完成本地 Workspace、安全 snapshot、状态机和分叉保护。
3. T03：实现 GitHub App 控制面、幂等建仓、首次 push 和 repo bootstrap。
4. T04：实现用户 GitHub MCP 路径与凭证零落地。
5. T05：把所有正式构建/发布收口到 trusted Actions、OIDC 和 provenance。
6. T06：完成 managed → user GitHub 接管、lineage 和回滚。
7. T07：加入部署路由、Pages policy gate、Cloudflare 配额、组织分片、成本和生命周期治理。
8. T08：以真实账号、真实 repo、真实 Actions/Release/Pages 或 Cloudflare、市场和安装完成双路径 E2E。

原子任务、固定 required check 名称和证据要求见 `EXECUTION_TASKS_V12.md`。不能用新增文档、mock、接口单测或截图代替真实端到端证据。

## 15. 完成定义

只有以下事实同时成立才可报告完成：

- 没有 GitHub 的用户能生成、离线重开、本地运行，并在明确确认后完成 managed GitHub 上线；
- 用户能通过官方 GitHub MCP 把同类项目保存到自己的 GitHub，且 Fabushi 零落地其 GitHub 凭证；
- managed 用户仓库从未进入 `bhrumom` 官方信任域；
- 源码托管、构建、网页部署、市场发布和本地安装状态彼此可解释、可回滚；
- Pages 仅在合规静态场景使用，Cloudflare 动态路径真实保留并受配额治理；
- managed 项目可无损迁移到用户 GitHub；
- 34 个 `v12 / Txx.n` required checks 均为 success，并附真实 commit、run、repo、release、deployment、market 和 install evidence；
- macOS、Windows、Linux、iOS、Android、Web/PWA 的既有多构件验收仍通过。
