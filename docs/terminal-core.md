# 终端核心与 libghostty-vt

> 最后更新对应的 git commit：`f81dcadc8`（`f81dcadc82ea2afdcf2dc92929037701122f05b5`，2026-08-14）
> 校验方式：`git log -1 --format='%H %h %ad %s'`

## 本文覆盖什么

- `src/terminal/main.zig` 作为终端核心的公共 API 面，以及各主要类型的真实归属文件。
- VT 字节流解析链：`Parser.zig` 状态机 → `parse_table.zig` 转移表 → `stream.zig` 泛型 Stream → `stream_terminal.zig` Handler → `Terminal.zig`。
- 屏幕存储三层：`page.zig` 的 `Page`、`PageList.zig` 的页链表与 `Pin`、`Screen.zig` 与 `ScreenSet.zig`。
- 样式/SGR 的引用计数集合、scrollback 与页压缩（`src/terminal/compress/`）。
- 子系统：kitty 图形与键盘协议解析、OSC/DCS/APC、search、snapshot、selection/highlight。
- libghostty-vt：`src/lib_vt.zig`、`src/terminal/c/`、`include/ghostty/vt/` 的分层与 ABI 约定。

## 本文不覆盖什么

- 渲染器怎么把 cell 画到屏幕、字体与图集（atlas）——见 `docs/rendering-and-font.md`。
- 键盘/鼠标事件的**编码**（`src/input/`）与 apprt/config——见 `docs/platform-and-config.md`；kitty 键盘协议的**解析**（`src/terminal/kitty/key.zig`）留在本篇。
- 线程模型、消息信箱（mailbox）、Surface 生命周期——见 `docs/architecture.md`。
- 完整的构建/调试流程与全部命令——唯一权威是 `docs/preview-manual.md`，本篇只给最小集。
- 终端 IO（termio）如何驱动 pty 与读线程——见 `docs/architecture.md`，本篇只给一个衔接点。

## 一句话概括

`src/terminal` 是一个可以脱离 Ghostty 应用单独编译的终端核心：`src/lib_vt.zig` 把它包成 Zig 模块的公共 API 面，`src/terminal/c/` 把它包成 C ABI 实现，`include/ghostty/vt/` 对外暴露头文件，构建产物就是 libghostty-vt。`src/lib_vt.zig:16-21` 的注释明确写出，这个公共 API 面有意与 `terminal/main.zig` 分离，以便扣掉过于 Ghostty 内部的部分；相关构建与测试命令见 `AGENTS.md:19-24`。

## 关键文件地图

| 路径                                   | 行数  | 职责                                                                                                                |
| -------------------------------------- | ----- | ------------------------------------------------------------------------------------------------------------------- |
| `src/terminal/main.zig`                | 97    | 终端包的 re-export 与类型别名面，无逻辑                                                                             |
| `src/terminal/Parser.zig`              | 1116  | DEC ANSI 状态机，输出低层 `Action`                                                                                  |
| `src/terminal/parse_table.zig`         | 388   | comptime 生成的状态转移表                                                                                           |
| `src/terminal/stream.zig`              | 4873  | 泛型 `Stream(H)`，低层 action → 语义 action                                                                         |
| `src/terminal/stream_terminal.zig`     | 3701  | 把语义 action 作用到 `Terminal` 的 Handler                                                                          |
| `src/terminal/stream_continuation.zig` | 606   | 快照切点处未完成字节的续传校验                                                                                      |
| `src/terminal/Terminal.zig`            | 15846 | 终端仿真主结构，跨屏状态与操作                                                                                      |
| `src/terminal/Screen.zig`              | 12011 | 单块屏幕：页链表 + 光标 + 选择 + 脏标记                                                                             |
| `src/terminal/ScreenSet.zig`           | 154   | primary / alternate 两块屏幕的容器                                                                                  |
| `src/terminal/PageList.zig`            | 19617 | 页链表、内存池、`Pin`、压缩策略                                                                                     |
| `src/terminal/page.zig`                | 4384  | 单块连续 mmap 内存的 `Page` 布局                                                                                    |
| `src/terminal/style.zig`               | 1221  | `Style` 与页内样式 ID                                                                                               |
| `src/terminal/sgr.zig`                 | 1103  | SGR 参数解析成 `Attribute`                                                                                          |
| `src/lib_vt.zig`                       | 517   | libghostty-vt 的 Zig 模块 API 面与 `@export`                                                                        |
| `src/terminal/c/main.zig`              | 284   | C API 各模块与函数的汇总 re-export                                                                                  |
| 其他                                   | —     | `bitmap_allocator.zig`、`hash_map.zig`、`size.zig`、`Tabstops.zig`、`UTF8Decoder.zig`、`modes.zig` 等（本篇不展开） |

`src/terminal/*.zig`（不含子目录）合计 89017 行；子目录共 9 个：`apc`、`c`、`compress`、`kitty`、`osc`、`res`、`search`、`snapshot`、`tmux`。

## src/terminal/main.zig：公共 API 面

这个文件不含终端逻辑，只做两件事：`:1-30` 是子模块 re-export，`:32-76` 是一长串类型别名。别名的真实归属如下表。

