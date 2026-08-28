# 感知层：屏幕静止检测

> 最后更新对应的 git commit：`f81dcadc8`（`f81dcadc82ea2afdcf2dc92929037701122f05b5`，2026-08-14）
> 校验方式：`git log -1 --format='%H %h %ad %s'`
> 状态：**S0 已实现**（`src/poltergeist/`，接线在 `src/termio/Thread.zig`）。本章其余部分是设计推导，实现与设计的出入记在「实现与本章的出入」一节。

## 本章覆盖什么

- 为什么感知层只测「屏幕多久没变」，不解析屏幕内容。
- 六条候选取法的逐条成本核实，以及推荐组合。
- 为什么第三方代码不能读写 Ghostty 的 dirty 标志。
- 光标闪烁、spinner 这两个干扰项在现状代码里到底存不存在。
- 静止事件的定义、字段、去抖、上报路径，以及三个配置项。
- 本层明确不做的判断。

## 本章不覆盖什么

- 总管收到静止事件之后怎么办、按住、确认策略、通知时间段、停掉监控 —— 见 [supervisor.md](supervisor.md)。
- 总管怎么把屏幕内容拉过去看（取屏工具）、身份识别、Skill 体系 —— 见 [mcp.md](mcp.md)。
- 群聊与私信界面 —— 见 [chatui.md](chatui.md)。
- tab 合并与 tab 状态标记 —— 见 [tabs.md](tabs.md)。
- Ghostty 的页 / 页链表 / 屏幕数据结构本身 —— 见 [terminal-core.md](../terminal-core.md)。

## 一句话概括

感知层是**传感器**：每个被监督终端（核心侧就是一个 `Surface`，其 `id` 见 `src/Surface.zig:57-62`）配一个采样器，只产出「距离上一次可见网格内容变化过了多久」这一个标量，达到静止阈值就发一次事件。屏幕上写的是什么、对方是在思考还是在等输入，一概不判断 —— 那是总管的活（见 [supervisor.md](supervisor.md)）。

## 设计目标与约束

对应 R1。以下五条是硬约束，本章所有取舍都回溯到这里。

1. **不可见 surface 必须照样工作。** R5 的主场景是挂机过夜，而 `renderCallback` 在不可见时直接 `return .disarm`（`src/renderer/Thread.zig:646-648`），`drawFrame` 同样直接返回（`src/renderer/Thread.zig:528-529`）。可见性由 `Surface.occlusionCallback`（`src/Surface.zig:3319`）翻转：macOS 来自 `windowDidChangeOcclusionState` → `syncSurfaceTreeOcclusionState`（`macos/Sources/Features/Terminal/BaseTerminalController.swift:1281-1293`）经 `ghostty_surface_set_occlusion`（`src/apprt/embedded.zig:1759-1761`）；GTK 来自 `glareaUnmap` → `updateOcclusion`（`src/apprt/gtk/class/surface.zig:3385-3391`、`3402-3408`）。
2. **不能干扰渲染正确性。** 见「为什么不能自己读写 dirty 标志」。
3. **不能新起线程。** 每个 surface 已有两条 libxev 循环：termio 线程（`src/termio/Thread.zig:279`）与渲染线程（`src/renderer/Thread.zig:279`）。再加一条等于每个终端多一份栈与调度成本。
4. **跨平台一份实现。** 感知层落在核心 Zig 侧，不进 apprt；apprt 差异只出现在事件送到界面之后（见 [tabs.md](tabs.md)）。
5. **与上游分叉面尽量小。** 优先「新增文件 + 少量既有文件插桩」，不改渲染热路径的语义。

## 为什么不做语义判断

### 成本差只是第二理由

- 「变没变」：一次 Wyhash。`Cell` 是 `packed struct(u64)`（`src/terminal/page.zig:2049`），即 8 字节/格；80×25 视口约 16 KB，200×60 约 96 KB。（未核实：Wyhash 处理 96 KB 的实际耗时未测，核实方式是按 `src/benchmark/TerminalSnapshot.zig` 的样式加一个视口哈希基准并用 `ghostty-bench` 跑，工作流见 `src/benchmark/AGENTS.md`；本次任务禁止改源码，故只标注。）
- 「变成了什么」：要先把网格转成文本。现成接口 `Screen.dumpString()`（`src/terminal/Screen.zig:3574`）的文档注释自陈「generally writes one byte at a time」（`src/terminal/Screen.zig:3571-3573`），不是为高频调用设计的。

