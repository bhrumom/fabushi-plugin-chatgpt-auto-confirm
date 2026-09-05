# Project-team orchestration protocol

本文件是 `chatgpt-project-orchestration` 的执行参考。它描述可移植的编排协议，
不替代目标仓库自己的治理文件；仓库规则、用户最新已落盘要求和保护分支规则优先。

本协议刻意把“Skill 规则”和“运行时能力”分开：规则可以要求某项能力，但只有在
调用方提供可核验实现和证据后才能通过门禁。没有实现的能力必须进入原子任务 DAG，
不能通过提示词或人工口头确认绕过。

## 1. 控制状态

编排器维护以下最小状态，不把敏感信息存入状态：

```text
project_id       = FAB-Pxxxx
project_key      = stable project key
repository       = owner/repository
project_path     = projects/<slug>
stage            = PLANNED | EXECUTING | REVIEW | TEST_RELEASE |
                   VIDEO_REVIEW | FORMAL_RELEASE | COMPLETE | BLOCKED
group_tabs       = architecture, execution, review, test-release, formal-release
atomic_tasks     = [{ task_id, task_path, owner_chat, status, branch, pr, head_sha }]
reviewed_pr_head_sha = exact reviewed PR head SHA, invalidated by any review-key change
accepted_main_sha    = exact protected-main SHA, once available
architecture_revision = immutable architecture revision
spec_digest      = digest of the canonical task/spec snapshot
evidence         = [screenshots, video, trace, reports, logs, run IDs]
next_action      = one concrete action
max_parallel_execution = runtime capability, not a hard-coded value in the Skill
```

`owner_chat` 是对话引用，不是事实来源。每个 group tab 必须唯一；如果 UI/API 返回
多个同组标签页，先以稳定 tab ID、标题和 URL 去重，再继续。保留仍处于生成状态的
页面，只有重复且不在工作的页面才可关闭。

## 2. 统一消息包

每次发给 ChatGPT 的工作消息都应包含以下区块；长文放仓库文件，提示词只传路径和
本轮目标：

```text
[PROJECT]
project_id: FAB-Pxxxx
project_key: KEY
repository: owner/repository
project_path: projects/<slug>
stage: EXECUTING

[AUTHORITATIVE INPUTS]
- projects/PORTFOLIO.json (canonical main)
- projects/<slug>/SOURCE_OF_TRUTH.md
- <exact task or review file paths>

[ROLE]
You are the <architecture|execution|review|test-release|formal-release> group.
Use Chat mode, GPT-5.6 Sol, Extra High reasoning. Work only in this group tab.

[ACTION]
<one bounded objective>

[REQUIRED OUTPUT]
Read the listed files, perform the allowed work, write every result to the
listed repository records, and return the exact commit/PR/head/evidence/next
action. Do not claim completion while the generation stop control is visible.

[GATES]
<acceptance criteria and explicit fail-closed conditions>
```

发送器必须记录 `connectorConfirmed`, `inputConfirmed`, `messageConfirmed` 和 `sent`
等发送验证结果；缺少消息气泡确认时不得开始回答超时计时。用户要求或上下文若尚未
落盘，先做 redaction/secret scan，只持久化脱敏后的 canonical requirement snapshot。

### 2.1 可恢复状态机

项目级状态建议细化为：

```text
NEW → ARCHITECTING → ARCH_FROZEN → ATOMS_READY → EXECUTING → CODE_REVIEWING
→ ALL_ATOMS_APPROVED → MERGING_TO_PROTECTED_MAIN → MAIN_CANDIDATE_FROZEN
→ PACKAGED_E2E → VIDEO_REVIEW → RELEASE_READY → FORMAL_RELEASE
→ POST_RELEASE_VERIFY → COMPLETE
```

单个原子任务使用：

```text
READY → CLAIMED → CHAT_RUNNING → IMPLEMENTED → PR_OPEN → REVIEW_PENDING
→ HEAD_APPROVED → MERGE_READY → MERGED → DONE
```

