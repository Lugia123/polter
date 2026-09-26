# 项目自动保存：结构与 scrollback

> 最后更新对应的 git commit：`3714cf132`
> 校验方式：`git log -1 --format='%H %h %ad %s'`

## 本文覆盖什么

- 「重新加载项目后，每个 pane 里看不到以前跑过的东西」这件事要怎么做。
- 为什么这件事必须是**自动保存**，不能是「存盘那一刻抓一次」—— 强制重启、掉电、崩溃都没有那一刻。
- 为什么自动保存的前提是一个现在**还不存在**的东西：**tab 和项目的绑定**。
- 自动保存把误操作变成永久的，这个代价怎么办。
- 为什么这不是一个序列化任务：编解码已经在仓里，而且是双向的。
- 上限的语义（**定量循环，不按时间**）、它落在哪一层、以及为什么这一层是唯一能落的地方。
- 三个平台各要改什么，以及为什么三个平台的工作量**不对称到可以只写一遍核心**。
- 哪些东西恢复不了，以及为什么接受。

## 本文不覆盖什么

- 命令历史（shell 上箭头能翻出来的那些）。那是**另一件事**，已经做完了，见 `src/CommandHistory.zig` 的模块注释和 `src/Project.zig:49-75` 的 `Leaf.history`。本文要做的是**屏幕上的内容**，两者在实现上没有一行重叠。
- 快照线格式本身。见 `src/terminal/snapshot/main.zig:21-63` 与 `src/terminal/snapshot/AGENTS.md`。
- 构建与运行命令。唯一权威是 [preview-manual.md](preview-manual.md)。

## 一、先把问题和现状对齐

目前「重新加载项目」恢复的是：窗口、分屏树、每个 pane 的工作目录、每个 pane 的 shell 命令历史。**不恢复屏幕内容** —— 打开一个几天前存的项目，每个 pane 都是一个干净的新 shell。

要注意 `Leaf.history` 恢复的是什么：它是一个 HISTFILE 形状的文件（`src/CommandHistory.zig` 的模块注释说明了它是**故意**长成这个形状的，好直接交给 shell），作用是让**上箭头能翻出旧命令**。它从来就不是屏幕内容，也装不了屏幕内容 —— 它只有命令行本身，没有输出、没有颜色、没有换行位置。

所以缺的那半是终端的 **scrollback**，和命令历史是两个不相干的东西。

## 二、决定性的事实：编解码已经有了，而且能往回写

`src/terminal/snapshot/` 是一套**双向**的编解码器。这一节的每一条都在 `3714cf132` 上核过。

**导出**：`src/terminal/snapshot/snapshot.zig:44` 的 `encode` 吃一个 `*const Terminal`，写出的东西包含 primary 和 alternate 两个屏、以及**全部 scrollback 历史页**（`snapshot.zig:60-95`；记录顺序 TERMINAL → SCREEN → CONTINUATION → READY → HISTORY → FINISH 见 `main.zig:47-63`）。

**导入**：`snapshot.zig:599` 的 `decode` 产出的**不是**一份旁路数据结构，而是一个原生可用的 `Terminal`（`terminal.zig:945-951` 的注释写明 "directly into native terminal state"）。

**而且能往活的终端里补历史**，这是最关键的一条：`snapshot.zig:457` 的 `Decoder.next(alloc, t: *Terminal)` 接的是一个**已经活着、甚至已经在吃新 pty 字节**的 `Terminal`，每调用一次把一页历史 prepend 上去；底层是 `history.zig:208` 的 `decodePage`，直接在目标 `PageList` 上 `allocatePage` + `finalize(.prepend)`，记录校验失败则 screen 原封不动。

保得住的：样式（`style.zig:1-23`）、超链接（`hyperlink.zig:1-30`）、宽字符与 spacer 配对（三种 wide 状态见 `grid.zig:386-424`，配对校验见 `:477-484`）、组合字符（`grid.zig:129-139`）、软换行（row flag 的 bit 0/1，`grid.zig:39-41`）、以及**语义 prompt 标记**（`history.zig` 的 `decodePage` 里 `hasSemanticPrompt` → `semantic_prompt.seen`，这条意味着恢复后 `cursorIsAtPrompt` 之类的判断不会全错）。

**所以这个功能缺的不是终端层的能力，是产品侧的接线。** 剩下的篇幅都在讲接线。

## 三、接线点：三处，其中一处是三份实现

### 3.1 项目文件格式被实现了三遍

这是设计这件事必须先知道的事实，否则会漏掉三分之二的工作：