**第一理由是可维护性**：模式匹配的判据要跟着被监督程序的 UI 版本走，屏幕指纹不依赖任何 UI 约定。第三理由是分工：语义判断是 AI 擅长的，程序不该抢。

### 不做 spinner 剔除

spinner 在转，恰恰说明对方在动。把它剔掉，等于把「在动」和「等输入」压成同一态 —— 而这正是总管唯一需要区分的东西。本设计假定 AI CLI 在等待输入时屏幕基本静止；这是用户的经验判断，也是 README 里 S0 阶段要验证的第一件事，本章不把它当已证事实。

### 不做旧稿的 working / thinking / idle / stalled 推断

这套推断需要对 UI 文案做模式匹配，等于给自己埋一个随对方版本更新而失效的雷。README 已把这条记为被推翻项，本章只补技术理由。（与它同名不同物的是 [supervisor.md](supervisor.md) 的上班 / 静止待判 / 等确认 / 下班状态机 —— 那是总管侧的簿记，不含对屏幕内容的判断。）

### 结构化信号只当可选增强，且默认关

Ghostty 已解析了几路语义零歧义的信号：OSC 9 / 777 桌面通知 `show_desktop_notification`（`src/terminal/osc.zig:95`）、OSC 9;4 进度 `conemu_progress_report`（`src/terminal/osc.zig:124`）→ apprt action `progress_report`（`src/apprt/action.zig:327`）、OSC 133 语义提示符（`src/terminal/osc/parsers/semantic_prompt.zig:23-32`）。三条都不够用：

- **覆盖不全。** 最贴题的一路 —— OSC 9;5「等待输入」`conemu_wait_input`（`src/terminal/osc.zig:127`）—— 解析出来后落到 `log.debug("unimplemented OSC callback")`（`src/terminal/stream.zig:2551-2566`），没有任何消费者。
- **语义对不上。** OSC 133 只对 `end_input_start_output` 与 `end_command` 两个动作发 surface 消息（`src/termio/stream_handler.zig:995-1010`），`Surface` 再计时后发 `command_finished`（`src/Surface.zig:1141-1170`，载荷 `src/apprt/action.zig:993-1009`）。它标的是「一条 shell 命令结束」，而 AI CLI 是长驻进程，一轮对话结束不会触发它。
- **多一路信号就多一路口径要维护。** S0 的目标是先验证单一静止量够不够用，故默认关。开关是 `polter-structured-signals`（见配置一节）。

## 六条候选取法

### 候选 A：复用 `Row.dirty` / `Page.dirty`

周期性调 `Page.isDirty()`（`src/terminal/page.zig:1700-1707`）或直接扫 `Row.dirty`（`src/terminal/page.zig:2004`）。需持有 `renderer_state.mutex`，`isDirty` 是 O(rows) 短路扫描。致命缺陷见下一节。**淘汰。**

### 候选 B：搭渲染器便车读 `RenderState.dirty`

读三态枚举 `terminal_state.dirty`（`src/terminal/render.zig:266-278`），`updateFrame` 已经在 `src/renderer/generic.zig:1234` 读它、帧末 `src/renderer/generic.zig:1377` 清零。成本近乎为零。两条致命缺陷：

- 不可见就不更新（`src/renderer/Thread.zig:646-648`），而挂机过夜正是主场景。
- `terminal_state` 是渲染器实例的私有字段（`src/renderer/generic.zig:228`），不受 `renderer_state.mutex`（`src/renderer/State.zig:17`）保护，跨线程读要新造一套同步 —— 连「免费」都不完全成立。

**只保留为「可见时的提前唤醒」，不能单独成立。**

### 候选 C：在渲染线程的绘制节流点观察

节流常量是 `DRAW_INTERVAL = 8`（注释标 120 FPS）与 `CURSOR_BLINK_INTERVAL = 600`（`src/renderer/Thread.zig:21-22`）。三条缺陷：

