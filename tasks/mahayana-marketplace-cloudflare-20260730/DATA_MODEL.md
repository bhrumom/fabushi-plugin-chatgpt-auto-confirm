# 数据模型：MCP Apps-only 大乘市场 v2

> v12.2 纠偏：`LocalWorkspace` 是设备端第一事实源；源码托管、构建、网页部署和市场版本为正交实体。旧的 Cloudflare-only `plugin_deployments` 不能继续作为新写入模型。

## 0. 本地优先与双 GitHub 核心实体

设备端 `local_workspaces` 至少保存 `local_project_id`、`app_id`、`plugin_id`、`workspace_revision`、`accepted_tree_hash` 和各层 sync 状态；真实磁盘路径不得上传。

服务端新增或使用等价模型：

```text
miniapp_identities
  app_id immutable
  plugin_id
  author_subject_id
  publisher_subject_id nullable
  official_status official | community | unverified
  lineage_id

source_snapshots
  snapshot_id
  app_id
  archive_sha256
  tree_hash
  file_manifest_json
  scanner_version
  created_at

source_bindings
  source_binding_id
  app_id
  snapshot_id
  provider local | github
  actor user | platform
  transport local-fs | github-mcp | github-app-api
  custody device | platform-managed | user-owned
  managed_org_id nullable
  repository_id nullable
  repository_owner nullable
  repository_name nullable
  commit_sha nullable
  tree_hash
  state none | consented | syncing | hosted | diverged | failed | outcome-unknown

web_deployments
  web_deployment_id
  app_id
  build_id
  provider none | github-pages | cloudflare-pages | cloudflare-workers | external
  runtime_profile local-native | local-web-wasm | web-static | remote-edge
  policy_decision_json
  provider_project_ref nullable
  provider_deployment_id nullable
  public_url nullable
  state none | queued | deploying | deployed | failed | rolled-back

deployment_intents
  intent_id
  app_id
  idempotency_key unique per subject
  plan_version
  expected_snapshot_sha256
  source_target managed-github | user-github
  requested_visibility private | public
  hosting_preference auto | none | github-pages | cloudflare | external
  consents_json
  status planned | confirmed | applying | applied | rejected | failed | outcome-unknown
```

GitHub `repository_id` 是远程来源主键；owner/name 是可变 locator。`source_host/repository_owner/publisher/official_status` 必须分开，任何一个都不能推导其他字段。

## 1. 设计原则

- 插件身份、版本、部署和审核分离；
- 正式版本只追加、不覆盖；
- MCP Apps runtime 合规是正式发布的必填数据；
- 旧插件只能作为迁移记录存在，不能安装或运行；
- 所有安全决策可从数据库和审计事件复现。

## 2. `publisher_namespaces`

```text
id
namespace unique
publisher_user_id
verification_type
verification_subject
verification_state
verified_at
created_at
updated_at
```

## 3. `marketplace_plugins`

```text
plugin_uuid immutable UUID
plugin_id unique stable ID
publisher_user_id
namespace_id
display_name
description
deployment_mode managed | self_hosted
visibility private | unlisted | public
review_tier unlisted | community | verified | official | blocked | migration_required
review_state pending | approved | rejected | suspended
latest_version
production_version
migration_state ready | migration_required | blocked
created_at
updated_at
```

`production_version` 只能引用已批准、未撤销且 MCP Apps 合规的 release。

## 4. `plugin_deployments`（兼容投影）

```text
id
plugin_uuid
provider none | github_pages | cloudflare_pages | cloudflare_workers | external
mode managed | self_hosted
provider_project_ref
service_name
stable_hostname
mcp_route
ownership_state
created_at
updated_at
```

该表只保留给既有查询兼容，权威新写入为 `web_deployments`。每个插件可以没有网页部署，也可以有 preview/production/history；不得把 source binding 写入本表。不同用户的不受信任服务端代码不得共享平台写凭证、Secret 或数据库边界。

## 5. `plugin_releases`

```text
id
plugin_uuid
plugin_id
version
release_status staged | pending | approved | rejected | revoked | deprecated | migration_required
review_tier
package_url
package_sha256
package_size
package_content_type
manifest_url
provenance_url
homepage_url
runtime_url
runtime_kind              mcp-app
runtime_profiles_json
hosting_provider          none | github_pages | cloudflare_pages | cloudflare_workers | external
remote_mcp_sdk_major      nullable
remote_transport_mode     nullable
remote_legacy_allowed     nullable
mcp_apps_extension        io.modelcontextprotocol/ui
ui_resources_json
ui_mime_types_json
ui_display_modes_json
ui_csp_json
tool_visibility_json
host_min_version
permissions_json
source_repository
source_commit_sha
source_workflow
source_run_id
metadata_version
metadata_expires_at
published_at
approved_at
revoked_at
revocation_reason_code
replacement_version
tuf_target_path
```

唯一约束：

