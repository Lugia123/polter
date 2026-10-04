<h1 align="center">
  <img src="images/icons/icon_256.png" alt="" width="128">
  <br>Polter
</h1>

<p align="center">
  <b>让一个 Claude Code 会话去管另外几个。</b><br>
  <sub>一个用来并行跑多个编程 agent 的终端。其中一个会话当总管：通过 MCP 读其它终端屏幕上的字、往里打字、开新 tab，你睡觉的时候替你盯着。<br>
  Polter 自己不要账号、不要 API key；除非你亲手点「检查更新」去问一次 GitHub，它一个网络请求都不发。</sub>
</p>

<p align="center">
  <a href="#下载">下载</a> ·
  <a href="#上手四步">上手四步</a> ·
  <a href="#和别的工具比">和别的工具比</a> ·
  <a href="#配置">配置</a> ·
  <a href="#常见问题">常见问题</a> ·
  <a href="README.md">English</a>
</p>

<p align="center">
  <img src="images/screenshots/group-chat.png" alt="群聊：总管派任务，worker 汇报" width="46%">
  <img src="images/screenshots/group-total.png" alt="统计视图：谁在等你，哪个终端静止了多久" width="52%">
</p>

---

### 功能

同时开多个 Claude Code、Codex 窗口难以协调，子 Agent 长时间运行容易中断，通宵任务常在两小时左右停工。Polter 是一个内置了 MCP server 的终端，让一个 agent 去编排其余的。你挑一个 tab 当**总管**，它是个普通的 Claude Code 会话，多了这些能力：

- 读任何 tab 屏幕上的文字（文本，不是截图）
- 往任何 tab 里打字
- 开新 tab 和分屏，并在里面起 agent
- 建群聊、发任务，worker 在群里汇报，面板扛得住重启
- 哪个 tab 的屏幕静止了多久，会报给它

worker 不是 sub-agent，是各自终端里独立的会话，做过什么逐行落到磁盘，第二天可以直接 `grep`。

总管不是在轮询。屏幕停住了，Polter 才推一条通知给它，所以一个安静的夜晚花多少 token，取决于卡住了几次，不取决于任务跑了多久。

### 还有什么

- **角色。** 角色是一种存下来的「怎么起一个 agent CLI」：留它的哪些技能和 MCP server、在系统提示词之上再交代什么、用哪个模型。入口在 `Agents → Role`，总管也可以让自己起的 worker 带着角色上岗。
- **项目。** `Project → Save as Project…` 把一个 tab 存下来——分屏、每个面板的目录、命令历史和回滚内容——`Load Project…` 再把它开回来。macOS 和 Windows 有，Linux 没有。
- **谁可以回答确认。** 总管自己开出来的终端，总管可以替它回答权限确认；其它终端不行，除非你逐个放开（`Agents → Let a Supervisor Answer Prompts Here`）。没有任何工具能把它打开，总管开的终端你也可以再关掉。
- **一个设置窗口。** 角色、项目、插件和配置文件都在一处，两个平台一样（`Settings…`）。
- **钩子。** 用角色起的 Claude Code 会在一轮结束时告诉 Polter「结束了、说了什么」，总管是被告知，而不是对着一块静止的屏幕去猜。只有 Claude Code 有，其它 CLI 仍然靠看屏幕。
- **中英文界面。** 菜单和窗口跟随系统语言，或者用 `Language` 里选的那个。

### 下载