| 实现                            | 规模   | 有没有产品调用者                                                 |
| ------------------------------- | ------ | ---------------------------------------------------------------- |
| `src/Project.zig`               | 829 行 | **没有**。全仓唯一引用是 `src/main_ghostty.zig:265` 的 `_ = @import("Project.zig")`，作用只是把它的测试拽进测试二进制 |
| `windows/host/src/project.rs`   | 701 行 | 有，Windows 上真正跑的就是这个（用 `serde_json`，理由见该文件 `:15-19` 的注释） |
| `macos/Sources/Features/Projects/` | 多文件 | 有，mac 上跑的是这个                                             |

也就是说 `src/Project.zig` 是一份**有测试、没用户**的参考实现，它不约束另外两份。往项目文件里加一个字段，就是**加三遍**，而且**没有任何闸会因为漏了一份而变红** —— 三份各自都能编过、各自的测试都能绿。这条要写进任务判据里。

### 3.2 存：核心 → 宿主

已有先例是 `Leaf.history` 那条路：`src/Surface.zig:871-882` 在 surface 创建时**同步**发一次 `.history_filename` action（`src/apprt/action.zig:424-430`），宿主把它记在 pane 上，将来「存成项目」时直接填进 JSON，不用回头问核心。

scrollback 不能照抄这条路，因为**差一个根本性质**：history 的文件名在 spawn 时就定了、终生不变（这正是那段注释说明为什么它不走 mailbox 的理由）；而 scrollback 的内容只有在**存盘那一刻**才知道。

而且 `Terminal` 是 IO 线程私有的。所以存盘必须是一次**拉取**，并且要跨线程：

1. 宿主在存项目时调新的 C API（形如 `ghostty_surface_capture_scrollback(surface, path)`）。
2. 核心把它变成一条发往 IO 线程的 mailbox 消息。
3. IO 线程上 `snapshot.encode` 写到 `path` 的临时文件，再原子 rename 就位。

**宿主不等它。** 宿主立刻写 JSON（里面写上它**预期**的快照文件名），快照文件异步落地。这样不阻塞 UI，而且失败模式正好退化成今天的行为（见 3.4）。

已实现为 `ghostty_surface_capture_scrollback(surface, path)`（`include/ghostty.h`）→ `Surface.captureScrollback` → `termio.Message.capture_scrollback` → `Termio.captureScrollback`：在 renderer 锁里编码成内存中的字节，**出锁以后**才原子写盘（`termio/scrollback.zig` 的 `writeFile`），所以文件系统不会卡住渲染。`path` 必须是绝对路径。

⚠️ **「不等」之所以成立，靠的是核心保证关窗时不丢请求。** surface 关闭时 IO 线程**不会**把 mailbox 抽干：`Surface.deinit` 发 `stop`，`stopCallback` 只调 `loop.stop()`，剩下的消息由 `Mailbox.deinit` 不经处理地释放。而「存成项目然后关窗」正是先给每个 pane 入队一次 capture、紧接着关掉所有 pane。所以 `termio/Thread.zig` 的 `run` 在循环停下之后用 `finishCaptures` 把还在队列里的 capture 全部写完，这一步在 join 之前，那时 terminal 还完整。**对宿主的保证：在 `ghostty_surface_free` 之前调过的 capture，`free` 返回时文件已经落盘。** 不经过 `free` 就退出的进程（直接 exit、崩溃）不在这个保证之内。

### 3.3 取：宿主 → 核心

这一半**照抄了** `history_restore`：`src/apprt/embedded.zig:585` 那个 `history_restore: ?[*:0]const u8` 字段，注释写明它「不在这里解释」，由核心在知道自己要 spawn 哪个 shell 的地方展开。新增一个同形状的 `scrollback_restore: ?[*:0]const u8`，在 `src/termio/Termio.zig:306` —— 现在无条件 `Terminal.init` 的那一行 —— 消费它。

⚠️ 这个字段在 C 结构体里的**声明顺序就是内存布局**（`embedded.zig:571-574` 明写了这一点，而且 `history_restore` 自己就带着「Declared last to match `ghostty_surface_config_s`」的注释）。加字段必须同时改 `include/` 里的 C 头和 Rust 侧手写的 extern 结构体，而 **Rust 手写的 extern 结构体在布局变了的时候不会编译失败** —— 这正是本次上游合并里 `ghostty_clipboard_content_s` 加 `len` 字段踩过的坑（见 `a4e13545a` 的提交信息）。