- 8 ms 的绘制定时器**不是常开的**：`syncDrawTimer`（`src/renderer/Thread.zig:312-337`）只在 `hasAnimations()` 为真且 `custom_shader_animation` 允许时才启动，而 `hasAnimations()` 的实现就是 `return self.has_custom_shaders;`（`src/renderer/generic.zig:1002-1004`）。没开自定义 shader 就没有这个节拍。
- 600 ms 的光标定时器在**失焦时被取消**（`src/renderer/Thread.zig:418-431`）。挂机过夜时窗口通常不是 key window，这个心跳也停了。
- 即便节拍还在，它反映的是「画了几帧」，不是「内容变了没」。

顺带说明：渲染 wakeup 本身不做合并延迟，合并代码整段被注释在 `src/renderer/Thread.zig:571-586`，所以也没有现成的合并窗口可蹭。**淘汰。**

### 候选 D：复用 `Terminal.compressionActivity()` 活动序号

`compressionActivity()`（`src/terminal/Terminal.zig:2564-2568`）包装 `PageList` 的 `activity_serial`（`src/terminal/PageList.zig:4563`），自增点是 `markActivity()`（`src/terminal/PageList.zig:4575`）。它极具迷惑性 —— 这是一个**不被消费者清零的单调令牌**，恰好绕开候选 A 的全部问题。

致命缺陷：`markActivity()` 的全部非测试调用点都是 `PageList` 的结构性操作 —— `src/terminal/PageList.zig` 的 `:1243`、`:3209`、`:3611`、`:3687`、`:3908`、`:4215`、`:4333`、`:4997`、`:5115`、`:5342`、`:6845`（其余命中在 `:8241` / `:8669`，位于测试内）。**原地改写某一行的单元格不会让它变。** spinner 在固定行上转、状态栏原地刷新，序号纹丝不动 —— 这是假阴性（把「在动」判成「静止」），是感知层最不能犯的错。**淘汰作判据**，但它的调度形态值得抄（见「定时器挂哪」）。

### 候选 E：字节静默计时

在 `Termio.processOutputLocked`（`src/termio/Termio.zig:656`）开头打一个时间戳。该函数第一行就是 `queueRender()`（`src/termio/Termio.zig:658` → `src/termio/stream_handler.zig:99-101`），紧接着 `src/termio/Termio.zig:664-676` 就有现成的「时间戳 + 500 ms 节流」写法可照抄（字段 `last_cursor_reset: ?std.Io.Timestamp` 在 `src/termio/Termio.zig:70`）。成本是一次 store，锁已由调用方持有（`src/termio/Termio.zig:650-652`）。

**在无人交互的前提下，pty 字节是可见网格内容变化的唯一来源，所以「一段时间没有字节」是「屏幕静止」的充分条件。** 已核实的例外全部由用户或配置驱动、挂机过夜时不发生：视口滚动（`PageList.scroll`，`src/terminal/PageList.zig:3195`）、选区（`Screen.Dirty.selection`，`src/terminal/Screen.zig:93`）、输入法预编辑与调色板（`Terminal.Dirty.preedit` / `palette`，`src/terminal/Terminal.zig:224`、`:214`）。闪烁文本不构成例外：`style.flags.blink`（`src/terminal/style.zig:34`）在 `src/renderer/` 下 grep 不到任何消费者，Ghostty 不动画闪烁文本。

代价是比真实静止保守 —— spinner 在转就一直算「不静止」。这正好符合我们不剔 spinner 的立场。**选作粗筛。**

### 候选 F：自采样 + 屏幕指纹

自带定时器，`tryLock` 拿 `renderer_state.mutex`，按 `src/terminal/render.zig:518-531` 的 `viewport_pin.pageIterator(.right_down, null)` chunk 迭代方式只读遍历视口，逐行算 Wyhash。成本 O(rows×cols)，每格 8 字节（`src/terminal/page.zig:2049`），1 Hz 采样下可忽略。不受可见性影响，不与渲染器争 dirty，顺便得到「变化行数」。**选作确认。**

### 成本对比