| 别名                   | 定义位置                                                 |
| ---------------------- | -------------------------------------------------------- |
| `Cell`                 | `src/terminal/main.zig:36`（来自 `page.zig`）            |
| `Page`                 | `src/terminal/main.zig:44`（来自 `page.zig`）            |
| `PageList`             | `src/terminal/main.zig:45`                               |
| `Parser`               | `src/terminal/main.zig:46`                               |
| `Pin`                  | `src/terminal/main.zig:47`（= `PageList.Pin`）           |
| `Point`                | `src/terminal/main.zig:48`（来自 `point.zig`）           |
| `RenderState`          | `src/terminal/main.zig:49`（来自 `render.zig`）          |
| `Screen` / `ScreenSet` | `src/terminal/main.zig:50` / `:51`                       |
| `Selection`            | `src/terminal/main.zig:53`                               |
| `Style`                | `src/terminal/main.zig:57`（来自 `style.zig`）           |
| `Terminal`             | `src/terminal/main.zig:58`                               |
| `TerminalStream`       | `src/terminal/main.zig:59`（= `stream_terminal.Stream`） |
| `Stream`               | `src/terminal/main.zig:60`（= `stream.Stream`，泛型）    |
| `Attribute`            | `src/terminal/main.zig:76`（来自 `sgr.zig`）             |

`pub const Pin = PageList.Pin;`（`src/terminal/main.zig:47`）值得单独记住，「屏幕存储三层」一节会展开它为什么重要。

文件尾部有四个 comptime 开关：

- `options`（`src/terminal/main.zig:79`）——来自 build 注入的 `terminal_options` 模块。
- `compression_enabled`（`:82`）——等于 `mem.canReclaim(.strict)`。
- `c_api`（`:85`）——`options.c_abi` 为真时才导入 `c/main.zig`，否则是 `void`。
- `tmux`（`:29`）——`options.tmux_control_mode` 为真时才导入 `tmux.zig`，否则是空 struct。`tmux/` 目录本篇不展开。

## VT 解析链

1. 状态机定义在 `Parser.zig`，文件头说明它直接实现 vt100.net 描述的 DEC ANSI parser（`src/terminal/Parser.zig:1-4`），共 14 个状态（`:15-30`）。
2. 转移表由 `parse_table.zig` 在 comptime 生成为 `[256][状态数]Transition` 的精确尺寸数组（`src/terminal/parse_table.zig:19`、`:36-42`）；它对标准状态机做了修改——`csi_param` 接受冒号，因为 SGR 用冒号做合法参数分隔（`:1-10`）。
3. Parser 对调用方吐出低层 `Action`：print / execute / csi_dispatch / esc_dispatch / osc_dispatch / dcs_hook / dcs_put / dcs_unhook / apc_start / apc_put / apc_end（`src/terminal/Parser.zig:51-78`）。
4. `stream.zig` 把这些低层 action 翻译成一个大型语义 `Action` 联合体（`src/terminal/stream.zig:35-37` 起），并用 `pub fn Stream(comptime H: type) type`（`:470`）生成泛型 Stream。
5. 入口是 `nextSlice`（`:590`）、`nextSliceUntilGround`（`:613`）与单字节的 `next`（`:1005`）。
6. `stream_terminal.zig` 把泛型 Stream 特化成作用于 `Terminal` 的实现：`pub const Stream = stream.Stream(Handler);`（`:25-27`）。

### 泛型 Stream 的 comptime 契约

出处：`src/terminal/stream.zig:448-469`

```zig
/// Returns a type that can process a stream of tty control characters.
/// This will call the `vt` function on type T with the following signature:
///
///   fn(comptime action: Action.Key, value: Action.Value(action)) void
// ...
/// The "comptime" key is on purpose (vs. a standard Zig tagged union)
/// because it allows the compiler to optimize away unimplemented actions.
```

handler 只需实现一个 `vt` 函数。comptime key 让 Zig 为每个 action 单独 codegen，未实现的分支被整块优化掉。同一段注释还规定：能一次解出多个码点时走 `print_slice`（成串交付），否则走 `print`，**handler 必须同时处理两者**（`:458-461`）。

在 ground 状态下，Stream 用 `simd.vt.utf8DecodeUntilControlSeq` 一次性解码到下一个 ESC（0x1B）为止，再按可打印段成批交给 handler（`src/terminal/stream.zig:698-720`）。

### Stream 与 Terminal 的分工

- `Handler` 只持 `*Terminal` 指针加一组可选 `effects` 回调，默认只读：只更新终端状态，忽略所有需要响应或有副作用的序列（`src/terminal/stream_terminal.zig:29-35`，默认值 `effects: Effects = .readonly` 在 `:58`）。
- 需要向 pty 回写数据（例如 DECRQM 查询响应）时走 `Effects.write_pty` 回调，数据只在调用期间有效（`:91-96`）。
- `vt()` 调用 `vtFallible()` 并吞掉错误，只置 `semantic_failure = true` 并打 warn 日志（`:233-242`）；该字段的语义见 `:40-52`——终端不能中途停下，但要让调用方知道发生过无法处理的错误。
- `vtFallible` 是真正的分发点，把语义动作映射到 `Terminal.print` / `printSlice` / `cursorUp` 等方法（`:249-270`）。

因此分工是：Stream 负责「字节 → 语义动作」，Terminal 负责「语义动作 → 屏幕状态」。

### 续传（continuation）

