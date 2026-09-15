# Ghostty 整体架构

> 最后更新对应的 git commit：`f81dcadc8`（`f81dcadc82ea2afdcf2dc92929037701122f05b5`，2026-08-14）
> 校验方式：`git log -1 --format='%H %h %ad %s'`

## 本文覆盖什么

- `src/` 的模块地图：每个子包的职责与规模量级。
- 三个 comptime 接口（apprt、渲染后端、字体后端）如何按 target 与构建选项选定。
- 两条进程启动链路：Linux/FreeBSD 的 `src/main_ghostty.zig` 与 macOS 的 Swift `main.swift` 经 C API 驱动 Zig 核心。
- 每个表面（surface）的线程模型，以及线程之间的四个消息信箱（mailbox）。
- `renderer.State.mutex` 的保护范围与 `lockDemand` / `yieldToDemand` 防饿死机制。
- 「按键进去、像素出来」的完整逐跳数据流。
- 两个都叫「libghostty」的东西如何区分。

## 本文不覆盖什么

- VT 序列解析、`Screen` / `PageList` / `Page` 存储、libghostty-vt 的 C API 细节，见 [terminal-core.md](terminal-core.md)。
- 渲染后端实现、着色器、字体发现与文本整形，见 [rendering-and-font.md](rendering-and-font.md)。
- apprt 各实现内部、macOS Swift 层结构、`src/config` 与 `src/input` 细节，见 [platform-and-config.md](platform-and-config.md)。
- 所有构建、运行、调试命令，见 [preview-manual.md](preview-manual.md)（唯一权威）。
- 构建选项的完整清单（`src/build/Config.zig` 共 803 行），本文只讲影响架构的三个 comptime 接口与产物矩阵。

## 一句话概括

Ghostty 是一个与平台无关的 Zig 核心，加一层在编译期选定的应用运行时（apprt）。核心里 `App` 拥有若干 `Surface`，每个 `Surface` 自己创建并拥有一个 pty 会话、一份终端状态和一个渲染器（`src/App.zig:1-3`、`src/Surface.zig:1-11`）。apprt 抽象掉「建窗口、收键鼠」这类平台工作，目标是让不同实现尽量共享核心逻辑（`src/apprt.zig:1-10`）。Linux 与 FreeBSD 默认用 GTK4 apprt 直接产出可执行文件；其余平台（含 macOS）默认 `app_runtime = .none`，核心被编译成库，由外部应用链接并驱动（`src/apprt/runtime.zig:14-24`）。

## 关键文件地图

| 路径                     | 规模量级             | 职责                                                             |
| ------------------------ | -------------------- | ---------------------------------------------------------------- |
| `build.zig`              | 420 行               | 构建入口 `pub fn build`，声明所有产物与 step                     |
| `src/build/Config.zig`   | 803 行               | 全部 `-D` 构建选项的定义与默认值推导                             |
| `src/build_config.zig`   | 105 行               | 把构建选项转成 comptime 常量供运行期代码使用                     |
| `src/main.zig`           | —                    | 按 `exe_entrypoint` 在 ghostty/helpgen/mdgen/webgen 之间切换入口 |
| `src/main_ghostty.zig`   | 266 行               | `ghostty` 可执行文件的 `main()` 与日志实现                       |
| `src/main_c.zig`         | 265 行               | 进程级 C API（`ghostty_init`、`ghostty_cli_try_action` 等）      |
| `src/App.zig`            | 653 行               | 核心 `App`：surface 列表、app mailbox、共享字体 grid 集合        |
| `src/Surface.zig`        | 6121 行              | 核心 `Surface`：线程编排、输入分发、与 termio/renderer 的粘合    |
| `src/apprt.zig` + 子目录 | 59 行 + 63 个 `.zig` | 应用运行时（apprt）抽象与 none/gtk/embedded/browser 实现         |
| `src/termio/`            | 9 个 `.zig`          | 终端 IO（termio）：pty 读写、写线程、读线程流水线                |
| `src/terminal/`          | 144 个 `.zig`        | 终端核心：VT 解析与屏幕数据结构（详见 terminal-core.md）         |
| `src/renderer/`          | 35 个 `.zig`         | 渲染器与渲染线程（详见 rendering-and-font.md）                   |
| `src/font/`              | 50 个 `.zig`         | 字体发现、face、整形器、图集（atlas）                            |
| `src/config/`            | 20 个 `.zig`         | 配置系统，`src/config/Config.zig` 单文件 11120 行                |
| `src/input/`             | 17 个 `.zig`         | 按键编码与键绑定，`src/input/Binding.zig` 单文件 4924 行         |
| `src/inspector/`         | 13 个 `.zig`         | 终端检查器（inspector）                                          |
| `src/cli/`               | 28 个 `.zig`         | `ghostty +<action>` 形式的 CLI action                            |
| `src/os/`                | 33 个 `.zig`         | 操作系统适配层                                                   |
| `src/datastruct/`        | 11 个 `.zig`         | 通用数据结构，含 `BlockingQueue`                                 |
| `src/build/`             | 37 个 `.zig`         | 构建脚本包（产物、xcframework、i18n 等）                         |

补充两条命名约定，细节不在本文展开：