| 取法                    | 是否要加锁      | 单次成本     | 不可见 surface 下是否有效 |
| ----------------------- | --------------- | ------------ | ------------------------- |
| A `Row/Page.dirty`      | 要              | O(rows)      | 否（恒为脏）              |
| B `RenderState.dirty`   | 要新加同步      | O(1)         | 否                        |
| C 绘制节流点            | 不适用          | 不适用       | 否（定时器本身会停）      |
| D `compressionActivity` | 要              | O(1)         | 是，但有假阴性            |
| E 字节静默              | 已在锁内        | 一次 store   | 是                        |
| F 屏幕指纹              | 要（`tryLock`） | O(rows×cols) | 是                        |

## 为什么不能自己读写 dirty 标志

1. **代码自称唯一消费者。** `RenderState.beginUpdate()`（`src/terminal/render.zig:356`）在 `src/terminal/render.zig:554-558` 清 `page.dirty`，注释原文是「we're the only consumer of dirty state」；随后在组扫描分支（`src/terminal/render.zig:606-619`）与全页重建分支（`src/terminal/render.zig:620-627`）清每行的 `row.dirty`，最后在 `src/terminal/render.zig:708-722` 汇总成 `self.dirty` 并清掉 `t.flags.dirty` 与 `s.dirty`。
2. **第三方若也清，渲染器会漏画。** `Row.dirty` 的文档注释（`src/terminal/page.zig:1993-2003`）写明「Dirty tracking may have false positives but should never have false negatives. A false negative would result in a visual artifact on the screen」。多一个清零者就是在制造假阴性。
3. **只读不清同样不成立。** 不可见 surface 上没人跑 `beginUpdate`，dirty 会一直积着，`Page.isDirty()`（`src/terminal/page.zig:1700-1707`）恒为 true —— 作为「没变」的探测器完全失效。
4. **`Page.dirty` 另有语义陷阱。** 它为 false **不代表**页内没有脏行（`src/terminal/page.zig:182-186` 的 NOTE 明写），所以也不能单独当门。

## 推荐方案：字节静默粗筛 + 屏幕指纹确认

**E 做粗筛（廉价、总是有效）+ F 做确认（精确、跨可见性一致）；B 只在可见时作为提前唤醒。** 分工的理由：E 是充分条件的廉价近似（没字节 → 一定没内容变化），F 负责排掉「有字节但可见网格没变」的情况（例如写的是不改变网格的转义序列）。

> **实现没有采用这条分工**，只做了 F，E 降级为随事件一起上报的元数据。原因见下面「实现与本章的出入」第 1 条。

### 定时器挂哪

挂 termio 线程既有的 libxev 循环（`src/termio/Thread.zig:279`），新增第四个 `xev.Timer`，照既有三个 timer 的写法（声明 `src/termio/Thread.zig:60`、`:65`、`:72`；init 在 `:104`、`:108`、`:112`；deinit 在 `:128-130`）。理由：

- Termio 同时持有终端本体（`src/termio/Termio.zig:43`）、渲染状态指针（`src/termio/Termio.zig:46`）与上报用的 `surface_mailbox`（`src/termio/Termio.zig:56`），采样所需对象全在同一结构内。
- 候选 E 的时间戳插桩点本来就在同一线程的 `processOutputLocked` 里，粗筛与确认同线程，`last_output` 不需要跨线程同步。
- 该线程的存活与可见性无关；只有 `updateFrame` 受可见性影响。

**要抄的是 `Compression` 的姿势而不是位置。** 渲染线程里已有几乎同构的先例（`src/renderer/Thread.zig:764-808`）：`idle_interval = 250`（`src/renderer/Thread.zig:765`）的空闲定时器 + 活动令牌 + `tryLock` 绝不阻塞终端锁，拿不到锁时保留既有 deadline（`src/renderer/Thread.zig:791-802`）。感知层照抄这套姿势，只把令牌换成指纹。理由：感知层绝不能拖慢 pty 解析 —— 一个后台监控功能把前台终端拖卡，是最不可接受的失败模式。

### 为什么不挂 app 线程