`stream_continuation.zig` 用于快照场景，只保留切点时未完成的字节后缀，并定义三类校验错误（`src/terminal/stream_continuation.zig:7-36`）：

- `NoPendingState` — 输入回到 ground，说明它是完整片段而非续传。
- `NonCanonicalContinuation` — 输入没有从有效重放起点开始。
- `ReplayWouldCommit` — 重放会产生 handler 可见的副作用，例如未完成 CSI 中的 BEL 会再响一次。

续传通过 `Stream.Options.continuation_max_bytes` 打开，为 null 或 0 时关闭，且只有 TerminalStream 支持（`src/terminal/stream.zig:485-504`）。

## 屏幕存储三层

### Page：一块连续的 mmap 内存

`Page` 是单块页对齐、页大小整数倍的连续内存（`src/terminal/page.zig:144`）。内部所有数组用 `Offset(...)` 而非指针，且 cells 不按行顺序存放而是列顺序，需要通过 `rows` 字段做映射（`:164-176`）。

backing memory 直接向 OS 要，不走 Zig 分配器——POSIX 用 `mmap(MAP_PRIVATE | MAP_ANONYMOUS)`，Windows 用 `VirtualAlloc(MEM_COMMIT | MEM_RESERVE)`，因为需要页对齐且保证清零，且分配处于性能关键路径（`src/terminal/page.zig:30-65`）。

标准容量 `std_capacity` 为 cols 215、rows 215、styles 128，`grapheme_bytes` 在测试构建为 512、否则 8192；标准容量的页走内存池快路径而非单独 mmap（`:1816-1821`）。

页内还带两个分配器：grapheme 分配器 chunk 为 4 个码点（理由是大多数肤色 emoji 与组合字符不超过 4 码点，`:84-95`），字符串分配器 chunk 32 字节，目前只用于 OSC8 的 ID 与 URI（`:102-118`）。

### PageList：页链表 + 内存池

`PageList` 自述为「维护一个 page 链表来构成终端屏幕」（`src/terminal/PageList.zig:1-3`）。链表类型是 `pub const List = DoublyLinkedList(Node);`（`:43`），顺序上第一页是最上面的 scrollback，最后一页是最下面的当前活动页。

每个 `Node.Data` 是 `resident: Page` 或 `compressed: compression.Page` 二选一（`:77-80`）。压缩节点保留同一份虚拟映射——丢弃物理内存但不释放虚拟地址范围，以保证恢复不会失败（`:70-76`）。

三个内存池分别是 `NodePool`（`:299`）、`PagePool`（`:312`，必须用页分配器因为要求清零且页对齐）与 `PinPool`（`:320`）。

坐标参照系由 `point.Tag` 定义四种（`src/terminal/point.zig:6-50`）：

- `active` — 运行程序可寻址的可编辑区，包含尚未写入的行。
- `viewport` — 当前可见视口，随用户滚动而变。
- `screen` — 含全部 scrollback 的已写行。
- `history` — 仅 scrollback，底端是 active 上一行。

### Pin：不会被滚动打散的坐标

出处：`src/terminal/PageList.zig:6931-6945`

```zig
/// Represents an exact x/y coordinate within the screen. This is called
/// a "pin" because it is a fixed point within the pagelist direct to
/// a specific page pointer and memory offset. The benefit is that this
/// point remains valid even through scrolling without any additional work.
///
/// A downside is that  the pin is only valid until the pagelist is modified
/// in a way that may invalidate page pointers or shuffle rows, such as resizing,
/// erasing rows, etc.
// ...
/// The PageList maintains a list of active pin references and keeps them
/// all up to date as the pagelist is modified. This isn't cheap so callers
/// should limit the number of active pins as much as possible.
```

`Pin` 结构本体是 `{node, y, x}` 加一个 `garbage` 标志（`src/terminal/PageList.zig:6946` 起）。tracked pin 的集合类型是 `PinSet`（`:319`），紧邻 `PinPool`（`:320`）声明。

### Screen 与 ScreenSet

`Screen` 是单块屏幕的全部状态：`io`（`src/terminal/Screen.zig:38`）、`alloc`（`:42`）、`pages: PageList`（`:45`）、`cursor`（`:53`）、`saved_cursor`（`:56`）、`selection`（`:62`）、`charset`（`:65`）、`protected_mode`（`:72`）、`kitty_keyboard`（`:75`）、`kitty_images`（`:78`）、`dirty`（`:87`）。相关类型 `Cursor` 在 `:132`、`SavedCursor` 在 `:198`、`Options` 在 `:259`、`init` 在 `:303`。

`ScreenSet` 的自述是：最初为 primary 与 alternate 而建，未来可扩展到 N 块；primary 总是初始化，alternate 直到首次使用才初始化（`src/terminal/ScreenSet.zig:1-7`）。它的 `Key` 只有两个值，用 `lib.Enum` 生成（`:18-21`）。

`generations: std.EnumMap(Key, usize)` 是单调计数：屏幕存储被移除或替换时递增，让外部句柄能区分新初始化的屏幕与指向已销毁存储的陈旧引用（`:33-36`）。懒初始化在 `getInit`（`:74-88`），`remove` 会断言 primary 不可移除并递增该计数（`:90-101`）。

