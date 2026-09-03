# 完成门禁

只有全部可审计条目满足，任务才可返回 `status=complete`。

## A. 版本与平台矩阵

- [ ] 从仓库代码和工作流生成受支持平台清单，明确 Web/PWA、Android、iOS、macOS、Windows、Linux、Electron/原生包装的支持或排除证据。
- [ ] 新版本号在所有 manifest、包元数据、安装器、更新源和 Release 标签一致，且有自动一致性检查。
- [ ] 每个平台使用 GitHub Actions 完成构建、签名或可验证替代、checksum、SBOM/provenance、产物上传和保留策略。
- [ ] 不把缓存、临时 Runner 修改、fixture、空壳安装包或旧版本重命名当作新版本。

## B. 真实安装、升级和发布

- [ ] 每个可运行平台在干净 Runner/设备上安装、首次启动、健康检查、关闭和重启成功。
- [ ] 从上一个正式版本升级到新版本，数据迁移与插件状态正确；失败可原子回滚。
- [ ] GitHub Release 指向同一 source commit，包含变更说明、校验值、各平台正式产物与验证 run。
- [ ] Web 正式部署可访问并通过真实 smoke；应用商店的提交、审核或人工阻塞状态有准确证据。

## C. 安装后远程操控

- [ ] `fabushi test` 工作区插件可发现并连接真实安装的 Fabushi，不依赖仓库内开发进程冒充安装包。
- [ ] 对真实应用验证启动/停止、语义树、应用截图、点击、滚动、按键、文本输入、状态和诊断；写操作返回新的短期快照。
- [ ] 每个平台至少有一条真实用户路径 E2E，并以结构化事件、截图、应用日志、correlation id 和产物 digest 证明。
- [ ] 未授权、凭证过期、重放、过期快照、锁屏、越权跨应用、敏感输入泄漏和 Release 调试后门均有负向测试。

## D. Actions 同步执行与在线修复

- [ ] Runner 控制器实时观察结构化子进程事件，测试报错后在整个 job 结束前进入诊断/修复流程。
- [ ] 有一条故障注入 E2E 证明：长阶段仍在运行时出现确定性失败；控制器在同一 Runner checkout 修改测试或实现、保留 diff 和审计、只重跑受影响阶段，成功后继续 DAG。
- [ ] 已构建应用可在隔离会话运行，同时由 `fabushi test` 执行远控测试；没有固定 sleep 或“等待工作流结束后再下载日志”的关键路径。
- [ ] 在线修复最终形成可审查 Git 提交/PR，并且 Runner 重启后可从持久状态继续，临时修改不会丢失或绕过审查。
- [ ] 并发、取消、超时、租约、端口/设备冲突、进程清理、重复事件与重复重试均有测试。

## E. 自动确认持续运行

- [ ] chatgpt-auto-confirm 控制器、隐藏 ChatGPT 会话和持久队列状态实际运行在本机，而不是 GitHub Actions Runner。
- [ ] 队列隐藏 ChatGPT 会话的实际模型/工具活动与插件 task/revision/round/status/next_task、Runner 和 Action 状态一致。
- [ ] 对 renderer 空白/覆盖层、CDP 断连、登录失效、网络错误、Action 中断和陈旧状态有恢复测试，恢复保持同一任务、分支、checkout、邮件线程和已完成证据。
- [ ] 7 分钟健康检查在健康状态不制造重复任务或噪声，在异常状态可修复插件并恢复持续任务。
- [ ] 任务不会因一次短回复、一次 Action 超时或一个平台等待商店审批而停止；仍可完成的工作会继续推进。

## F. 最终证据

- [ ] 所有重型验证来自通过的 GitHub Actions run；本地仅做轻量静态检查且没有声称本地构建通过。
- [ ] 最终报告列出 Release/部署/商店链接、commit、workflow run、各产物 digest、远控 E2E correlation id、在线修复故障注入证据和所有剩余人工事项。
- [ ] `MAHAYANA_TASK_REPORT_V1` 满足 complete 协议：`all_tasks_complete=true`，且 remaining、blockers、next_task 为空，wait_seconds 为 0。
