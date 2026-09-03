# v12.2 原子执行任务与自动验收矩阵

任务：`mahayana-marketplace-cloudflare-20260730`

总门禁：`34`

权威交接基线（2026-08-09）：`0/34`；T01 `0/4`；首个阻塞项 `v12 / T01.1 identity-schema`。

状态来源：GitHub required checks 与真实 evidence；本文的交接数字不覆盖后续实时状态。

本文件把 T01-T08 拆成可独立验收、可由 GitHub Actions 自动判定的原子任务。`v12.2` 是对 v12 的兼容增强：保留全部 34 个 check 名称，新增“源码托管与网页部署解耦、GitHub Pages 合规路由、Cloudflare 动态保留、Cloudflare OS 低成本模式”要求。

## 统一执行规则

- 任务队列使用 `applyMode=next_chat` 承接当前执行，不重启、不清空进度、不重复创建 PR。
- 开始一项前先读取实际分支、PR、required checks、最近 Actions 和现有 evidence，从首个未通过项继续。
- 项目测试、构建、打包、安装、发布和 artifact 验证只在 GitHub Actions 执行；本地只允许文档/源码读取、编辑、Git 状态和 `gh` 协调。
- 不得用新增文档、mock、接口单测、截图、日历勾选或口头报告代替真实 GitHub/API/Release/市场/安装事实。
- 每个原子任务必须对应真实实现、自动断言、固定 required check、commit SHA、workflow run/check URL 和必要 provider receipt。
- 状态只允许 `not-started`、`in-progress`、`blocked`、`passed`、`failed`。
- 只有 check conclusion=`success` 且业务证据完整时才可记为 `passed`；skip、neutral、allow-failure 或只上传空 evidence 均不算通过。
- Txx 进度 = `passed 原子任务数 / 必需原子任务总数`；任一必需任务未通过，父阶段不得完成。
- 34 个门禁全部通过前，本项目不得报告 `complete`。

建议统一 workflow：`.github/workflows/mahayana-v12-atomic-acceptance.yml`。Job/display name 必须与下列 Required check 完全一致，防止 ruleset context 漂移。

建议统一 evidence：`.mahayana/evidence/v12/<task-id>.json` 或 Actions artifact 中的等价 JSON，至少包含：

```json
{
  "taskId": "T01.1",
  "checkName": "v12 / T01.1 identity-schema",
  "commit": "<sha>",
  "runUrl": "<url>",
  "assertions": [],
  "externalReceipts": [],
  "completedAt": "<rfc3339>"
}
```

---

## T01 架构与源码所有权边界

### T01.1 身份与部署模型落库

- 实现：数据模型明确区分 `author`、`sourceHost`、`sourceCustody`、`repositoryOwner`、`publisher`、`officialStatus`、`sourceProvider/sourceActor/sourceTransport`、`hostingProvider`、`runtimeProfile` 和 `deploymentTarget`；源码托管与网页部署不得共用一个布尔字段。
- Required check：`v12 / T01.1 identity-schema`
- 自动断言：schema/migration/serialization round-trip；旧数据升级不丢 source identity；`source-hosted` 不自动产生 `deployed`。
- 通过标准：官方 App、managed 用户 App、用户自有 GitHub App，以及 local-only/Pages/Cloudflare 三类部署 fixture 均得到正确且正交的身份组合。

### T01.2 用户托管组织与官方组织隔离

- 实现：`bhrumom` 仅作为官方代码组织；用户托管目标来自独立 `managedUserAppsOwner`/shard 配置，不得硬编码到 `bhrumom`。
- Required check：`v12 / T01.2 managed-org-boundary`
- 自动断言：official repo 可在 `bhrumom`；managed 用户 repo 若 owner=`bhrumom` 必须失败；配置缺失或容量水位关闭时 fail closed。
- 通过标准：真实或受控测试证明用户托管仓库不能进入官方源码组织信任域，且 repositoryId 不依赖 owner/name。

### T01.3 市场身份展示

- 实现：市场/详情页展示作者、源码托管方、GitHub owner/repo、publisher、hosting provider、`官方/用户作品` 标识。
- Required check：`v12 / T01.3 marketplace-source-labels`
- 自动断言：UI/component/API contract snapshot 覆盖 official、managed-hosted、user-github 和 local-only；source-hosted/网页已上线/市场已发布用不同状态文案。
- 通过标准：法布施托管用户 App 不得显示为“法布施官方应用”，GitHub Pages/Cloudflare 域名不得改变作者身份。

### T01.4 信任边界负向测试