`Terminal` 持有 `screens: ScreenSet`（`src/terminal/Terminal.zig:48`），并把跨屏状态放在自己身上：`tabstops`、`rows`/`cols`、`scrolling_region`、`pwd`、`title`、`colors`、`modes`、`cursor`、`mouse_shape`、`glyph_glossary` 等（`:47-92`）。文件头自述见 `:1-3`。

`Terminal.Options`（`:260`）里两个值得记的默认值：`max_scrollback_bytes = 10_000`（`:266`）；`kitty_image_storage_limit` 按 artifact 分——ghostty 320MB、lib 10MB，注释说明嵌入库要对内存更保守（`:285-293`）。

## 样式与 SGR

`sgr.zig` 负责 SGR（Select Graphic Rendition）属性解析与类型定义，输出 `Attribute` 联合体（`src/terminal/sgr.zig:1`）。

`style.zig` 定义 `Id = size.StyleCountInt` 与 `default_id: Id = 0`（`src/terminal/style.zig:14-17`），以及 `Style{fg_color, bg_color, underline_color, flags}`，其中 `Flags` 是 `packed struct(u16)`（`:20-41`）。

样式在页内用 `RefCountedSet` 去重（引入见 `src/terminal/style.zig:10`）。该结构的自述（`src/terminal/ref_counted_set.zig:9-34`）给出几条关键约束：

- 底层是开放寻址哈希表 + 线性探测 + Robin Hood 哈希，外加一个扁平 item 数组。
- ID 0 保留，永不分配。
- 超出容量时返回 `OutOfMemory` 或 `NeedsRehash`，由调用方决定后续路径。
- 引用计数归零的 item 会保留到该桶被其他 item 覆写为止，因此可以被「复活」。

hyperlink 用同一套机制（引入见 `src/terminal/hyperlink.zig:10`）：`hyperlink.Id = size.HyperlinkCountInt`（`:18`），cell→id 的映射用 `AutoOffsetHashMap(Offset(Cell), Id, 80)`——注释说明因为一个 cell 是超链接的概率很低，把 ID 直接存进 cell 太浪费（`:20-23`）。

## scrollback 与页压缩

`compress.zig` 只有 15 行，是一个纯命名空间：`lz4` 是用于终端页内存的 raw block 编解码器，`Page` 是保留原虚拟映射的压缩页。文件头明确写明「压哪些页、何时解除物理内存、何时恢复」的策略属于 `PageList`（`src/terminal/compress.zig:1-11`）。

是否支持由 `terminal.compression_enabled = mem.canReclaim(.strict)` 决定（`src/terminal/main.zig:82`）。`canReclaim`（`src/terminal/mem.zig:32`）在测试构建恒为 true；运行时只在 64 位地址空间的 Linux（MADV_DONTNEED）与 Darwin（MADV_FREE_REUSABLE/FREE_REUSE）返回 true，其他目标返回 false（`:44-60`）。

`PageList.compress`（`src/terminal/PageList.zig:4681`）的可压缩节点定义写在其文档注释里（`:4660-4665`）：位于 active 边界之前、且不与 viewport 相交的完整页；边界页被排除（它可能同时含 scrollback 与 active 行），可见页保持常驻以便立即重绘与滚动。它接受三种模式 `incremental` / `drain` / `full`（`:4683`）。

`Terminal` 层把它收敛成两个 `lib.Enum`：`CompressionMode{incremental, full}`（`src/terminal/Terminal.zig:2574`）与 `CompressionResult{unsupported, pending, complete}`（`:2583`），两处注释都写明「声明顺序是 libghostty-vt C ABI 的一部分，删除的值必须留 null 洞」。入口函数是 `Terminal.compress`（`:2603`），只作用于 primary 屏幕的 pages。

调度由调用方负责：`Terminal.compressionActivity()`（`:2564`）返回一个不透明的变更令牌，注释建议每当该值变化就安排一次 `compress`（`:2550-2563`）。C 头文件把这条约定写得更直白——scrollback 压缩由调用方驱动，libghostty-vt 不创建定时器也不起后台线程（`include/ghostty/vt/terminal.h:44-50`）。

`src/terminal/compress/AGENTS.md:9-19` 给出取舍优先级，依次为：

1. 页形数据上的压缩率——编码后的字节就是留存的 scrollback 内存。
2. 解压吞吐——页冷却时压一次，但按需恢复（scrollback 访问、搜索、检视），恢复延迟直接可感知。
3. 压缩吞吐——后台跑在空闲页上，慢一点可接受。

同一份文档还有两条硬约束：codec 必须能为 `wasm32-freestanding` 构建，不用 libc、不依赖 `src/simd`（`:26-28`）；每个 codec 都要有差分属性测试套件——往返一致、独立格式 walker、错误尺寸输出拒绝、损坏/截断解码，轻量版进常规单测，穷举版用环境变量门控（`:29-33`）。目录里只有四个文件：`AGENTS.md`、`lz4.zig`、`lz4_differential.zig`、`Page.zig`；`lz4.zig` 是免分配的 raw block（非 frame）实现，block 不携带解码尺寸，调用方须给精确大小的输出缓冲（`:80-82`）。

## 子系统一览

### kitty

`kitty.zig` 聚合三个子模块，`graphics` 受 `build_options.kitty_graphics` 门控，关闭时退化成空 struct（`src/terminal/kitty.zig:5-11`）。

