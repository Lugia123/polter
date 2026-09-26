# 项目重新加载时恢复 scrollback

> 最后更新对应的 git commit：`3714cf132`
> 校验方式：`git log -1 --format='%H %h %ad %s'`

## 本文覆盖什么

- 「重新加载项目后，每个 pane 里看不到以前跑过的东西」这件事要怎么做。
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

**建议：宿主不等它。** 宿主立刻写 JSON（里面写上它**预期**的快照文件名），快照文件异步落地。这样不阻塞 UI，而且失败模式正好退化成今天的行为（见 3.3）。

### 3.3 取：宿主 → 核心

这一半可以**照抄** `history_restore`：`src/apprt/embedded.zig:585` 那个 `history_restore: ?[*:0]const u8` 字段，注释写明它「不在这里解释」，由核心在知道自己要 spawn 哪个 shell 的地方展开。新增一个同形状的 `scrollback_restore: ?[*:0]const u8`，在 `src/termio/Termio.zig:306` —— 现在无条件 `Terminal.init` 的那一行 —— 消费它。

⚠️ 这个字段在 C 结构体里的**声明顺序就是内存布局**（`embedded.zig:571-574` 明写了这一点，而且 `history_restore` 自己就带着「Declared last to match `ghostty_surface_config_s`」的注释）。加字段必须同时改 `include/` 里的 C 头和 Rust 侧手写的 extern 结构体，而 **Rust 手写的 extern 结构体在布局变了的时候不会编译失败** —— 这正是本次上游合并里 `ghostty_clipboard_content_s` 加 `len` 字段踩过的坑（见 `a4e13545a` 的提交信息）。

三条**必须按顺序**的约束，顺序错了的表现都是「静默地少恢复」：

1. **先把 `Terminal` 放到最终地址，再建 `Stream`。** `snapshot.zig:113-128` 反复强调这一点，因为 `Decoded.toOwned()` 会**移动** `Terminal`。现有代码正好合适：`Termio.zig:306` 造终端，`:380` 才 `terminal_stream: .init(...)`，中间没有别的东西拿 `&self.terminal`。
2. **先把历史收完，再 resize。** `snapshot.zig:440-458` 明写：一旦 `t.cols != state.cols`，当前页被消费但丢弃，**并且该序列其余的页一并丢弃**（因为后面的页更老，跨空洞贴上去会把 scrollback 顺序弄坏）。快照解出来的终端是**存盘时**的尺寸，而窗口现在可能是别的尺寸。所以顺序是：decode → 把 `next` 抽干 → 然后才 `Terminal.resize`，让 `PageList` 自己做 reflow。反过来做的结果是：小窗口恢复出一屏内容，其余几千行无声消失。
3. **continuation 字节要丢掉，不要喂。** `src/terminal/snapshot/continuation.zig:1-24` 里的 continuation 是「把 VT 解析器从 ground 带到当前状态所需的最小 pty 字节」，它服务的是**热迁移**：快照切在一个转义序列中间，后续的 pty 字节接着来。项目恢复不是热迁移 —— 后续字节来自一个**全新的 shell**，和旧的半截转义序列毫无关系。把它喂进去，新 shell 的头几个字节会被当成旧转义序列的尾巴解析。⚠️ 这一条与格式设计的**意图相反**，是本场景特有的决定，实现时要把理由写在调用点上，否则下一个人会「修好」它。

### 3.4 读不动就当没有

格式版本号当前是 1，`envelope.zig:57` 要求**严格相等**，不匹配直接 `error.UnsupportedVersion`，没有迁移层；而 `main.zig:21-23` 自称版本 1 是 work-in-progress、**会继续破坏兼容**。

这对本功能不是问题，但必须是**设计出来的**行为而不是事后补的：**快照缺失、版本不符、CRC 坏、任何 decode 错误 → 起一个空终端，并把那个文件删掉。** 退化结果恰好等于今天的行为。这条要有测试。

## 四、上限：定量循环，不按时间

### 4.1 语义

上限是**容量**，不是**年龄**。比如设 10 MB，就永久保留最近的 10 MB；一个几个月没开过的项目，加载时照样把那 10 MB 显示出来。没有过期，没有「多久以前」这个维度。

### 4.2 「循环」这一层几乎是免费的