- 实现：用户托管仓库不能获得官方发布身份、官方 badge、官方 signing/OIDC trust；hosting provider 不能授予市场信任。
- Required check：`v12 / T01.4 trust-boundary-negative`
- 自动断言：伪造 publisher/officialStatus/owner/hostingProvider 或复用官方 plugin identity 必须被拒绝。
- 通过标准：至少覆盖 API、manifest validation、release policy 和 marketplace projection 四层负向测试。

---

## T02 本地 Workspace 与发布状态机

### T02.1 本地生成、持久化、离线重开

- 实现：聊天生成代码先写本地 Workspace，不依赖 GitHub/Cloudflare；支持 provisional diff、接受/拒绝、重开、继续修改和本地运行。
- Required check：`v12 / T02.1 local-workspace-offline`
- 自动断言：禁网且无 connector fixture 下 create → persist → reopen → edit → accept/revert → run 全链成功。
- 通过标准：远程配置完全缺失仍能完成本地循环，未点击上线时远程资源创建调用次数为 0。

### T02.2 安全发布快照

- 实现：发布前生成 deterministic source snapshot/tree hash，过滤 `.env`、Token、Cookie、数据库、聊天记录、缓存、构建目录，并防 symlink/path traversal/zip bomb。
- Required check：`v12 / T02.2 safe-source-snapshot`
- 自动断言：secret/PII/path fixtures 必须被阻断；相同源码产生相同 hash；服务端与 trusted builder 均可重算。
- 通过标准：敏感文件零泄漏，manifest、文件数/大小和 hash 可复核；本地确认前不上传。

### T02.3 正交发布状态机

- 实现：Workspace、source、build、hosting、market 分开记录；聚合路径可表现 `local-ready → source-hosted → build-passed → deployed → marketplace-listed → installable`，失败状态显式。
- Required check：`v12 / T02.3 deployment-state-machine`
- 自动断言：合法转移通过；跳级、越权回退、把 source push 当网页上线、把 Pages 成功当市场发布等非法转移失败。
- 通过标准：每个 UI/API 状态与后端/provider 事实一一对应，`hostingProvider=none` 是合法终态。

### T02.4 失败、未知结果与远程分叉保护

- 实现：上线失败保留本地项目；副作用前持久化 idempotency claim；未知结果先 reconcile；远程已有未知提交时禁止强推覆盖。
- Required check：`v12 / T02.4 sync-and-rollback-safety`
- 自动断言：模拟 API/GitHub/Pages/Cloudflare timeout、outcome unknown 和 diverged history；不得重复建仓/部署，本地无损，force push 路径被拒绝。
- 通过标准：明确失败可重试，未知结果可对账，任意失败至少保留一个完整可用源码副本。

---

## T03 官方托管 GitHub 控制面

### T03.1 GitHub App 最小权限控制面

- 实现：官方托管只使用 GitHub App installation token/短期凭证；禁止组织 PAT 下发客户端。
- Required check：`v12 / T03.1 github-app-control-plane`
- 自动断言：配置扫描和集成测试证明客户端 payload/log/db 无 org PAT；token 为最小 repo scope 且过期后不可用。
- 通过标准：无 GitHub 账号的法布施用户可触发可信后端建仓，GitHub 凭证只存在于受控服务边界。

### T03.2 幂等建仓、分片与命名隐私

- 实现：`deploymentId/idempotencyKey` 保证重复请求只产生一个 repo；容量路由选择 managed org shard；repo name 不含邮箱/手机号/真实姓名等 PII。
- Required check：`v12 / T03.2 idempotent-repo-create`
- 自动断言：并发/重试/outcome-unknown fixture 返回同一 repositoryId；满水位组织不再建仓；PII 命名被拒绝/脱敏。
- 通过标准：不存在重复仓库、官方组织误投、超水位建仓或明显 PII 泄露。

### T03.3 首次 push 与来源绑定

- 实现：本地安全快照写入 managed repo，记录 managedOrgId、repositoryId、defaultBranch、commit、treeHash 和 snapshot hash。
- Required check：`v12 / T03.3 initial-source-push`
- 自动断言：真实测试 repo 的文件清单/hash 与本地发布快照完全一致；额外、缺失或变更字节均失败。
- 通过标准：exact commit/tree 可复核，首次源码 push 仍未被错误标为网页部署或官方作品。

### T03.4 仓库策略 bootstrap