键盘协议的核心是 `FlagStack`：固定 8 层、无堆分配，实现 `CSI > u`（push）/ `CSI < u`（pop）语义（`src/terminal/kitty/key.zig:1-11`）；栈满时靠 `idx` 的 `u3` 回绕淘汰最老项（`:37-43`）。这里是**解析与状态**侧；编码侧在 `src/input/`，见 `docs/platform-and-config.md`。

`kitty/graphics.zig` 只是聚合层，把 `graphics_command` / `graphics_exec` / `graphics_image` / `graphics_render` / `graphics_storage` / `graphics_unicode` 六个文件汇成 `Command`、`CommandParser`、`Image`、`LoadingImage`、`ImageStorage`、`RenderPlacement`、`Response`、`execute`（`:19-34`）。文件头列出未实现项——共享内存传输、unicode 虚拟放置、动画——并自陈这个子系统性能不佳（`:1-17`）。

### OSC / DCS / APC

`osc.zig` 文件头解释：OSC 以 `ESC ]` 开头，可能包含字符串和不规则格式，因此写了专门的 parser（`src/terminal/osc.zig:1-5`）。具体命令解析拆到 `src/terminal/osc/parsers.zig` 汇总的 16 个文件（`:3-18`），涵盖窗口标题/图标、剪贴板、颜色、hyperlink、iterm2、kitty 各协议、mouse shape、OSC 9、report pwd、rxvt 扩展、semantic prompt。

`dcs.zig` 的 `Handler` 给单条 DCS 命令设 1MB 上限以防恶意输入耗内存（`src/terminal/dcs.zig:10-19`）。

`apc.zig` 的 `Handler` 识别 kitty 与 glyph 两种协议，各自有独立 `max_bytes` 上限；`unknown_max_bytes` 为 0 时直接丢弃未知 APC（`src/terminal/apc.zig:10-31`）。glyph 协议的规范源头是 Rio 仓库的 `specs/glyph-protocol.md`，规范摘要在 `src/terminal/apc/glyph.zig` 顶部，AGENTS 要求优先用本地规范（`src/terminal/apc/glyph/AGENTS.md:3-9`）。

### search / snapshot

`search.zig` 导出 Active、PageList、Screen、Viewport 四种搜索；`Thread` 因为依赖 libxev，只在 `options.artifact == .ghostty` 时存在，libghostty 下是 `void`（`src/terminal/search.zig:5-15`）。

`snapshot/` 是终端状态的二进制表示，不是通用重放/录制传输格式。布局优先让终端尽快可用：先发 active 状态，再发 READY 记录，然后才是完整历史（scrollback），最后是空的 FINISH 标记（`src/terminal/snapshot/main.zig:1-17`）。开发原则是 Postel 定律——编码时校验，解码时优雅降级，例如非法样式退化为忽略该样式（`src/terminal/snapshot/AGENTS.md:3-7`）。

### selection / highlight / render state

- `src/terminal/Selection.zig:14-22` 有作者的自我批评注释：排序操作频繁用到 `pointFromPin` 而它很慢，之所以保留是因为太多调用方已依赖该行为，未来需要重做。
- `highlight.zig` 是更通用的「连续 cell 区间」概念，用于选择、搜索结果等，注释写明计划最终完全取代 `Selection`，但因耦合太深需要时间（`src/terminal/highlight.zig:1-10`）。
- `render.zig` 特意放在 `src/terminal` 而不是 `src/renderer`，目的是对多种渲染器保持通用，尤其能帮 libghostty-vt 把终端状态转成可渲染形式；它取代了旧的「每帧 clone 视口 Screen」做法，clone 时间一直是阻塞 IO 的瓶颈（`src/terminal/render.zig:20-35`）。具体渲染见 `docs/rendering-and-font.md`。
- `SelectionGesture.zig` 只负责解释一条指针事件流，除 `autoscrollTick` 会滚动视口外不直接修改终端选择，由调用方把返回的 `Selection` 应用到活动屏幕（`src/terminal/SelectionGesture.zig:1-8`）。
- `formatter.zig` 的 `Format` 枚举包含 `plain` 与保留颜色/样式/URL 的 VT 序列格式（`src/terminal/formatter.zig:23-31`）。
- `modes.zig` 的文件头说明它用了很重的 comptime 来保证各类型与逻辑同步（`src/terminal/modes.zig:1-8`）；`ModeState.saved` 每个模式只允许保存一次，与其他实现 XTSAVE/XTRESTORE 的终端一致，理由是防 DoS（`:18-22`）。

## libghostty-vt：从 Zig 模块到 C ABI

### 四层结构

