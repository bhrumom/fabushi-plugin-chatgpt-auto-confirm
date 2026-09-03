# GitHub 原生共创的 MCP App 仓库模型

## 文档地位

本文件是任务 `mahayana-marketplace-cloudflare-20260730` 的最高优先级源码协作、Fork、Pull Request、AI 修复和派生发布约束。

> v12.2 范围纠偏：本文件只适用于用户已经明确上传的 source snapshot 或正式市场版本。local-only 小程序不要求 GitHub 仓库；managed 用户仓库必须进入与 `bhrumom` 隔离的 managed user apps 组织。生成、上传、网页部署和市场发布的优先规则见 `LOCAL_GENERATION_GITHUB_DEPLOYMENT.md`。

它建立在以下架构之上：

1. `MCP_APPS_ONLY.md`：统一 MCP Apps UI、Host 与安全协议；
2. `LOCAL_FIRST_MCP_APPS.md`：本地优先执行；
3. `LOCAL_WEB_MCP_RUNTIME.md`：移动/Web 本地网页与 WASM Runtime；
4. `MULTI_ARTIFACT_MCP_APP.md`：单一插件身份、单一版本、多平台构件发布。

核心结论：

> 一个完成源码托管或进入市场的大乘小程序，同时是可安装 MCP App 和可协作 GitHub 仓库；local-only 阶段仍以设备 Workspace 为事实源。源码可被社区 Fork、修改和提 PR；正式插件身份、签名和更新通道由发布者控制。Fork 可以贡献回上游，也可以更换插件身份后独立发布为派生 App。

## 1. 一个已托管小程序对应一个规范化源码仓库

正式市场版本必须绑定可验证的源码仓库身份：

```json
{
  "source": {
    "provider": "github",
    "repository": "publisher/global-dharma",
    "repositoryId": 123456,
    "defaultBranch": "main",
    "commit": "<40-char-sha>",
    "treeHash": "<source-tree-hash>",
    "license": "Apache-2.0",
    "visibility": "public",
    "subdirectory": "."
  }
}
```

要求：

- 市场使用稳定 GitHub repository ID，而不仅依赖可改名的 `owner/name`；
- 每个正式 Release 必须记录精确 source commit；
- provenance、构件签名和父级 Release Manifest 必须绑定同一 commit；
- 仓库转移、改名、归档、删除或变为私有时必须重新验证；
- 开源仓库必须声明 SPDX license；
- 市场展示“源码”“许可证”“贡献指南”“问题”“Pull Requests”和“派生项目”。

默认采用“一仓库一个主要小程序”。确需 monorepo 时必须绑定不可变 `subdirectory`，并为每个插件独立构建、签名和发布。

## 2. 标准仓库结构

```text
repository/
├── .github/
│   ├── CODEOWNERS
│   ├── ISSUE_TEMPLATE/
│   ├── PULL_REQUEST_TEMPLATE.md
│   ├── workflows/
│   │   ├── pr-untrusted.yml
│   │   ├── main-trusted.yml
│   │   └── release-trusted.yml
│   └── dependabot.yml
├── CONTRIBUTING.md
├── SECURITY.md
├── LICENSE
├── mcp-app.yaml
├── common/
├── crates/ or packages/
├── artifacts/
├── tests/
└── docs/
```

仓库模板必须预置：

- MCP Tool Contract 测试；
- native CLI 与 web-wasm 一致性测试；
- MCP Apps conformance、CSP、权限和 sandbox 测试；
- 多平台构建；
- SBOM 与 artifact attestations；
- Fork PR 的无密钥 CI；
- 合并后受信任发布；
- CODEOWNERS、规则集和发布权限边界。

## 3. 社区用户的三条路径

### 3.1 报告问题

用户在小程序详情或运行错误页点击：

```text
报告问题
```

Host 生成经过脱敏的诊断包：