- 实现：创建仓库后配置标准模板、CODEOWNERS、无 Secret 的 untrusted PR CI、平台控制的 trusted release、ruleset、Pages/hosting policy 和审计事件。
- Required check：`v12 / T03.4 managed-repo-bootstrap`
- 自动断言：读取真实测试 repo rulesets/workflows/CODEOWNERS/environment；缺任一保护或用户 workflow 可控制 production trust 时失败。
- 通过标准：managed repo 达到正式 MCP App 的最小供应链基线，Pages 默认关闭，只有 policy/consent 通过才能启用。

---

## T04 用户 GitHub 连接器与凭证隔离

### T04.1 provider/actor/transport/hosting 分层

- 实现：`sourceProvider=github`，`sourceActor=user|platform`，`sourceTransport=github-mcp|github-app-api`，`hostingProvider` 独立；不得把 MCP 或 Pages 当 repository provider。
- Required check：`v12 / T04.1 github-actor-transport-model`
- 自动断言：serialization/API contract 覆盖 managed 与 user GitHub，以及 none/Pages/Cloudflare hosting 组合。
- 通过标准：更换 MCP 工具实现或 hosting provider 不改变 repository identity/source lineage。

### T04.2 用户显式选择 owner/repository

- 实现：首次部署到“我的 GitHub”必须明确选择 owner/repo/visibility；多组织权限时不得猜测；公开/Pages 另行确认。
- Required check：`v12 / T04.2 explicit-user-target`
- 自动断言：多 owner、未选 repo、private→public、Pages 未同意等 fixture 必须阻断；确认后才能写远程。
- 通过标准：不存在静默发布到错误账户/组织、复用旧项目同意或暗改 public。

### T04.3 GitHub connector 凭证零落地

- 实现：用户 access/refresh token、connector secret 不进入 Fabushi API、日志、DB、analytics、repo 或 deployment receipt。
- Required check：`v12 / T04.3 connector-secret-isolation`
- 自动断言：集成测试抓取请求/日志/持久化/遥测并扫描 token canary；发现即失败。
- 通过标准：Fabushi 只保存 repositoryId/repo/commit/treeHash、同意事件等非敏感事实。

### T04.4 用户仓库真实发布与断连降级

- 实现：通过 GitHub 官方连接器/MCP 创建/更新真实用户测试 repo；连接断开时仍保留本地项目并可改走 managed GitHub。
- Required check：`v12 / T04.4 user-github-e2e`
- 自动断言：真实 repo commit 可读取；断连后本地运行、导出和 target switch 正常；远程分叉不强推。
- 通过标准：用户 GitHub 路径不依赖 Fabushi 保存长期 GitHub 凭证。

---

## T05 可信构建与正式发布供应链

### T05.1 不受信任 PR CI

- 实现：Fork PR 仅 `pull_request`、只读 `GITHUB_TOKEN`、无 Secret、隔离 runner；禁止特权 `pull_request_target` 执行 Fork 代码。
- Required check：`v12 / T05.1 untrusted-pr-boundary`
- 自动断言：workflow policy lint + 恶意 PR fixture 尝试读取 Secret/写 repo/触发 deploy 必须失败。
- 通过标准：PR 只能验证，不能发布正式构件或污染后续可信 cache。

### T05.2 Trusted Builder 与 OIDC

- 实现：正式发布仅受保护 main/tag/release → 平台 trusted reusable workflow → OIDC；用户源码 repo 不能控制生产信任根。
- Required check：`v12 / T05.2 trusted-builder-oidc`
- 自动断言：非受保护 ref、Fork、普通 PR 触发 publish 必须拒绝；可信 ref 的 OIDC claims 与 environment 完全匹配。
- 通过标准：长期 cloud/marketplace signing secret 不作为普通 repo Secret 使用。

### T05.3 SBOM/Attestation/Provenance 同 commit

- 实现：common/native-*/web-wasm、静态/远程部署 artifact、SBOM、attestation、release manifest 全绑定同一 source commit/tree/snapshot。
- Required check：`v12 / T05.3 provenance-consistency`
- 自动断言：下载 release/deployment artifacts 后校验 digest、provenance subject、source SHA、manifest graph；任一不一致失败。
- 通过标准：每个正式构件和网页部署都可追溯至精确 commit/workflow run。

### T05.4 恶意源码不可越权发布

- 实现：恶意 managed repo/Fork 无法修改 central signing/deployment policy、污染 cache、窃取 provider credential 或生成市场接受的正式构件。
- Required check：`v12 / T05.4 malicious-source-release-negative`
- 自动断言：攻击 fixtures 覆盖 workflow overwrite、cache poisoning、fake manifest、plugin ID reuse、Pages policy bypass 和 Cloudflare credential exfiltration。
- 通过标准：全部攻击被拒绝且无可信发布副作用。