**实现（`src/termio/scrollback.zig` 的 `restore`）不直接拿解码出来的 `Terminal` 当 pane 的终端**，而是只把它 primary 屏的 pages 和 cursor 移植进 pane 自己新建的终端（`transplantPrimary`）。原因：pane 里跑的是一个**新 shell**，旧会话的模式、alternate 屏、颜色、charset、kitty keyboard 标志描述的都是一个已经不在的程序，照搬会让新 shell 起在旧 vim 的 alternate 屏里、带着旧程序开的鼠标上报。移植后 scrollback 上限改用当前配置的值，画笔复位，光标移到恢复内容下面一行。恢复在 `Termio.init` 里、shell spawn 之前、任何线程启动之前做。

三条**必须按顺序**的约束，顺序错了的表现都是「静默地少恢复」。每一条都有测试，每一条的地板都是「把顺序写反、仍然编得过 → 测试红在断言上」：

1. **先把 `Terminal` 放到最终地址，再建 `Stream`。** `snapshot.zig:113-128` 反复强调这一点，因为 `Decoded.toOwned()` 会**移动** `Terminal`。在移植方案里，Stream 从来不指向解码出来的终端（它只属于 pane 自己的终端，而 continuation 不喂，见第 3 条），所以这一条变成了它的同类：**历史必须在移植之前抽进解码出来的那个终端。** 反过来（先移植再抽）时，页会被 prepend 到解码终端**此刻**拿着的屏上，也就是 pane 那块空屏，而它随后就被释放了。测试：`restore at the same size brings all the history back`，写反时红在 `history_rows >= saved_history`。
2. **先把历史收完，再 resize。** `snapshot.zig:440-458` 明写：一旦 `t.cols != state.cols`，当前页被消费但丢弃，**并且该序列其余的页一并丢弃**（因为后面的页更老，跨空洞贴上去会把 scrollback 顺序弄坏）。快照解出来的终端是**存盘时**的尺寸，而窗口现在可能是别的尺寸。所以顺序是：decode → 把 `next` 抽干 → 然后才 `Terminal.resize`，让 `PageList` 自己做 reflow。反过来做的结果是：小窗口恢复出一屏内容，其余几千行无声消失。测试：`restore into a narrower window keeps every line of history`（存 40 列、恢复 12 列），写反时红在 `history_rows >= saved_history`。⚠️ 这条测试的夹具必须**真的有 HISTORY 页**：几百行输出全都落在 SCREEN 带的那一页里，HISTORY 一页都没有，这时把顺序写反测试照样绿。所以夹具写两万行，并断言快照里有 ≥ 2 个 HISTORY 页。
3. **continuation 字节要丢掉，不要喂。** `src/terminal/snapshot/continuation.zig:1-24` 里的 continuation 是「把 VT 解析器从 ground 带到当前状态所需的最小 pty 字节」，它服务的是**热迁移**：快照切在一个转义序列中间，后续的 pty 字节接着来。项目恢复不是热迁移 —— 后续字节来自一个**全新的 shell**，和旧的半截转义序列毫无关系。把它喂进去，新 shell 的头几个字节会被当成旧转义序列的尾巴解析。⚠️ 这一条与格式设计的**意图相反**，是本场景特有的决定，实现时要把理由写在调用点上，否则下一个人会「修好」它。测试：`a continuation in the snapshot does not reach the new shell`，快照切在 `ESC [` 中间，恢复后喂 `hello`；写反时 `h` 会被当成 CSI 的终结字节，只剩 `ello`，红在 `hello` 那条断言。抓取一侧写的 continuation 一律是 ground，因为项目快照从来不会被续写，Termio 的 stream 也不跟踪 continuation。

### 3.4 读不动就当没有

格式版本号当前是 1，`envelope.zig:57` 要求**严格相等**，不匹配直接 `error.UnsupportedVersion`，没有迁移层；而 `main.zig:21-23` 自称版本 1 是 work-in-progress、**会继续破坏兼容**。

这对本功能不是问题，但必须是**设计出来的**行为而不是事后补的：**快照缺失、版本不符、CRC 坏、任何 decode 错误 → 起一个空终端，并把那个文件删掉。** 退化结果恰好等于今天的行为。所有可能失败的步骤都在移植之前完成，所以 pane 的终端要么完全没被碰过，要么已经完整恢复。

测试 `an unreadable snapshot starts empty and is deleted` 用的是**真快照改字节**：翻转最后一个历史页 payload 里的一个字节（`InvalidChecksum`，此前的页已经抽进去了）、改版本号（`UnsupportedVersion`）、截掉一半（`EndOfStream`）。