另外保留 `SUPERSEDED`、`BLOCKED`、`INVALIDATED`。架构 revision 或 spec digest 变化
会使旧任务和旧审查失效；不得用旧 revision 的最终回答推进新目标。

## 3. 架构组输出

架构组先做只读调查，然后在一次或多次同一标签页的 Chat 中写入：

1. `docs/03-架构与实现策略.md`：现状、目标边界、组件、数据/控制流、接口、迁移和
   取舍。
2. `management/01-WBS原子任务.md`：每个原子任务唯一、可并行或明确依赖，包含文件
   所有权和验证面。
3. `management/tasks/<TASK_ID>-<slug>.md`：完整任务卡。至少包括 objective、需求
   引用、范围、依赖、验收、验证、开源调查、分支/PR、风险、下一步和时间戳。
4. `decisions/ADR-*.md`：只为难以逆转的架构、协议、数据、安全、发布或治理决策建 ADR。

原子任务应遵循：

```text
TASK_ID: <stable project-key task number>
Goal: one observable outcome
Owns: explicit files or subsystem
Depends on: task IDs or none
Produces: code/docs/evidence
Acceptance: objective checks
Blocked by: exact condition, if any
```

架构组不得用“实现全部功能”作为单个原子任务，也不得把尚未审查的聊天内容当作
架构结论。

## 4. 执行组并行规则

- 一个 Chat 只认领一个原子任务，但所有执行 Chat 共用执行组的唯一标签页。
- 开始前读取 `task_path` 和其引用的 `SOURCE_OF_TRUTH.md`；若任务文件缺失或
  与 canonical main 不一致，返回 `blocked`，让架构组修复记录。
- 先确认依赖完成和文件所有权不重叠。依赖独立的任务可以并行；冲突任务必须串行。
- 修改实现、测试和任务记录；用项目规定的分支/PR 工作流交付。不要把本地重型构建
  结果当成验收，Fabushi 的应用构建和测试交给 GitHub Actions。
- 完成时更新 WBS、状态、变更日志、验收矩阵和证据索引，并返回：提交 SHA、PR URL、
  PR head SHA、执行过的检查、未完成项和下一步。代码和记录尽量处于同一变更流。

并行能力由调用方明确声明 `max_parallel_execution`。它可以限制同时运行的任务数量，
但不能改变“一项目组一标签页”的不变量，也不能让执行 Chat 自行创建项目组或标签页。
若现有 Browser 控制器只能为并行任务提供额外标签页，必须返回 `blocked`，等待架构组
调整调度策略或运行时实现共享项目组标签页。

## 5. 代码审查组精确 head 门禁

审查消息必须列出 PR 编号、实际 base SHA、声明的 head SHA、任务 ID、spec digest 和
仓库。审查组计算并锁定：

```text
review_key = SHA256(repository + pr_number + head_sha + base_sha
                    + atomic_task_id + spec_digest)
```

`review_key` 的任意组成部分变化都会使原批准失效；`base` 不能只记录分支名。
审查组随后：

1. 从 GitHub 获取 PR 实际 head、changed files、review/CI 状态和项目任务记录。
2. 检查实现是否只完成任务范围，是否有安全/并发/错误处理/回滚/许可证问题，测试
   是否验证了真实边界，项目记录是否可重建。
3. 把每一条问题写到审查记录，标注阻塞级别、文件/行和修复验收方式。
4. 通过时写出 `REVIEW-PASS`，同时锁定被审查的 `review_key`；若 PR、head、base、
   task revision 或 spec digest 任一变化，审查失效，必须重新审查。

审查组不得自行偷偷改产品代码来消除问题。需要改动时退回执行组；若只需补充审查
记录，可在审查组自己的记录变更中完成并保留关联提交。

## 6. 测试发布与证据合同

测试发布组的输入必须是审查通过的 PR。保护分支合并后，把合并事件和实际
`main` HEAD 都记录下来；不得用不同 SHA 的旧绿色结果替代。

对每条模拟用户旅程，证据目录/索引至少包含：