- **`PascalCase.zig`** — 文件即类型，文件顶部通常有 `= @This()`，例如 `src/App.zig:4` 的 `const App = @This();`。
- **`lowercase.zig`** — 命名空间模块，只做 import 与 re-export，例如 `src/terminal/main.zig:8-30`。完整约定见根 [AGENTS.md](../AGENTS.md) 的 Conventions 一节。

## 核心对象：App 与 Surface

### App

`App` 的注释自述它是 ghostty 的主 GUI 应用对象，负责建窗口、装配渲染器，主循环由 `run` 启动（`src/App.zig:1-3`）。它持有的关键状态：

- **`surfaces`** — 当前活跃的 `*apprt.Surface` 列表（`src/App.zig:27-28`）。
- **`mailbox`** — app 线程的消息队列，注释提醒队列满时会报错或阻塞（`src/App.zig:50-51`）。
- **`font_grid_set`** — 配置相同的 surface 之间共享的 `font.SharedGridSet`（`src/App.zig:53-55`）。
- **`config_conditional_state`** — 应用级配置的条件状态，同时作为新 surface 的默认值（`src/App.zig:63-66`）。
- **`focused`** / **`focused_surface`** — 应用是否聚焦，以及最后聚焦的 surface；注释说明 `focused_surface` 可能已失效，必须先用 `hasSurface` 校验（`src/App.zig:30-47`）。

`App.deinit` 会先关掉所有 surface，然后断言 `font_grid_set.count() == 0`——因为销毁只发生在应用关停时，此时所有 surface 都应已优雅退出（`src/App.zig:132-143`）。

### Surface

`Surface` 是「一个最小的部件，终端在其上绘制并响应键鼠事件」，每个 surface 自己创建并拥有 pty 会话；它到底是窗口、标签页、分屏还是大窗口里的预览面板，完全由上层 apprt 决定，这个结构体不关心（`src/Surface.zig:1-11`）。

surface 处理输入的返回值是 `InputEffect` 三态（`src/Surface.zig:187-200`）：

- **`ignored`** — Ghostty 没有以任何方式处理，应交回 OS 等子系统继续处理。
- **`consumed`** — 已被 Ghostty 处理并消费。
- **`closed`** — 输入导致该 surface 关闭，`Surface`、runtime surface 等指针都可能已不安全，调用方必须立即退出。

## 三个 comptime 接口

Ghostty 在编译期一次性钉死三样东西：用哪个 apprt、用哪个渲染后端、用哪个字体后端。三者最终都由 `BuildConfig.fromOptions()` 转出并在 `src/build_config.zig:41-43` 顶层导出。

### apprt：应用运行时

`apprt.runtime` 先按产物类型 `build_config.artifact` 分支，`exe` 再按 `app_runtime` 细分（`src/apprt.zig:42-49`）；`apprt.App` 与 `apprt.Surface` 就是选中实现里的同名类型（`src/apprt.zig:51-52`）。

| `artifact`    | `app_runtime` | 实际实现                 | 出处               |
| ------------- | ------------- | ------------------------ | ------------------ |
| `exe`         | `.none`       | `src/apprt/none.zig`     | `src/apprt.zig:44` |
| `exe`         | `.gtk`        | `src/apprt/gtk.zig`      | `src/apprt.zig:45` |
| `lib`         | 不适用        | `src/apprt/embedded.zig` | `src/apprt.zig:47` |
| `wasm_module` | 不适用        | `src/apprt/browser.zig`  | `src/apprt.zig:48` |

要点：

- `artifact` 不是构建选项，而是 `Artifact.detect()` 从 `builtin.output_mode` 探测出来的（`src/build_config.zig:32`、`src/build_config.zig:83-98`）。
- `Runtime.default` 只对 Linux 与 FreeBSD 返回 `.gtk`，其余一律 `.none`；注释直接说明 `.none` 表示不产出可执行文件、改为产出库，macOS 用 Xcode 构建链接该库的应用（`src/apprt/runtime.zig:14-24`）。
- 因此 macOS 上核心被编成 `lib`，实际 apprt 是 `embedded`——即「Ghostty 被宿主应用嵌入、不掌握应用生命周期」的形态（`src/apprt/embedded.zig:1-5`）。
- `none` 只是个空壳：`App` 里只有一个恒返回 `false` 的 `performIpc`，`Surface` 是空结构体（`src/apprt/none.zig:8-19`）。
- `browser` 分支存在于选择表里（`src/apprt.zig:19`、`src/apprt.zig:48`），本文不描述其行为（未核实：未阅读 `src/apprt/browser.zig`，也未验证 wasm 构建路径）。

### 渲染后端与字体后端

`renderer.Renderer` 是 `GenericRenderer(Metal)`、`GenericRenderer(OpenGL)` 或 `WebGL` 三选一（`src/renderer.zig:38-42`）。默认值由 target 决定（`src/renderer/backend.zig:10-22`）：

| 条件               | 渲染后端 | 字体后端              |
| ------------------ | -------- | --------------------- |
| `wasm32` + browser | `webgl`  | `web_canvas`          |
| Windows            | `opengl` | `freetype_windows`    |
| Darwin             | `metal`  | `coretext`            |
| 其余               | `opengl` | `fontconfig_freetype` |

字体后端默认值出处是 `src/font/backend.zig:39-61`；注释说明 Windows 上避开 fontconfig 是因为其 libxml2 依赖可能因符号链接而解包失败。两个后端内部实现见 [rendering-and-font.md](rendering-and-font.md)。

