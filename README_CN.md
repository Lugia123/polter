<h1 align="center">
  <img src="images/icons/icon_256.png" alt="" width="128">
  <br>Polter
</h1>

<p align="center">
  <b>让一个 Claude Code 会话去管另外几个。</b><br>
  <sub>它替你读它们屏幕上的字、往里打字、开新 tab，你睡觉的时候替你盯着。<br>
  Polter 自己不要账号、不要 API key，一个网络请求都不发。</sub>
</p>

<p align="center">
  <a href="#下载">下载</a> ·
  <a href="#上手四步">上手四步</a> ·
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

同时开多个 Claude Code、Codex 窗口难以协调，子 Agent 长时间运行容易中断，通宵任务常在两小时左右停工。Polter 让你挑一个 tab 当**总管**，它是个普通的 Claude Code 会话，多了这些能力：

- 读任何 tab 屏幕上的文字（文本，不是截图）
- 往任何 tab 里打字
- 开新 tab 并在里面起 agent
- 建群聊、发任务，worker 在群里汇报，面板扛得住重启
- 哪个 tab 静止了多久，会报给它

worker 不是 sub-agent，是各自终端里独立的会话，做过什么逐行落到磁盘，第二天可以直接 `grep`。

### 下载

[**最新版本**](https://github.com/Lugia123/polter/releases/latest)

| | |
| --- | --- |
| **macOS 13+** | `Polter-*-macos-universal.zip`，Apple Silicon 和 Intel 一个包 |
| **Windows 10+** | `Polter-*-windows-x64.zip`，核心 72 个 action 实现了 63 个（2026-09） |
| **Linux** | 无安装包，可自行编译 |

**macOS** 的包没有签名，Gatekeeper 会拦：

```sh
unzip Polter-*-macos-universal.zip
xattr -dr com.apple.quarantine Polter.app
mv Polter.app /Applications/
```

装完**从访达或 Dock 打开，不要从终端启动**，两者 `PATH` 不同，注册插件会找不到你的 agent CLI。

**Windows** 解压后运行 `polter-host.exe`，两个 DLL 和 `share/` 留在它旁边。SmartScreen 会要你点「仍要运行」。

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

### 配置

所有配置项都有能用的默认值，不改也跑得起来。常用的几个：

| 配置项 | 作用 |
| --- | --- |
| `poltergeist-watch` | 是否采样终端屏幕。默认关，总管用 `set_watch` 逐个打开 |
| `poltergeist-quiescence-after` | 静止多久报给总管 |
| `poltergeist-register-mcp` | 启动时是否注册 MCP，默认开 |

数据都在 `$XDG_STATE_HOME/polter/` 下：`chat/` 是 agent 之间说了什么，`terminals/` 是每个终端里发生了什么，`tasks/` 是面板变动，`stats/` 是每群每小时一行。不做脱敏，当成 shell 历史对待。

### 它目前不做的事

- **不替 agent 回答权限确认**，只会通知你。
- **不让 agent 解开你上的锁。** 按住和屏蔽只有你能上、只有你能解。
- **不长成一个任务系统。** 面板只存谁在做哪件事、做完没有。
- **不当绕过 agent 自身权限的近路。** `terminal_send` 只发文本，走粘贴通道，控制字节换成空格。

### 常见问题

**agent 说它没有 polter 工具。** 三个原因：插件被关了、Polter 启动时 `claude` 不在 `PATH` 上、`poltergeist-register-mcp` 被关了。注册记的是最后启动的那个构建。

**能用别的 CLI 吗。** server 是标准 MCP，任何 MCP 客户端都能跑，发行包带了七个注册插件。只在 Claude Code 上测过，别的请按「没测过」看待。

**这不就是 tmux 吗。** 不是，tmux 不会告诉你哪个 agent 卡住了。

**它怎么知道 agent 卡住了。** 它不知道。它只测一块屏幕多久没动，不解析任何 CLI 的输出格式。是卡住还是在想，判断交给总管。

**插件怎么写。** 一个目录，一个 `plugin.json` 加一个可执行文件，二十行 shell 脚本就够。

### 和 Ghostty 的关系

让它成为一个好终端的一切都是 [Ghostty](https://github.com/ghostty-org/ghostty) 的功劳。Polter 是 fork 不是重写，渲染器、VT 实现、字体栈、原生界面全是他们的，上游有更新就合过来。

关于终端本身的一切都问上游：转义序列、性能、配置、快捷键、`libghostty`。看 [ghostty.org/docs](https://ghostty.org/docs)，把里面的 `ghostty` 换成 `polter` 就行。

Polter 加的是 `src/poltergeist/`、MCP 工具面、聊天 TUI、终端转录和插件宿主。本项目与 Ghostty 项目无关联，这里的 bug 除非上游也能复现，否则不要报到那边。

构建看 [`docs/preview-manual.md`](docs/preview-manual.md)，设计推演在 [`docs/poltergeist/`](docs/poltergeist/README.md)。

MIT 协议，和上游一样。