- 插件 ID/version/source commit；
- 平台与构件 ID；
- Tool 名称、错误码和可公开日志；
- 不包含 Token、Cookie、Secret、私密内容或用户数据；
- 用户确认后创建 GitHub Issue。

### 3.2 让 AI 修复并贡献回上游

```text
发现问题
→ 创建或关联 Issue
→ Fork 上游仓库
→ AI 在用户 Fork 的分支修改
→ 本地/Actions 运行无密钥测试
→ 生成变更说明和风险报告
→ 创建 Draft Pull Request 到上游
→ 维护者与 CODEOWNERS 审核
→ 合并后由上游决定何时发布
```

AI 必须：

- 在独立分支工作；
- 不直接推送上游受保护分支；
- 在 PR 中关联 Issue；
- 列出复现、根因、改动、测试、权限差异、Tool Contract 差异和构件影响；
- 对生成代码标记 AI 辅助来源；
- 未获用户明确同意不得创建公开 Issue/PR；
- 不把本机敏感日志提交到仓库。

### 3.3 Fork 后发布自己的派生 App

用户可选择：

```text
Fork 并自定义
→ AI 修改
→ 在自己的仓库测试
→ 注册自己的发布者命名空间
→ 更换 plugin ID
→ 用自己的签名和发布工作流发布
```

派生发布必须：

- 使用新的 plugin ID，例如 `io.mahayana.alice.global-dharma-plus`；
- 使用派生发布者自己的市场身份、签名和 OIDC 信任；
- 不得复用上游 plugin ID、官方徽章、签名或更新通道；
- 遵守上游许可证、NOTICE、商标和署名要求；
- 在市场显示 `Based on <upstream app>`；
- 记录 upstream repository、upstream commit 和 fork repository；
- 独立承担权限、审核、撤销、漏洞和发布责任。

## 4. 派生关系与上游同步

市场数据模型必须支持：

```json
{
  "lineage": {
    "kind": "fork",
    "upstreamPluginId": "io.mahayana.global-dharma",
    "upstreamRepository": "publisher/global-dharma",
    "upstreamCommit": "<sha>",
    "forkRepository": "alice/global-dharma",
    "divergedAt": "2026-07-31T00:00:00Z"
  }
}
```

派生 App 页面显示：

- 原始项目；
- Fork 来源 commit；
- 相对上游新增/删除的 Tool；
- 权限差异；
- 当前落后/领先上游多少提交或版本；
- 是否可安全同步上游；
- 是否存在上游已修复但派生版本未合入的漏洞。

提供操作：

```text
同步上游
比较差异
选择性合并提交
向上游提交 PR
发布派生版本
```

不得自动强制合并上游代码。AI 可以完成 merge/rebase/cherry-pick、解决冲突并运行测试，但最终变更和发布由 Fork 所有者确认。

## 5. Pull Request 与正式发布必须隔离

### 不受信任 PR CI

来自 Fork 的 PR 使用 `pull_request`：

- `GITHUB_TOKEN` 只读；
- 不提供仓库、组织、市场或 Cloudflare Secret；
- 不获得生产 OIDC 发布权限；
- 在临时 GitHub-hosted runner 或等价隔离环境运行；
- 只执行构建、单元测试、Tool Contract、MCP Apps conformance、静态扫描和权限差异检查；
- 生成的构件仅用于测试，不能成为市场正式 Release。

禁止使用具有 Secret 或写权限的 `pull_request_target` 去 checkout、构建或执行 Fork 代码。需要标签、评论或分类时，特权工作流只能读取 PR 元数据，不得执行 PR 代码或其构件。

### 受信任发布

正式发布只能由受保护上游仓库中的可信事件触发：

```text
PR 合并到受保护默认分支
→ trusted main CI
→ 维护者批准版本发布
→ protected tag/release
→ reusable trusted release workflow
→ OIDC 短期凭证
→ 多构件构建
→ SBOM + artifact attestations
→ 市场签名与发布
```

PR 合并本身不等于立即更新用户设备。只有创建新的语义版本并完成受信任发布，市场才产生新的可安装版本。