## 进程启动：两条链路

在看具体链路之前先注意：可执行文件的 Zig 入口并不是固定的。`src/main.zig` 按 `build_config.exe_entrypoint` 在 `src/main_ghostty.zig`、`src/helpgen.zig`、两个 mdgen 与三个 webgen 之间切换，再把选中模块的 `main` 原样导出（`src/main.zig:4-16`）。下文只讲 `.ghostty` 这一支。

### Linux 与 FreeBSD：可执行文件

1. `main(minimal)` 是入口（`src/main_ghostty.zig:26`）。
2. 先 `global.init` 建立进程级全局状态（`src/main_ghostty.zig:31`）；其中解析出 `+action` 后会强制关掉 stderr 日志，避免日志污染 action 输出（`src/global.zig:129-141`），随后按环境变量 `GHOSTTY_LOG` 解析日志目标（`src/global.zig:148-155`）。
3. Debug 构建打三行「性能会很差」的警告（`src/main_ghostty.zig:61-65`）。
4. 若存在 CLI action，执行它并 `std.process.exit`（`src/main_ghostty.zig:68-75`）。
5. 若 `build_config.app_runtime == .none`，只打印一段帮助文本后 `exit(0)`，文本明说要启动终端请启动图形应用（`src/main_ghostty.zig:77-97`）。
6. 创建核心 `App`（`src/main_ghostty.zig:100`，实现见 `src/App.zig:77`）。
7. 依次 `apprt.App.init`、可选的 `startQuitTimer`、最后 `apprt.App.run()` 进入 GUI 事件循环（`src/main_ghostty.zig:104-114`）。

### macOS：Swift 应用驱动 Zig 库

1. Swift 的 `main.swift` 先调 `ghostty_init`（`macos/Sources/App/main.swift:8`），C 侧实现同样是 `global.init`，失败返回 1（`src/main_c.zig:110-135`）。
2. 再调 `ghostty_cli_try_action()`（`macos/Sources/App/main.swift:31`）：有 action 就执行并退出进程，没有则直接返回（`src/main_c.zig:139-148`）。这是 `ghostty +version` 一类命令在 macOS 上仍然可用的原因。
3. 然后才进 `NSApplicationMain`（`macos/Sources/App/main.swift:33`）。
4. Swift 侧构造运行时配置（含 `wakeup_cb`、`action_cb`）并调 `ghostty_app_new`（`macos/Sources/Ghostty/Ghostty.App.swift:61-71`），C 侧 `app_new_` 先 `CoreApp.create`，再创建并 `init` embedded 的 `App`（`src/apprt/embedded.zig:1426-1440`）。
5. Swift 的 `appTick()` 调 `ghostty_app_tick`（`macos/Sources/Ghostty/Ghostty.App.swift:107-109`）→ `v.core_app.tick(v)`（`src/apprt/embedded.zig:1444-1448`）→ `App.tick` 的全部工作就是排空 app mailbox（`src/App.zig:156-159`）。

注意：macOS 路径上 `src/main_ghostty.zig:26` 的 `main()` 不是进程入口，上一条链路第 5 步的「打印帮助并退出」只在 exe 形态下成立。macOS 默认 `app_runtime == .none`，而 `build.zig:180-185` 只在 `app_runtime != .none` 时安装可执行文件。

### App.create 里的两个 warmup 线程

`App.create` 在 `init` 之后有条件地起两个 detached 线程做预热：`font.Discover.warmup`（CoreText 之类有毫秒级的一次性启动成本）与 `renderer.Renderer.API.warmup`（如 Metal 的框架初始化成本）。两者都由 `@hasDecl` 守卫，后端没有声明就不起线程（`src/App.zig:85-105`）。

## 每个 surface 的线程模型

### 线程清单

| 线程名      | 启动位置                        | 入口                                    | 职责                             |
| ----------- | ------------------------------- | --------------------------------------- | -------------------------------- |
| 主线程      | apprt 事件循环                  | `Surface.init`（`src/Surface.zig:466`） | 输入分发、apprt action、绘制转发 |
| `renderer`  | `src/Surface.zig:724-729`       | `src/renderer/Thread.zig:216`           | 更新帧数据并绘制                 |
| `io`        | `src/Surface.zig:732-737`       | `src/termio/Thread.zig:136`             | 写 pty、处理模式变化             |
| `io-reader` | `src/termio/Exec.zig:140-145`   | `src/termio/Exec.zig:1411` / `:1777`    | VT 解析热路径                    |
| `io-gather` | `src/termio/Exec.zig:1461-1474` | `src/termio/Exec.zig:1525`              | 仅 POSIX，独占 fd 轮询与采集     |
| `search`    | `src/Surface.zig:4991-4996`     | `src/terminal/search/Thread.zig:133`    | 按需创建的搜索线程               |

`Surface` 上对应的字段是 `renderer_thr`（`src/Surface.zig:95`）、`io` / `io_thread` / `io_thr`（`src/Surface.zig:127-129`）与 `search`（`src/Surface.zig:178`）。搜索线程是按需创建的：首次需要时才 spawn 并命名为 `search`（`src/Surface.zig:4991-4996`），传入的搜索文本长度为 0 表示停止搜索；`Search` 结构由 `state` 与 `thread` 两个字段组成，`deinit` 先 notify stop 再 join，最后才 deinit 状态（`src/Surface.zig:203-220`）。