没有周期性 app tick 可用：GTK 是每次主循环迭代调一次 `core_app.tick`（`src/apprt/gtk/class/application.zig:562-566`），频率由事件决定；macOS 只在 wakeup 时经 `DispatchQueue.main.async` 调 `appTick`（`macos/Sources/Ghostty/Ghostty.App.swift:401-409`、`:107-110`，C 入口 `src/apprt/embedded.zig:1444-1448`）。想要固定节拍必须自带定时器，那就不如挂在离数据最近的 per-surface 循环上。

### 采样回调的算法

以下为当初的设计示意。实际实现见 `src/poltergeist/Sampler.zig` 的 `observe` 与 `noteActivity`；与本图的出入记在下一节。

```text
1. now - last_output < threshold  ->  重排定时器，返回（零锁的粗筛路径）
2. mutex.tryLock() 失败           ->  说明正在解析输出，按「有活动」处理并重排
3. 只读遍历视口，逐行 Wyhash      ->  得到每行指纹与全屏指纹
4. 指纹变了                       ->  last_change = now；清「已上报」标志；重排
5. 指纹未变 且 now - last_change >= threshold 且 未上报
                                  ->  发一次静止事件，置「已上报」
```

实现落在 `src/poltergeist/Sampler.zig` 的 `observe` 与 `noteActivity`，第 1 步未实现（理由见下节），第 2 步对应 `noteActivity`，第 3 步对应 `src/poltergeist/screen.zig` 的 `sample`，第 4、5 步对应 `observe`。

**去抖是边沿触发**：一次静止只报一次，直到指纹再变才复位。这样总管不会被同一段静止反复叫醒。

### 屏幕指纹为什么用 Wyhash

仓库里已经在用：`Surface.showDesktopNotification`（`src/Surface.zig:6038`）用 `std.hash.Wyhash`（`src/Surface.zig:6041`）对 title+body 做摘要，配合时间戳实现「每秒最多一条」「相同内容 5 秒内抑制」（`src/Surface.zig:6045-6070`）。零新依赖，且那段限流结构正好是静止事件上报限流要的形状，可以一并照搬。

## 干扰项与廉价对策

### 光标闪烁：核实结论是不构成干扰

Ghostty **不把光标闪烁计入 dirty**。闪烁只翻转渲染线程的私有标志 `cursor_blink_visible` 并 wakeup（`src/renderer/Thread.zig:685-686`），该值作为参数传进 `updateFrame`（`src/renderer/Thread.zig:651-653`）再传给 `rebuildCells` 的 `cursorStyle(.blink_visible = ...)`（`src/renderer/generic.zig:1396-1402`），全程不碰 `Row.dirty` / `Terminal.Dirty` / `Screen.Dirty`；失焦时定时器直接被取消（`src/renderer/Thread.zig:418-431`）。推荐方案（E 与 F 都只看网格内容）天然免疫，不需要任何特殊处理。这条写出来是为了让后来者不必重复担心。

### spinner 与进度条

会让某几行持续变化，因此推荐方案会判为「不静止」—— 这是想要的行为，不是缺陷（理由见「不做 spinner 剔除」）。

### 变化行数比例：可选的廉价增强，仍属传感器

按行存上一轮指纹（rows × u64，60 行不到 500 字节），得出 `changed_rows / rows`。**这只是随事件一起上报的一个数字，程序不据此做任何判断。** 这条边界必须写死，否则它会滑向语义分析（例如「变化行数 < 2 就当静止」—— 那就是变相的 spinner 剔除，违反 R1）。逐行扫描本身很便宜：渲染器就是这么做的（`RowDirtyMask` 组扫描，`src/terminal/render.zig:998-1002`）。

### 用户交互引起的变化

滚动、选区、IME 会让屏幕变而 pty 无字节（出处见候选 E）。挂机过夜时不发生；有人在场时误判成「不静止」是安全方向的错误（少催一次），不需要额外处理。

## 实现与本章的出入

S0 落地时有三处与上面的推导不一致，记在这里而不是偷偷改掉，因为每一处都是有理由的判断。

**1. 没有做「字节静默粗筛」，每一拍都算指纹。**

本章推荐 E+F 分工，实现只做了 F。粗筛那条门是「最近有输出 → 跳过采样」，它成立，但把它装上之后，一个正在干活的终端几乎每一拍都会走粗筛路径，于是整套机制退化成「pty 静默多久」——而滚动、选区、IME 预编辑都会改变屏幕却不产生任何 pty 字节，这些恰恰是有人在场的信号，退化后全看不见了。