⚠️ **核心只删以 `.snap` 结尾的路径。** 路径是宿主给的，而删它的是核心，所以「只删快照」这条校验放在核心，三个宿主不用各做一遍。其他路径一律不删，只记一条 warn。测试：`an unreadable file that is not a .snap is left where it is`。`project-scrollback-limit-bytes = 0` 时，capture 删掉 `path` 上的旧快照（同样只删 `.snap`），restore 什么都不做。

### 3.3.1 ⚠️ 已知缺口：Windows 上恢复时，落在活动区里的那一屏会整段消失

核心这一侧是完整的 —— `src/termio/scrollback.zig` 的 `transplantPrimary` 把**整个 `pages`
（含活动区）和光标**都换过去，然后 `carriageReturn` + `index` 把新 shell 的提示符放在恢复内容
下面。本机探针也证实了：一个只有 3 行、全在屏上的快照，恢复后活动区里就是那 3 行。

**但真机（Windows）上，恢复那一刻落在活动区里的内容整段没有了，而历史完好。**
用一份 200 行、最后一行带 OSC 133;A 提示符标记的快照量到：

    核心报        scrollback restored history_rows=184
    历史里        PROBE-FULL-000 … 183   （184 行，和 history_rows 一致）
    不见了        PROBE-FULL-184 … 199 + 那行带标记的 `$ `，共 17 行
    窗格高度      约 20 行  ⇒ 不见的正好是「恢复那一刻在屏幕上的那一屏」

⚠️ **mac 上没有这个现象**（同样的做法，300 行的最后一屏和标记行都在，单屏内容也在）。

**成因还没定案**，但两种擦除都已被读数排除：
· **不是 RIS**（`ESC c`）—— 本机喂 RIS 是 0 行，而真机历史完好。
· **不是 ED2** —— 本机喂 ED2（在带 133;A 的提示符上）是 200 行**全进历史**，而真机那 17 行
  **没有**进历史。⚠️ 而真机那份快照的最后一行**确实带着标记**，所以「不在提示符上所以没走
  `scrollClear`」这条解释也用不上。
⇒ 目前最吻合的候选（**推断，未量**）：**来的不是擦除命令，是用空格逐格覆写活动区**
（一次全屏重画）。那会让内容消失、**不产生擦除语义因而不推进历史**、历史不动 —— 三条都对上，
而 ED2 和 RIS 各自都对不上至少一条。
⇒ **唯一能定案的读数是 ConPTY 在 restore 之后发来的前几百个原始字节**，需要一个只加转储、
不改行为的临时构建。仓里现有代码**没有**任何 pty dump/trace 开关（已 grep 核过）。

⚠️⚠️ **这个缺口三条顺序约束的地板一条都抓不到**，而原因不是它们只看历史行数（有一条也断言
了活动区里的最后一行）——**而是没有一条判据包含「恢复之后新 shell 发了什么」，所有测试都停在
`restore` 返回的那一刻**。⇒ **判据的边界在时间上，不在数据上。** 任何补进来的判据至少要有一条
跨过那一刻：恢复 → 再喂一段字节 → 断言内容还在。

⚠️ **另有一条造判据时的陷阱**：ED2 判断「是否在提示符上」是**从活动区最底下一行往上扫**
（`Terminal.zig:3630-3652`）。⇒ **夹具的行数必须填满活动区**，否则底下的空行会让它判成
「不在提示符上」，走到错误的分支 —— 而它走错时不报错，只给你一个合理的答案。第一版分辨文件
（3 行内容、20 行高的窗格）就是这么失效的。

## 三·五、自动保存：这件事的形状（2026-09-26 由产品负责人改定）

### 3.5.1 「存盘那一刻抓一次」是错的

本文前面几节写的是「宿主在存项目时调一次 capture」。**那个设计只在用户正常关窗时有效。**
强制重启、掉电、进程崩溃都没有「那一刻」，而这些恰恰是用户最希望历史还在的场合。

⇒ 抓取必须是**持续的**，不是一次性的。

### 3.5.2 但「定时存整份」的成本不对

标准页是 215×215（`src/terminal/page.zig:1896`）。80 列纯 ASCII 满行按 §4.3 的编码规则约
83 字节/行 ⇒ **一页约 18 KB**；反过来 10 MB 上限 ≈ 550 页 ≈ **11.8 万行**（和 §4.3 的推算一致）。

若每个周期重编整份：12 个 pane × 10 MB ÷ 60 秒 = 120 MB/分钟，8 小时写约 57 GB。不可行。

### 3.5.3 增量的单位是「页」，而这一点成立

两条都在 `3714cf132` 上核过：