### Surface.init 的装配顺序

线程不是一上来就起的，`Surface.init`（`src/Surface.zig:466`）按固定顺序把状态铺好再 spawn：

1. 构造渲染器实例，随后单独 `alloc.create` 一把 `std.Io.Mutex` 用于保护渲染状态（`src/Surface.zig:567-570`）。
2. 把这把锁与 `&self.io.terminal` 一起填进 `renderer_state`（`src/Surface.zig:609-612`）。
3. 用 `termio.Mailbox.initSPSC` 建 IO 信箱（`src/Surface.zig:674`）。
4. 调 `termio.Termio.init`，把 `renderer_state`、`renderer_wakeup`、`renderer_mailbox`、`surface_mailbox` 一并注入（`src/Surface.zig:677-687`）。
5. 通过 `rt_app.performAction` 报告 `.cell_size` 与 `.size_limit`（`src/Surface.zig:693-710`）。
6. 在主线程上调 `renderer_impl.finalizeSurfaceInit`，注释说明 retina 相关设置必须在起渲染线程之前于主线程完成（`src/Surface.zig:720-722`）。
7. 最后才依次 spawn 渲染线程与 IO 线程（`src/Surface.zig:724-737`）。

### 架构图

```text
                       ┌──────────────────────────────────────┐
                       │  主线程（apprt 事件循环）             │
                       │  App.drainMailbox / Surface.init      │
                       └───▲───────────────┬──────────────────┘
              app mailbox  │               │ apprt action
                           │               ▼
                       ┌───┴──────────────────────────────────┐
                       │  Surface（核心）                      │
                       │  renderer_state (mutex + terminal)    │
                       └───┬───────────────┬──────────────────┘
        renderer mailbox   │               │  termio mailbox
        + renderer_wakeup  │               │  (spsc + wakeup)
                           ▼               ▼
                    ┌────────────┐   ┌────────────┐
                    │  renderer  │   │     io     │──── 写 pty
                    └────────────┘   └────────────┘
                           ▲
                           │ renderer_wakeup.notify()
                    ┌──────┴─────┐   ┌────────────┐
                    │ io-reader  │◀──│ io-gather  │──── 读 pty
                    │  (parse)   │   │  (POSIX)   │
                    └────────────┘   └────────────┘
```

图中只出现上表已核实的线程名与下一章已核实的通道名。

### 读线程为什么是两条

POSIX 下 `ReadThread` 被拆成 gather 与 parse 两级。gather 线程独占所有 fd 监控（含 quit fd），把数据填进固定环形缓冲；parse 阶段就是 `io-reader` 线程本身，逐批调 `Termio.processOutput`（`src/termio/Exec.zig:1480-1494`）。关键常量都带注释说明取值理由（`src/termio/Exec.zig:1304-1356`）：

- **`buffer_count = 4`** — gather 最多领先 parse 4 批，再多就阻塞，从而经内核 pty 队列对子进程维持流控。
- **`buffer_capacity = 64 * 1024`** — 一批也是 parse 每次持锁的工作量，同时限定 gather 延迟与锁持有时间。
- **`bridge_threshold = 1024`**、**`bridge_spin_max = 16`**、**`bridge_poll_timeout_ms = 1`**、**`gather_budget_ns = 3ms`** — 用于在饱和流的内核队列补给间隙里短暂自旋而不睡眠。

Windows 上没有 gather 线程，`threadMainWindows` 直接读完就调 `Termio.processOutput`（`src/termio/Exec.zig:1788-1811`）。

### IO 写线程做什么

`src/termio/Thread.zig` 的 `//!` 自述得很直接：它是「writer」线程，reader 侧由 `Termio` 自身与具体后端负责；写线程除了把字节写进 pty，还处理启动同步输出、切换 linefeed 之类的模式变化，目的是把工作从 reader 线程这条 VT 解析热路径上卸下来（`src/termio/Thread.zig:1-11`）。它有三个时间常量（`src/termio/Thread.zig:27-41`）：

- **`Coalesce.min_ms = 25`** — resize 一类消息的合并窗口，注释注明并非所有消息类型都会被合并。
- **`sync_reset_ms = 1000`** — 运行中的程序若没有自己复位同步输出标志，多久后强制复位。
- **`selection_scroll_ms = 15`** — 选区滚动时每次移动的间隔。

线程主体在 `threadMain_` 里：Darwin 下用 `pthread_setname_np` 命名为 `io`，设置崩溃元数据，取出 mailbox（`switch` 只有 `.spsc` 一个分支，另一个被注释掉了），装上 mailbox wakeup 与 stop 两个 async，然后 `loop.run(.until_done)`（`src/termio/Thread.zig:237-280`）。

### 渲染线程的定时器

渲染线程有两个常量：`DRAW_INTERVAL = 8`（注释写 120 FPS）与 `CURSOR_BLINK_INTERVAL = 600`（`src/renderer/Thread.zig:21-22`）。线程内部跑一个 libxev 事件循环：`threadMain_` 在 Darwin 上用 `pthread_setname_np` 命名为 `renderer`，设置崩溃元数据与线程 QoS，装上 `wakeup` / `stop` / `draw_now` 三个 async，先 notify 一次立即渲染，再启动光标闪烁定时器与绘制定时器，最后 `loop.run(.until_done)`（`src/renderer/Thread.zig:224-278`）。

