# 安全

[English](SECURITY.md)

Polter 是一个终端模拟器，它让一个 agent 去读另一个终端的屏幕、往里面打字、新开终端。
这就是产品本身，所以安全问题不是「这件事做不做得到」，而是「谁可以做、对哪个终端做、
过程中记下了什么」。本文从代码出发回答这些问题，每一条机制性的说法都给出文件和行号，
并且在答案是「没有任何东西做这件事」的地方直说。

**本文和代码不一致时，以代码为准。** 行号对应的是本文最初写成时的那个提交，会漂移；
周围的函数名不会。

**2026-10-10 修订**，因为底下有三件事变了：总管现在可以在某些终端里代答权限提示；
agent 可以截图；路线图不再承诺 Polter 永远不用网络。这几节是对照代码重写的。**其余
各处的行号在这一轮没有重新核对**，已经落后好几个版本；请以函数名为准。

本文是 [SECURITY.md](SECURITY.md) 的中文译本；两者有出入时以英文版为准。

---

## 范围

本文覆盖 Polter 这一层——agent socket、可达性规则、凭据引用，以及落到磁盘上的东西。
Polter 是 [Ghostty](https://github.com/ghostty-org/ghostty) 的 fork，终端模拟器部分整体
继承自它；VT 解析、字体排版或渲染器里的漏洞属于 Ghostty，应当报给 Ghostty。

---

## 威胁模型

### 防的是什么

- **本机上的另一个进程来驱动你的终端。** 够得着 agent socket 还不够；调用方必须持有
  本进程签发的令牌（`src/poltergeist/Server.zig:684`、`:457`）。
- **一个 agent 冒充另一个终端。** 身份从令牌推出，从不取自调用方说的任何话。协议里
  没有让调用方自报身份的字段（`src/poltergeist/Server.zig:450-456`）。
- **插件越过它声明的范围。** 插件自己的 `wants.calls` 清单最先被检查，而且只能做减法
  （`src/poltergeist/rpc.zig:1066-1074`、`:1210`）。
- **一行被注入的文字把 worker 提升成总管。** 被监视的终端调用 `become_supervisor` 会在
  代码里被拒绝（`src/poltergeist/rpc.zig:4489`），所以出现在 worker 屏幕上的文字没法
  重排「谁能碰谁」。
- **在 Windows 上，管道被机器之外的人够到。** 命名管道会通过 SMB 提供给这台机器肯
  认证的任何人（`src/poltergeist/transport.zig:36-45`），所以创建它时带一个受保护的
  DACL，只列当前用户的 SID（`src/os/windows.zig:389-416`、
  `src/poltergeist/transport_windows.zig:88`、`:260`）。如果这个 DACL 建不出来，服务端
  **拒绝监听**，而不是开一个没保护的管道
  （`src/poltergeist/transport_windows.zig:260-273`）。

### 不防的是什么

- **任何以你的身份运行的东西。** 一个和你同 uid 的进程能读你的环境变量，也就能读到
  你的令牌，或者直接读状态目录。Polter 和你会话里的其它部分之间没有边界，本文也不
  声称有。
- **屏幕上的内容。** 见[提示注入](#提示注入)。
- **恶意插件。** 插件是你安装、由 Polter 运行的程序；`wants.calls` 这道闸收窄的是插件
  能发哪些 RPC，不是这个程序能对你的机器做什么。
- **任何经由网络的东西。** Polter 不开任何网络端口。它唯一会发的对外请求是访问 GitHub
  的 releases API，而且只在你选择「检查更新」时——没有后台检查，没有定时检查。那是
  一个匿名的 HTTPS GET：GitHub 能看到你的 IP 地址和一个写着程序名的 User-Agent（macOS
  上是系统默认值，含系统版本），看不到任何账号或本机数据。socket 是本机的。

  **这对迄今为止的每一个发行版都成立，但不再是对以后版本的承诺。** `ROADMAP.md`
  （「跨机器」一节）计划在经人配对的机器之间建立直连，不打开就不启用。任何发行版里
  都还没有这些东西。等它有了，会在发布之前在本文里拥有自己的威胁模型，这一段也会被
  重写，而不是原样留着。

---

## 本机 socket

**POSIX：** 状态目录里的一个 unix domain socket，路径里带的是八个随机字节而不是 pid
（`src/poltergeist/transport_posix.zig`，`defaultName`；理由在
`src/poltergeist/Server.zig:809-814`）。

**Windows：** 一个命名管道 `\\.\pipe\polter-<随机>`，原因是标准库的一个限制，写在
`src/poltergeist/transport.zig:9-34`——不是偏好。

**socket 文件上有意不做 `chmod`，文件权限不是边界。**
`src/poltergeist/Server.zig:220-224` 原话就是这么说的：socket 的权限在本程序运行的各个
系统上并不被一致地执行，依赖它只是虚假的安心。

### 调用方是怎么被认出来的

1. 每个终端启动时被签发一个自己的令牌：32 字节，渲染成 64 个十六进制字符
   （`src/poltergeist/Server.zig:74-76`、`:405-417`）。字节来自 `randomSecure`；**如果它
   失败，代码会退回到进程内的 `io.random`，而不是拒绝启动**
   （`src/poltergeist/Server.zig:410-415`）——那仍然是一个密码学生成器，只是更早被播种。
   这次回退会以 `warn` 级别记日志。
2. 令牌以 `GHOSTTY_POLTER_TOKEN` 放进该终端子进程的环境变量，和
   `GHOSTTY_POLTER_SOCKET` 一起（`src/Surface.zig:717-718`）。
3. 一条连接上的第一行必须是 `auth` 请求，否则连接被拒绝
   （`src/poltergeist/Server.zig:684-706`）。
4. 令牌用 `std.crypto.timing_safe.eql` 和每一个已签发的令牌比较
   （`src/poltergeist/Server.zig:457-478`）。
5. 终端消失时它的令牌被吊销（`src/poltergeist/Server.zig:430-448`）。

并发连接上限是 16（`src/poltergeist/Server.zig:42`），所以够得着 socket 的调用方没法
靠不断开线程把进程耗尽。

**一个观察，不是在声称缺陷：** 每个候选令牌的比较是常数时间的，但循环对每个*已签发*
的令牌跑一次，所以耗时随打开的终端数变化。这会把存活终端的数量泄露给一个本来就够得
着 socket 并能计时的东西。它不随令牌的内容变化。

---

## 可达性：三种标记

下面每条规则都在同一个函数 `authorize` 里（`src/poltergeist/rpc.zig:1059`），按这个
顺序执行。

| 目标带的标记 | 谁能碰它 |
| --- | --- |
| **护盾（shielded）** | 谁都不能，包括总管（`src/poltergeist/rpc.zig:1137`） |
| **被监视（watched）**或**总管（supervisor）** | 只有总管（`src/poltergeist/rpc.zig:1167`） |
| **没有标记** | 任何持有令牌的 |

这里有三点容易想反：

- **能不能碰由目标决定，不由关系决定**（`src/poltergeist/rpc.zig:1139-1160`）。没有
  「同级」这回事：一个被监视的终端碰不了另一个，不是因为它们平级，而是因为对方带着
  标记。
- **没有标记的终端是开放的那一种。** Polter 分不清那里面是一个 agent 在干活，还是一个
  人在看邮件，也不去猜。有标记意味着有人做了安排，而重排别人的安排不是陌生人该做的。
- **护盾是在考虑调用方的身份之前、对所有人先问的**，否则 `become_supervisor` 会让任何
  没有标记的终端提升自己、然后径直穿过去（`src/poltergeist/rpc.zig:1126-1137`）。

另外，改变监管安排的方法要求总管角色（`src/poltergeist/rpc.zig:656`、`:1085`）；指向
调用方自己终端的调用会被拒绝，除非它在一张很短的安全清单上
（`src/poltergeist/rpc.zig:955`、`:1124`）。

### 光是打开 socket 几乎什么都拿不到

在你把某个终端设成总管之前，一个持有令牌的 agent 能做的是：问自己是谁、读一份 skill、
列出它所在的群——一个都没有。读别的终端的屏幕、往里面打字、建群，都要求总管角色，
而总管只有用户能给（`src/config/Config.zig:1289-1294`）。

**有一个例外，而且不小：截图。** 截图工具对任何持有令牌的 agent 开放，不论是不是总管，
只要 `screenshot-agent-access` 允许——而它默认允许。见[截图](#截图)。

### 往终端里打字

`terminal_send` 走的是 `Surface.typePoltergeistText`（`src/Surface.zig:3724`），它直接
拒绝两样东西：带有「粘贴结束」序列的文本，不管目标在做什么
（`src/Surface.zig:3733-3737`）；以及目标没开括号粘贴时的多行文本
（`src/Surface.zig:3770-3773`）。除此之外它就是普通的粘贴通道，按粘贴的方式加框。

### 代答另一个 agent 的权限提示

**在 2026-09-08 之前，本文说没有这样的工具，而且永远不会有。现在有了一个**：
`terminal_answer_prompt`。当初反对它的那条理由，正是它如今长成这个样子的原因
（`src/poltergeist/rpc.zig` 里 `authorize` 的注释把两半都留着）。

- 它是总管的工具，而且只对开关打开了的终端起作用（`Bus.Entry.may_authorise`）。否则
  它回答 `AuthoriseOff`，并且能回答确认框的那些键——回车、方向键、tab——在那个终端
  也同样被拒绝。
- **在你自己开的终端里，开关是关的**，直到你从那个终端自己的菜单里把它打开
  （`Agents → Let a Supervisor Answer Prompts Here`）。没有任何工具能打开它；
  `setMayAuthorise` 拒绝用户以外的所有人。
- **在总管开出来的标签页或分屏里，它从一开始就是开的**（`Bus.markOpenedByAgent`，
  自 0.9.1684 起），你可以在那里把它关掉。普通 worker 开出来的终端不带这个授权。
- 插件完全不能调用这个工具；也没有谁能通过它回答*自己的*提示（`selfPermitted`）。

**这个默认值放开了什么，直说：** 总管可以在某个目录里开一个终端，并在那里选「Yes, and
don't ask again」，这对以后在那个目录里运行的每一个 agent 都是一个长期有效的许可。
没有任何设置能把这个默认值关掉；每个终端自己的开关是退路。

`terminal_send` 不受这个开关管。它只能打字、不能按回车，而且是一次和别的调用一样被
记录下来的普通调用，不是什么绕过——但它是一条公开存在的路，不是不存在。

插件打到屏幕上或写进日志的文本，会先被剥掉所有低于 `0x20` 的字节、`DEL` 和 C1 区段
（`src/poltergeist/scrub.zig`，`clean` 在 `:55`）——终端是一个解释器，插件的一行字
就是换了个名字的粘贴。

---

## 凭据

插件的参数可以是**引用**，在调用插件的那一刻才解析，而不是存下来
（`src/poltergeist/secret.zig`，`resolve` 在 `:75`）：

| 引用 | 从哪里解析 |
| --- | --- |
| `env:NAME` | 一个环境变量 |
| `file:~/path` | 一个文件的第一行 |
| `keychain:service/account` | 系统钥匙串 |
| `cmd:...` | 该命令打印出的内容 |

- **什么都不缓存**（`src/poltergeist/secret.zig:46-47`）。保险库锁上了就必须失败；缓存
  会把「它锁上了」这件事藏起来。
- **解析不了的引用就失败；它绝不会退回成它自己**（`src/poltergeist/secret.zig:69-74`）。
  把 `cmd:op read …` 当成密钥本身发给一个 webhook，会把你保险库的结构留在别人的聊天
  记录里。
- **`cmd:` 通过系统的命令解释器运行**——Unix 上是 `/bin/sh -c`，Windows 上是
  `cmd.exe /C`（`src/poltergeist/secret.zig:29-38`）。你能在里面写什么，取决于由哪一个
  来读。解析器有 30 秒时间，因为解锁保险库可能要弹窗
  （`src/poltergeist/secret.zig:60`）。
- **`keychain:` 在 Windows 上没有解析器**，并且会如实说明
  （`src/poltergeist/secret.zig:39-44`、`:218-222`）。

插件的设置文件以仅属主可读写的方式写入，而且是在任何密钥写进去之前、对着空文件先设
好——POSIX 上是 `0o600`，Windows 上是受保护的 DACL
（`src/poltergeist/Plugin.zig:1051-1058`）。Windows 上收紧失败会以 `warn` 记日志而不致命
（`src/poltergeist/Plugin.zig:1074-1080`），这和 socket 那边的取舍正相反，两边都是有意的。

---

## 写到磁盘上的东西

一切都在 `$XDG_STATE_HOME/polter` 下（Windows 上是 `LOCALAPPDATA`）。

| 是什么 | 路径 | 轮转 |
| --- | --- | --- |
| 聊天流（给程序） | `chat/chat.jsonl`（+`.1`） | 8MB，两代 |
| 聊天记录（给人） | `chat/<群>/<日期>.jsonl` | **无** |
| 终端记录 | `terminals/<id>-<标题>/<日期>.jsonl` | **无** |
| 任务面板事件 | `tasks/<群>/<日期>.jsonl` | **无** |
| 每小时统计 | `stats/<群>/<日期>.jsonl` | **无** |
| 截图与粘贴进来的图片 | `shots/<时间戳>.png`，各带一个 `.json` | **7 天后删除**，在启动时 |
| 保存的项目、上一次会话的安排 | `projects/`、`session.json` | 原地覆盖 |

- **没有保留期限，也没有任何东西清理这些记录。** 截图是唯一的例外，见下。按天的记录
  文件从不轮转、从不截短；一天超过 8MB 时，会在旁边接着写一个 `.partN` 文件，而不是
  把什么挪走（`src/config/Config.zig:1500-1503`、`:1544-1545`；
  `dev-docs/poltergeist/storage.md`）。
- **什么都不脱敏。** 终端输出里有 API 密钥、令牌和路径。一个十个密钥能抓到九个的清洗
  器比没有更糟，因为它会让人觉得这个文件可以放心发出去
  （`src/config/Config.zig:1539-1543`）。请像对待你的 shell 历史那样对待这些文件。
- 两类记录在 POSIX 上都以 `0o600` 创建（`src/poltergeist/daylog.zig:49-56`）。
- **截图**在 POSIX 上以 `0o600` 写在一个 `0o700` 的目录里。该目录里超过七天的文件会在
  应用启动时被删除，而且只删文件名符合 Polter 自己写出的那种模式的——所以把
  `screenshot-directory` 指到你自己的某个文件夹，不会让你的文件有危险
  （`dev-docs/poltergeist/screenshot.md` §5）。马赛克在任何东西写出之前就已经打上：
  未打码的图从不出现在磁盘或剪贴板上。截图旁边的 `.json` 里有：每个标注的文字和位置、
  它截的是哪块显示器和哪个窗口、是谁截的。
- 两类记录都可以关掉：`poltergeist-chat-log` 和 `poltergeist-terminal-log`，默认都开
  （`src/config/Config.zig:1511`、`:1548`）。
- 屏幕采样除非被要求，否则是关的：`poltergeist-watch` 默认 `false`
  （`src/config/Config.zig:1332`）。
- **永远没有遥测。** 关于你和你的终端的任何信息都不会被发往任何地方；Polter 没有账号、
  没有云服务、没有中继（`ROADMAP.md`，「这个项目不会变成什么」）。那唯一的对外请求——
  你选择时的「检查更新」——在上面「任何经由网络的东西」里说过了。

不脱敏和没有保留期限，作为已知限制写在
[issue #7 第 2 项](https://github.com/Lugia123/polter/issues/7)里。

**未验证：** 在 Windows 上这些日志文件是用 `.default_file` 创建的，而不是带一个收紧的
DACL（`src/poltergeist/daylog.zig:52-56`）——`Plugin.zig` 用的那个 `restrict` 辅助函数
没有用在它们身上。所以它们实际得到什么权限，取决于状态目录传下来的是什么，而这一点
没有在 Windows 机器上量过。

---

## 截图

自 0.9.1728 起 Polter 能截图，agent 也能请求截图。

- **任何持有令牌的 agent 都可以截，不只是总管。** 列出屏幕上有什么、截一块显示器或
  一个窗口或一个区域、截长图、在已有的截图上画标注——这些工具是按用户的设置来拒绝的，
  不看身份（`src/poltergeist/rpc.zig` 里的 `requiresSupervisor` 对它们全部回答
  `false`）。那个设置是 `screenshot-agent-access`，**它默认是 `allow`**
  （`src/config/Config.zig`）。把它设成 `deny`，或者在「设置 → 通用 → 截图」里关掉，
  它们就全部被拒绝，并附一句话说明原因。
- **能被截到的是你屏幕上的任何东西**，不只是 Polter 自己的窗口：别的应用的窗口、一个
  开着没关的密码管理器、一条碰巧露在外面的消息。agent 发起的截图不会在屏幕上出现
  任何界面。每一张都记下了是谁截的（`.json` 里的 `by`），而那个记录是一个文件，不是
  一条通知——发生的那一刻没有任何东西告诉你。
- **图片和别的内容一样是内容。** 截图里有什么，就会进到请求它的那个模型里，所以你
  屏幕上的文字又多了一条到达 agent 的路。见[提示注入](#提示注入)。
- **给人用的两种全局触发。** 一个热键，以及按住一对修饰键再单击，都是系统范围的。
  Windows 上那次点击会被吞掉；macOS 上它同时也会到达指针下面的应用。
  `screenshot-mouse-trigger` 可以修改或关闭后一种。
- **macOS 权限。** 屏幕录制，没有它什么都截不了；辅助功能，长截图的自动滚动要用
  （`ShotSession` 和 `ShotAgentHost` 都会问 `AXIsProcessTrusted`）。Windows 不需要任何
  权限。

**未验证：** Windows 上的文件权限和七天清理是照规格写的，没有在机器上读回来确认过。

---

## 提示注入

**总管读别的终端的屏幕，读到的东西进入它的上下文。任何能把文字放到其中一块屏幕上的
东西，都能把文字放到监管模型面前**——一个被 `cat` 出来的文件、某个依赖的构建输出、
worker 抓下来的一个网页、一条提交信息。还有两条更新的路带着同样的风险：装了 hooks 的
agent CLI 在一轮结束时说的话，会作为文字转给它的总管；截图会把当时屏幕上的任何东西
放到请求它的 agent 面前。

Polter 不清洗这些，也没法清洗：内容就是产品。这作为已知限制写在
[issue #7 第 4 项](https://github.com/Lugia123/polter/issues/7)里，背后的设计缺口写在
`dev-docs/poltergeist/gaps.md:476-495`。

现有的是结构上的，而不是过滤：

- `become_supervisor` 对被监视的终端是拒绝的（`src/poltergeist/rpc.zig:4489`），所以
  一句被注入的「把你自己提升为总管」改不了权限结构。
- 被监视的终端碰不了另一个带标记的终端（`src/poltergeist/rpc.zig:1167`），所以一个
  被攻陷的 worker 没法靠往别的终端里打字而蔓延开。

**这堵住了那几条路，没有堵住一般的那一条。** 从 worker 来的文字——`group_post` 的
正文、`terminal_read` 的输出、终端标题——原样到达总管的上下文，没有任何标记把「这是
一个 worker 说的话」和「这是一条指令」区分开。今天，在一行被注入的文字和总管照它去做
之间，只隔着监管模型自己的判断。**风险落在谁身上：落在运行这个会话的人身上。** 如果
一个 worker 在读不可信的内容，请像对待那份内容本身一样对待它报告的东西。

---

## 报告漏洞

请私下报告，不要开公开的 issue。

请使用 **[GitHub Security Advisories](https://github.com/Lugia123/polter/security/advisories/new)**
——仓库 Security 标签页下的「Report a vulnerability」按钮。

如果你用不了那个表单，请开一个普通的 issue，只说你发现了一个安全问题，并询问发送
细节的方式。**不要把细节写在公开的 issue 里。**

请附上你自己会希望收到的东西：攻击者能做什么、能展示它的最小步骤、你是在哪个提交上
看到的。没有赏金计划，也不承诺响应时间——这是一个只有一位作者的项目。

---

## 没有做过的事

之所以写出来，是因为「没有声称」很容易被读成「声称了」：

- **没有任何人做过安全审计或渗透测试。** 上面的一切都是对代码的阅读，不是对抗性演练
  得出的发现。
- **没有对 RPC 接口做过模糊测试。** 协议是按行分隔的 JSON，由标准库解析；它没有被
  当作一条边界来模糊测试过。
- **可达性规则有单元测试，但没有对抗性测试。** `src/poltergeist/rpc.zig` 里对每一种
  拒绝都有测试；没有人专门去找过绕开这一整套的办法。
- **本文里的行号自最初写成以来没有重新核对过**，除了 2026-10-10 修订的那几节——它们
  引用的是函数名。
- **没有人去查过：一个默认就被允许截图的 agent，能从截图里得知些什么。** 设置是有的；
  它的默认值会带来什么后果，是推理出来的，不是测出来的。
- **Linux 未验证。** GTK 版能构建，但没有人在上面跑过带总管的会话（`ROADMAP.md`），
  所以上面这些在那里一条都没被实际运行过。
- **上面关于 Windows 的行为是从代码读出来的**，只有管道 DACL 那条路背后有一番论证
  而不是一次测量；Windows 上实际生效的权限没有在机器上核对过。