代价是每秒一次全屏哈希。200×60 的屏幕是 96 KB，Wyhash 一次约几十微秒，1 Hz 下可以忽略，不值得为它牺牲正确性。字节数仍然每拍上报（`silent_ms`），总管照样能自己分辨「一直在刷但没变化」和「彻底没动静」。

**2. `tryLock` 失败按「有活动」处理，这条实现了，而且是必须的。**

第一版实现写成了拿不到锁就直接返回，采样器完全不知道有一拍被跳过。这是错的：持续输出时解析线程几乎焊住这把锁，一段被跳过的窗口里屏幕完全可能变了又变回来，之后就会被算成「一直静止」。现在走 `Sampler.noteActivity`，把未知窗口当作活动，并把上一次指纹标记为失效，使下一次成功采样无条件算作一次变化。

**3. `changed_rows` 报的是「上一次真变化时变了几行」，不是本次采样的变化行数。**

静止事件里本次采样的变化行数按定义恒为 0，说不了任何事情。有用的是「最后发生的那件事，是整屏重绘还是某一行在跳」。

## 静止事件的定义与配置

### 事件字段只有四个

- **terminal id** — 直接用 `Surface.id`（`src/Surface.zig:57-62`），它已以 `GHOSTTY_SURFACE_ID` 注入子进程环境（`src/Surface.zig:651-655`），两侧对得上号。
- **quiescence duration** — 静止时长。
- **changed rows ratio** — 上一次变化时的变化行数比例。
- **screen fingerprint** — 供总管侧判重。

**不带屏幕内容。** 三条理由：其一，时效性 —— 总管拉取时拿到的是当下的屏幕，而事件里的快照是阈值触发那一刻的旧影；其二，事件要过 mailbox、可能落日志、可能进群聊，塞进几 KB 屏幕文本会同时放大体积与隐私面；其三，感知层带内容就等于替总管决定了「该看多少」。取屏接口本章只提一句存在（`Screen.dumpString()` 在 `src/terminal/Screen.zig:3574`，渲染态版 `RenderState.string()` 在 `src/terminal/render.zig:855`），怎么暴露给总管归 [mcp.md](mcp.md)。

「终端名字」也不进事件：embedded apprt 把标题存在 `rt_surface.title`（`src/apprt/embedded.zig:315-323`），是 apprt 侧状态，跨 apprt 口径不统一，交给界面层解决（见 [tabs.md](tabs.md)）。

### 上报路径

1. 采样定时器回调（termio 线程）→ `surface_mailbox`（`src/termio/Termio.zig:56`），推送写法照 `surfaceMessageWriter`（`src/termio/stream_handler.zig:115-126`），它先试 `.instant` 再退回 `.forever`。
2. `Surface` 侧处理该消息 —— 现有的 `.start_command` / `.stop_command` 就是在 `src/Surface.zig:1141-1170` 这样处理的。
3. 需要跨到 app 线程时走 `App.Mailbox.push`，它在推入后会顺带 `rt_app.wakeup()`（`src/App.zig:617-621`）—— 这正是没有周期 tick 时把事件送上去的办法。

### 配置项

实际实现了三个，定义在 `src/config/Config.zig`：

```ini
poltergeist-watch = true             # 默认 false，不开就什么都不做
poltergeist-quiescence-after = 3m    # 屏幕静止多久算静止
poltergeist-quiescence-repeat = 15m  # 仍在静止时隔多久再报一次
```

与本章原先设想的三个名字对不上，逐条说明：

| 本章原名                      | 实际                                                                                               |
| ----------------------------- | -------------------------------------------------------------------------------------------------- |
| `polter-quiescence-threshold` | 改名 `poltergeist-quiescence-after`，与 `notify-on-command-finish-after` 同构                      |
| `polter-sample-interval`      | **没做成配置**，硬编码 `quiescence_sample_ms = 1000`（`src/termio/Thread.zig`）                    |
| `polter-structured-signals`   | **没做**，S0 不消费 OSC，等 S1 再说                                                                |
| —                             | 新增 `poltergeist-watch` 总开关，与 R4「没有一键开关」不冲突：它是「要不要观察」，不是「启停总管」 |
| —                             | 新增 `poltergeist-quiescence-repeat`，本章原先漏了这一项                                           |