```text
journey_id, repository, main_sha, app_version, platform, workflow_run_id,
job_id, started_at, finished_at,
screenshots[]      # step-labelled meaningful checkpoints
operation_video[]  # complete journey, segmented only with coverage continuity
trace, test_report, platform_logs, result
retention_days, upload_if, next_action
artifact_digest, producer, source_sha, redaction_scan_result
```

截图应按动作标注，例如 `01-startup`, `02-login`, `03-navigation`, `04-search`,
`05-message`, `06-miniapp-action`, `07-result`；按场景删减，但不能只留最终截图。
视频必须覆盖从开始到结果的整条操作链。CI 上传走 always-equivalent 路径，以便
失败也能复盘；证据缺失时即使断言通过也不能进入 `VIDEO_REVIEW`。

## 7. 视频审查与正式发布

视频审查消息应引用证据索引而不是把大型视频塞进提示词，并回答：

- 是否为精确 main SHA 和正确版本？
- 是否从真实用户初始状态完成了目标动作？
- 是否覆盖启动/登录/导航/搜索/消息/MiniApp 或任务特定步骤？
- 结果是否来自生产路径而不是 fixture、假 toast、mock chat 或接口单测？
- 视频、截图、trace、报告、日志和运行 ID 是否互相对应？

只有所有答案为“是”才写 `VIDEO-REVIEW-PASS`。正式发布组随后检查发布资产、版本
单调性、签名/来源、更新元数据和回滚说明，发布后把 tag、Release URL、target SHA
和资产清单写回 `evidence/` 与发布记录。

正式发布还必须满足 artifact lineage：QA 通过的 artifact digest 必须等于发布 digest，
或者由可复核的供应链证明说明二者等价。版本号的单一事实源或显式映射必须写进发布
记录，避免插件版本、运行时版本、tag 和安装包版本互相漂移。

## 8. 上下文续接和失败恢复

- 每条 Chat 结束前都要把工作状态写回仓库；不要把“我记得上次说过”作为续接依据。
- 上下文过长或需要新会话时，在当前 group tab 内创建 fresh Chat，发送持久化摘要、
  未完成原子任务、已接受提交、外部运行 ID 和精确下一步。旧 Chat 保留为只读证据。
- 生成期间 Stop Answering 控件仍存在时，不得读取结果、发送续接或任何新消息、创建
  fresh Chat、关闭页面/标签页或切换项目组。若 transport 报告失败，RUNNING 状态下的
  retry 只能做非破坏性观察或重连，仍不得 read-result、send、new Chat、close 或 switch。
- 任何外部 CI、部署、发布等待都保持 `in-progress`；不要把超时、空回答、工具活动
  行或折叠思考区当成成功。

### 8.1 失败分类

`TRANSIENT`（网络、短暂 API/Browser 断线）可以有限退避重试；`DETERMINISTIC`
（编译、测试、schema、审查问题）必须先诊断和修改；`HUMAN_AUTH`（密码、passkey、
OTP、CAPTCHA）进入 `WAITING_HUMAN_AUTH`，严禁进入 prompt、仓库、日志或媒体；
`SPEC_CHANGE` 进入 `SUPERSEDED → ARCH_REPLAN`。视频、截图、trace、HAR、崩溃转储和
console log 也属于敏感证据边界，上传前必须脱敏和扫描。

## 9. 机器可读交接（可选）

插件队列需要结构化交接时，使用单个 `PROJECT_TEAM_REPORT_V1` JSON，不放凭证：

```json
{
  "schema": "PROJECT_TEAM_REPORT_V1",
  "status": "complete|in-progress|blocked|failed",
  "projectId": "FAB-Pxxxx",
  "projectKey": "KEY",
  "stage": "REVIEW",
  "completedTasks": [],
  "pendingTasks": [],
  "repository": "owner/repository",
  "acceptedHead": null,
  "prs": [],
  "evidence": [],
  "blockers": [],
  "nextAction": "one concrete next action"
}
```

`complete` 只表示本报告覆盖的门禁全部满足；若仍有其他原子任务、CI、审查或发布
等待，必须使用 `in-progress` 或 `blocked`。