### GTK 例外

`drawFrame` 在不可见时不画；渲染器自带 vsync 时只有 `now` 为真才画；`must_draw_from_app_thread` 为 `true` 时不直接画，而是给 app mailbox 推一条 `redraw_surface`（`src/renderer/Thread.zig:527-544`）。该常量取自 `apprt.App` 的同名声明，缺省 `false`（`src/renderer/Thread.zig:24-32`），GTK 侧把它声明为 `true`，注释说明原因是 GTK 的 `GLArea` 不支持跨线程绘制（`src/apprt/gtk/App.zig:21-24`）。

## 消息通道（mailbox）

四条通道里有三条各自持有一个真实队列，底层都是同一个 `BlockingQueue`（`src/datastruct/blocking_queue.zig:29`，由 `src/datastruct/main.zig:10` 再导出），容量一律硬编码 64；第四条（surface mailbox）没有自己的队列。`BlockingQueue` 的 `//!` 与文档注释写明设计取舍：固定大小、没有阻塞 pop（靠外部事件循环通知）、提供一次性 drain（`src/datastruct/blocking_queue.zig:1-27`）。

- **app mailbox** — 类型是 `BlockingQueue(App.Message, 64)`；`push` 之后会调 `self.rt_app.wakeup()` 唤醒应用循环（`src/App.zig:609-625`）。消息类型有 `open_config`、`new_window`、`close`、`quit`、`surface_message`、`redraw_surface`（`src/App.zig:569-606`），由 `App.drainMailbox` 在主线程排空；收到 `quit` 会立刻短路返回，把剩余消息推迟到下一 tick（`src/App.zig:265-288`）。
- **surface mailbox** — `apprt.surface.Mailbox` 并不是独立队列：它的 `push` 把消息包成 `App.Message.surface_message` 再投给 app mailbox，注释说明 surface 消息实际是在 app 线程上实现的（`src/apprt/surface.zig:135-155`）。消息类型定义在 `src/apprt/surface.zig:14` 起的 union 里。
- **renderer mailbox** — `BlockingQueue(rendererpkg.Message, 64)`，注释说容量目前硬编码（`src/renderer/Thread.zig:34-37`）。消息成员包括 `crash`、`focus`、`visible`、`reset_cursor_blink`、`font_grid`、`resize`、`change_config`、`search_viewport_matches`、`search_selected_match`、`inspector`、`macos_display_id`（`src/renderer/message.zig:10-68`）。唤醒与停止各有一个 `xev.Async`：`wakeup` 可以从任意线程安全地强制渲染，`stop` 在下一轮循环停止渲染器（`src/renderer/Thread.zig:47-54`）。
- **termio mailbox** — `termio.Mailbox` 是个 union，目前只有 `spsc` 变体：一个 `BlockingQueue(termio.Message, 64)` 加一个 `xev.Async` wakeup（`src/termio/mailbox.zig:11-45`）。由 `Surface.init` 用 `initSPSC` 建立（`src/Surface.zig:674`）。队列满时的行为有明确实现：先用 `.instant` 尝试入队，失败则唤醒写线程、临时解开渲染状态锁、再以 `.forever` 重试；若仍返回 0 就丢弃消息（`src/termio/mailbox.zig:63-98`）。

汇总一下四条通道：

| 通道             | 类型                                  | 消费者   | 唤醒方式           |
| ---------------- | ------------------------------------- | -------- | ------------------ |
| app mailbox      | `BlockingQueue(App.Message, 64)`      | 主线程   | `rt_app.wakeup()`  |
| surface mailbox  | 无独立队列，转投 app mailbox          | 主线程   | 同上               |
| renderer mailbox | `BlockingQueue(renderer.Message, 64)` | 渲染线程 | `xev.Async` wakeup |
| termio mailbox   | `BlockingQueue(termio.Message, 64)`   | IO 线程  | `xev.Async` wakeup |

出处依次为 `src/App.zig:611`、`src/apprt/surface.zig:145-153`、`src/renderer/Thread.zig:37`、`src/termio/mailbox.zig:15`。此外渲染线程还有一条不经过队列的裸唤醒通道 `renderer_wakeup`，`Termio` 每次处理输出时直接 notify 它（`src/termio/stream_handler.zig:99-101`）。

`Termio` 同时握着三个出口——`renderer_state`、`renderer_wakeup`、`renderer_mailbox` 与 `surface_mailbox`（`src/termio/Termio.zig:46-62`），全部在 `Surface.init` 里一次性注入（`src/Surface.zig:677-687`）。

## apprt action：核心回调 apprt 的单向通道

- `Target` 是 `union(Key){ app, surface: *CoreSurface }`，并带一套 C ABI 镜像 `Target.C` / `CValue` 与 `cval()` 转换，注释标注要与 `ghostty_target_s` 保持同步（`src/apprt/action.zig:16-52`）。
- `Action` 的文档注释写得很清楚：action 是发给应用运行时触发某种行为的**单向**消息；重要的是 action 对 apprt 一般是**可选**实现的，必需功能会直接调用 runtime 结构上的函数，未实现就是编译错误（`src/apprt/action.zig:54-62`）。
- macOS 侧通过 `action_cb` 回调接收（`macos/Sources/Ghostty/Ghostty.App.swift:62`）。
- 一个具体例子：`Surface.init` 在创建期间就通过 `rt_app.performAction` 报告 `.cell_size` 与 `.size_limit`（`src/Surface.zig:693-710`）。