1. **单个 PAGE 记录是自描述的、能独立解码。** `src/terminal/snapshot/page.zig` 有独立的
   `encode`（`:142`）和 `decode`（`:167`），`Decoder.init`（`:192`）从 PAGE 头部就能读出要分配
   多大（`capacity`，`:203`）；头部自带列数、行数与各项容量（`page.zig:26-35`）。而
   `history.zig:208` 的 `decodePage` 已经是「解一页 → prepend 到活着的 screen」。
2. **scrollback 本身就是一个页的环，滚出去的页不再变。** 新输出只写活动页；一页填满就换一页。

⇒ 定时保存只需写**活动页**（几十 KB），完成的页各写一次，淘汰就是删。
**成本从 10 MB/周期降到几十 KB/周期**，间隔可以做到几秒。

**磁盘形状**：每个 pane 两个文件 —— 一个只追加的完成页日志（淘汰时头部前进，死掉的前缀
大到一定比例再压实一次），加一个小文件放元数据 + 活动页，每周期重写。不是 550 个文件。

**一串裸 PAGE 记录不是一份合法的 v1 快照，但可以直接拿来当容器的零件**（在 `e5c8a9b6e` 上核过）：

- **不合法**：v1 的语法是 envelope 之后必须紧跟 TERMINAL（`main.zig:47-63`）。`snapshot.decode` / `Decoder.ready` 读到的第一个记录如果不是 TERMINAL，就报 `UnexpectedRecordTag`（`terminal.zig:961`）。所以「envelope + 裸 PAGE」这种文件不能冒充快照，也不该复用快照的 magic `GHOSTSNP`：同一个 magic 配两套语法，读错的人只会得到一个莫名其妙的错误。
- **零件能单独用**：记录分帧（`record.Writer` / `record.Reader`，带 CRC）和 PAGE 编解码都是 pub 的，也不依赖外壳。`page.encode` 写出一个完整的带帧记录；`page.Decoder.init` 只检查记录 tag 是不是 `page`（`page.zig:192-200`）；`history.decodePage` 把一页 prepend 到一个活着的 screen 上。
- ⇒ 第 3 步的形状：**完成页日志** = 自己的一个小文件头（自己的 magic 和版本）+ 一串带帧的 PAGE 记录；**活动部分** = 一份普通的 v1 快照，写成 `max_history_bytes = 0`，于是只有 TERMINAL、SCREEN 和一个空的 HISTORY，有几十 KB，每个周期整份重写。恢复时先照第三节的办法解那份小快照，然后在 resize 之前，从日志里由新到旧逐页调 `decodePage` prepend。3.3 的顺序约束原样适用。⚠️ 但宽度检查和「丢一页就丢掉其后更老的所有页」这两条规则写在 `Decoder.nextPage` 里，不在 `decodePage` 里，所以直接调 `decodePage` 的人要自己把它们补上。
- 要另外定的只有日志的文件头，以及淘汰和压实的记账，线格式本身不用动。

### 3.5.4 有**三**件事会打破「页不可变」，都必须有地板

⚠️ **本节的第一版写错了一条、漏了最危险的一条。** 下面是核实过的版本。

- **resize 会 reflow 重写页**：`src/terminal/PageList.zig:1261` `resize`、`:1343` `resizeCols`、
  `:1654` `reflowRow`。页全部新建、换号。
- **`ESC[3J`（清 scrollback 历史）**：`Terminal.zig` → `eraseHistory`（`PageList.zig:5480`）→
  删整页，或者对被截断的页调 `invalidateNodeLayout` ⇒ 换号或消失。
- ⚠️⚠️ **窗口变高，把历史行拉回活动区**。写完的页又变成可写的，**而且不换号** ——
  `page_serial` 只在「不同世代」时改变（`PageList.zig:411-419`），而这里同一个页节点还活着、
  布局没变，只是它的行重新落进了活动区。**号不变，内容却会被程序改掉。**
  ⇒ 这是三条里最危险的一条，因为**任何依赖「页号变了才说明页变了」的检测都看不见它**。

**而「清 scrollback」那一条（`scrollClear`，`PageList.zig:3561`）不在这张表里** ——
核实过：它的函数体末尾只有 `for (0..non_empty) |_| _ = try self.grow();`，也就是把活动区的行
往后追加，**不改写已经完成的页**。第一版把它列进来是错的。