1. `src/lib_vt.zig` 是 Zig 模块的公共 API 面（517 行），文件头警告「API 不保证稳定」——功能极其稳定，因为它直接从 Ghostty 抽取、多年被大量用户实际使用，但 API 本身可能无预警变化（`:1-9`）。
2. 它额外暴露三样 `terminal/main.zig` 没有的东西：`sys`（运行时可替换的函数指针，例如 PNG 解码器，让库本身对外部库零运行时依赖，`:23-39`）、`TinyIo`（为二进制体积优化的极简阻塞式 `std.Io`，可省约 110KB，`:41-50`）、以及 `input` 子命名空间（谨慎地只导入 input 包中的少数文件，提供 focus/paste/key/mouse 编码，`:111-146`）。
3. C 层实现在 `src/terminal/c/` 的 32 个 `.zig`（约 19014 行），由 `src/terminal/c/main.zig` 统一汇总：`:5-49` 列模块，`:52-248` 逐个 `pub const` re-export 具体函数（`osc_*`、`color_*`、`render_state_*`、`sgr_*`、`key_event_*`、`key_encoder_*`、`mouse_*`、`terminal_*`、`snapshot_*` 等）。
4. `src/lib_vt.zig` 中共 200 处 `@export`，全部包在 `if (@import("root") == lib)` 的 comptime 块内——只有在构建 C 库而非 Zig 模块时才引用并导出 C API（`:160-163`），符号统一带 `ghostty_` 前缀（例见 `:183-199`）。
5. 头文件共 34 个 `.h`：`include/ghostty/vt.h` 一个总入口，`include/ghostty/vt/` 下 29 个直属头文件，加 `vt/key/` 与 `vt/mouse/` 各 2 个。`vt.h` 是纯汇总头，文件头声明这是不完整、未稳定、必然会变的 API（`:1-12`），中段用 Doxygen 把 API 分组（`:28-47`），末尾在 `extern "C"` 块内 include 全部子头文件（`:126-161`）。

### 新增一个 C 函数的四步

出处：`src/terminal/c/AGENTS.md:6-13`

```md
- Any functions must be updated all the way through from here to
  `src/terminal/c/main.zig` to `src/lib_vt.zig` and the headers
  in `include/ghostty/vt.h`. Specifically:
  1. Define the function in `src/terminal/c/<module>.zig`.
  2. Re-export it via a `pub const` in `src/terminal/c/main.zig`.
  3. Add an `@export` call in `src/lib_vt.zig` with the
     `ghostty_` prefixed symbol name.
  4. Declare it in the corresponding header under `include/ghostty/vt/`.
```

同一份文档还规定 `include/ghostty/vt.h` 的内容必须按「(1) 宏 (2) 前向声明 (3) 类型 (4) 函数」排序（`:14-15`）。

### ABI 约定

- **opaque 指针** — 长生命周期对象优先用不透明句柄（`src/terminal/c/AGENTS.md:19-20`）。实例：`typedef struct GhosttyTerminalImpl* GhosttyTerminal;`（`include/ghostty/vt/types.h:113`），Zig 侧对应 `pub const Terminal = ?*TerminalWrapper;`（`src/terminal/c/terminal.zig:488`）。
- **sized struct** — struct 可以留 padding，也可用 sized struct 模式：`extern struct` 首字段为 `size: usize = @sizeOf(Self)`，C 侧用 `GHOSTTY_INIT_SIZED` 零初始化并填 size（`src/terminal/c/AGENTS.md:21-27`；宏定义在 `include/ghostty/vt/types.h:322-332`）。实例：`GhosttyTerminalProgressReport` 首字段是 `size_t size;` 并注明回调只能访问 size 所报告范围内的字段（`include/ghostty/vt/terminal.h:599-616`），Zig 侧例子见 `src/terminal/c/formatter.zig:64`。
- **tagged union** — Zig tagged union 必须经 `lib.TaggedUnion` 转成 C ABI 兼容 union（`src/terminal/c/AGENTS.md:4-5`；实现在 `src/lib/union.zig:22`，其中 `Padding` 类型给 C union 加 `_padding` 字段以固定尺寸且永不允许更改，`:5-21`；C 目标下会 comptime 断言尺寸一致，`:28-37`）。
- **枚举** — 经 `lib.Enum` 生成，C 目标下用 `c_int`、Zig 目标下用能表示所有索引的最小无符号整数；每个值等于其在 keys 中的索引，当整数值属于 ABI 或序列化格式时顺序不得更改，删除字段要用 null 保留整数洞（`src/lib/enum.zig:4-17`，函数在 `:18`）。
- **枚举哨兵（硬规则）** — `include/ghostty/vt/` 里所有 C enum 必须以 `_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE` 作为最后一项，强制 int 尺寸（pre-C23 可移植性，`AGENTS.md:25-26`）。宏定义为 `#define GHOSTTY_ENUM_MAX_VALUE INT_MAX`（`include/ghostty/vt/types.h:83`）；`:52-56` 解释了为什么用 `INT_MAX` 而不是 `0xFFFFFFFF`——pre-C23 中枚举常量必须是 int 类型，超过 `INT_MAX` 是约束违规，接受它的编译器可能按二补数解释成负值，从而与合法的负枚举值冲突。真实例子：`include/ghostty/vt/types.h:103`、`:238`、`include/ghostty/vt/sgr.h:93`、`include/ghostty/vt/terminal.h:194`。

`GhosttyResult` 定义 7 个结果码：`GHOSTTY_SUCCESS = 0`、`OUT_OF_MEMORY = -1`、`INVALID_VALUE = -2`、`OUT_OF_SPACE = -3`、`NO_VALUE = -4`、`IO_ERROR = -5`、`LIMIT_EXCEEDED = -6`（`include/ghostty/vt/types.h:88-104`）。

### 一个 C 调用的落地路径

以 `ghostty_terminal_vt_write` 为例，三跳：