apprt 侧如何消费这些 action，见 [platform-and-config.md](platform-and-config.md)。

## 数据流：按键进去，像素出来

### 输入方向（按键到 pty）

以 macOS 路径为例：

1. `ghostty_surface_key` 收到原始按键，转调 `surface.app.keyEvent`（`src/apprt/embedded.zig:1785-1796`）。
2. `embedded.App.keyEvent` 把 C 事件转成 `input.KeyEvent`，按 target 分派给 `CoreApp.keyEvent` 或 `core_surface.keyCallback`，再把 `InputEffect` 折成 bool（`src/apprt/embedded.zig:184-210`）。
3. app 级：`App.keyEvent` 忽略 release 事件，直接查顶层键绑定集合（不支持序列）；未聚焦时只处理 global 绑定，global 绑定走 `performAllChainedAction`（`src/App.zig:360-400`）。
4. surface 级：`Surface.keyCallback`（`src/Surface.zig:2674`）先做按键重映射，再试键绑定 `maybeHandleBinding`（`src/Surface.zig:2719`）。
5. 没被绑定消费就调 `encodeKey` 编码（`src/Surface.zig:2822-2825`），结果按 small/stable/alloc 转成 `write_small` / `write_stable` / `write_alloc` 交给 `queueIo`；若子进程已退出则改为关闭 surface 并返回 `.closed`（`src/Surface.zig:2826-2839`）。
6. `Surface.queueIo` 是所有发往 IO 线程消息的唯一出口，readonly 模式在这里丢弃三种写消息，最后调 `self.io.queueMessage`（`src/Surface.zig:867-888`）。
7. `Termio.queueMessage` 入队并 notify；`MutexState` 为 `.locked` 时把 `renderer_state.mutex` 传给 mailbox，以便队列满时临时解锁重试（`src/termio/Termio.zig:397-407`）。
8. IO 线程的 `drainMailbox`（`src/termio/Thread.zig:290`）取出消息，把三种写请求转成 `io.queueWrite`（`src/termio/Thread.zig:342-359`）→ `Termio.queueWrite`（`src/termio/Termio.zig:416-423`）→ 后端 `Exec.queueWrite` 写入 pty（`src/termio/Exec.zig:403`）。
9. 收尾：非修饰键会在持锁下按配置清选区、滚到底，并 `queueRender`（`src/Surface.zig:2848-2861`）。

### 输出方向（pty 到屏幕）

1. gather 线程轮询并读取 pty，把数据填进环形缓冲的一批（`src/termio/Exec.zig:1525`）。
2. parse 阶段取出一批，在锁外拿到切片后调 `io.processOutput(batch)`（`src/termio/Exec.zig:1480-1494`）。
3. `Termio.processOutput` 取 `renderer_state.mutex`（普通 `lockUncancelable` / `unlock`），再调 `processOutputLocked`（`src/termio/Termio.zig:647-653`）。
4. `processOutputLocked` 先 `queueRender()`（`src/termio/Termio.zig:658`，实现就是 `renderer_wakeup.notify()`，见 `src/termio/stream_handler.zig:99-101`），再做 500ms 节流的 `reset_cursor_blink` 推送，然后喂 `terminal_stream.nextSlice(buf)` 更新终端状态（`src/termio/Termio.zig:695`）；有 inspector 时退化成逐字节慢路径（`src/termio/Termio.zig:681-693`）。若解析过程中产生了发往写线程的消息，结尾会 `mailbox.notify()`（`src/termio/Termio.zig:698-703`）。
5. 回到 parse 循环，在每个批次边界调 `yieldToDemand` 让渡锁（`src/termio/Exec.zig:1515-1517`）。
6. 渲染线程被 `wakeup` 唤醒：`wakeupCallback` 先 `drainMailbox`，随后立刻调用 `renderCallback`，再触发 scrollback 压缩调度（`src/renderer/Thread.zig:546-569`）。
7. `renderCallback` 不可见时直接 disarm，否则调 `Renderer.updateFrame` 再 `drawFrame(false)`（`src/renderer/Thread.zig:633-661`）。`updateFrame` 定义在 `src/renderer/generic.zig:1144`，快照临界区用 `lockDemand` / `unlockDemand` 包住（`src/renderer/generic.zig:1193-1194`），并在 `synchronized_output` 模式下直接跳过本帧（`src/renderer/generic.zig:1197-1200`）。
8. `drawFrame` 真正提交绘制；GTK 上改为经 app mailbox 绕回主线程（`src/renderer/Thread.zig:527-544`）。

快照之后如何变成三角形与字形（glyph），见 [rendering-and-font.md](rendering-and-font.md)。

### 数据流图

```text
keyboard ─▶ apprt ─▶ Surface.keyCallback ─▶ queueIo ─▶ termio mailbox
                                                            │
                                                            ▼
                                                     io thread ─▶ pty ─▶ child

child ─▶ pty ─▶ io-gather ─▶ io-reader (parse)
                                   │
                                   │ 持 renderer_state.mutex
                                   ▼
                              Terminal 状态更新
                                   │ renderer_wakeup.notify()
                                   ▼
                            renderer thread ─▶ updateFrame ─▶ drawFrame ─▶ GPU
```