两个 `Duration` 换算成毫秒时取 `@max(采样间隔, ...)` 下限。整除会把亚毫秒值变成 0，而阈值为 0 会让每个终端在第二次采样就「静止」，重复间隔为 0 会让日志每秒刷一行。

字段风格照仓库里语义最接近的一条 —— `notify-on-command-finish-after`（`src/config/Config.zig:1261`，类型 `Duration` 定义在 `src/config/Config.zig:10047`，消费点 `src/apprt/gtk/class/surface.zig:1176`），那也是一条「超过某时长就通知」的配置。默认值 `2m` / `1s` 是**设计建议**，不是实测结论，待 README 未决问题 1 在 S0 阶段定夺。

**每终端可配怎么落地**：R6 要求每个被监督终端各自设定，但 Ghostty 的 per-surface 配置全部由全局 Config 派生（`Surface.DerivedConfig` 的赋值块，含三个 notify-on-command-finish 系列字段，见 `src/Surface.zig:420-422`），没有「某个 surface 单独写配置文件」的机制。所以 per-terminal 的阈值覆盖必须是**运行时状态**，参照 `Surface.readonly`（`src/Surface.zig:164-168`）那种 per-surface 布尔的做法，由总管在运行时设定；工具面归 [mcp.md](mcp.md)。这一层区分不写清，实现者会去 `Config.zig` 里造一堆 per-surface 字段，走上死路。

### 尺度参照

静止阈值是分钟量级，与渲染节流（`DRAW_INTERVAL = 8`、`CURSOR_BLINK_INTERVAL = 600`，`src/renderer/Thread.zig:21-22`）差两到四个数量级。所以采样周期取秒级即可，既不需要跟任何渲染节拍对齐，也不可能影响渲染。

## 本层明确不做的事

- 不判断 AI 在思考还是卡死。
- 不判断任务是否完成 —— 任务本身不归 Poltergeist 管（R8，见 [mcp.md](mcp.md)）。
- 不识别 spinner、进度条、权限询问框。
- 不产生任何催促动作，只发事件（见 [supervisor.md](supervisor.md)）。
- 不代替用户或总管做决定；不做自动点 yes（R2）。

这几条不是能力不足的借口，而是可靠性边界：连最贴题的协议级信号 OSC 9;5「等待输入」在 Ghostty 里都还没有消费者（`src/terminal/stream.zig:2551-2566`），靠文本模式匹配去猜只会更不可靠。

## 取舍记录