三者都是明确事件，发生时把磁盘上那一份标记作废或重来。
⭐ **不要为三条各加一个钩子。** 一个覆盖全部三条的不变式是：**把「当前写完的页序列」和
「已写进磁盘的页序列」做后缀比对** —— 相等或只是前缀被淘汰 ⇒ 追加；否则 ⇒ 重开。
第三条正是靠「当前序列**比**已写的**短**」被抓住的，而它没有任何换号可依赖。
（这个不变式由 #834 的设计提出，见那份设计的「怎么认写完的页」一节。）
⚠️ **漏了的表现是「恢复出一份和当时屏幕对不上的历史」—— 比恢复不出来更糟**，因为它看起来是
成功的。所以判据不能只验「恢复出了东西」，要验「恢复出的内容等于当时的内容」，并且地板是
「故意跳过作废这一步 → 判据红」。

### 3.5.5 前提：tab 和项目的绑定，现在不存在

核过：`macos/Sources/Features/` 里 **没有** `projectName` / `boundProject` / `currentProject`
这一类状态（全仓 grep 无命中）。「存成项目」是**一次性导出** —— tab 存完不记得自己属于哪个
项目，反过来打开项目建出来的 tab 也不记得。

⇒ 自动保存缺的第一块不是定时器，是这个绑定。

- **何时建立**：存成项目时；打开项目时。
- **存在哪**：控制器上的内存状态 + 要能活过 app 重启，否则重启一次就退回手动。
- **触发结构保存的事件**：分屏增删、比例拖动、cwd 变、标题变。⚠️ 拖分屏会连续触发，
  要合并（约 1 秒去抖）。项目 JSON 很小，写的成本可忽略。
- **两个 tab 绑到同一个项目**：拒绝第二次绑定并说明。理由是另一种做法（都写同一个文件）
  的失败形式是静默互相覆盖。

### 3.5.6 自动保存会把误操作变成永久的

现在手动存是一道闸：打开一个项目、误关五个窗格，只要不存，项目还是原样。自动保存之后
那五个窗格就没了。

⇒ **结构**：写之前把旧文件留一份（`<name>.json.prev`，只留一代）+ 一个「恢复上一个版本」的
入口。比版本历史轻得多，挡得住绝大多数误操作。
⚠️ **这一招对 scrollback 不适用**（10 MB 留两代就是 20 MB）。scrollback 那边接受
「追加的东西不会丢，删掉的东西找不回」，并且要在文档里对用户说明。

### 3.5.7 顺带解掉的两件事

- **issue #22 的影响面缩小**：「关闭前要存成项目吗？」那个框（没有取消按钮、存盘失败还照样
  关窗杀进程）**对已绑定的 tab 就不需要了**，它只在未绑定的 tab 上弹。
- **关窗时 mailbox 会丢消息这件事从阻塞降级**。核心侧已经补上：IO 线程退出前
  `finishCaptures` 把队列里的 capture 全部写完（`src/termio/Thread.zig`），保证
  **「在 `ghostty_surface_free` 之前调过的 capture，free 返回时已落盘」**；地板是把它写成
  `defer if (false) …`（仍编得过）后红在读文件那一行。⚠️ 剩下的口子是进程不经过
  `ghostty_surface_free` 就退出（直接 exit 或崩溃），核心无能为力 —— **而这正是 3.5.1 那条
  要自动保存的理由**：自动保存让这条保证从「唯一防线」变成「最后一道」。

### 3.5.8 落地顺序：三步，每步能独立交付

1. **完整快照的存取做通**（本文第三节的原方案）。它是后面一切的基础，也是退路 ——
   第 3 步失败了也还有一个能用的功能。
2. **绑定 + 结构自动保存**（小、独立、立刻有用：改了分屏和布局就自动存）。
3. **scrollback 按页增量**（最大的一块）。

## 四、上限：定量循环，不按时间

### 4.1 语义

上限是**容量**，不是**年龄**。比如设 10 MB，就永久保留最近的 10 MB；一个几个月没开过的项目，加载时照样把那 10 MB 显示出来。没有过期，没有「多久以前」这个维度。

### 4.2 「循环」这一层几乎是免费的

因为**终端自己就是一个环**。`src/config/Config.zig` 里 `@"scrollback-limit-bytes"` 默认 50 MB、`@"scrollback-limit-lines"` 默认无限，先到者生效；活着的 `PageList` 早就在淘汰最老的页了。所以「最近的 N MB」这个窗口不需要新造，它就是终端当前持有的那些页。

解码这一侧也已经按这个语义写好了：超出目标 screen 的 scrollback 上限的历史页是**丢弃而不是报错**（`snapshot.zig:589-593`）。所以一个偏大的快照读起来是安全的。

### 4.3 落盘的上限要单独一个旋钮

