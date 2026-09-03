# 大乘本地优先、双 GitHub 托管与分级上线任务

任务 ID：`mahayana-marketplace-cloudflare-20260730`

目标版本：`goalVersion = 12`（架构修订 `v12.2`）

文档状态：已完成方案纠偏，按 34 个原子门禁实施与验收。

## 一句话目标

> AI 先把代码可靠地保存在用户本地；只有用户明确选择上线，才把安全快照托管到官方 managed GitHub 组织或用户自己的 GitHub，并按应用能力选择 GitHub Pages、Cloudflare 或仅本地运行。

## 最高优先级设计

1. `EXECUTION_TASKS_V12.md`：34 个原子任务、固定 required check 和完成证据；
2. `LOCAL_GENERATION_GITHUB_DEPLOYMENT.md`：本地工作区、双 GitHub 源码路径、部署路由、成本与规模治理；
3. `GITHUB_NATIVE_MCP_APP_COLLABORATION.md`：Fork、PR、AI 修复、派生发布和供应链安全；
4. `MULTI_ARTIFACT_MCP_APP.md`：common、native CLI、web-wasm 等按平台选择的构件；
5. `LOCAL_WEB_MCP_RUNTIME.md`、`LOCAL_FIRST_MCP_APPS.md`、`MCP_APPS_ONLY.md`：本地运行、MCP Apps Host 与旧协议删除。

发生冲突时按以上顺序解释；旧文档中的“每个项目默认创建 Cloudflare 项目”“生成即创建 GitHub 仓库”或“managed 用户仓库进入 `bhrumom`”均已废止。

## 产品与成本决策

- `local-only` 是默认状态，生成、编辑、本地运行不需要 GitHub 或 Cloudflare；
- 官方托管使用独立 managed user apps GitHub 组织和 GitHub App 短期安装令牌，用户不需要 GitHub 账号；
- 用户自己的 GitHub 通过官方 GitHub MCP/连接器操作，法布施不保存用户 GitHub 凭证；
- GitHub Pages 只作为合规的公开纯静态项目的优先零增量成本目标，不是无限容量或商业 SaaS 通用主机；
- Cloudflare 现有部署继续保留，服务动态、鉴权、API、实时和 GitHub Pages 不适用的项目；
- 产品身份使用稳定 `appId`、GitHub `repositoryId` 和法布施入口 URL，不与 owner/repo 或部署供应商耦合；
- 官方源码 `bhrumom`、managed 用户源码、用户自有源码属于三个不同信任域。

所有市场发布、父级 Release Manifest、构件 provenance、SBOM 与 attestations 必须绑定同一精确 source commit。

## GitHub 共创原则

- 市场版本绑定稳定 GitHub repository ID、精确 commit、tree hash 和 SPDX license；
- 用户可以报告 Issue、Fork、让 AI 修复并创建 Draft PR；
- AI 只能在用户 Fork 或授权分支修改，不能直接推送上游受保护分支；
- Fork PR 只运行 `pull_request` 无 Secret、只读 Token、隔离环境 CI；
- 禁止在有 Secret/写权限的 `pull_request_target` 中 checkout 或执行 Fork 代码；
- PR 合并不等于发布；只有上游受保护分支、受保护标签和可信 Release workflow 能发布正式版本；
- 正式发布使用 OIDC、SBOM、artifact attestations、provenance、source commit 绑定和市场签名；
- Fork 可贡献回上游，也可更换 plugin ID 后发布自己的派生 App；
- 派生 App 必须展示上游来源、许可证、差异、权限变化和同步状态，不能复用上游官方身份或签名。

## 多构件运行原则

同一个全球法布施 Release 包含：

- `common`：MCP Apps UI、Tools、权限、Skills 和工作流；
- `native-*`：macOS、Windows、Linux 的本地 CLI；
- `web-wasm`：iOS、Android、桌面 WebView 和普通 Web/PWA 的本地网页/WASM Runtime。

平台安装器只下载当前平台需要的最小构件，但所有构件共享同一插件 ID、版本和 Tool Contract。

## 实施状态与交接

`v12.2` 不重启当前队列任务，使用 `applyMode = next_chat` 从首个未通过门禁继续。2026-08-09 的权威交接基线为 T01 `0/4`，首个阻塞项是 `v12 / T01.1 identity-schema`；后续状态以 GitHub required checks 和证据为准，而不是以本文快照为准。

本任务已经进入全面实施与验收：

- 按受保护分支、Pull Request、CODEOWNERS 和 ruleset 流程推进实现与合并；
- 启动并持续执行所需 GitHub Actions、真实发布和跨平台验收；
- 所有正式 Release 继续遵守可信工作流、OIDC、SBOM、artifact attestations、provenance 和人工/环境审批；
- 只有 34 个原子门禁全部取得可复核真实证据后，任务状态才可报告为完成。