1. 头文件声明 `GHOSTTY_API void ghostty_terminal_vt_write(GhosttyTerminal terminal, const uint8_t* data, size_t len);`（`include/ghostty/vt/terminal.h:1749`）。
2. `src/terminal/c/main.zig:186` 的 `pub const terminal_vt_write = terminal.vt_write;` re-export。
3. `src/terminal/c/terminal.zig:691-697` 的实现只有一行有效代码：`wrapper.stream.nextSlice(ptr[0..len]);`。相邻的 `vt_write_until_ground` 则调 `nextSliceUntilGround` 并回填 consumed 字节数（`:717-720`）。

这里的 `wrapper` 是 `TerminalWrapper`（`src/terminal/c/terminal.zig:97-114`），它在 `ZigTerminal` 之外额外持有一个持久 VT `stream`，正是为了处理跨多次 `vt_write` 调用被切断的转义序列；同时还持有 io owner、`tmp_dir_path`、`terminfo_name_buf`、`effects` 与 `tracked_grid_refs`。

构造入口 `ghostty_terminal_new(const GhosttyAllocator*, GhosttyTerminal*, uint16_t cols, uint16_t rows)`（`include/ghostty/vt/terminal.h:1645-1648`）对应 Zig 侧 `pub fn new`（`src/terminal/c/terminal.zig:635`），cols 或 rows 为 0 时返回 `InvalidValue`（`:652-658`）。它还会把 `t.flags.shell_redraws_prompt` 强制设为 `.false`（`:678-681`），注释理由是 libghostty-vt 的嵌入方不一定装了 Ghostty 的 shell 集成，因此不能假设 OSC 133 提示符能在 resize 时重绘；shell 仍可用 `OSC 133;A;redraw=1` 显式打开。

## 构建选项与条件编译

| 选项                | 定义位置                            | 说明                                                     |
| ------------------- | ----------------------------------- | -------------------------------------------------------- |
| `artifact`          | `src/terminal/build_options.zig:14` | `ghostty` 或 `lib`，门控部分功能                         |
| `oniguruma`         | `:23`                               | 无正则支持时禁用部分功能（注释自陈可能已过时，`:16-23`） |
| `simd`              | `src/terminal/build_options.zig:28` | 是否构建 SIMD 加速路径，会引入 libc 运行时依赖           |
| `c_abi`             | `:37`                               | 强制 C ABI 模式开或关                                    |
| `kitty_graphics`    | `:58-72`                            | 派生项，仅在 `wasm32-freestanding` 关闭（拿不到时间戳）  |
| `tmux_control_mode` | `:75`                               | 派生项，直接等于 `oniguruma`                             |

`src/terminal/lib.zig:6` 用 `c_abi` 决定 `lib.target` 是 `.c` 还是 `.zig`，从而决定所有 `lib.Enum` / `lib.TaggedUnion` 生成 C 形态还是紧凑 Zig 形态；该文件同时转发 `alloc`、`TinyIo`、`Buffer`、`Enum`、`TaggedUnion`、`Struct`、`String` 等工具（`:5-24`）。

构建侧：`-Demit-lib-vt` 定义在 `src/build/Config.zig:78-84`，描述是「为 libghostty-vt-only 构建设置默认值（禁用 xcframework、macOS app 和 docs）」，当 Ghostty 作为依赖被引用（`b.dep_prefix.len > 0`）时默认开启。`GhosttyZig` 建两个模块 `vt` 与 `vt_c`，root source file 都是 `src/lib_vt.zig`（`src/build/GhosttyZig.zig:118`），区别只是 `vt_c` 把 `c_abi` 设成 true（`:93`）；两者的 artifact 都是 `.lib`（`:68`），且 Zig 模块里一律禁用 Oniguruma（`:72`）。

## 构建与测试命令（最小集）

命令的唯一权威是 `docs/preview-manual.md`；这里只列与终端核心直接相关的四条。

构建 libghostty-vt（出处 `AGENTS.md:21`）：

```sh
zig build -Demit-lib-vt
```

构建 WASM 版本（出处 `AGENTS.md:22`；也是 `src/terminal/compress/AGENTS.md:28` 用来验证 codec 的 wasm 兼容性的命令）：

```sh
zig build -Demit-lib-vt -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall
```

跑 libghostty-vt 测试（出处 `AGENTS.md:23`，step 声明在 `build.zig:68-71`）：

```sh
zig build test-lib-vt -Dtest-filter=<filter>
```

跑 LZ4 的穷举差分测试（出处 `src/terminal/compress/AGENTS.md:83-86`）：

```sh
GHOSTTY_LZ4_SLOW=1 zig build test -Dtest-filter="lz4 differential"
```

以上四条命令本机均未执行（未核实：本机 PATH 中没有 `zig`）；每条都已标注仓库内出处。

`test-lib-vt` 到底跑了什么：`build.zig:325-339` 给 `mod.vt` 和 `mod.vt_c` 各建了一个 `addTest` 并都挂到 `test_lib_vt_step`——同一份源码在 Zig 模式和 C ABI 模式下各测一遍，两者都遵守 `-Dtest-filter`。另外 `build.zig:341-343` 规定：`emit_lib_vt` 为真时，`test` step 会跳过整套完整单测。

