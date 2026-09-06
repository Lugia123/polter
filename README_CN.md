<h1 align="center">
  <img src="images/icons/icon_256.png" alt="" width="128">
  <br>Polter
</h1>

<p align="center">
  <b>让一个 Claude Code 会话去管另外几个。</b><br>
  <sub>它能读它们的屏幕、往里打字、开新 tab，在你睡着的时候盯着。
  全程本地 —— 不要账号，不要 API key，一个网络请求都不发。</sub>
</p>

<p align="center">
  <a href="#下载">下载</a> ·
  <a href="#五分钟上手">五分钟上手</a> ·
  <a href="#完整例子">完整例子</a> ·
  <a href="#它永远不会做的事">它不做什么</a> ·
  <a href="README.md">English</a>
</p>

---

## 问题

你本来就在终端里开着好几个 tab 跑 agent。开到第四个就乱了：一个卡在没人回答的
确认框上，一个二十分钟前就干完了在发呆，一个在安静地等编译，还有一个"干"了四十
分钟其实早就挂了。不一个个点开看，你分不清谁是谁 —— 而最该被抓住的那个（半路停
下的、或者活没干完就跟你说做完了的），看上去和正在认真思考的那个一模一样。

## Polter 怎么解决

**把你的某个 tab 变成总管。** 它不是一块看板，也不是进程守护 —— 它就是**另一个
Claude Code 会话**，跑在一个普通 tab 里，只不过手上多了几件能够到别的 tab 的
工具：

| 它能 | 也就是说 |
| --- | --- |
| **读任何一个 tab 的屏幕** | 它看得见你的 worker 卡在哪个确认框上。 |
| **往任何一个 tab 里打字** | 它能把卡住的 worker 弄动，或者叫它换个法子。**但它不能替 agent 点那个"允许"** —— 那种情况只会来叫醒*你*，几点都一样。 |
| **开新 tab 并在里面起 agent** | 那几个干活的终端不用你来铺。 |
| **知道每块屏幕静止了多久** | 就这一个数，决定它先去看谁。 |
| **拉群聊、开任务面板** | worker 向它汇报；面板能扛过重启和上下文压缩。 |

你用人话告诉它目标 ——「把导出功能做出来，拆三块，除非要我拍板别叫我」—— 它自己
写计划、按每块活开一个 tab、在每个里面起 agent，然后盯着。

上面那张表里的"它"，全部指**总管**。总管和 Polter 是两个东西，后面整篇都依赖这
个区别：

- **总管**是你派去管事的那个 agent —— 一个普通的 Claude Code 会话。读屏幕、看懂
  屏幕上是什么、决定要不要去捞一把，都是它干的。你随时可以看它在干什么，也随时
  可以把键盘抢回来。
- **Polter** 是那个终端，就是这个程序。它不看内容，只递东西：把屏幕上的字原样交
  给总管，把总管打的字原样送进另一个 tab，另外**只测一个量——这块屏幕多久没动
  了**。屏幕不动到底是"卡住了"还是"在想"，Polter 不回答；答案要看屏幕上写着什么，
  而那是总管的活。

## 决定之前

有三件事值得先知道，再决定要不要花这十分钟：