---

## T06 托管仓库接管、迁移与退出机制

### T06.1 接管资格与明确确认

- 实现：用户连接 GitHub 后可发起“转移到我的 GitHub”；展示目标 owner、权限、源码/部署/市场影响与不可逆项并再次确认。
- Required check：`v12 / T06.1 takeover-eligibility`
- 自动断言：无写权限、目标冲突、未确认或 repo policy 不兼容时拒绝；满足条件生成 transfer plan。
- 通过标准：不存在静默所有权迁移，hosting 可以保持、重建或停用但必须明确选择。

### T06.2 Managed → User GitHub 真实迁移

- 实现：执行真实 transfer 或受控 migration，保留 Git history，尽可能保留 Issues/PR/Releases；记录迁移方式。
- Required check：`v12 / T06.2 managed-to-user-migration`
- 自动断言：迁移前后 commit graph/default branch/source files 一致；目标 repositoryId/owner 更新；失败不删除源 repo。
- 通过标准：真实测试项目从 managed owner 迁移到用户测试 GitHub，用户可继续提交。

### T06.3 Lineage 与市场来源更新

- 实现：市场更新 repository identity/lineage/host history，旧链接有明确迁移状态，不把接管后的 repo 继续标作平台代管。
- Required check：`v12 / T06.3 migration-lineage`
- 自动断言：API/market fixtures 验证 before/after identities、source commit 和 deployment relationship 连续。
- 通过标准：用户能证明作品来源连续，ownership/custody/hosting 状态准确。

### T06.4 失败回滚与非破坏退出

- 实现：迁移中断、权限变化、目标冲突或 hosting 重建失败时不得删除原 repo 或本地 Workspace；可安全重试。
- Required check：`v12 / T06.4 migration-rollback`
- 自动断言：在各迁移阶段注入失败，验证至少存在一个完整源码副本，deployment record 可恢复且未知结果会 reconcile。
- 通过标准：无数据丢失、无 orphaned ownership、无重复 repo/deployment。

---

## T07 规模治理、部署路由与成本控制

### T07.1 Managed Org 权限与 Actions 策略

- 实现：独立 managed org/shard 默认权限、GitHub App、Actions allowlist/reusable workflow、Fork policy、branch/tag ruleset 和 environment 标准化。
- Required check：`v12 / T07.1 managed-org-policy`
- 自动断言：读取真实测试组织/仓库策略并与 policy-as-code 比对；`bhrumom` 和 managed org 信任设置不可互换。
- 通过标准：用户源码不能获得组织管理、官方 signing 或 production environment 权限。

### T07.2 配额、滥用、容量与部署路由

- 实现：每用户 repo/build/storage/rate quota、org shard 水位、Cloudflare project 水位、Pages eligibility/policy gate、abuse 检测和异常批量建仓防护。
- Required check：`v12 / T07.2 quota-and-abuse`
- 自动断言：100k/50k 文档上限的配置护栏、满 shard、Cloudflare Pages 100-project 水位、Pages 非静态/无公开同意/不合规用途、并发超额等 fixtures 均正确路由或阻断。
- 通过标准：系统不宣传或依赖无限资源；达到配额只阻止远程副作用，不损坏本地源码。

### T07.3 成本归集与预算护栏

- 实现：按 user/app/sourceBinding/build/webDeployment 记录 Actions minutes、artifact/storage、Pages/Workers 等可得用量与成本估计；只在明确上线触发远程 build。
- Required check：`v12 / T07.3 cost-accounting`
- 自动断言：usage events 聚合、同 hash 去重、预算阈值、private/public runner 差异、none/Pages/Cloudflare routing 的归属正确。
- 通过标准：可回答“哪个项目为什么使用了哪个供应商、消耗多少资源”，不得用笼统的 `$0` 掩盖配额。

### T07.4 生命周期、归档、删除与审计

- 实现：private/public policy、inactive archive、删除/恢复窗口、账号删除与 repo 删除解耦、导出/迁移、完整审计。
- Required check：`v12 / T07.4 lifecycle-audit`
- 自动断言：archive/delete/restore/export/transfer fixtures + audit immutable event assertions；稳定 app URL 在 hosting 迁移后保持有效。
- 通过标准：删除法布施账号不得静默删除 GitHub repo；敏感操作可审计且平台托管可退出。

---

## T08 真实双路径 E2E 与市场验收