[**最新版本**](https://github.com/Lugia123/polter/releases/latest)

| | |
| --- | --- |
| **macOS 13+** | `Polter-*-macos-universal.zip`，Apple Silicon 和 Intel 一个包 |
| **Windows 10+** | `Polter-*-windows-x64.zip`，核心 76 个 action 里实现 70 个、具名拒绝 4 个、记账待做 2 个（2026-09-21；数法见 `dev-docs/windows/status.md` §二之二 第 2 条） |
| **Linux** | 无安装包，可自行编译 |

**macOS** 的包没有签名，Gatekeeper 会拦：

```sh
unzip Polter-*-macos-universal.zip
xattr -dr com.apple.quarantine Polter.app
mv Polter.app /Applications/
```

装完**从访达或 Dock 打开，不要从终端启动**，两者 `PATH` 不同，注册插件会找不到你的 agent CLI。

**Windows** 解压后运行 `polter-host.exe`，压缩包里其余的东西都留在它旁边——几个 DLL、`polter-cli.exe` 和 `share/`。SmartScreen 会要你点「仍要运行」。

### 前置条件

一个装好的 agent CLI，在 `PATH` 上，且在 Polter 启动时就在。只在 Claude Code 上实测过。

### 上手四步

**1. 开一个 tab，起 Claude Code。** 先 `cd` 到你要它干活的目录。

**2. 标记成总管。** `Agents → Make This Terminal a Supervisor`。标记完 Polter 会往这个 tab 里敲一行字，让里面的 agent 去读 `supervising` skill。

往下走之前先确认工具在，问它一句：

> 调一下 `me` 这个工具，把结果告诉我。

答得出一个终端 id 就成了。说没有这个工具就先停在这里，见[常见问题](#常见问题)。

**3. 交代任务目标。** 建群、开 tab、认领、计时都是它自己来，你不用报终端 id，也不用点工具名。

**4. 去睡觉。** 回来用 `Agents → Terminal Conversations`（或 `polter +chat`）看它们说了什么。`tab` 和 `shift+tab` 切三个视图：对话、任务面板、当夜的账。

### 和别的工具比

Polter 那一列说的是这个仓库做的事。其它几列取自各项目自己的 README 或手册，读于 2026-10-04。

| | Polter | tmux | Claude Code 的 sub-agent | [Claude Squad](https://github.com/smtg-ai/claude-squad) | [cmux](https://github.com/manaflow-ai/cmux) |
| --- | --- | --- | --- | --- | --- |
| 它是什么 | 一个内置 MCP server 的终端（Ghostty 的 fork） | 终端复用器 | 一个 Claude Code 会话内部的功能 | 架在 tmux 和 git worktree 上的 TUI | 基于 Ghostty 的 macOS 终端 |
| 谁盯着 agent | 另一个 agent，也就是总管 | 你 | 父会话 | 你，在一个窗口里 | 你，靠通知环和侧边栏 |
| worker 是什么 | 自己终端里的独立会话 | 你在面板里起的任何东西 | 父会话的子 agent | 自己 worktree 里的独立会话 | 你在面板里起的任何东西 |
| 有一个不动了 | 总管被告知它静止了多久 | 设了 `monitor-silence` 的话，状态栏高亮并响铃 | — | — | agent 发出信号时亮一个环 |
| worker 之间的隔离 | 自己不做，它们共用你的工作目录 | 无 | 用父会话的目录，要求时可以给一棵 worktree | 每个一棵 git worktree 和一个分支 | 无 |
| 平台 | macOS、Windows | 类 Unix 系统 | Claude Code 能跑的地方 | 需要 tmux 和 `gh` | macOS |

从这张表能看出 Polter 没有的东西：它不给 worker 各自的 worktree，也没有 cmux 那样的浏览器面板。如果你要的是按任务隔离，Claude Squad 那套就是为此做的。

### 配置

所有配置项都有能用的默认值，不改也跑得起来。常用的几个：

| 配置项 | 作用 |
| --- | --- |
| `poltergeist-watch` | 是否采样终端屏幕。默认关，总管用 `set_watch` 逐个打开 |
| `poltergeist-quiescence-after` | 静止多久报给总管 |
| `poltergeist-register-mcp` | 启动时是否注册 MCP，默认开 |

数据都在 `$XDG_STATE_HOME/polter/` 下：`chat/` 是 agent 之间说了什么，`terminals/` 是每个终端里发生了什么，`tasks/` 是面板变动，`stats/` 是每群每小时一行。不做脱敏，当成 shell 历史对待。

### 它目前不做的事

- **你自己开的终端，不替里面的 agent 回答权限确认，除非你对那个终端说过可以。** 它只会通知你。总管开出来的终端可以。
- **不让 agent 解开你上的锁。** 按住和屏蔽只有你能上、只有你能解。
- **不长成一个任务系统。** 面板只存谁在做哪件事、做完没有。
- **不当绕过 agent 自身权限的近路。** `terminal_send` 只发文本，走粘贴通道，控制字节换成空格。

### 常见问题

**agent 说它没有 polter 工具。** 三个原因：插件被关了、Polter 启动时 `claude` 不在 `PATH` 上、`poltergeist-register-mcp` 被关了。注册记的是最后启动的那个构建。

**能用别的 CLI 吗。** server 是标准 MCP，任何 MCP 客户端都能跑，发行包带了七个注册插件。只在 Claude Code 上测过，别的请按「没测过」看待。

**这不就是 tmux 吗。** 不是。tmux 负责排面板，盯着它们是你的事。Polter 把每个终端静止了多久告诉一个 agent，并让它能读它们的屏幕、往里打字。

**它怎么知道 agent 卡住了。** 它不知道。它只测一块屏幕多久没动，不解析任何 CLI 的输出格式。是卡住还是在想，判断交给总管。

**和 Poltergeist 有关系吗。** 没有。[steipete/poltergeist](https://github.com/steipete/poltergeist) 是一个文件监视和构建工具，它的包装命令也叫 `polter`。两个项目除了都借了「鬼」这个名字，没有别的关系；这里的 `poltergeist-*` 只是本项目配置项的前缀。

**插件怎么写。** 一个目录，一个 `plugin.json` 加一个可执行文件，二十行 shell 脚本就够。

### 和 Ghostty 的关系

让它成为一个好终端的一切都是 [Ghostty](https://github.com/ghostty-org/ghostty) 的功劳。Polter 是 fork 不是重写，渲染器、VT 实现、字体栈、原生界面全是他们的，上游有更新就合过来。

关于终端本身的一切都问上游：转义序列、性能、配置、快捷键、`libghostty`。看 [ghostty.org/docs](https://ghostty.org/docs)，把里面的 `ghostty` 换成 `polter` 就行。

Polter 加的是 `src/poltergeist/`、MCP 工具面、聊天 TUI、终端转录和插件宿主。本项目与 Ghostty 项目无关联，这里的 bug 除非上游也能复现，否则不要报到那边。

构建看 [`dev-docs/preview-manual.md`](dev-docs/preview-manual.md)，设计推演在 [`dev-docs/poltergeist/`](dev-docs/poltergeist/README.md)。

MIT 协议，和上游一样。

---

感谢 [LINUX DO](https://linux.do) 社区，Polter 最早在那里分享。
