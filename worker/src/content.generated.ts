export const HOME = {
  "schema": "mahayana.miniapp.home.v1",
  "revision": "f12983221c3c60162e112a0b367d8c71b5dc7c473cc14b76db1a99ad42cadb93",
  "app": {
    "id": "chatgpt-auto-confirm",
    "title": "ChatGPT 自动确认",
    "version": "1.0.0+codex.20260902221447"
  },
  "welcome": {
    "id": "welcome",
    "markdown": "欢迎使用 **ChatGPT 自动确认**。\n\n它既能在后台自动确认 ChatGPT 授权卡，也能编排可恢复的任务队列。对长期目标，插件可以在用户明确授权的当前内置 Browser 标签页中派发和监控 Chat；只开放 `browser.in-app.dispatch-and-watch`，绑定本机随机令牌、仅监听 127.0.0.1，不提供通用 CDP 或任意网页控制。每次派发只发送一条完整总目标；未完成时自动创建新 Chat 续作，确认整个目标已完成并验证后才停止。最多两个独立目标可同时运行，每个目标各自占用一个后台标签页、持久任务 id 与恢复链路。\n\n对每个长期目标使用一次 `dispatch_goal`，只提交完整总目标；第二次调用会新开隔离标签页，既不会重发、暂停或复用第一个目标。ChatGPT 可以内部自行拆解，但必须一次性持续工作并验证全部结果，不能以部分完成或阶段性总结停止。插件每轮固定在聊天页新建 Chat，验证 GPT-5.6 Sol 与极高；遇到授权卡时优先选择“允许本次会话”，界面不提供会话范围选项时自动点击卡片上的“允许”继续执行。在回复明确未完成、阻塞、模糊或缺少完整完成回执时继续派发，不携带上一轮进度。插件服务器会持久监督两个任务；标签页绑定失效或浏览器列表短暂为空时会自动重试、认领或新建内置 Browser 标签页并恢复各自会话。整个 Browser 执行租约结束时，`browser_watch` 会返回宿主泵元数据；可长期占用的执行会一直等待 `runUntilTerminal()`，而受时限的定时监督会在每次执行中等待一个已持久化的短租约切片，再由下一次唤醒重新附着。两种方式都会继续各自任务，不会回退到 Devspace 或重复派发目标。\n\n通用确认和任务队列始终共用同一个已登录的 ChatGPT 实例。队列通过 ChatGPT 自带的 `show:false` 预热机制为每个运行中的任务持有一个从未显示、从不获取焦点的隐藏页面；无依赖且没有资源锁冲突的任务可并行执行，任务、续作和验收仍各自在自己的隐藏页面中完成。它不会新开第二个 ChatGPT 实例，也不会把你刚打开的新聊天切回任务会话。队列、会话引用和审计记录只保存在本机；辅助功能扫描仅作为旧版 ChatGPT 的兼容通道，而且只会处理当前前台窗口中真正可见的授权卡，绝不点击隐藏会话里的辅助功能元素。\n\n现在可以在「账号」中添加最多 10 个 ChatGPT 账号。每个账号使用独立 profile、独立 CODEX_HOME 和 macOS Keychain 条目；任务入队时固定账号，之后切换默认账号只影响新任务。也可以生成只绑定 127.0.0.1、十分钟一次性的登录链接，确认后自动打开隔离登录窗口。\n\n需要脱离本机长期运行时，可点「启动 6 小时 Action」。每个账号使用独立 GitHub Environment 和并发组；Runner 首轮读取 Environment Secret，之后优先恢复最近一次成功 smoke 产生的 AES-256-GCM 加密凭据构件。每 6 小时会为已注册账号运行短 smoke，成功后滚动保存最新 Codex auth.json 和 renderer Cookie；认证失败会暂停该账号，等待本机重新登录。不存在官方永久 ChatGPT 页面 Cookie，仍需按需重新登录。"
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
        "revision": "8",
        "kind": "article",
        "title": "使用指南",
        "publishedAt": "2026-07-19",
        "summary": "在同一实例中发送一次性总目标、后台确认会话、自动续作并独立验收。",
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
  "mahayana://chatgpt-auto-confirm/content/articles/guide": "# 使用指南\n\n## 快速开始\n\n1. 对单个长期目标调用 `dispatch_goal`，只传完整 `goal` 原文；ChatGPT 可在内部自行拆解，但必须一次性持续完成整个总目标，不能以部分完成或阶段性总结停止。插件请求 `browser.in-app.dispatch-and-watch`，在当前已授权的内置 Browser 中每轮新建 Chat，并选择聊天页、GPT-5.6 Sol、极高。\n2. 需要两个独立目标并行时，再调用一次 `dispatch_goal`。插件会为第二个目标新建隔离后台标签页，并在同一个长期宿主泵中轮询两个标签页；一个目标的续作、授权、失联或完成不会覆盖、暂停或重复另一个目标。第三个非终态目标会被拒绝，直到有空闲槽位。\n3. 插件在后台检测授权卡；出现分体授权按钮时先点箭头并优先选择“允许本次会话”，如果菜单没有该选项，就关闭菜单并自动点击卡片上的“允许”，不中断当前任务。\n4. 新提示词会附带固定的 `MAHAYANA_TASK_REPORT_V1` 完成回执要求；只有回执字段完整、剩余项和阻塞项为空且有验证证据时，插件才会停止。只有自然语言而没有回执，不算完成。\n5. 回复模糊、只完成部分工作、提前结束或明确仍需继续时，插件保留原目标并在该目标的新 Chat 再次发送同一条完整总目标；不会携带上一轮进度。\n6. 每个 Chat 开始时从配置的 GitHub 仓库按稳定任务 id 读取项目文档；找不到匹配项目时，先在仓库内创建完整立项目录并登记任务文件。\n7. 每次提示词只含一次性总目标，不携带上一轮进度；小程序未检测到可靠的完成回执，就保留共享 checkout 中的进度并自动在新 Chat 继续同一总目标。\n\n需要多个相互独立的目标时，再使用 `enqueue_tasks`；它会进入本地持久队列并按依赖与资源锁调度。\n\n## 内置 Browser 授权\n\n普通插件进程不能直接取得内置 Browser 标签页。启用 `browser.in-app.dispatch-and-watch` 后，受信任的 Browser 宿主才会为插件建立一个只监听 127.0.0.1 的短期授权桥；桥接只接受固定的聊天派发/监控请求，强制使用聊天页、GPT-5.6 Sol、极高，并自动批准当前 Chat 产生的授权卡：优先使用“允许本次会话”，没有会话范围选项时回退到卡片上的直接“允许”。桥接不暴露通用 CDP 操作。授权文件包含随机令牌并限制为当前本机用户可读。桥接最多保存两个独立任务及其标签页绑定，按轮询顺序推进；标签页绑定失效时，宿主会自动重试浏览器列表读取，随后寻找同一受控会话、认领同一用户标签页，或在最后才新建背景标签页并恢复保存的 URL；浏览器列表短暂为空不会丢弃任何任务。若整个 Browser 执行租约结束，`browser_watch` 返回每个待恢复目标的 `reattachRequired=true` 元数据及插件宿主工厂、目标 URL、长期泵入口和可选的短租约参数。拥有长执行租约时，监督器持续等待 `runUntilTerminal()`；若宿主环境存在硬性时限，监督自动化就在每次唤醒中等待带返回选项的短租约切片，先持久化两个任务再主动返回，下一次唤醒重新附着，从而持续恢复各自任务而不重复派发或携带上一轮进度。\n\n## 中断恢复\n\n任务、隐藏页面引用、会话引用和结果文件都写入本机持久状态。重新调用 `resume_queue` 后，小程序会先接管仍存活的隐藏页面，再处理尚未入账的结果，不会从头重复发送。\n\n## GitHub Actions 持续运行\n\n点「启动 6 小时 Action」会用本机已登录的 `gh` 刷新三个仓库 Secret：ChatGPT 登录令牌、加密状态密钥和压缩后的初始任务状态。工作流只从 `main` 读取可信实现，在 GitHub 托管的 macOS Runner 安装官方 ChatGPT 应用、恢复登录并继续队列。\n\n每轮在 GitHub 的六小时硬限制前主动停止，使用 AES-256 加密任务状态并上传短期 artifact。若任务尚未完成，本轮使用 `workflow_dispatch` 启动下一轮并传递上一轮 Run ID；完成后停止续作。Action 日志只显示登录恢复结果和任务状态，不输出登录令牌、加密密钥或任务 Secret。\n\n## 单进程并行队列安全\n\n用 `dependsOn` 表示先后关系，用 `resourceLocks` 表示不能同时修改的仓库、发布环境或外部资源。队列状态会同时返回请求并发数、有效并发数、每个活动隐藏页面和执行模式 `single-authenticated-process-multi-hidden-window-parallel`；默认验收门会阻止新一批任务在上一批尚未验收时启动。\n\n## 前台会话不受干扰\n\n自动确认会扫描每个已经加载的 ChatGPT 页面，包括隐藏页面和非当前会话，并直接在原页面处理授权卡。扫描不会选中会话、切换侧栏或激活 ChatGPT。队列的会话恢复、续作和验收只允许发生在同一实例内从未显示的隐藏页面中，不能回退到用户正在输入的页面。"
};