因为**终端自己就是一个环**。`src/config/Config.zig` 里 `@"scrollback-limit-bytes"` 默认 50 MB、`@"scrollback-limit-lines"` 默认无限，先到者生效；活着的 `PageList` 早就在淘汰最老的页了。所以「最近的 N MB」这个窗口不需要新造，它就是终端当前持有的那些页。

解码这一侧也已经按这个语义写好了：超出目标 screen 的 scrollback 上限的历史页是**丢弃而不是报错**（`snapshot.zig:589-593`）。所以一个偏大的快照读起来是安全的。

### 4.3 落盘的上限要单独一个旋钮

50 MB 是**一个**焦点终端的内存上限。落到盘上它是「每 pane × 每项目」，而且每次存盘都付一遍：一个 12 pane 的项目按 50 MB 算是 600 MB。所以持久化要有自己的上限。

**建议：`project-scrollback-limit-bytes`，按 pane 计，默认 10 MB，`0` 表示彻底关掉这个功能。**

为什么是 10 MB 而不是 50：这个数字的依据是内容量而不是感觉 —— 编码在 cell 层省空间的手段是「每行只编到最后一个非默认 cell，全默认行就是 3 字节的行头」加「每行按需选 1/2/4/8 字节的 cell 宽度，纯 ASCII 无样式行是 1 字节/cell」（`grid.zig:57-92`）。所以 10 MB 对典型输出是十万行以上的量级，远超任何人会往回翻的距离；而重样式行最坏能到 8 字节/cell，10 MB 在最坏情况下仍有约一万五千行。**这个量级是按上述编码规则推算的，没有实测**（未核实：`src/benchmark/TerminalSnapshot.zig:307-311` 会打印 `framing=` / `encoded=` 实测值，想要准数跑它；这是定默认值之前该做的第一件事）。

按 pane 而不是按项目总量，理由是：按项目总量要在 pane 之间仲裁「谁被砍」，而没有一个非任意的答案。这一条是全文里最值得回头确认的决定。

### 4.4 上限怎么落到实现里

不能靠截断文件。记录是 CRC 分帧的，而且 HISTORY 清单在**页之前**声明 `page_count`（`history.zig:5-7`，字段 `:86`，解码端靠它找序列末尾 `:56`），所以写之前就得知道要写几页。

同时**不要用上界估算**：上界是 8 字节/cell，而真实内容常常接近 1 字节/cell，按上界卡 10 MB 可能只装进 1.2 MB。

**建议：给 `EncodeOptions`（`snapshot.zig:34-36`，目前只有 `continuation` 一个字段）加一个 `max_history_bytes: ?u64`，实现成两趟：把历史页由新到旧逐页编到一块暂存缓冲里，边编边累加**真实**字节数，到预算就停，然后写 page_count = 已编页数 + 那批缓冲。** 峰值内存就是上限本身（10 MB），有界。

由新到旧这个顺序是现成的：`history.zig:6-7`（图见 `:28-38`）说明历史页就是按新→旧排的，`:177` 的注释写明这么排就是为了让解码端能边收边 prepend。所以「停在预算处」天然保留的是**最近的**内容 —— 正是要的语义。

⚠️ 这是要动 `src/terminal/snapshot/` 的，那个子树有自己的 `AGENTS.md`（原则是「encode 严格校验，decode 优雅降级」），改之前先读。如果两趟方案在实现中发现代价不可接受，退路是全有或全无（超预算就不存这个 pane），但那对一个忙碌的 pane 意味着什么都留不下，是明显更差的选择。

### 4.5 快照文件放哪、什么时候删

`Leaf.history` 的文件放在 `CommandHistory.defaultDir`，是项目目录的**兄弟**，理由写在 `src/Project.zig:61-65`：一个 pane 的命令历史比任何一个把它存进去的项目活得长。

scrollback **相反** —— 它是为这一次项目存盘抓的，脱离那个项目没有意义。所以放在项目自己旁边：`<projects>/<sanitized-name>.scrollback/<n>.snap`，用 `Project.pathFor`（`src/Project.zig:166`）同一套名字消毒。

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
- **`（未核实）`**：第 4.3 节的默认值 10 MB 是推算的，落地前先用 `src/benchmark/TerminalSnapshot.zig` 量一遍真实字节数再定。