### T08.1 无 GitHub 用户完整链路

- 实现：新用户仅登录 Fabushi → AI 生成 → 本地保存/离线重开/运行 → 明确上线 → managed repo → trusted Release → 合规 hosting route → 市场 → 安装。
- Required check：`v12 / T08.1 managed-user-full-e2e`
- 自动断言：真实测试账号、独立 managed org 真实 repo、真实 workflow/release/Pages 或 Cloudflare receipt/market response。
- 通过标准：用户全程不需要 GitHub 账号；repo 不在 `bhrumom`；source/hosting/market 三种状态显示准确。

### T08.2 用户自己的 GitHub 完整链路

- 实现：独立本地项目或等价 fixture 通过 GitHub connector/MCP 明确发布到用户测试 GitHub → trusted Release/可选 hosting → 市场 → 安装。
- Required check：`v12 / T08.2 user-github-full-e2e`
- 自动断言：真实 repositoryId/commit/tree/release 可复核，Fabushi 无 connector secret，多 owner 选择有审计。
- 通过标准：repository owner 明确属于用户选择目标，平台只登记来源事实。

### T08.3 托管项目接管链路

- 实现：T08.1 的 managed project 迁移到用户 GitHub，再继续构建/发布新版本，并处理原 hosting 目标。
- Required check：`v12 / T08.3 takeover-full-e2e`
- 自动断言：迁移前后 history/lineage/market source/version/稳定 app URL 连续，故障注入可回滚。
- 通过标准：平台托管不存在不可退出锁定，旧 owner 不再被显示为当前 custody。

### T08.4 多平台构件、本地运行与部署矩阵

- 实现：同一版本验证 macOS/Windows/Linux native 与 iOS/Android/Web/PWA web-wasm 的选择、下载、启动；另验证一个 Pages 静态样例和一个 Cloudflare 动态样例的自动路由。
- Required check：`v12 / T08.4 platform-install-matrix`
- 自动断言：GitHub-hosted runner/设备或模拟器 E2E；各平台只取最小兼容构件；Pages 样例无动态能力，Cloudflare 样例证明动态需求。
- 通过标准：各平台运行相同 Tool Contract/插件版本，网页 hosting 不替代本地 Runtime 验收。

### T08.5 供应链一致性总校验

- 实现：最终 release 的 repositoryId/source commit/tree hash/snapshot/manifest/artifact digest/SBOM/attestation/hosting receipt/market record/install receipt 全链一致。
- Required check：`v12 / T08.5 end-to-end-provenance`
- 自动断言：统一 verifier 从 GitHub/Release/hosting/market/install evidence 重建 identity graph 并比较。
- 通过标准：任一 SHA、digest、identity、provider receipt 或同意计划不一致都失败。

### T08.6 最终安全与回归门禁

- 实现：聚合 T01-T08 required checks，并运行恶意 Fork、Secret、权限、Pages policy bypass、Cloudflare quota、迁移失败、未知结果和远程分叉回归套件。
- Required check：`v12 / T08.6 final-project-gate`
- 自动断言：读取同一 commit 的全部 33 个前置 check 和 evidence；禁止 skip/allow-failure/过期证据伪通过。
- 通过标准：T01-T08 全部 34 个原子任务 `passed`，项目进度自动计算为 100%。

---

## Calendar / Drive / GitHub 同步协议

Google Calendar 中每个原子任务使用稳定标题：`☐ TASK Txx.n <short title>`。当且仅当对应 required check 成功且业务证据满足本文件后，才更新为 `☑ TASK Txx.n <short title>`，并写 commit、run/check URL、外部 evidence 和完成时间。

父阶段 Calendar 进度按本文件必需任务数量自动计算，不得手动声称 100%。Google Drive 保存产品目标和阶段上下文；Calendar 保存计划和进度视图；GitHub 保存代码、Checks 和可验证工程事实。三者冲突时，不得把 Calendar/文档勾选当工程完成证据。

## 最终报告最小内容

- 34 个 check 的 conclusion、commit 和 run URL；
- managed org/repositoryId 与用户 GitHub repositoryId，证明未混入 `bhrumom`；
- local snapshot、source commit/tree、build、Release、SBOM、attestation、hosting、market 和 install 的 identity graph；
- Pages policy/公开同意证据与 Cloudflare 动态路由证据；
- GitHub connector secret 零落地扫描结果；
- managed → user GitHub 迁移和回滚证据；
- 各平台构件选择与本地运行证据；
- 未通过项、剩余风险和实际成本/配额，不得隐藏。