| 方案                       | 成本                                          | 为什么没选 / 为什么选                                                                                                                                                                                  |
| -------------------------- | --------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 语义解析屏幕文字           | 全屏文本化 + 模式匹配，判据随对方 UI 版本失效 | 没选。`dumpString` 自陈逐字节写（`src/terminal/Screen.zig:3571-3573`）；且语义判断该由总管做。推翻条件：静止信号假阳性高到总管每次白跑，届时也应加结构化信号而非文本匹配                               |
| A `Row/Page.dirty`         | O(rows) + 加锁                                | 没选。渲染路径消费即清零（`src/terminal/render.zig:554-558`），第三方参与会造假阴性；不可见时又恒为脏                                                                                                  |
| B `RenderState.dirty`      | O(1)                                          | 只作可见时的提前唤醒。不可见即停（`src/renderer/Thread.zig:646-648`）；字段私有且无锁保护（`src/renderer/generic.zig:228`）。推翻条件：上游把它改成受 `renderer_state.mutex` 保护且不可见时也推进      |
| C 绘制节流点               | 零                                            | 没选。8 ms 定时器需自定义 shader 才启动（`src/renderer/generic.zig:1002-1004`），600 ms 光标定时器失焦即取消（`src/renderer/Thread.zig:418-431`）                                                      |
| D `compressionActivity`    | O(1)，单调不清零                              | 没选。只在 PageList 结构性操作里自增（`src/terminal/PageList.zig:4575`），原地改写单元格不变 → 假阴性                                                                                                  |
| E 字节静默（选）           | 一次 store，锁已持有                          | 选作粗筛。总是有效、与可见性无关；例外全是用户交互驱动，挂机场景不发生                                                                                                                                 |
| F 屏幕指纹（选）           | O(rows×cols)，1 Hz                            | 选作确认。不受可见性影响、不与渲染器争 dirty，顺带得到变化行数                                                                                                                                         |
| 定时器挂 termio 线程（选） | 复用既有 libxev 循环                          | 选。数据全在 `Termio` 内（`src/termio/Termio.zig:43`、`:46`、`:56`），且与 E 的插桩点同线程                                                                                                            |
| 定时器挂渲染线程           | 有 `Compression` 同构先例                     | 没选。数据不在手边，且该线程的节拍受可见性与焦点影响                                                                                                                                                   |
| 定时器挂 app 线程          | 零新定时器                                    | 没选。GTK 与 macOS 都没有周期 tick（`src/apprt/gtk/class/application.zig:562-566`、`macos/Sources/Ghostty/Ghostty.App.swift:401-409`）                                                                 |
| 新起采样线程               | 每 surface 一条线程                           | 没选。栈与调度成本换不来任何东西                                                                                                                                                                       |
| 事件带屏幕摘要             | 几 KB / 次                                    | 没选。快照会过期，且放大通道体积与隐私面。推翻条件：实测发现总管几乎每次都立刻拉取且拉取成为瓶颈，届时作为配置项而非默认                                                                               |
| 结构化信号默认开           | 多一路口径                                    | 没选。OSC 9;5 无消费者（`src/terminal/stream.zig:2551-2566`），OSC 133 标的是 shell 命令结束（`src/termio/stream_handler.zig:995-1010`）。推翻条件：某个被监督程序开始老实发 OSC 9;5，可对该终端默认开 |
| 变化行数比例只上报、不判断 | rows × u64                                    | 选。一旦据此判断就变成变相的 spinner 剔除，违反 R1                                                                                                                                                     |
| Wyhash 做屏幕指纹          | 零新依赖                                      | 选。仓库已在用（`src/Surface.zig:6040`），且其限流写法可整段照搬                                                                                                                                       |

## 未决问题

1. 静止阈值默认值 —— README 未决问题 1 已列。本章补一句采集方法：S0 阶段只采样、只写日志、不通知任何人，事后把日志与人工观察对齐。
2. 屏幕指纹的实际耗时未做基准（见上文标注）。若实测发现 1 Hz 指纹在超大视口（如 400×100）上有可测开销，把采样周期改为随静止时长指数退避。
3. 多个被监督终端时，采样定时器是各自一份还是共用一个节拍。各自一份写起来简单（每个 termio 线程一个），共用节拍省定时器但要跨线程协调。
4. 视口之外（scrollback 里有变化但视口没变）是否需要单独计量。本设计选择只看视口，因为总管看到的也只是视口。
5. macOS 背景 tab 的可见性取值。（未核实：macOS 原生 NSWindow tabbing 下非活动 tab 的 `occlusionState` 运行时报什么未实测，核实方式是开两个 tab 并在 `syncSurfaceTreeOcclusionState`（`macos/Sources/Features/Terminal/BaseTerminalController.swift:1285-1293`）处观察 `visible` 取值。）GTK 侧是确定的：非活动 tab 的 GLArea 被 unmap，`visible` 变 false（`src/apprt/gtk/class/surface.zig:3385-3391`）。这条不影响结论 —— 推荐方案不依赖可见性，只是「最坏情况有多坏」的描述会变。

## 延伸阅读

- [README.md](README.md) —— Poltergeist 总览、核心原则、分阶段计划。
- [supervisor.md](supervisor.md) —— 总管拿到静止事件之后做什么。
- [mcp.md](mcp.md) —— 取屏工具、运行时设定阈值的工具面。
- [terminal-core.md](../terminal-core.md) —— 页 / 页链表 / 屏幕数据结构。
- [_conventions.md](../_conventions.md) 与 [_spec.md](_spec.md) —— 写作规范与术语表。