## 6. 仓库保护

每个正式上游仓库必须配置：

- 默认分支 ruleset；
- 禁止直接 push；
- 必须通过 Pull Request；
- 至少一个维护者审批；
- 敏感目录要求 CODEOWNERS 审批；
- dismiss stale approvals；
- 所有必需检查通过；
- 对发布标签进行保护；
- 限制谁可以触发 production release；
- `.github/workflows/`、`CODEOWNERS`、权限清单、发布清单和签名配置由发布者安全团队或维护者所有；
- 可选要求签名提交和线性历史。

示例：

```text
/.github/workflows/        @publisher/security
/.github/CODEOWNERS         @publisher/security
/mcp-app.yaml               @publisher/maintainers
/permissions.json           @publisher/security
/tools.json                 @publisher/maintainers
/crates/core/               @publisher/core
/runtime/web/               @publisher/web
```

## 7. AI 共创入口

大乘客户端和市场提供：

```text
查看源码
报告问题
让 AI 诊断
让 AI 修复
Fork 并自定义
创建上游 PR
发布为派生 App
同步上游
比较我的版本与官方版本
```

AI 使用 GitHub 连接器完成：

- 创建 Fork 或使用已有 Fork；
- 创建分支；
- 读取 Issue、PR 和仓库规范；
- 修改代码；
- 运行与风险相称的测试；
- 推送分支；
- 创建 Draft PR；
- 根据审查意见继续修改；
- 不自动合并上游 PR；
- 不在 Fork PR 上执行正式发布。

客户端必须始终显示当前目标：

```text
正在修改：alice/global-dharma
上游项目：publisher/global-dharma
发布身份：io.mahayana.alice.global-dharma-plus
```

避免用户误把 Fork 修改当成上游官方版本。

## 8. 插件市场中的来源信任

市场为每个版本展示并验证：

- 上游/派生身份；
- GitHub repository ID、URL 和 source commit；
- 许可证；
- 发布者 GitHub 身份与市场身份绑定；
- Actions workflow、run ID 和 reusable workflow ref；
- artifact attestation、SBOM、provenance；
- 构件 SHA 和签名；
- 最近安全审查；
- 未解决高风险 Issue/Advisory；
- 上游同步状态。

源码公开不等于自动可信。可信度来自：

```text
可审计源码
+ 受保护仓库
+ 可信 CI
+ source commit 绑定
+ 构件证明
+ 市场签名
+ 权限审核
```

## 9. 许可证与商标

Fork 和派生发布前必须检查：

- SPDX license 是否允许修改和再发布；
- 是否要求公开源码、NOTICE 或相同许可证；
- 商标、名称、图标是否允许继续使用；
- 第三方依赖许可证；
- 数据、模型和内容资产的授权。

如果仓库没有明确许可证，市场不得把“源码可见”解释为允许 Fork 后再发布。可以允许用户为自己研究修改，但不得提供“一键公开发布派生 App”。

## 10. 完成标准

该功能只有在以下真实流程全部通过后才算完成：

1. 一个公开 MCP App 仓库绑定市场 App；
2. 用户从市场创建 Fork；
3. AI 根据真实 Issue 在 Fork 分支修复；
4. Fork PR 在无 Secret、只读 Token 环境通过测试；
5. 创建 Draft PR 回上游；
6. CODEOWNERS 和 ruleset 正确阻止未审批合并；
7. 上游合并后不会自动泄露发布权；
8. 可信 release workflow 使用 OIDC、attestation 和 source commit 发布新版本；
9. 用户 Fork 更换 plugin ID 后发布派生 App；
10. 市场正确展示上游、派生关系、许可证和差异；
11. 派生 App 能同步上游并由 AI 解决冲突；
12. 恶意 Fork PR 无法读取 Secret、写入上游、污染缓存或发布正式构件；
13. 上游撤销、漏洞修复和许可证状态能传递给派生版本风险提示。