- **这要你换掉现在用的终端。** Polter 是 [Ghostty](https://github.com/ghostty-org/ghostty)
  的分支，所以它必须是你正在跑的那个终端 —— 读一块屏幕、往里打字，这是外部进程
  做不到的事。代价其实没听上去那么大：它本身就是一个完整、快的终端，你可以先装上
  当普通终端用一周，什么时候想起来再把某个 tab 设成总管。
- **想让它半夜叫醒你，得自己写二十行 shell。** 通知是一个[插件](#插件)，这是故意
  的 —— 你用 Telegram、ntfy 还是 `osascript`，Polter 不该替你决定。**发行包里不带
  任何通知插件**，所以开箱状态下总管能盯一整夜，但够不到你的手机。脚本很短，文档
  里有现成例子，但确实得你自己写。
- **它是个实验，端到端只在一个 agent CLI 上跑通过**：Claude Code。底下就是普通
  MCP 加普通终端，所以别的 CLI *应该*也能用 —— 但除它之外没有测过。macOS 是日常
  开发和使用的平台；[Windows 是新的，还不全](#下载)；Linux 只能自己编。

**关于花钱，老实说：目前没有实测数字。** 总管就是一个普通的 Claude Code 会话，
整夜读屏幕、写消息，所以它就按一个会话的量烧。决定烧多少的是这几样：它同时盯几个
worker、多久被提醒一次没看过的东西（`poltergeist-notice-interval`，默认一分钟，
调大账单就降）、以及每次去看时读进多少屏幕内容。**先拿一个 worker 跑一小时，再决
定要不要让它盯着四个过夜。** 如果你测出来了，
[告诉我](https://github.com/Lugia123/polter/issues)，这一段就会有个数字。


## 除此之外你还得到什么

- **随时可以把键盘抢回来。** 每个 worker 都是一个普通 tab 跑着一个普通 CLI。你想
  打字就打字 —— 总管操纵的不是什么模拟环境；一个 tab 崩了不影响其它的。而且它们
  不必是同一个 CLI。
- **两把只有你能上、只有你能解的锁。** 把一个 tab 按住不许它下班（总管就不能放它
  走），或者干脆让某个 tab 从 MCP 工具面里消失（谁都读不到、打不进去）。两种状态
  都直接显示在 tab 上，而且**都不能从工具面解开** —— agent 解不开你上的锁。
- **一整夜都在磁盘上，按 JSON 行。** 每条群消息、每个 tab 里滚过去的每一行。第二
  天早上 `grep` 和 `jq` 直接能用。不做任何脱敏，请当成你的 shell 历史来对待。
- **规矩是一个你能改的文件。** 怎么当总管，是一份你能改、能版本化的 Markdown
  skill。而**不许做**的事编译在二进制里 —— 所以它不会在凌晨四点悄悄从总管的上下文
  里掉出去，你嘱咐过一次的话则会。
- **一个统计页。** 任务活了多久、谁在说话说了多少、哪些终端静止了多久，按小时排
  开。它只算不判断：一个超过**你自己设的**那条阈值线的任务会被标成 `over`，那只
  表示它过了你的线，不表示出了任何问题。

## 下载

[**最新版本**](https://github.com/Lugia123/polter/releases/latest) —— 版本号是
`0.5.<n>`，`n` 数的是这个 fork 自己的提交数。

| | |
| --- | --- |
| **macOS 13+** | `Polter-*-macos-universal.zip` —— Apple Silicon 和 Intel 打在一个包里。这是日常开发和使用的平台。 |
| **Windows 10+** | `Polter-*-windows-x64.zip` —— 新加的，边界在下面老实写了。 |
| **Linux** | 没有二进制包。GTK 版编得过，但没有人在上面真跑过一次监管 —— 一个没人启动过的包，不该默不作声地发出去。要用请从源码构建。 |

### macOS：这些包没有签名

背后没有 Apple 开发者证书，所以是 ad-hoc 签名、未公证。Gatekeeper 会拦，先解掉：

```sh
unzip Polter-*-macos-universal.zip
xattr -dr com.apple.quarantine Polter.app
mv Polter.app /Applications/
```

然后**从访达或 Dock 打开，不要从终端启动**。两者的 `PATH` 不一样，而负责把总管
skill 装出去的注册插件要在 `PATH` 上找你的 agent CLI —— 从终端起它找不到，然后
**安静地退出**，什么都不说。

### Windows：能用什么，不能用什么

解压到任意目录，运行 `polter-host.exe`。**两个 DLL 和 `share/` 必须留在它旁边**
—— DLL 是启动时按名字加载的，`share/` 里放着总管要读的 skill 和注册插件。没有
签名，SmartScreen 会要你点「仍要运行」。

Windows 这一侧的外壳是一个独立的 Rust 程序（`windows/host/`），通过 libghostty
的 C API 驱动同一份核心 —— 因为 Ghostty 本身没有 Windows GUI。它比 macOS 那侧
年轻，能力还没对齐：

| | |
| --- | --- |
| 在一台 Windows 11 上验过 | 窗口能开、标签页能用、shell 能起、含中日韩文字渲染正常、输入法能打出汉字、菜单和快捷键可用、资源目录找得到、注册插件能启动。 |
| 已知缺的 | **分屏** —— 布局算法已经移植（`windows/split-tree/`），但还没接到窗口树上。**部分键位动作**还没实现，具体数目记在 [`docs/windows/status.md`](docs/windows/status.md)。**shell 集成**没有注入。**`archive` 插件**装上了也启用了，但从不启动，因为插件目前没有办法声明自己能在哪些系统上跑。 |
| 还缺的 | **群聊界面打不开。** 在 0.5.447 上实测：菜单项能点，标签页能创建，日志里的命令行也是对的 —— 但那个标签一直是空白。群聊是作为一个标签跑起来的 TUI（`polter-host.exe +chat`），而宿主本身是 GUI 子系统程序，问题正在这条线上查。群和任务面板通过 MCP 工具照常可用，缺的是屏幕上那个界面。 |

这些缺口的进度在 [`ROADMAP.md`](ROADMAP.md)。

## 五分钟上手

你只需要指定一个 tab 当头儿。就这一步配置。

### 1. 开一个 tab，在里面起 Claude Code

跟你平时一样。先 `cd` 到合适的目录 —— 总管以后可以自己开 tab，但它自己是从你把
它留在哪儿开始的。

### 2. 把它设成总管

**Agents → Make This Terminal a Supervisor**（命令面板里也有，也可以绑给
`poltergeist_supervisor` 这个 action）。同一个菜单项再点一次就取消；一个窗口里
可以有好几个总管，各管各的一摊。

设完的那一刻，Polter 会往那个 tab 里敲一行字，告诉里面的 agent 刚发生了什么，
以及先去读它的 `supervising` skill。所以你还没开口，它已经知道该怎么操作了。

**先确认工具真的在，再往下走。** 问它一句：

> `me` 这个工具返回什么？

如果它答出一个 id、以及一串它能够到的东西，就成了。如果它说没有这个工具，**先停在
这里** —— 下面每一步都不会成，而原因基本上就是
[如果 agent 说它没有 polter 工具](#如果-agent-说它没有-polter-工具)那一节里的三种
之一。一句话版本：得有个插件去告诉 Claude Code「Polter 的工具存在」，它的做法是跑
`claude mcp add`，而它只有在 **Polter 启动的那一刻** `claude` 就在 `PATH` 上，才做
得成 —— 这正是安装说明里让你从访达打开、而不是从终端打开的原因。

### 3. 告诉它活是什么

你的部分到此为止。建群、开 tab 或认领 tab、起表 —— 都是它自己来。你不需要报终端
id，也不需要点工具名。

### 4. 去睡觉

回来用 **Agents → Terminal Conversations**（或者 `polter +chat`）看它们之间都说
了什么。`tab` 和 `shift+tab` 在同一个群的三个视图之间切换：对话、任务面板，以及
一页关于这一夜的算术 —— 任务活了多久、谁在说话、哪些终端静止了多久。

## 完整例子

比如你想让它通宵把一个 REST API 做出来，而且不想中途一直看着。

开一个 tab，`cd` 到项目里，起 `claude`，设成总管。然后这么说 —— **这段是故意
把工具名和参数都写出来的，好让你看清它接下来会去做什么**。你不必这么写：
「把这个做出来，拆三块，只有要我拍板的时候才叫我」就够了，剩下的它照自己的
skill 补齐。

> 你现在是总管。目标：把 `~/src/notes` 里 notes 服务的 REST API 做出来，测试全
> 过，OpenAPI 文档同步更新。
>
> 先给我一份开发计划，把活拆成三块互不打架的。然后每块开一个终端 —— 用
> `terminal_open`，指定对的目录，`watch: true` —— 在每个里面起
> `claude --permission-mode acceptEdits`，把任务连同"做到什么算完"一起交代下去。
>
> 把它们都拉进一个群。我睡觉的时候你盯着，谁卡了你去捞，谁想提前收工不许。只有
> 谁停在权限确认上的时候才叫醒我。早上给我一份汇报。

接下来它会自己做这些事：`group_create` + `group_set_brief` 建个说话的地方，
`terminal_open` 开三个 tab，`terminal_send` 在每个里面起 agent，`group_add` 把
人拉进群，再 `set_watch` 挨个认领、开始计时。然后它就转圈：哪个 tab 静止久了，
它去读屏幕，判断这是真卡住还是编译时间长，决定催一下还是让它继续。

这段话里有三个点值得说：

- **先要计划。** 一个先拆活再开 tab 的总管，第二天早上能给你一份读得懂的东西，
  而不是一堆流水账。
- **一定要说清"做到什么算完"。** `supervising` skill 里反复强调这条：只派任务不
  给验收标准，干活的那个就会自己定义什么叫完成，然后你凌晨两点才发现它定义的跟
  你想的不一样。
- **干活的终端用自动模式起。** Polter 永远不会替 agent 回答权限确认 —— 这是硬
  规矩不是配置项 —— 所以谁停在确认上，最后被叫醒的是**你**。要用就用 Claude Code
  自己的自动模式（会话里 shift+tab 切，或者启动时加
  `--permission-mode acceptEdits`）。`--dangerously-skip-permissions` 也是有的，
  它字面意思就是它的意思。

### 跑起来之后

- **汇报是攒着一起给的**，每个终端一行，每 `poltergeist-notice-interval`（默认
  一分钟）给一次。总管想主动看的话随时可以调 `notices`。
- **屏幕不动超过 `poltergeist-quiescence-after`（默认三分钟）** 才算"静止"；一直
  静止的每 `poltergeist-quiescence-repeat`（默认十五分钟）再提一次。
- **如果有人停在权限确认上**，总管调 `notify_user`，你就会被通知 —— 什么点都通
  知，无视 `poltergeist-notify-window`，因为这事没别人能替你办。这需要配一个通知
  [插件](#插件)。

### 两个只有你能按的开关

两个都直接显示在 tab 上，不只是藏在菜单里：

- **Agents → Keep This Terminal Working** —— 这个不许下班。总管来要求下班会被
  拒。tab 的标记上会多一个环（`◉` 在动 / `◎` 静止）。
- **Agents → Keep Agents Out of This Terminal** —— 整个从工具面里拿掉。这个是绝
  对的：总管和插件一并拒绝。tab 上会带一把锁。你自己看邮件的那个 tab 用这个。

这两个都不能从工具面解除。故意没有这个工具 —— 一个能解锁的总管，会先解锁再把它
打卡下班。

## 总管能做什么

所有事情都走同一个 MCP 工具面（`src/cli/mcp.zig` 前端，后面是
`src/poltergeist/rpc.zig`），清单是刻意短的：一共四十个工具，其中二十三个只有总管
能调 —— 下面标 🔑 的就是。

**「安排」是总管的。** 认领终端、上下班、建群拉人、任务面板、通知你、开 tab、插件
那几个 —— 因为一个能认领别的终端的终端，等于绕开 `become_supervisor` 另开了一条
当头儿的路。而在一个你本来就在的群里说话不算安排，所以聊天那几个工具对每个成员都
开放：不让说话的团队不叫团队。

**「操作一个终端」也不算安排。** 读屏幕、打字、按键、执行菜单动作 —— 任何 agent
都可以，能不能过取决于**目标**身上的标记，而不是谁在问。一个 tab 里的 agent 可
以去重启另一个没人看着的 tab 里的服务；但被监视的、被屏蔽的、当总管的，它碰不了。

还有两条贯穿整个工具面。**群聊只留痕，不推人**：被人盯着的终端不会被群消息唤醒，
所以发群消息永远推不动任何人，真要驱动只能 `terminal_send`。以及**凡是会替你做出
不可撤销决定的，一律拒绝**，并交回给总管去说给你听：`cmd:` 凭据、关掉插件、替
agent 回答权限确认。

每个工具做什么、拒绝什么，全在
**[`docs/tools_CN.md`](docs/tools_CN.md)** 里。那是查阅材料，想知道某个调用具体干
什么的时候去翻。**你不需要它就能用 Polter**：总管会自己读它的 skill 然后自己调这些工具，
上面那个[完整例子](#完整例子)才是你实际操作的样子。

五个家族，这样下文出现的名字你能对上号：

| | |
| --- | --- |
| `terminal_*` | 看和驱动一个 tab：读屏幕、打字、按键、开一个、执行菜单动作。 |
| `group_*` | 群聊。它是**记录**，**发消息不会唤醒任何人** —— 所以派活从来不靠它。 |
| `task_*` | 任务面板。这是唯一能扛过重启、上下文压缩和一整夜的东西。 |
| `plugin_*` | 列出、配置、测试插件。总管专属。 |
| 身份类 | `me`、`become_supervisor`、`stand_down`、`clock_in`/`clock_out`、`notices`、`notify_user`、`skill_read`、`session_recall`。 |

## 它永远不会做的事

四条，这几条是前面一切值得信的原因：

- **永远不替 agent 回答权限确认。** 没有白名单，没有开关。替别人按下"yes"等于
  废掉别人的安全模型。它会改成通知你，什么点都通知。
- **永远不让 agent 解开你上的锁。** 按住和屏蔽都是你的。工具面能看到"有一把
  锁"，但改不了它。
- **永远不长成一个任务系统。** 面板存的是「谁在做哪件事、做完没有」—— 一行标题、
  一个负责的终端、开 / 关 / 取消。不存需求描述和验收细节，不存依赖、优先级、截止
  日期，不存子任务、附件、评论。它存在的唯一理由是：晚上九点打进终端的一条指令，
  凌晨三点还得在。这条线为什么画在这儿，见
  [`docs/poltergeist/tasks.md`](docs/poltergeist/tasks.md)。
- **永远不当绕过 agent 自身权限的近路。** 一个 CLI 把 `Bash` 关在授权确认后面的
  agent，不会因为多装了个 Polter 就拿到执行权。`terminal_send` 只发文本、永远
  只发文本：它走粘贴通道，每个控制字节都会被换成空格，跟 xterm 一样。所以"按一
  个键"是另一个动词，有它自己的授权（`src/poltergeist/keys.zig`）。

还有两条同样路子的小规矩：agent 可以把插件**打开**、但永远不能**关掉**（能关掉
你通知渠道的 agent，等于能关掉自己头顶的灯）；正被监视的终端不能用
`become_supervisor` 自荐（它是最可能在读网络内容的那个，一行注入的文字不能把谁
扶上位）。

## 东西都写在哪

两个默认都开，第二天早上 `less`、`grep`、`jq` 直接能用：

- `$XDG_STATE_HOME/polter/chat/` —— agent 之间说了什么。
- `$XDG_STATE_HOME/polter/terminals/` —— 每个终端里实际发生了什么。一个终端一个
  目录，一天一个文件，一行一条 JSON。**不做任何脱敏，请当成你的 shell 历史来
  对待。**
- `$XDG_STATE_HOME/polter/tasks/` —— 任务面板的每一次变动，各自带时间。
  `task_history` 读的就是它。
- `$XDG_STATE_HOME/polter/stats/` —— 每个群每小时一行：开着几个、关了几个、取消
  几个、过线几个，最安静的和最久没被碰的各自静了多久。**当时生效的那条线一起
  写在同一行**，因为「过线几个」这个数在阈值改过之后就没有对照物了。

## 值得知道的几个配置

一个都不是必须的。`polter +show-config --default --docs` 会打印全部。

| 配置项                              | 默认    | 干嘛用的                                                                 |
| ----------------------------------- | ------- | ------------------------------------------------------------------------ |
| `poltergeist-mcp`                   | `true`  | 开不开 agent socket。`false` 就是一个普通终端。                          |
| `poltergeist-register-mcp`          | `true`  | 允许插件去告诉你的 agent 运行时"Polter 的工具存在"。                     |
| `poltergeist-watch`                 | `false` | 每个终端一打开就采样。不需要为了上手打开它 —— 被认领的时候采样自然会开。 |
| `poltergeist-quiescence-after`      | `3m`    | 屏幕不动多久才上报。                                                     |
| `poltergeist-quiescence-repeat`     | `15m`   | 一直不动的，隔多久再提一次。                                             |
| `poltergeist-notice-interval`       | `1m`    | 多久才允许打断总管一次。                                                 |
| `poltergeist-supervisor-stand-down` | `true`  | 活干完之后总管能不能自己卸任。                                           |
| `poltergeist-notify-window`         | 空      | 允许打扰你的时段，写成 `HH:MM-HH:MM`。权限确认无视这个。                 |
| `poltergeist-chat-log`              | `true`  | 群聊落盘。                                                               |
| `poltergeist-terminal-log`          | `true`  | 终端转录落盘。                                                           |
| `poltergeist-task-idle-after`       | `12h`   | 一个任务多久没被碰过，就值得跟总管提一句。是「没被碰」，不是「卡住了」。 |
| `poltergeist-group-quiet-after`     | `1h`    | 一个群多久没人说话，就值得提一句。                                       |
| `poltergeist-worker-nudge-after`    | `10m`   | 一个手上有活的员工静止多久之后，会被问一句是不是有什么该汇报。           |
| `poltergeist-compact-after`         | `64KB`  | 一个群还没被压缩的正文攒到多少，就随总管下一次交接把这个数字带出来。     |

## 如果 agent 说它没有 polter 工具

Polter 已经把 socket 路径和 token 放进了每个终端的环境变量，agent **够得着**它
需要的全在那儿了 —— 但 MCP 客户端只会加载它被配置过的 server。

做这件配置是插件的活，不是核心的活（原因写在
`src/poltergeist/provision.zig`）。**`claude-code`** 插件默认就是开的，它做的就是
这件事：`claude mcp add --scope user`，外加把 Polter 的 skill 复制进
`~/.claude/skills/polter-*`。所以常见原因就三个：插件被关了、Polter 启动时
`claude` 不在 `PATH` 上、`poltergeist-register-mcp` 被关了。要注册但没有任何一个
注册插件开着的时候，Polter 会把这件事打在终端屏幕上，而不是只写进日志。

**注册记的是某一个构建，最后启动的那个说了算。** 起一个开发构建，会悄悄把你
用户级的 `polter` 条目指向它。开发的时候你要的就是这个，开发完就不是了。要么把
你想留的那个构建再起一次，要么设 `poltergeist-register-mcp = false`，自己用
`claude mcp` 管这条记录。

## 它支持哪些 agent

**只在 Claude Code 上测过**，也只有它开箱即用。但这件事的形状值得讲清楚，因为它
并不是"只能 Claude Code"：

- **server 本身是标准 MCP。** `polter +mcp` 在 stdio 上说标准 MCP，再通过 unix
  socket 转给 Polter。任何 MCP 客户端都能跑它。每个终端都有
  `GHOSTTY_POLTER_SOCKET` 和各自的 `GHOSTTY_POLTER_TOKEN`；token 决定了"你是哪个
  终端"，agent 冒充不了别人。
- **跟 Claude Code 绑定的只有配置那一步，而那是插件。** 核心发布的是**数据** ——
  哪个二进制提供端点、有哪些 skill、文件在哪 —— `claude-code` 插件把它翻译成
  Claude Code 认的形状。换一个 agent CLI，是再写一个插件，不是改核心。
- **`PATH` 上没有 `claude` 不算错误。** 插件说清它没能做成什么，Polter 把那句话
  打在屏幕上，其它照常。

所以别的 agent 原则上也能用这一整套：把 `polter +mcp` 注册进它自己的运行时，再
想办法把 `supervising` skill 送到模型面前（`skill_read` 会把正文交出来，但得有人
想到去调它）。**没测过。请当成未测试，而不是支持。**

## 插件

一个插件就是 `$XDG_CONFIG_HOME/polter/plugins/` 下的一个目录，里面一个
`plugin.json` 加一个可执行文件。它被启动一次然后常驻，Polter 往它 stdin 写 JSON
行，它在 stdout 回答。二十行的 shell 脚本就是一个完整的插件。

插件"是什么"，取决于它订阅了什么：

```json
{ "wants": { "events": ["chat"], "calls": [], "groups": ["*"] } }
```

- **`chat`** —— 群里有人说话了。
- **`terminal.quiet`** —— 某个终端静下来了，该告诉谁。
- **`provision`** —— 这是 Polter 的自我介绍，去让某个 agent 运行时能看见它。

**插件说的是跟 agent 一样的线协议**，过的是一模一样的检查：没声明的方法被拒，
总管的方法被拒（插件永远不是总管），被屏蔽的终端对它不可达 —— 跟对总管一样。

### 随构建装的这两个

两个都跟 Polter 一起装好，默认都开，而且都不要网络。

- **`archive`** —— 把每条群消息再存一份，一天一个文件，所有群写在同一条时间线
  上，按 JSON 行追加。把 `dir` 指向一个同步目录或者一块外置盘，这份拷贝就比这台
  机器活得久。填了 `sign_key`，每一行就带一个 HMAC-SHA256，事后被改过的拷贝自己
  会说出来 —— 这个 key 是凭据，所以要用引用的形式给（`env:`、`file:`、
  `keychain:`），别明文写。这是一道双保险：不管这个插件开不开，Polter
  [自己那份记录](#东西都写在哪)都照写，而且插件读的也不是那份 —— 事件是实时递给
  它的。
- **`claude-code`** —— 告诉 Claude Code 说 Polter 在这儿。它以 `user` scope 跑
  `claude mcp add`（所以在哪个目录下工具都在，而不是只在某一个项目里），再把
  Polter 的 skills 镜像到 `~/.claude/skills/polter-*`。没有它，agent 环境里躺着
  socket 和 token，却没有任何办法用上 —— 这也正是
  [下面那个问题](#如果-agent-说它没有-polter-工具)最常见的答案。只想注册 MCP
  server、不要 skills，就把 `skills` 设成 `no`。

想关掉哪个，去 **Agents → Plugins**。agent 只能把插件打开，永远不能关掉，所以关
不关只有你能决定。

通知渠道留给你自己塞：这类东西有几十种，随便预装一个都会立刻过时。

**`"network": false` 是一句声明，不是一个沙箱。** Polter 只是把插件自称需要什么
记下来、摆给你看，它并不去限制它（`src/poltergeist/Plugin.zig` 里就是这么写
的）。插件是你自己放进那个目录的一个可执行文件，以你的身份运行，你能干的它都能
干。装之前先读一遍，跟对待任何一个 shell 脚本一样。

**凭据只存引用，绝不明文** —— `env:NAME`、`file:` 路径、
`keychain:service/account`，或者 `cmd:` 一条命令、它的 stdout 就是值；在调用的那
一刻才解析，从不缓存。所以配置文件可以放进 dotfiles 仓库。`cmd:` 一条就覆盖了所
有密码管理器，而它恰恰是 agent **不许写**的那一种：agent 写下的 `cmd:` 会变成
Polter 以后自己去跑的一条命令，跑的时候早已不在当初授权它的那个场景里。**你自己
手改这个文件不受任何这些限制** —— 这个不对称说的是"这是谁的手"。

配置入口在 **Agents → Plugins**。完整契约见
[`docs/poltergeist/plugins.md`](docs/poltergeist/plugins.md)。

## 和 Ghostty 的关系

让它成为一个好终端的一切，都是 [Ghostty](https://github.com/ghostty-org/ghostty)
的功劳 —— Mitchell Hashimoto 和 Ghostty 的贡献者们。Polter 是分支不是重写：渲染
器、VT 实现、字体栈、原生界面全是他们的，上游有更新就合过来。

**所以关于终端本身的一切都该问上游**：支持哪些转义序列、性能、配置、快捷键、
`libghostty`、崩溃报告。看 [ghostty.org/docs](https://ghostty.org/docs)，那些内容
在这里全都成立，把 `ghostty` 念成 `polter` 就行。

Polter 加的是 `src/poltergeist/`、agent 说话的那个 MCP 工具面、聊天 TUI、终端转录
和插件宿主。本项目与 Ghostty 项目无关联，在这里发现的 bug，除非在上游 Ghostty 上
也能复现，否则不要报到那边去。

MIT 协议，和上游一样；见 [LICENSE](LICENSE)，原始版权声明保留在里面。

## 构建与文档

`zig build` 就能构建。[`docs/preview-manual.md`](docs/preview-manual.md) 是构建、
运行、调试的唯一权威，[`docs/README.md`](docs/README.md) 是其余文档的索引。上面这
些东西的设计推演在 [`docs/poltergeist/`](docs/poltergeist/README.md) —— 从它的
`README.md` 开始读，那是其余各章都要回答的那部宪法。

[`CONTRIBUTING.md`](CONTRIBUTING.md) 讲清楚这棵树哪一半是 Polter 的、哪一半是
上游 Ghostty 的 —— 动手写补丁前值得花两分钟看，猜错了要重做。
[`ROADMAP.md`](ROADMAP.md) 是活到哪了，包括 Windows 上还缺什么。