50 MB 是**一个**焦点终端的内存上限。落到盘上它是「每 pane × 每项目」，而且每次存盘都付一遍：一个 12 pane 的项目按 50 MB 算是 600 MB。所以持久化要有自己的上限。

**已实现：`project-scrollback-limit-bytes`，按 pane 计，默认 10 MB，`0` 表示彻底关掉这个功能。**

为什么是 10 MB 而不是 50：编码在 cell 层省空间的手段是「每行只编到最后一个非默认 cell，全默认行就是 3 字节的行头」加「每行按需选 1/2/4/8 字节的 cell 宽度」（`grid.zig:57-92`）。**实测**（`ghostty-bench +terminal-snapshot --mode=report`，ReleaseFast，80×24，scrollback 不设上限；`encoded=` 是读数，行数是按语料文本去掉转义序列、按 80 列折行**算出来的**，不是从终端读的）：

| 语料 | 行数（算） | `encoded=` | 字节/行 | 字节/cell | 10 MB ≈ |
| ---- | ---------: | ---------: | ------: | --------: | ------: |
| `ghostty-gen +ascii` 5 MB，满行无样式 | 62,500 | 5,192,155 | 83 | 1.04 | 12 万行 |
| `git log --color=always --stat -n 6000` | 172,038 | 16,990,808 | 99 | 1.23 | 10 万行 |
| `git log -p --color=always -n 400` | 263,487 | 40,005,747 | 152 | 1.90 | 6.6 万行 |
| `ls -laR --color=always /usr/share`（中文 locale，每行带宽字符和颜色） | 27,942 | 11,527,446 | 413 | 5.2 | 2.4 万行 |

所以 10 MB 对普通输出是十万行量级；最重的那种每行都带颜色和宽字符的输出也有两万多行。编码速度：`git log --stat` 那份（17 MB）编一次约 5 ms（`--mode=encode --loops=10` 对比 `--mode=noop` 的墙钟差，粗测）。

按 pane 而不是按项目总量，理由是：按项目总量要在 pane 之间仲裁「谁被砍」，而没有一个非任意的答案。这一条是全文里最值得回头确认的决定。

### 4.4 上限怎么落到实现里

不能靠截断文件。记录是 CRC 分帧的，而且 HISTORY 清单在**页之前**声明 `page_count`（`history.zig:5-7`，字段 `:86`，解码端靠它找序列末尾 `:56`），所以写之前就得知道要写几页。

同时**不要用上界估算**：上界是 8 字节/cell，而真实内容常常接近 1 字节/cell，按上界卡 10 MB 可能只装进 1.2 MB。

**已实现：给 `EncodeOptions` 加了 `max_history_bytes: ?u64`（`history.zig` 的 `encodeLimited`），实现成两趟：把历史页由新到旧逐页编到一块暂存缓冲里，边编边累加**真实**字节数，到预算就停，然后写 page_count = 已编页数 + 那批缓冲。** 峰值内存就是上限本身（10 MB），有界。

由新到旧这个顺序是现成的：`history.zig:6-7`（图见 `:28-38`）说明历史页就是按新→旧排的，`:177` 的注释写明这么排就是为了让解码端能边收边 prepend。所以「停在预算处」天然保留的是**最近的**内容 —— 正是要的语义。

⚠️ 这是要动 `src/terminal/snapshot/` 的，那个子树有自己的 `AGENTS.md`（原则是「encode 严格校验，decode 优雅降级」），改之前先读。如果两趟方案在实现中发现代价不可接受，退路是全有或全无（超预算就不存这个 pane），但那对一个忙碌的 pane 意味着什么都留不下，是明显更差的选择。

### 4.5 快照文件放哪、什么时候删

`Leaf.history` 的文件放在 `CommandHistory.defaultDir`，是项目目录的**兄弟**，理由写在 `src/Project.zig:61-65`：一个 pane 的命令历史比任何一个把它存进去的项目活得长。

scrollback **相反** —— 它是为这一次项目存盘抓的，脱离那个项目没有意义。所以放在项目自己旁边：`<项目文件去掉扩展名>.scrollback/<n>.snap`。

⚠️ **目录名从项目文件自己的路径推出，不要拿项目名再消毒一次。** 本文第一版写的是「用 `Project.pathFor`（`src/Project.zig:166`）同一套名字消毒」，那是错的，因为它默认三份实现的消毒器一致 —— 而它们不一致，见 issue #23：Zig 按**字节**截到 200（`src/Project.zig:179`），Swift 按 **Character** 截到 200（`macos/Sources/Features/Projects/ProjectStore.swift:169`），一个 67 个汉字的名字是 201 字节，两边算出**不同的文件名**。照第一版写法，快照会存进一个目录、恢复时去另一个目录找，而表现是「恢复不出来且不报错」。

