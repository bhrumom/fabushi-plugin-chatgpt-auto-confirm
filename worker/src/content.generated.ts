export const HOME = {
  "schema": "mahayana.miniapp.home.v1",
  "revision": "fe6a9ed70b9836109ad05eab20ec2d359461202a07b0ccab6a708edce6e1317f",
  "app": {
    "id": "chatgpt-auto-confirm",
    "title": "ChatGPT 自动确认",
    "version": "1.0.0+codex.20260907050926"
  },
  "welcome": {
    "id": "welcome",
    "markdown": "欢迎使用 **ChatGPT 自动确认**。\n\n它既能自动确认 ChatGPT 授权卡，也能编排可恢复的任务队列。`send_and_watch` 使用插件自己创建并拥有的 ChatGPT.app 实例；这个实例可以可见，也可以隐藏，但不会借用用户主窗口或 Work composer。插件只在真实 Chat 页面发送，并严格绑定自己的 profile、调试端口和 target。\n\n每一轮都由插件创建新的工作 Chat。工作 Chat 只收到自然语言执行目标并返回自然结果；插件把这个结果连同原始目标交给另一个新的规划/验收 Chat，只有规划 Chat 才收到 `MAHAYANA_TASK_REPORT_V1` 模板。规划 Chat 用模板决定完成或把 `next_task` 安排给下一轮新的工作 Chat，插件递归串联，绝不把模板转发给工作 Chat。遇到授权卡时优先选择“允许本次会话”，界面不提供会话范围选项时自动点击卡片上的“允许”继续执行。\n\n通用确认和任务队列使用插件自己的 ChatGPT 实例；运行状态如实报告为 `hidden-chat` 或 `visible`，可见并不代表失败。每个运行中的任务都绑定自己的 Chat/target，工作、规划、续作和验收都创建新的 Chat；旧 Chat 只读。重试、停止或取消时，插件只关闭精确识别出的自有 target/profile/process，不影响用户自己的 ChatGPT/Codex 实例。队列、会话引用和审计记录只保存在本机；辅助功能扫描仍只处理真正可见的授权卡。\n\n现在可以在「账号」中添加最多 10 个 ChatGPT 账号。每个账号使用独立 profile、独立 CODEX_HOME 和 macOS Keychain 条目；任务入队时固定账号，之后切换默认账号只影响新任务。也可以生成只绑定 127.0.0.1、十分钟一次性的登录链接，确认后自动打开隔离登录窗口。\n\n需要脱离本机长期运行时，可点「启动 6 小时 Action」。每个账号使用独立 GitHub Environment 和并发组；Runner 首轮读取 Environment Secret，之后优先恢复最近一次成功 smoke 产生的 AES-256-GCM 加密凭据构件。每 6 小时会为已注册账号运行短 smoke，成功后滚动保存最新 Codex auth.json 和 renderer Cookie；认证失败会暂停该账号，等待本机重新登录。不存在官方永久 ChatGPT 页面 Cookie，仍需按需重新登录。"
  },
  "tips": [
    {
      "id": "getting-started",
      "revision": "1",
      "markdown": "回复 `/` 可查看当前 MCP Tools。"
    }
  ],
  "quickReplies": [
    {
      "id": "account-list",
      "label": "查看 ChatGPT 账号",
      "aliases": [
        "账号列表",
        "管理账号"
      ],
      "action": {
        "type": "tool",
        "name": "account_list",
        "arguments": {}
      }
    },
    {
      "id": "account-add",
      "label": "添加 ChatGPT 账号",
      "aliases": [
        "添加账号",
        "登录新账号"
      ],
      "action": {
        "type": "tool",
        "name": "account_add",
        "arguments": {}
      }
    },
    {
      "id": "account-login-link",
      "label": "生成一次性登录链接",
      "aliases": [
        "登录链接"
      ],
      "action": {
        "type": "tool",
        "name": "account_login_link",
        "arguments": {}
      }
    },
    {
      "id": "account-status",
      "label": "检查账号凭证状态",
      "aliases": [
        "账号健康检查"
      ],
      "action": {
        "type": "tool",
        "name": "account_status",
        "arguments": {}
      }
    },
    {
      "id": "sync-actions-credentials",
      "label": "一键更新凭证到 GitHub Secrets",
      "aliases": [
        "同步已登录凭证",
        "更新 Action 凭证",
        "一键更新凭证"
      ],
      "action": {
        "type": "tool",
        "name": "sync_actions_credentials",
        "arguments": {}
      }
    },
    {
      "id": "login-and-sync-actions",
      "label": "登录并同步 Action 凭证",
      "aliases": [],
      "action": {
        "type": "tool",
        "name": "login_and_sync_actions",
        "arguments": {}
      }
    },
    {
      "id": "queue-status",
      "label": "查看任务队列",
      "aliases": [],
      "action": {
        "type": "tool",
        "name": "queue_status",
        "arguments": {}
      }
    },
    {
      "id": "start-actions-runner",
      "label": "启动 6 小时 Action",
      "aliases": [],
      "action": {
        "type": "tool",
        "name": "start_actions_runner",
        "arguments": {}
      }
    },
    {
      "id": "prompt-templates",
      "label": "内置任务提示词",
      "aliases": [],
      "action": {
        "type": "tool",
        "name": "prompt_templates",
        "arguments": {}
      }
    },
    {
      "id": "wait-review",
      "label": "等待验收任务",
      "aliases": [],
      "action": {
        "type": "tool",
        "name": "wait_for_review",
        "arguments": {
          "timeout": 60
        }
      }
    }
  ],
  "feed": {
    "items": [
      {
        "id": "guide",
        "revision": "10",
        "kind": "article",
        "title": "使用指南",
        "publishedAt": "2026-07-19",
        "summary": "由插件编排工作 Chat、规划验收 Chat 和下一轮自然语言任务。",
        "tags": [
          "指南",
          "任务队列",
          "自动续作"
        ],
        "quickReplies": [],
        "resourceUri": "mahayana://chatgpt-auto-confirm/content/articles/guide"
      },
      {
        "id": "launch",
        "revision": "1",
        "kind": "announcement",
        "title": "小程序上线",
        "publishedAt": "2026-07-19",
        "summary": "欢迎使用这个对话式 MCP 小程序。",
        "tags": [
          "公告"
        ],
        "quickReplies": [],
        "resourceUri": "mahayana://chatgpt-auto-confirm/content/announcements/launch"
      }
    ],
    "nextCursor": null
  }
} as const;
export const RESOURCES: Record<string,string> = {
  "mahayana://chatgpt-auto-confirm/content/announcements/launch": "# 小程序上线\n\n这里是首条公告。",
  "mahayana://chatgpt-auto-confirm/content/articles/guide": "# 使用指南\n\n## 快速开始\n\n1. 对单个长期目标调用 `send_and_watch`，以 `role: \"work\"` 和 `autoPlanAfterWork: true` 发送完整原始目标；插件在自己拥有的 ChatGPT.app 实例中创建工作 Chat，实例可见或隐藏，并选择 Chat、GPT-5.6 Sol、极高。\n2. 需要两个独立目标并行时，再调用一次 `dispatch_goal`。插件会为第二个目标新建隔离标签页（可见或隐藏），并在同一个长期宿主泵中轮询两个标签页；一个目标的续作、授权、失联或完成不会覆盖、暂停或重复另一个目标。第三个非终态目标会被拒绝，直到有空闲槽位。\n3. 插件在后台检测授权卡；出现分体授权按钮时先点箭头并优先选择“允许本次会话”，如果菜单没有该选项，就关闭菜单并自动点击卡片上的“允许”，不中断当前任务。\n4. 工作 Chat 只接收自然语言工作目标，不附带 `MAHAYANA_TASK_REPORT_V1`。工作结果稳定后，插件新开规划/验收 Chat，把原始目标和自然结果交给它；只有这个规划 Chat 收到固定回执要求。\n5. 规划 Chat 的回执完整且完成条件满足时插件停止；否则插件把 `next_task` 原文发送给新的工作 Chat，且不把回执模板或规划提示追加进去。工作 Chat 的自然结果、阻塞和提前结束都由插件交给新的规划 Chat 判断。\n6. 每个 Chat 开始时从配置的 GitHub 仓库按稳定任务 id 读取项目文档；找不到匹配项目时，先在仓库内创建完整立项目录并登记任务文件。\n7. 每次实际发送都创建新的 Chat；旧 Chat 只读。插件不把旧自然结果伪装成完成，而是把它交给规划 Chat，再由规划 Chat 安排下一轮。\n\n需要多个相互独立的目标时，再使用 `enqueue_tasks`；它会进入本地持久队列并按依赖与资源锁调度。\n\n## 内置 Browser 授权\n\n普通插件进程不能直接取得内置 Browser 标签页。启用 `browser.in-app.dispatch-and-watch` 后，受信任的 Browser 宿主才会为插件建立一个只监听 127.0.0.1 的短期授权桥；桥接只接受固定的聊天派发/监控请求，强制使用聊天页、GPT-5.6 Sol、极高，并自动批准当前 Chat 产生的授权卡：优先使用“允许本次会话”，没有会话范围选项时回退到卡片上的直接“允许”。桥接不暴露通用 CDP 操作。授权文件包含随机令牌并限制为当前本机用户可读。桥接最多保存两个独立任务及其标签页绑定，按轮询顺序推进；标签页绑定失效时，宿主会自动重试浏览器列表读取，随后寻找同一受控会话、认领同一用户标签页，或在最后才新建背景标签页并恢复保存的 URL；浏览器列表短暂为空不会丢弃任何任务。若整个 Browser 执行租约结束，`browser_watch` 返回每个待恢复目标的 `reattachRequired=true` 元数据及插件宿主工厂、目标 URL、长期泵入口和可选的短租约参数。拥有长执行租约时，监督器持续等待 `runUntilTerminal()`；若宿主环境存在硬性时限，监督自动化就在每次唤醒中等待带返回选项的短租约切片，先持久化两个任务再主动返回，下一次唤醒重新附着，从而持续恢复各自任务而不重复派发或携带上一轮进度。\n\n## 网页回复结束后唤醒本地 Work\n\n需要托管交接时，受信任的本机 Browser 宿主会在检测到已安装的 Codex 可执行文件后自动创建本地桥；若要停用可设置 `CHATGPT_AUTO_CONFIRM_WORK_BRIDGE=0`。宿主会先用官方 `codex app-server` 的 `thread/resume` 验证传入的本地 Work 会话，再通过 `codex queue --thread` 写入可恢复消息；队列入口由独立本地进程承接，所以网页模型结束后本地模型不需要继续等待或轮询。注册完成后由插件服务器的后台 supervisor 每秒读取一次网页状态，观察循环也不会占用模型回合。唤醒消息固定使用 `gpt-5.6-luna` 和 `medium`，并带有一次性事件标识；事件账本以 0600 权限原子写入，重复回调只返回已接受，不会重复消耗一轮模型。消息只包含网页会话地址和“读取完整回复并继续”的指令，不转发网页回复正文。\n\n`browser_reply_handoff` 注册前必须提供精确网页地址、已发送用户消息摘要和发送前 assistant 摘要；在当前本地 Work 回合中可省略会话 ID，插件会绑定 `CODEX_THREAD_ID`，也可以显式传入另一个已授权会话。回复必须在两次相隔至少两秒的观测中保持不变，且没有停止按钮、重试按钮、授权卡或页面错误；用户改写了这一轮消息时，旧监视会被标记为过期。未启用桥接、会话不存在或队列入口不可用时，注册会返回明确错误，不会退化为高频模型心跳。\n\n## 中断恢复\n\n任务、插件页面引用、会话引用和结果文件都写入本机持久状态。页面可以可见或隐藏；重新调用 `resume_queue` 后，小程序会先接管仍存活的插件页面，再处理尚未入账的结果，不会从头重复发送。\n\n## GitHub Actions 持续运行\n\n点「启动 6 小时 Action」会用本机已登录的 `gh` 刷新三个仓库 Secret：ChatGPT 登录令牌、加密状态密钥和压缩后的初始任务状态。工作流只从 `main` 读取可信实现，在 GitHub 托管的 macOS Runner 安装官方 ChatGPT 应用、恢复登录并继续队列。\n\n每轮在 GitHub 的六小时硬限制前主动停止，使用 AES-256 加密任务状态并上传短期 artifact。若任务尚未完成，本轮使用 `workflow_dispatch` 启动下一轮并传递上一轮 Run ID；完成后停止续作。Action 日志只显示登录恢复结果和任务状态，不输出登录令牌、加密密钥或任务 Secret。\n\n## 单进程并行队列安全\n\n用 `dependsOn` 表示先后关系，用 `resourceLocks` 表示不能同时修改的仓库、发布环境或外部资源。队列状态会同时返回请求并发数、有效并发数、每个活动 Chat 的 target、真实 `hidden-chat`/`visible` 状态和执行模式；默认验收门会阻止新一批任务在上一批尚未验收时启动。\n\n## 前台会话不受干扰\n\n自动确认会扫描插件自有的 ChatGPT 页面，并直接在拥有的 target 处理授权卡。扫描不会选中会话、切换侧栏或激活 ChatGPT。队列的会话恢复、续作和验收只能发生在插件自有的真实 Chat 页面中；页面可见或隐藏均可，但不能回退到用户正在输入的页面。"
};