## 共享状态与锁

`renderer.State` 的注释明确：`mutex` 只保护成员**值**（`terminal`、`inspector`、`preedit`、`mouse`），State 结构本身不是线程安全的（`src/renderer/State.zig:13-34`）。

问题出在锁的公平性。`lockDemand` 的注释原文指出：`std.Thread.Mutex` 与 os_unfair_lock 都不公平，一个解锁后立刻重锁的运行线程每次都会赢过必须先被唤醒和调度的等待者；在持续 pty 输出下 IO parse 线程正是这样一个热循环，没有额外信号渲染器就会一直被饿死（`src/renderer/State.zig:54-66`）。

解法是三个函数配两个原子计数：

| 成员 / 函数          | 位置                            | 作用                                            |
| -------------------- | ------------------------------- | ----------------------------------------------- |
| `demand`             | `src/renderer/State.zig:36-40`  | 正在通过 `lockDemand` 等锁的线程数              |
| `handoff_gen`        | `src/renderer/State.zig:42-45`  | 交接代数计数，配 futex 唤醒                     |
| `handoff_timeout_ns` | `src/renderer/State.zig:47-52`  | 1ms，界定 parse 线程最长停顿                    |
| `lockDemand`         | `src/renderer/State.zig:67-72`  | 加锁前后增减 `demand`                           |
| `unlockDemand`       | `src/renderer/State.zig:76-80`  | 解锁后递增 `handoff_gen` 并 `futexWake`         |
| `yieldToDemand`      | `src/renderer/State.zig:91-105` | 不持锁时若有 demand 就 futex 等到交接完成或超时 |

全仓只有两处使用这套机制：渲染器的帧快照用 `lockDemand` / `unlockDemand`（`src/renderer/generic.zig:1193-1194`），读线程在批次边界用 `yieldToDemand`（`src/termio/Exec.zig:1517` 与 `src/termio/Exec.zig:1810`）。

注意 `Termio.processOutput` 用的是普通 `mutex.lockUncancelable` / `unlock`（`src/termio/Termio.zig:650-651`），所以让渡发生在**批次之间**而不是批次之中。换句话说，`lockDemand` 与 `yieldToDemand` 是一对约定：只有 parse 线程主动在批次边界让路，渲染器的 `lockDemand` 才能及时拿到锁；任何新加入这条热路径的代码都必须遵守同一约定。

搜索线程对这把锁的使用方式本文不作断言（未核实：未阅读 `src/terminal/search/Thread.zig` 的加锁实现，核实方式是通读该文件中对 `renderer_state` 或 terminal 指针的访问）。

## 两个 libghostty：命名陷阱

仓库里有两样东西名字都带 libghostty，但它们不共用头文件、也不共用构建路径。

**libghostty-vt** 是独立的纯终端库。Zig 模块入口是 `src/lib_vt.zig`（517 行），其 `//!` 注释自述这是 ghostty-vt 的公共 API，并警告 API 不保证稳定（功能稳定，但函数与类型可能无预警变化，`src/lib_vt.zig:1-9`）。往 C API 加函数的四步流程写在 `src/terminal/c/AGENTS.md:6-13`：先在 `src/terminal/c/<module>.zig` 定义，再在 `src/terminal/c/main.zig` 用 `pub const` 再导出，然后在 `src/lib_vt.zig` 加带 `ghostty_` 前缀的 `@export`，最后在 `include/ghostty/vt/` 下的头文件里声明。构建开关字段是 `emit_lib_vt`（`src/build/Config.zig:55`），对应的 `b.option` 名为 `emit-lib-vt`（`src/build/Config.zig:82`）。

**GhosttyLib** 则是 macOS 的胶水库。`build.zig` 的注释原文是「This is NOT libghostty (even though its named that for historical reasons). It is just the glue between Ghostty GUI on macOS and the full Ghostty GUI core.」，产物名为 `ghostty-internal.dll` / `ghostty-internal-static.lib` / `ghostty-internal.so` / `ghostty-internal.a`（`build.zig:186-207`）。它对应的头文件是 `include/ghostty.h`（1235 行）。

两者在构建里是互斥的：`app_runtime != .none` 时产出可执行文件，否则且 `!emit_lib_vt` 时才构建 GhosttyLib（`build.zig:179-207`）。其他文档提到「libghostty」时一律回指本节。

## 构建产物矩阵

| 产物                               | 触发条件                                                                  | 出处                                                |
| ---------------------------------- | ------------------------------------------------------------------------- | --------------------------------------------------- |
| 可执行文件 `ghostty`               | `emit_exe`（默认 `!emit_lib_vt`）且 `app_runtime != .none`                | `src/build/Config.zig:405-409`、`build.zig:180-185` |
| GhosttyLib（`ghostty-internal.*`） | `app_runtime == .none` 且 `!emit_lib_vt`                                  | `build.zig:186-207`                                 |
| Ghostty xcframework + macOS app    | `!emit_lib_vt`、target 为 Darwin，且 `emit_xcframework or emit_macos_app` | `build.zig:209-244`、`src/build/Config.zig:510-514` |
| libghostty-vt shared / wasm        | 总是构建；wasm target 走 `initWasm`，否则 `initShared`                    | `build.zig:119-133`                                 |
| libghostty-vt static               | 总是构建；非依赖场景重命名为 `libghostty-vt.a` 或 `ghostty-vt-static.lib` | `build.zig:135-156`                                 |
| libghostty-vt xcframework          | `emit_lib_vt` 且 `emit_xcframework` 且在 Darwin 上构建 Darwin             | `build.zig:158-174`                                 |