正确的形状是让每一份实现只用**自己手里已经打开的那个项目文件的路径**去推目录名，于是平台内部只经过一个消毒器，跨平台的消毒分歧到不了这条路上。JSON 里只存 `"N.snap"` 这样的相对名，目录由读它的那一方推出。

用子目录而不是平铺的兄弟文件，是为了让删除是一次递归删、以及让孤儿可见。`Project.delete`（`src/Project.zig:398`）要同步删这个目录 —— **三份实现都要**（见 3.1）。孤儿快照（项目还在但 pane 没了）要在存盘时按「这次写了哪些编号」清理，判据参照 `cleanup-filter-vs-what-you-made` 那类错误：**清场的过滤条件必须和这次实际产生的东西对齐，不能只认一个名字模式。**

## 五、恢复不了的东西

以下几项是格式当前不支持的，接受，不要在本任务里试图补：

- **Kitty 图片**。`terminal.zig:238-242` 明确列为本版本不支持、抓取时忽略。虚拟占位符 cell（U+10EEEE，`grid.zig:242`）作为文本保留、解码时重建 row 提示位（`:1238-1239`），但 image 和 placement 全丢。**用户可见的表现是：图片位置留下一块占位而不是图。** 这一条要在文档里对用户说明。
- **选区、滚动视口位置、dirty/search 标志、hyperlink hover、压缩状态**。被归为 presentation/cache，恢复时重置（`terminal.zig:232-236`）。
- **线格式不压缩**。`src/terminal/compress/` 是**运行时内存压缩**（压变冷的 `Page` 的 backing memory，`compress/AGENTS.md:1-20`），不是快照压缩；encode 时反而会把压缩页解压成普通页再编（`history.zig:406-420`）。想压得在外面套一层。第 4 节的上限就是不压缩的前提下定的。

## 六、三个平台各要做什么

工作量**极不对称**，这一点决定了怎么分任务：

**平台无关的核心（一遍）** —— 第 3.2、3.3、3.4 节和第 4 节的全部：mailbox 消息、`Termio.zig:306` 的分支、`EncodeOptions.max_history_bytes`、配置项、C API 与 C 头、以及退化路径的测试。这是本任务的主体，**必须只有一份**，三个平台共用。

**每个宿主各自的一小块** —— 只有两件事：存盘时调那个新 C API；把快照文件名读写进项目文件（即 3.1 那张表里对应的那一份实现）。

- **Windows**：`windows/host/src/project.rs`（701 行，`serde_json`）+ `windows/host/src/ffi.rs` 里手写的 extern 结构体。⚠️ 布局改了不会编译失败，见 3.3。
- **mac**：`macos/Sources/Features/Projects/` 下的存取。
- **Linux（GTK）**：`src/apprt/gtk`。**没有测试机，所以这一份是「写了但没跑过」**，交付时必须这么标，不能因为它编过就算验过。

所以分任务的形状不是「三个平台三个人并行」—— 那三个人会在同一批核心文件上打架。是**一个核心任务，三个宿主任务接在它后面**，而真机验证按新策略走两个专职 worker（mac 一个、Windows 一个），Linux 留欠账。

## 七、判据要注意的地方

- **「三份实现」的判据**：改完之后，三份里任意一份**漏加字段都不会有闸变红**。判据必须直接数三处（例如三份各自都能读到一个含新字段的样例文件，且都能写出含新字段的文件），不能只跑测试。
- **地板**：每一条判据都要先**故意打坏被测对象、看它红在哪一行**。特别是第 3.3 节那三条顺序约束 —— 它们失败的形式是「静默地少恢复」，所以地板必须是「把顺序故意写反 → 判据红」，而不是「顺序对 → 判据绿」。
- **resize 那条的地板**：存盘时用一个宽度，恢复时用另一个宽度，断言历史行数没少。顺序写反的时候这一条会红在行数上，而一个只在同宽度下测的判据永远绿。
- 第 4.3 节的默认值 10 MB 已经实测过，见那一节的表。
- **关窗那条的地板**：「存成项目 + 立刻关窗 → 快照文件存在且能解码」。测试 `a capture queued as the surface closes is still written`（`termio/Thread.zig`）入队 capture 后**不发 wakeup**，直接 stop 再跑循环，这是竞态最坏的情况。拆掉 `finishCaptures` 后红在读文件那一行。