产物形态：wasm 目标走 `GhosttyLibVt.initWasm`（`build.zig:119-132`），其余走 `initShared`；此外总是产出静态库，非依赖场景下重命名为 `libghostty-vt.a`（Windows 上为 `ghostty-vt-static.lib`，`build.zig:135-156`）；在 macOS 本机构建且同时开启 `emit_lib_vt` 与 `emit_xcframework` 时还会产出 xcframework（`build.zig:158-173`）。wasm 模块用 `zig.vt_c` 作 root module，并设 `rdynamic = true`（`src/build/GhosttyLibVt.zig:52`）、`export_table = true`（`:56`，让浏览器 JS 能往间接函数表里插回调）、`entry = .disabled`（`:59`，无入口点）。

## 常见坑 / 注意事项

1. `Node.page()` 会**静默解压**一整页；只想读行列数或容量就用 `rows()` / `cols()` / `capacity()`，只想看是否常驻就用 `pageIfResident()`（`src/terminal/PageList.zig:87-97`、`:105-110`、`:214-226`）。
2. 未追踪的 `Pin` 在 resize / erase 等 shuffle 行的操作后失效；tracked pin 由 PageList 统一维护，代价不低，要少用（`src/terminal/PageList.zig:6931-6945`）。
3. `Stream` 的 handler 必须同时处理 `print` 和 `print_slice`，否则批量路径的文本会丢（`src/terminal/stream.zig:458-461`）。
4. 解析出错不会中断流，只置 `semantic_failure`；调用方要自己检查（`src/terminal/stream_terminal.zig:40-52`、`:233-242`）。
5. 默认 `Handler.effects = .readonly`，不设回调就没有 bell、标题、剪贴板与 pty 回写（`src/terminal/stream_terminal.zig:29-35`、`:58`）。
6. `title_report` 默认关闭，因为把攻击者可控的标题回报给 pty 等于向前台进程的输入流注入文本（`src/terminal/stream_terminal.zig:60-63`）。
7. 改 `include/ghostty/vt/` 里任何枚举都要补 `_MAX_VALUE` 哨兵（`AGENTS.md:25-26`）。
8. 压缩不是所有平台都有：非 64 位、非 Linux/Darwin 上 `canReclaim` 返回 false（`src/terminal/mem.zig:44-60`），`Terminal.compress` 相应返回 `unsupported`（`src/terminal/Terminal.zig:2603-2617`）。

## example/：C API 的活文档

每个示例是独立项目，自带 `build.zig`、`build.zig.zon`、`README.md` 和 `src/main.c`（或 `.zig`）；CI 通过 `example/*/build.zig.zon` 自动发现，新增示例不用改 workflow 文件（`example/AGENTS.md:3-6`）。仓库当前有 27 个含 `build.zig.zon` 的示例目录。

示例源码用 Doxygen `@snippet` 机制：用 `//! [snippet-name]` 包住相关代码，头文件里写 `@snippet <dir>/src/main.c my-snippet` 而不是内联 `@code` 块。文档明令「绝不要在头文件里内联复制示例代码」，改示例时必须与 `include/ghostty/vt/` 的头文件保持标记同步（`example/AGENTS.md:18-33`）。

实际引用点：`include/ghostty/vt.h:49-62` 用 `@ref` 列出全部完整示例（`c-vt-build-info`、`c-vt`、`c-vt-encode-key`、`c-vt-encode-mouse`、`c-vt-paste`、`c-vt-sgr`、`c-vt-formatter`、`c-vt-grid-traverse`、`c-vt-grid-ref-tracked`、`c-vt-compression`）；`include/ghostty/vt/terminal.h:41-42` 与 `:52-53` 则用 `@snippet` 直接嵌入 `c-vt-stream` 和 `c-vt-compression` 的片段。

其他约定：可执行文件名用下划线（`c_vt_encode_focus` 而非连字符）；所有 C 示例通过 `lazyDependency("ghostty", ...)` 链接 `ghostty-vt`；`build.zig` 遵循统一模板；新增示例要生成新的唯一 fingerprint 并保持 `minimum_zig_version` 一致（`example/AGENTS.md:10-16`、`:35-39`）。

## 与 Ghostty 应用的衔接点

Ghostty 应用**不**使用 `stream_terminal.Handler`，而是用自己的 handler 实例化同一个泛型 Stream：`pub const Stream = terminal.Stream(StreamHandler);`（`src/termio/stream_handler.zig:80`），该 handler 的自述是「有状态、预期存活整个终端生命周期」（`:19-21`）。termio 如何驱动 pty、读线程与 IO 线程，见 `docs/architecture.md`。

## 延伸阅读

- [AGENTS.md](../AGENTS.md) — libghostty-vt 命令与枚举哨兵规则
- [src/terminal/c/AGENTS.md](../src/terminal/c/AGENTS.md) — C API 四步流程与 ABI 约定
- [src/terminal/compress/AGENTS.md](../src/terminal/compress/AGENTS.md) — codec 优先级、测试与 benchmark
- [src/terminal/snapshot/AGENTS.md](../src/terminal/snapshot/AGENTS.md) — 快照健壮性原则
- [src/terminal/apc/glyph/AGENTS.md](../src/terminal/apc/glyph/AGENTS.md) — glyph 协议规范来源
- [example/AGENTS.md](../example/AGENTS.md) — 示例项目与 Doxygen snippet 约定
- [src/benchmark/AGENTS.md](../src/benchmark/AGENTS.md) — `ghostty-bench` 的通用工作流（本篇未展开）
- 其他篇目：`docs/architecture.md`、`docs/rendering-and-font.md`、`docs/platform-and-config.md`、`docs/preview-manual.md`