`build.zig` 声明的 step 有 `run`、`run-valgrind`、`test`、`test-lib-vt`、`test-valgrind`、`update-translations`、`dist`、`distcheck`（`build.zig:62-79`、`build.zig:111-117`）。具体命令一律见 [preview-manual.md](preview-manual.md)。

## 全局状态与日志

`global.init` 建立的是**进程级**状态。核心注释写明：之所以用全局变量，是因为 C API 需要访问这份状态，其他 Zig 代码永远不应该直接碰它（`src/main_ghostty.zig:27-30`）。两条启动链路（`src/main_ghostty.zig:31` 与 `src/main_c.zig:110-135`）走的是同一个 `global.init`，只是传入的初始化来源不同（`.main` 对 `.c`）。

日志目标由 `GlobalState.Logging` 这个 packed struct 决定：`stderr` 的默认值是 `build_config.app_runtime != .none`（即 lib 形态默认关掉 stderr 日志），`macos` 默认在 Darwin 上开启（`src/global.zig:394-402`）。运行时可以用环境变量 `GHOSTTY_LOG` 覆盖，解析走 `cli.args.parsePackedStruct`（`src/global.zig:148-155`）。

日志级别则与 `GHOSTTY_LOG` 无关：`std_options.log_level` 在 Debug 构建是 `.debug`、其余是 `.info`，注释解释说不降级是为了让昂贵的 debug 日志在非 debug 构建里被优化掉（`src/main_ghostty.zig:201-212`）。Darwin 上 `logFn` 走 unified log，注释里直接给出了查看用的 predicate `subsystem=="com.mitchellh.ghostty"`（`src/main_ghostty.zig:118-132`）；这个 bundle ID 硬编码在 `src/build_config.zig:58`。

## 常见坑 / 注意事项

1. 「libghostty」有两个含义，先看上一章的区分（`build.zig:186-207`）。
2. surface mailbox 不是独立线程队列，`push` 实际投递到 app 线程（`src/apprt/surface.zig:145-153`）。
3. macOS 上进程入口是 Swift 的 `main.swift`，不是 `src/main_ghostty.zig:26`；CLI action 能力来自 `ghostty_cli_try_action()`（`macos/Sources/App/main.swift:31`）。
4. POSIX 下读路径是两条线程（`io-gather` 加 `io-reader`），改读路径要同时考虑（`src/termio/Exec.zig:1461-1474`）。
5. 想在热路径上持 `renderer_state.mutex`，必须先理解 `lockDemand` 语义：用普通 `mutex.unlock` 释放虽然数据安全，但会让停在 `yieldToDemand` 的调用方等满整个 1ms 超时（`src/renderer/State.zig:54-59`）。
6. `Termio.queueWrite` 的文档注释写明：使用 `termio.Thread` 时它只能在 mailbox 线程调用，不在该线程要改用 `queueMessage`（`src/termio/Termio.zig:409-423`）。
7. 三个真实队列（app / renderer / termio）容量都是 64。termio mailbox 满时会唤醒写线程、临时解锁重试，最终仍失败才丢弃消息（`src/termio/mailbox.zig:69-95`）；另外两个信箱的满队列语义本文不作断言（未核实：未逐行阅读 `BlockingQueue.push` 在各 `Timeout` 下的返回语义，核实方式是读 `src/datastruct/blocking_queue.zig` 的 `push` 实现）。
8. `GHOSTTY_LOG` 在执行 CLI action 时会被强制关掉 stderr 输出（`src/global.zig:141`），且不会泄漏给子进程（`src/Surface.zig:648-649`）；`Logging` 的默认值本身也依赖 `app_runtime`（`src/global.zig:395-401`）。
9. 渲染线程不一定自己画。改绘制流程前先确认 `apprt.App.must_draw_from_app_thread`：为 `true` 时 `drawFrame` 只是往 app mailbox 推消息，真正的绘制发生在主线程（`src/renderer/Thread.zig:535-540`）。
10. `Surface.init` 里 `renderer_state` 的 mutex 是 `alloc.create` 出来的独立分配，不是 `Surface` 的内联字段（`src/Surface.zig:567-570`），复制 `Surface` 或移动其地址时要留意。

## 延伸阅读

- 根 [AGENTS.md](../AGENTS.md) 的 Repository Map 与 Architecture at a Glance 两节（`CLAUDE.md` 是指向它的符号链接）。
- [HACKING.md](../HACKING.md)：环境依赖、日志与 lint。
- [src/terminal/c/AGENTS.md](../src/terminal/c/AGENTS.md)、[macos/AGENTS.md](../macos/AGENTS.md)、[src/inspector/AGENTS.md](../src/inspector/AGENTS.md)。
- 其余四篇：[terminal-core.md](terminal-core.md)、[rendering-and-font.md](rendering-and-font.md)、[platform-and-config.md](platform-and-config.md)、[preview-manual.md](preview-manual.md)。
- 写作规范见 [\_conventions.md](_conventions.md)。