```text
UNIQUE(plugin_id, version)
UNIQUE(package_url)
```

正式 release 的数据库约束必须保证：

- `runtime_kind = 'mcp-app'`；
- `runtime_profiles_json` 至少声明一个真实构件/运行 profile；
- 若 `hosting_provider IN ('cloudflare_workers', 'external')` 且存在远程 MCP，则 `remote_mcp_sdk_major = 2`、`remote_transport_mode = 'stateless-http'`、`remote_legacy_allowed = false`；
- 若 `hosting_provider IN ('none', 'github_pages', 'cloudflare_pages')` 且没有远程 MCP，则上述 remote 字段为空，不得伪造 endpoint；
- extension、UI resource 和 MIME 非空。

## 6. `plugin_release_deployments`

```text
id
release_id
provider none | github_pages | cloudflare_pages | cloudflare_workers | external
provider_version_id
provider_deployment_id
deployment_stage preview | production | rollback
public_url nullable
mcp_url nullable
artifact_sha256
policy_decision_json
legacy_rejection_verified nullable boolean
stateless_cross_edge_verified nullable boolean
static_export_verified nullable boolean
created_by
created_at
superseded_at
```

远程 MCP production 只能引用 `legacy_rejection_verified = true` 且 `stateless_cross_edge_verified = true` 的记录；静态 production 只能引用 `static_export_verified = true` 且 Pages/Cloudflare policy gate 通过的记录；`provider=none` 不创建远程 deployment receipt。

## 7. `plugin_ui_resources`

```text
id
release_id
resource_uri
mime_type
content_sha256
csp_json
display_modes_json
cache_policy_json
created_at
```

约束：

- URI 必须为 `ui://`；
- MIME 必须为 `text/html;profile=mcp-app`；
- 同一 release 内 URI 唯一；
- 内容哈希与实际 resource 一致。

## 8. `plugin_tool_visibility`

```text
release_id
tool_name
model_visible boolean
app_visible boolean
risk_class read | write | destructive | open_world
permission_key
created_at
```

跨插件 app-only Tool 调用永远不允许。

## 9. `plugin_permissions`

```text
release_id
permission_type network | filesystem | secret | command | mcp_tool | ui_surface | browser
permission_value
access_level
required
created_at
```

支持版本间权限 diff；市场元数据与包内 manifest 必须一致。

## 10. OIDC 与 provenance

### `publish_intents`

```text
id
plugin_uuid
version
stage
publisher_user_id
repository
workflow
commit_sha
github_environment
oidc_audience
nonce_hash
nonce_used_at
expires_at
created_at
```

### `release_provenance`

```text
release_id
repository
commit_sha
workflow_path
workflow_ref
run_id
builder_identity
artifact_sha256
attestation_url
verified_at
verification_result
raw_digest
```

不得存原始 token、完整 OIDC JWT 或 Secret。

## 11. 签名、审核和撤销

保留独立表：

- `marketplace_signing_keys`；
- `release_signatures`；
- `plugin_reviews`；
- `plugin_revocations`；
- `plugin_production_history`；
- `marketplace_audit_events`。

审核 checks 必须保存 MCP Apps、SDK v2、stateless、legacy rejected、UI resource、CSP、visibility 和 browser smoke 结果。

## 12. 旧插件迁移记录

旧记录不得迁入正式 `plugin_releases` 后伪装成可运行 v2。使用独立表或独立不可运行状态：

```text
legacy_plugin_inventory
legacy_plugin_id
legacy_version
source_reference
migration_state detected | queued | converted | retired
replacement_release_id nullable
last_seen_at
```

规则：

- 旧记录不可成为 production；
- 不生成可安装 URL；
- 不生成假签名或假 provenance；
- 新 Host 不读取其 runtime；
- 仅迁移工具、升级 UI 和审计可读取。

## 13. 客户端本地状态

```json
{
  "pluginId": "io.mahayana.bhrum.hello",
  "installedVersion": "1.1.0",
  "installedSha256": "...",
  "runtimeKind": "mcp-app",
  "mcpSdkMajor": 2,
  "legacyAllowed": false,
  "uiResources": ["ui://..."],
  "permissions": {},
  "csp": {},
  "reviewTier": "community",
  "migrationState": "ready",
  "highestKnownSafeVersion": "1.1.0",
  "metadataVersion": 4,
  "revocationState": "clear"
}
```

旧本地插件状态改为：

```json
{
  "migrationState": "migration_required",
  "runnable": false,
  "upgradeTarget": "1.1.0"
}
```

## 14. 审计事件

至少记录：

```text
plugin.created
release.staged
mcp_apps.validated
sdk_v2.validated
legacy.rejected
ui_resource.validated
csp.validated
tool_visibility.validated
release.approved
release.promoted
plugin.migration_required
host.upgrade_required
release.revoked
plugin.blocked
```

不得记录 token、Secret、敏感表单值或安装包正文。
