# 应用运行时、配置与输入

> 最后更新对应的 git commit：`f81dcadc8`（`f81dcadc82ea2afdcf2dc92929037701122f05b5`，2026-08-14）
> 校验方式：`git log -1 --format='%H %h %ad %s'`

## 本文覆盖什么

- 应用运行时（apprt）抽象层：comptime 三选一、action 单向通道、surface 消息，以及 `embedded`/`gtk`/`none`/`browser` 四个实现的完整度差异。
- macOS 原生应用的组织方式，以及它与 libghostty 之间的真实边界（`GhosttyKit` 模块，不是 bridging header）。
- 配置系统：`Config` 的「字段即配置项」模式、五级加载顺序、条件配置与主题、C API 与相关 CLI action。
- 键绑定与输入栈的结构：绑定语法、`Binding` 数据结构、按键编码选项、平台默认差异。
- 输入栈的手工验证矩阵（这部分目前完全没有自动化测试）。

## 本文不覆盖什么

- 线程模型、mailbox 全貌与各线程职责 —— 见 `docs/architecture.md`。
- VT 解析、`Screen`/`PageList`、kitty 协议的终端侧状态、libghostty-vt —— 见 `docs/terminal-core.md`。
- 渲染后端、着色器、字体栈 —— 见 `docs/rendering-and-font.md`。
- 所有构建、运行、调试命令的完整用法 —— 见 `docs/preview-manual.md`。
- 具体配置项的取值语义。那属于 Ghostty 官方文档与 `ghostty +show-config --docs` 的范围，本文只讲配置系统本身的机制。

## 一句话概括

同一份 Zig 核心通过 `src/apprt.zig:42-49` 的 comptime 分派长出三个前端：Linux 与 FreeBSD 上是 GObject 化的 GTK4 应用，macOS 上核心只编译成库、由 Swift 应用反过来驱动它，两边共用同一套 action 协议、同一份 `Config` 结构体和同一个键绑定解析器。

## 关键文件地图

| 路径                       | 行数量级 | 职责                                                           |
| -------------------------- | -------- | -------------------------------------------------------------- |
| `src/apprt.zig`            | 59       | apprt 包入口，comptime 选定唯一实现                            |
| `src/apprt/runtime.zig`    | 29       | `Runtime` 枚举与按目标平台的默认值                             |
| `src/apprt/action.zig`     | 1071     | 核心 → apprt 的 action 协议与 C ABI 派生                       |
| `src/apprt/surface.zig`    | 197      | surface 消息联合体、Mailbox、新 surface 配置继承               |
| `src/apprt/structs.zig`    | 114      | 跨实现共享的小结构（`Clipboard`/`CursorPos` 等）               |
| `src/apprt/embedded.zig`   | 2245     | 嵌入式实现 + libghostty 的 `CAPI` 导出面                       |
| `src/apprt/none.zig`       | 19       | 空实现（macOS 默认构建用）                                     |
| `src/apprt/browser.zig`    | 4        | wasm 占位实现                                                  |
| `src/apprt/ipc.zig`        | 252      | 跨进程动作（new window/tab、quick terminal）                   |
| `src/apprt/gtk/`           | 目录     | GTK4 实现，主体在 `src/apprt/gtk/class/` 下的 22 个 GObject 类 |
| `macos/Sources/`           | 目录     | Swift 应用，四个顶层目录 `App`/`Ghostty`/`Features`/`Helpers`  |
| `src/config/Config.zig`    | 11120    | 配置结构体本体，绝大部分是字段文档注释                         |
| `src/input/Binding.zig`    | 4924     | 键绑定解析、`Trigger`、`Action`、查找集合                      |
| `src/input/key_encode.zig` | 2540     | 按键 → pty 字节序列的编码                                      |
| `src/cli/ghostty.zig`      | 330      | `+xxx` 形式的 CLI action 枚举与分派                            |

## apprt：一个核心，三种运行时

### 抽象的定位

`src/apprt.zig:1-10` 的模块自述说明了这层存在的理由：抽象应用运行时与生命周期管理（创建窗口、获取鼠标键盘输入等），使不同实现尽可能共用核心逻辑，只在必要时才触碰平台相关代码。

### comptime 三选一

实现的选择发生在编译期，一次构建只存在一个实现（`src/apprt.zig:38-49`）。

出处：`src/apprt.zig:42-49`

```zig
pub const runtime = switch (build_config.artifact) {
    .exe => switch (build_config.app_runtime) {
        .none => none,
        .gtk => gtk,
    },
    .lib => embedded,
    .wasm_module => browser,
};
```

`build_config.app_runtime` 由构建选项 `-Dapp-runtime` 决定，默认值取自 `ApprtRuntime.default(target.result)`（`src/build/Config.zig:174-178`）。注意 `src/build/Config.zig:180-184` 的 `-Drenderer` 帮助文本误写成 "The app runtime to use"，这是上游的笔误，不影响行为。

### `.none` 不是「无界面」

`Runtime.none` 的注释原文是「Will not produce an executable at all when `zig build` is called. This is only useful if you're only interested in the lib only (macOS).」（`src/apprt/runtime.zig:6-8`）。`default()` 的分支为：Linux 与 FreeBSD 返回 `.gtk`，其余（含 macOS）返回 `.none`，注释说明 macOS 上由 Xcode 构建应用去链接 libghostty（`src/apprt/runtime.zig:14-24`）。

### 各实现的完整度差异

| 实现       | 触发条件                      | 内容                                                                       |
| ---------- | ----------------------------- | -------------------------------------------------------------------------- |
| `gtk`      | `.exe` + `-Dapp-runtime=gtk`  | 完整实现，见下文 GTK 章节                                                  |
| `embedded` | `.lib`                        | 完整实现 + C API 导出面                                                    |
| `none`     | `.exe` + `-Dapp-runtime=none` | 空 `App`/`Surface`，`performIpc` 恒返回 false（`src/apprt/none.zig:8-19`） |
| `browser`  | `.wasm_module`                | 只有 `resourcesDir` 与两个空 struct（`src/apprt/browser.zig:1-4`）         |

## action：核心到 apprt 的单向通道

### Target 与 cval

`Target` 是 `union(Key){ app, surface: *CoreSurface }`（`src/apprt/action.zig:16-19`），`Key` 是 `enum(c_int)` 且注释标明与 `ghostty_target_tag_e` 同步（`:20-28`）。`cval()` 把核心的 `*CoreSurface` 替换成 `v.rt_surface`（apprt 层的 surface 指针）再交给 C（`:43-51`）。

### 关键设计：action 是可选实现的

出处：`src/apprt/action.zig:54-62`

```zig
/// The possible actions an apprt has to react to. Actions are one-way
/// messages that are sent to the app runtime to trigger some behavior.
///
/// Actions are very often key binding actions but can also be triggered
/// by lifecycle events. For example, the `quit_timer` action is not bindable.
///
/// Importantly, actions are generally OPTIONAL to implement by an apprt.
/// Required functionality is called directly on the runtime structure so
/// there is a compiler error if an action is not implemented.
```

这段注释是理解各平台功能差异的钥匙：必需能力直接调用运行时结构体上的函数，缺失会编译报错；而 action 缺失不会报错，只是那个平台没有那个功能。

### C ABI 是自动派生的

- `Action.Key` 是 `enum(c_int)`，共 69 项，从 `quit`（`src/apprt/action.zig:362`）到 `move_tab_to_new_window`（`:430`），并用 `checkGhosttyHEnum` 单测校验与 `ghostty.h` 一致（`:432-434`）。
- `CValue` 用 comptime 反射从 `Key` 生成 extern union，值类型若自带 `C` 声明则用它替代（`:438-459`）。
- 有 `@sizeOf(CValue) == 24` 的 comptime 断言，注释说明当前不承诺 ABI 兼容但要感知变化（`:467-476`）。
- `cval()` 用 `inline else` 逐 tag 转换，值类型若有 `cval` 方法则递归调用（`:489-502`）。

新增 action 的四步流程以注释形式写在 union 开头（`:64-78`），第 4 步明确要求手工更新 `include/ghostty.h` 并保证顺序完全一致。`src/apprt/ipc.zig:56-80` 的 `Action` 有同样的四步指南与同步要求。

### 代表性 action

| action                 | 载荷类型              | 出处                       |
| ---------------------- | --------------------- | -------------------------- |
| `close_tab`            | `CloseTabMode`        | `src/apprt/action.zig:94`  |
| `new_split`            | `SplitDirection`      | `src/apprt/action.zig:98`  |
| `toggle_fullscreen`    | `Fullscreen`          | `src/apprt/action.zig:107` |
| `goto_tab`             | `GotoTab`             | `src/apprt/action.zig:138` |
| `size_limit`           | `SizeLimit`           | `src/apprt/action.zig:160` |
| `inspector`            | `Inspector`           | `src/apprt/action.zig:190` |
| `desktop_notification` | `DesktopNotification` | `src/apprt/action.zig:203` |
| `set_title`            | `SetTitle`            | `src/apprt/action.zig:206` |
| `quit_timer`           | `QuitTimer`           | `src/apprt/action.zig:250` |
| `config_change`        | `ConfigChange`        | `src/apprt/action.zig:296` |

其中两条的注释值得单独看：`quit_timer` 只是「没有 surface 了」的通知，是否退出、延迟多久完全由 apprt 按配置自行决定（`:239-250`）；`config_change` 传的是新配置的指针，只在 action 期间有效，apprt 必须自己拷贝需要的数据（`:284-296`）。

### 谁来调

`App.performAction` 只接受 app 作用域的绑定动作（`input.Binding.Action.Scoped(.app)`），逐个转发给 `rt_app.performAction`；注释说明非 app 作用域的动作要用 `performAllAction` 在所有 surface 上执行（`src/App.zig:449-480`）。

## surface 消息与共享结构

### Message 联合体

`apprt.surface.Message`（`src/apprt/surface.zig:14-132`）里几条值得注意：

- `set_title: [256]u8`（`:23`）带 TODO 注释，说明定长数组是临时方案，将来应改成 `WriteReq` 风格。
- `change_config: *const Config`（`:43`），注释说明指针在收到消息后即失效，必须立即使用或派生。
- `desktop_notification`（`:55-61`）用的是 `[63:0]u8` 标题与 `[255:0]u8` 正文的定长缓冲。
- `child_exited: ChildExited`（`:52`）、`ring_bell`（`:89`）。

### Mailbox 实际走主线程

`Mailbox.push` 会把消息重新包装成 `App.Mailbox` 的 `surface_message` 再发出去，注释明说 surface 消息实际是在主线程上实现的（`src/apprt/surface.zig:139-154`）。线程模型本身见 `docs/architecture.md`。

### 新 surface 的配置继承

`NewSurfaceContext` 是 `enum(c_int){ window = 0, tab = 1, split = 2 }`（`src/apprt/surface.zig:158-162`），`shouldInheritWorkingDirectory` 据此分别读 `window-`/`tab-`/`split-inherit-working-directory` 三个配置项（`:164-170`）。`newConfig` 对配置做 `shallowClone`，并在需要继承时把上一个聚焦 surface 的 pwd 写进 `working-directory`（`:175-197`）。

### structs.zig 的 GTK 特例

`Clipboard` 的底层整数类型在 GTK 构建下是 `c_int`、其余是 `u2`，并且带 `getGObjectType` 以便在 GTK 环境里成为合法 GObject（`src/apprt/structs.zig:38-59`）。这说明共享结构本身也要感知 apprt。

## embedded apprt：Swift 与 Zig 的真正边界

### 定位

`src/apprt/embedded.zig:1-5` 自述：嵌入式版本是「宿主应用拥有生命周期，而不是 Ghostty 自己拥有」，并明确点名 macOS 的 Swift + Xcode 应用。

### `App.Options` 就是 `ghostty_runtime_config_s`

`src/apprt/embedded.zig:30-36` 的注释解释了为什么用 `extern struct`：只在嵌入环境使用，可直接暴露给 C callconv，不付任何转换开销；C 侧类型名就是 `ghostty_runtime_config_s`。字段依次是（`:42-81`）：

- `userdata` — 传给所有回调的用户数据
- `supports_selection_clipboard: bool`
- `wakeup` — 唤醒宿主事件循环，触发一次完整的 app tick
- `action` — 签名 `*const fn (*App, apprt.Target.C, apprt.Action.C) callconv(.c) bool`，上一节整套 action 协议的落地点（`:52-53`）
- `read_clipboard` / `confirm_read_clipboard` / `write_clipboard`
- `close_surface`（可空，默认 null）

### 回调式设计的含义

`App.performAction` 先跑 `performPreAction` 处理本地特例，再调用 `self.opts.action(self, target.cval(), ....cval())`（`src/apprt/embedded.zig:285-305`）。第一个特例是 `set_title`：embedded apprt 自己 dupe 并保存标题，使实现方不必自行保存（`:307-323`），对应的 `Surface.title` 字段注释也说明了这一点（`:439-441`）。

要点是 Zig 侧不知道也不关心 Swift 如何实现，只看回调返回的 bool 表示动作有没有被执行。

### Surface.Options 与 C API 面

`Surface.Options` 是 extern struct（`src/apprt/embedded.zig:444-484`），含 `platform_tag`/`platform`/`userdata`/`scale_factor`/`font_size`/`working_directory`/`command`/`env_vars`/`initial_input`/`wait_after_command`/`context`。`command` 的注释特别指出它总是通过 shell 运行（例如 `/bin/sh -c`），与配置文件里可直接执行命令不同，属于历史遗留（`:462-470`）。

`CAPI` 块从 `src/apprt/embedded.zig:1263` 开始，导出面举例：`ghostty_app_new`（`:1416`）、`ghostty_app_tick`（`:1444`）、`ghostty_surface_new`（`:1554`）、`ghostty_surface_draw`（`:1702`）、`ghostty_surface_key`（`:1785`）。

### 键事件的转换

`App.KeyEvent.core()` 线性遍历 `input.keycodes.entries`，用宿主给的原生 keycode 反查物理键，查不到则落 `.unidentified`；注释说明这是为了「拿到未映射的物理键来处理键绑定」（`src/apprt/embedded.zig:96-118`）。键绑定匹配依赖的是物理键，不是宿主的翻译结果。

## GTK apprt：GObject 化的应用

### 入口很薄，内容在 class/

`src/apprt/gtk.zig:1-10` 只导出三个必需 API（`App`/`Surface`/`resourcesDir`，其中 `resourcesDir` 直接来自 `src/apprt/gtk/flatpak.zig`）与四个自定义 API（`class`/`WeakRef`/`pre_exec`/`post_fork`）。`src/apprt/gtk/App.zig` 是一个持有 `*Application`（GObject）的薄壳，`init`/`run`/`terminate` 全部转发（`src/apprt/gtk/App.zig:33-59`）；`src/apprt/gtk/Surface.zig` 同理只持有 `src/apprt/gtk/class/surface.zig` 的 `Surface`（`src/apprt/gtk/Surface.zig:11-22`）。真正的实现在 `src/apprt/gtk/class/` 下的 22 个文件里，包括 `application.zig`、`window.zig`、`tab.zig`、`surface.zig`、`split_tree.zig`、`command_palette.zig`、`global_shortcuts.zig`、`inspector_window.zig` 等。

### must_draw_from_app_thread

出处：`src/apprt/gtk/App.zig:21-24`

```zig
/// This is detected by the Renderer, in which case it sends a `redraw_surface`
/// message so that we can call `drawFrame` ourselves from the app thread,
/// because GTK's `GLArea` does not support drawing from a different thread.
pub const must_draw_from_app_thread = true;
```

渲染线程侧如何响应这个标志属于渲染路径，见 `docs/architecture.md` 与 `docs/rendering-and-font.md`。

### UI 用 blueprint 描述，按 libadwaita 版本分目录

- 路径规则是 `src/apprt/gtk/ui/{major}.{minor}/{name}.blp`，目录名是该 blueprint 需要的**最低 libadwaita 版本**，不是项目整体的最低要求（`src/apprt/gtk/build/gresource.zig:12-15`）。目前有 `1.0`/`1.2`/`1.3`/`1.4`/`1.5` 五个目录、21 个 `.blp` 文件。
- 注册表硬编码在 `src/apprt/gtk/build/gresource.zig:33-55`，共 21 条。同名可有多版本，例如 `clipboard-confirmation-dialog` 有 1.0 与 1.4 两版（`:34-35`）、`debug-warning` 有 1.2 与 1.3 两版（`:38-39`）。
- `blueprint()` 是 comptime 函数，在注册表里找不到对应项直接 `@compileError("invalid blueprint")`（`:103-123`）。
- 需要 `blueprint-compiler` 0.16.0 或更新版本（`src/apprt/gtk/build/blueprint.zig:31-35`，`HACKING.md:48`）。
- 主题样式是 `src/apprt/gtk/css/` 下的四个文件：`style.css`、`style-dark.css`、`style-hc.css`、`style-hc-dark.css`。

### 窗口协议与外围

`src/apprt/gtk/winproto.zig` 的 `Protocol` 是 `enum { none, wayland, x11 }`（`src/apprt/gtk/winproto.zig:17-21`），分别对应 `src/apprt/gtk/winproto/noop.zig`、`src/apprt/gtk/winproto/wayland.zig`（另有 `src/apprt/gtk/winproto/wayland/` 目录）与 `src/apprt/gtk/winproto/x11.zig`（`src/apprt/gtk/winproto.zig:13-15`）。GTK 目录下另有 `src/apprt/gtk/portal/OpenURI.zig`、`src/apprt/gtk/ipc/DBus.zig` 与三个 IPC 动作实现（`src/apprt/gtk/ipc/new_window.zig`、`src/apprt/gtk/ipc/new_tab.zig`、`src/apprt/gtk/ipc/toggle_quick_terminal.zig`），以及 `src/apprt/gtk/cgroup.zig`、`src/apprt/gtk/gsettings.zig`（这两个文件只确认了存在，实现细节未核实：本次只读到目录清单，核实方式是直接读这两个文件）。

### 版本探测的两套 API

`gtk_version.zig` 与 `adw_version.zig` 都提供 `atLeast` 与 `runtimeAtLeast`。`atLeast` 在 comptime 上下文只检查头文件版本，用于会影响代码生成的场景（例如使用某版本之后才有的符号）；只依赖运行时行为的检查应该用 `runtimeAtLeast`（`src/apprt/gtk/gtk_version.zig:33-47`）。

## macOS 应用：Swift 侧怎么长出来

### 启动顺序

1. `ghostty_init(argc, argv)` 先执行；失败时按 `Ghostty.launchSource` 区分 `.cli`/`.zig_run` 与 `.app` 两种处理，前者向 stderr 打印提示后 `exit(1)`（`macos/Sources/App/main.swift:8-27`）。
2. `ghostty_cli_try_action()` 执行 `+xxx` 形式的 CLI action 并在命中时退出（`macos/Sources/App/main.swift:29-31`）。
3. 最后才是 `NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)`（`macos/Sources/App/main.swift:33`）。

这解释了为什么 macOS 上 `Ghostty.app/Contents/MacOS/ghostty` 同时是 GUI 入口和 CLI 入口。

### 边界不是 bridging header

`macos/Sources/App/ghostty-bridging-header.h` 全文只有两行 import（`ObjCExceptionCatcher.h` 与 `VibrantLayer.h`），都是本地 ObjC 辅助文件，与 libghostty 无关（`macos/Sources/App/ghostty-bridging-header.h:1-4`）。

真实机制是 Swift 侧 `import GhosttyKit`（`macos/Sources/App/main.swift:3`）。该模块由 `include/module.modulemap:4-7` 定义，umbrella header 是 `ghostty.h`；打包产物是 `macos/GhosttyKit.xcframework`（`src/build/GhosttyXCFramework.zig:39-41`）。构建时会特意生成一个只含 `ghostty.h` 与 `module.modulemap` 的 headers 目录，因为直接用 `include/` 会把 `include/ghostty/` 下的 libghostty-vt 头也带进来，触发 Clang 模块系统的 umbrella 警告（`src/build/GhosttyXCFramework.zig:27-35`）。`include/ghostty.h` 共 1235 行。

### 运行时配置在 Swift 侧的样子

`Ghostty.App.init` 构造 `ghostty_runtime_config_s`，六个回调（`wakeup_cb`/`action_cb`/`read_clipboard_cb`/`confirm_read_clipboard_cb`/`write_clipboard_cb`/`close_surface_cb`）都是闭包转发到静态方法，`userdata` 用 `Unmanaged.passUnretained(self).toOpaque()`（`macos/Sources/Ghostty/Ghostty.App.swift:58-68`）；随后 `ghostty_app_new(&runtime_cfg, config.config)` 并立即 `ghostty_app_set_focus(app, NSApp.isActive)`（`:71-78`）。`appTick()` 就是 `ghostty_app_tick`（`:107-110`）。

### action 的 Swift 落点

`static func action(_:target:action:)`（`macos/Sources/Ghostty/Ghostty.App.swift:448`）先校验 target tag，再对 `action.tag` 做一个大 switch（`:460` 起）。该文件中 `case GHOSTTY_ACTION_` 共出现 63 次，而 Zig 侧 `Action.Key` 有 69 项（`src/apprt/action.zig:362-430`）——这正是「action 可选实现」的直接证据。两个数字都是本次核实时的快照，会随开发变化。

### 目录组织

| 目录                      | 内容                                                                                                                                                                                                    |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `macos/Sources/App/`      | `main.swift`、`AppDelegate.swift`(1390 行)、`AppDelegate+Ghostty.swift`、`MainMenu.xib`、bridging header                                                                                                |
| `macos/Sources/Ghostty/`  | C API 的 Swift 封装层：`Ghostty.App.swift`(2312)、`Ghostty.Input.swift`(1315)、`Ghostty.Config.swift`(918)、`Ghostty.Action.swift`、`Ghostty.Surface.swift`，以及 `Surface View/`                       |
| `macos/Sources/Features/` | 14 个功能模块目录：About、App Intents、AppleScript、ClipboardConfirmation、Command Palette、Custom App Icon、Global Keybinds、QuickTerminal、Secure Input、Services、Settings、Splits、Terminal、Update |
| `macos/Sources/Helpers/`  | 通用工具                                                                                                                                                                                                |

macOS 的全局键绑定用 `CGEventTap` 实现，`GlobalEventTap` 是单例并在轮询到辅助功能权限后才启用 event tap（`macos/Sources/Features/Global Keybinds/GlobalEventTap.swift:10-23`）。

### 构建纪律

`macos/AGENTS.md:3-11` 规定的四条纪律（不是教程，命令完整用法见 `docs/preview-manual.md`）：

1. 用 `swiftlint` 格式化与检查 Swift 代码。
2. 若修改了 `macos/` 之外的代码，先跑 `zig build -Demit-macos-app=false` 更新底层库，再构建 macOS 应用。
3. 用 `macos/build.nu` 构建应用而不是 `zig build`；产物在 `macos/build/<configuration>/Ghostty.app`。
4. 单元测试用 `macos/build.nu --action test`。

`build.nu` 的机制：用 `env -i` 清空环境（注释说明是为了避免 Nix shell 的 `NIX_LDFLAGS`/`NIX_CFLAGS_COMPILE` 干扰）后调 `xcodebuild`，`SYMROOT` 指向 `macos/build`；`--action test` 时自动追加 `-skip-testing GhosttyUITests`，因为 UI 测试需要特殊权限（`macos/build.nu:3-31`）。

### AppleScript 与 App Intents

`macos/Polter.sdef:5-297` 的 Ghostty Suite 含 4 个 class（`application`/`window`/`tab`/`terminal`）、1 个 record-type（`surface configuration`）、4 个 enumeration（split direction/input action/mouse button/scroll momentum）和 16 条 command；`:298` 之后是 Standard Suite。

`macos/AGENTS.md:19-23` 硬性规定 sdef 顶层定义顺序必须是 Classes → Records → Enums → Commands。入口与对象访问器要用 `NSApp.isAppleScriptEnabled` 与 `NSApp.validateScript(command:)` 守卫（`macos/AGENTS.md:16-18`，实际用法可见 `macos/Sources/Features/AppleScript/ScriptTerminal.swift:37`），整体受配置项 `macos-applescript` 控制，默认 `true`（`src/config/Config.zig:3489`）。测试时 `osascript` 必须用 app bundle 的绝对路径而不是应用名，以免打到错误的应用（`macos/AGENTS.md:24-34`）。

App Intents 是另一套机制，位于 `macos/Sources/Features/App Intents/`，含 8 个 `*Intent.swift` 文件、`GhosttyIntentError.swift`、`IntentPermission.swift`，以及 `Entities/` 下的 `CommandEntity.swift` 与 `TerminalEntity.swift`。

## 配置系统：字段即配置项

### Config.zig 的结构约定

`src/config/Config.zig:1-9` 的文件头注释说明两件事：字段名直接映射 CLI flag 名，所以大量使用 `@""` 语法支持连字符；字段的文档注释必须用 Pandoc 风格 Markdown，因为要拿去自动生成 man page 与其他文档。

全文 11120 行，绝大部分是文档注释。以 `keybind` 为例：文档从 `src/config/Config.zig:1591` 开始，字段声明在 `:1937`，中间约 346 行都是语法说明。

### 内部字段以下划线开头

`_arena`（`:3909`）、`_diagnostics`（`:3913`）、`_conditional_state`（`:3917`）、`_conditional_set`（`:3921`）、`_replay_steps`（`:3926`）、`@"_xdg-terminal-exec"`（`:3929`）。

这个下划线约定是 API 契约而不是私有习惯，被两处工具消费：`src/config/key.zig:12-20` 从 `std.meta.fields(Config)` 反射生成 `Key` 枚举时跳过 `_` 开头的字段；`src/helpgen.zig:38-40` 生成帮助文本时同样跳过。

### 加载顺序

`Config.load()` 的文档注释直接给出五级顺序（`src/config/Config.zig:3936-3959`）：

1. 默认值（`default()`，`src/config/Config.zig:3961`）
2. XDG config 目录
3. macOS 的 Application Support 目录
4. CLI flags（`loadCliArgs`，`:4208`）
5. 递归定义的配置文件（`loadRecursiveFiles`）

最后调用 `finalize()`（`:3956`）。

### 配置文件位置

| 平台              | 新名（1.3.0 起）         | 旧名（<1.3.0）   | 出处                             |
| ----------------- | ------------------------ | ---------------- | -------------------------------- |
| 全平台 XDG        | `ghostty/config.ghostty` | `ghostty/config` | `src/config/file_load.zig:12-34` |
| macOS App Support | `config.ghostty`         | `config`         | `src/config/file_load.zig:63-71` |

`preferredDefaultFilePath` 在 macOS 上优先 Application Support，其次 XDG，两者都不存在时返回 Application Support；其他平台只用 XDG（`src/config/file_load.zig:105-130`）。

新旧两份同时存在时会打两条 warn 并按「先旧后新」的顺序都加载（`src/config/Config.zig:4141-4152`）。一份都不存在时会写一个模板配置文件（`:4191-4204`）。

### 条件配置

设计取向写在 `src/config/conditional.zig:5-8`：基于静态的、有类型的世界状态，而不是动态 key-value 集合，理由是简化实现、更好的类型检查，以及支持类型化的 C API。

`State` 目前只有两个字段：`theme`（`light`/`dark`）与 `os`（默认为构建目标 OS）（`src/config/conditional.zig:9-16`）。`Conditional` 结构是 `{ key, op, value }`，`Op` 只有 `eq`/`ne`（`:55-60`）。

状态变化时不重读文件：`changeConditionalState` 先比对 `_conditional_set` 里用到的 key 是否真的变了，没变直接返回 null；变了则 `cloneEmpty` 后用 `_replay_steps` 重放重建整份配置并 `finalize`（`src/config/Config.zig:4443-4484`）。`_replay_steps` 的注释解释了动机：可以在不重新打开文件的情况下重载配置，即使中途文件被删掉（`:3923-3926`、`:4440-4442`）。

### 主题

- `theme` 字段声明在 `src/config/Config.zig:597`，类型是含 `light`/`dark` 两个 `[]const u8` 字段的 struct（`src/config/Config.zig:9941-9943`）。`parseCLI` 支持用逗号、等号或冒号分隔的 `light:dark` 成对写法；Windows 下 index 为 1 的冒号按盘符处理，不触发成对解析（`src/config/Config.zig:9945-9962`）。
- 主题搜索位置的枚举顺序即优先级：`user`（XDG config 目录）在前，`resources`（Ghostty 资源目录）在后（`src/config/theme.zig:8-13`）。
- `loadTheme` 的做法（`src/config/Config.zig:4521-4615`）：先把主题文件加载进一份新 config，再把主题带来的每条 `arg` 改写成「仅在当前 theme 条件下生效」的 conditional 步骤，最后重放用户原有配置压在主题之上。遇到 `-e` 步骤就停止改写，以免污染初始命令（`:4570-4573`）。
- `finalize()` 先执行 `loadTheme`，并带一条大写 Warning 注释说明它会 deinit 并替换整个 config；若 light 与 dark 主题不同，会把 `window-theme = auto` 强制改成 `system`，并把 `.theme` 插入 `_conditional_set`（`:4619-4638`）。

### 文档由字段注释生成

`src/helpgen.zig` 用 `std.zig.Ast.parse` 直接解析 `src/config/Config.zig` 的源码抽取每个字段的文档注释（`src/helpgen.zig:27-41`）；同一个程序还生成 CLI action 与键绑定 action 的帮助（`:21-23`）。产物经 `src/build/HelpStrings.zig:12-51` 变成名为 `help_strings` 的匿名模块，又被 `src/config/Config.zig:34` 反过来 import。这就是 `+show-config --docs` 与 `+explain-config` 有文档可显示的来源。

### C API 与 CLI

`src/config/CApi.zig` 的导出面：`ghostty_config_new`（`:15`）、`_free`（`:30`）、`_clone`（`:38`）、`_load_cli_args`（`:54`）、`_load_default_files`（`:63`）、`_load_file`（`:71`）、`_finalize`（`:87`）、`_get`（`:93`）、`_diagnostics_count`（`:124`）、`_get_diagnostic`（`:128`）。Swift 侧 `Ghostty.Config` 持有 `ghostty_config_t`，`errors` 属性通过后两个函数读取诊断（`macos/Sources/Ghostty/Ghostty.Config.swift:22-34`）。

`src/config/c_get.zig:9-16` 的注释很重要：`get()` 返回 false 表示该 key 尚未被 C API 支持，这是可修复的问题、需要时应开 issue。也就是说 C API 覆盖的配置 key 是 Zig 侧的一个子集。

配置相关的 CLI action（枚举见 `src/cli/ghostty.zig:31-87`）：

| action             | 说明                                                        | `Options` 字段                                                                                        |
| ------------------ | ----------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| `+show-config`     | 把配置输出到 stdout（`src/cli/ghostty.zig:63`）             | `--default`、`--changes-only`（默认 true）、`--docs`、`--no-pager`（`src/cli/show_config.zig:10-23`） |
| `+explain-config`  | 解释单个配置项或键绑定动作（`src/cli/ghostty.zig:66`）      | `--option`、`--keybind`（`src/cli/explain_config.zig:12-21`）                                         |
| `+validate-config` | 校验配置文件（`src/cli/ghostty.zig:69`）                    | `--config-file`，不传则校验默认路径（`src/cli/validate_config.zig:8-11`）                             |
| `+edit-config`     | 用 `$VISUAL`/`$EDITOR` 打开配置（`src/cli/ghostty.zig:60`） | `Options` 为空结构体；编辑后不会自动重载配置（`src/cli/edit_config.zig:12-31`）                       |
| `+list-themes`     | 列出可用主题（`src/cli/ghostty.zig:45`）                    | `--path`、`--plain`、`--color`（默认 `all`）（`src/cli/list_themes.zig:21-29`）                       |

`openPath()`（`src/config/edit.zig:21`）的注释说明了平台差异：Linux 只有 XDG 路径有效；macOS 因为优先 App Support，所以按「App Support 存在 → XDG 存在 → 都不存在则 App Support」的顺序决定，且存在性判断偏好非空文件（`src/config/edit.zig:9-20`）。

CLI 参数也能通过 `zig build run` 转发：`app_runtime` 非 `.none` 时走 `run_cmd.addArgs(args)`（`build.zig:250`），macOS 的 `.none` 路径则由 open step 追加（`src/build/GhosttyXcodebuild.zig:161-163`），后者还会强制设置 `GHOSTTY_LOG=stderr,macos` 与 `GHOSTTY_MAC_LAUNCH_SOURCE=zig_run`（`:156-159`）。命令用法见 `docs/preview-manual.md`。

## 输入与键绑定

### 导出面与平台差异

`src/input.zig` 汇出 `Binding`/`Trigger`/`Key`/`Mods`/`KeyEvent`/`key_encode`/`kitty`/`function_keys`/`keycodes` 等（`src/input.zig:10-37`）。`Keymap` 只有 macOS 有真实实现（`KeymapDarwin.zig`，289 行），其余平台是 `KeymapNoop.zig`（39 行），注释说明理论上 Linux 可以用 XKB 实现但目前不需要（`src/input.zig:39-44`）。

### 键绑定语法

以下均出自 `keybind` 字段的文档注释：

| 规则                                                                                                 | 出处                              |
| ---------------------------------------------------------------------------------------------------- | --------------------------------- |
| 格式 `trigger=action`，重复 trigger 后者覆盖前者                                                     | `src/config/Config.zig:1591-1593` |
| 键可写成 Unicode 码点（随键盘布局变化）或 W3C 物理键码 `KeyA`（也支持 snake_case 的 `key_a`）        | `src/config/Config.zig:1598-1630` |
| 物理键匹配优先级永远高于 Unicode 码点，与配置顺序无关                                                | `src/config/Config.zig:1635-1637` |
| 码点匹配大小写不敏感、按未修饰码点比较，故美式键盘上 `ctrl+_` 不可能触发                             | `src/config/Config.zig:1604-1618` |
| `catch_all` 匹配任何未被绑定的键；先试带修饰的，再回退到不带修饰的                                   | `src/config/Config.zig:1639-1644` |
| 修饰键与别名：`shift`、`ctrl`(control)、`alt`(opt/option)、`super`(cmd/command)；`fn`/globe 键不支持 | `src/config/Config.zig:1646-1653` |
| 用 `>` 分隔构成序列；Ghostty 无限期等待下一个键，没有超时；在 shell 里需要加引号                     | `src/config/Config.zig:1664-1673` |
| 序列不允许用于 `global:` 或 `all:` 前缀                                                              | `src/config/Config.zig:1699-1700` |
| 前缀可叠加，且触发键不因前缀不同而唯一：`ctrl+a` 与 `global:ctrl+a` 是同一个绑定                     | `src/config/Config.zig:1797-1804` |

`global:` 的平台代价单独说明（`src/config/Config.zig:1806-1833`）：macOS 需要辅助功能权限；Linux 自 Ghostty 1.4.0 起主要通过 `vicinae-hotkey-v1` 协议支持，在 X11 或不支持该协议的合成器上退回 XDG Global Shortcuts。

### Binding 的数据结构

- `Binding` 是 `{ trigger: Trigger, action: Action, flags: Flags }`（`src/input/Binding.zig:16-23`）。
- `Flags` 是 packed struct，四个字段 `consumed`（默认 true）、`all`、`global`、`performable`，带 `cval()` 转成 `u8` 供 C API 使用（`:31-59`）。
- `parseFlags` 识别 `all:`、`global:`、`unconsumed:`、`performable:` 四个前缀；遇到不认识的前缀就 break，注释说明这是为了给 trigger 专属前缀留出扩展空间（历史上曾有 `physical:`）（`:148-187`）。
- `Parser` 是迭代器式实现，为的是支持多键序列而无需分配（`:72-92`）。
- `Trigger.Key` 是 `union(C.Tag) { physical: key.Key, unicode: u21, catch_all }`，另有配套的 extern `C` 表示（`:1707-1740`）。
- `Trigger.parse` 按 `+` 切分，先匹配 `Mods` 的布尔字段名，再匹配 `key_mods.alias` 里的别名（`:1746-1770`）。
- `Action` 是从 `:303` 开始的大 union，前几项是 `ignore`、`unbind`、`csi`、`esc`、`text`、`cursor_key`、`reset`。

`Set` 同时维护正向 `bindings` 与反向 `reverse` 两张表（`src/input/Binding.zig:2085-2118`）。注释解释了为什么序列触发与 `performable` 触发都不进反向表：反向表的主要用途是给 GUI 工具包做菜单快捷键，主流工具包不支持序列，而 GTK 这类工具包处理菜单快捷键的时机在事件生命周期里太早，`performable` 无法生效。

### Keybinds 容器

`Config.Keybinds` 除根 `set` 外还有命名的 `tables`（key table，默认表就是根 `set`）与 `chain_target`（`chain=` 追加的目标，可跨表按解析顺序生效）（`src/config/Config.zig:6489-6503`）。

### 从按键到 pty

`key_encode.Options` 是终端 DEC 模式与应用配置的混合体（`src/input/key_encode.zig:12-38`）：

- `cursor_key_application` — DEC 模式 1
- `keypad_key_application` — DEC 模式 66
- `backarrow_key_mode` — DECBKM，false 时 backspace 发 `0x7f`，true 时发 `0x08`
- `ignore_keypad_with_numlock` — DEC 模式 1035
- `alt_esc_prefix` — DEC 模式 1036
- `modify_other_keys_state_2` — xterm modifyOtherKeys mode 2
- `kitty_flags` — kitty keyboard protocol 标志

`src/input/kitty.zig:3-11` 是 kitty keyboard protocol 的键表，`Entry` 含 `key`/`code`/`final`/`modifier` 四个字段，注释说只有约 100 条、建议直接线性搜索。协议的终端侧状态与语义见 `docs/terminal-core.md`。

### 默认键绑定的平台差异

默认表硬编码在 `Config.Keybinds.init` 里并按平台分支。以 inspector 为例：通用/Linux 侧是 `ctrl+shift+i`（`src/config/Config.zig:6875-6880`），macOS 侧是 `cmd+opt+i`（`:7222-7227`），两处注释都写着 "Inspector, matching Chromium"。

查看当前生效的绑定用 `ghostty +list-keybinds`，选项是 `--default`、`--docs`、`--plain`（`src/cli/list_keybinds.zig:15-25`）；列出全部可用动作用 `ghostty +list-actions`（`src/cli/ghostty.zig:51`）。

### 输入栈的手工验证矩阵

`HACKING.md:262-265` 定义「输入栈」是从按键事件开始、到文本编码发送到 pty 结束的部分，不包括渲染文本（那属于字体或渲染栈）。`HACKING.md:267-270` 是硬性要求：修改输入栈的任何部分，都必须手工验证下列全部输入用例，项目目前完全没有自动化这部分。

Linux IME 测试矩阵四个维度（`HACKING.md:284-287`）：

1. Wayland、X11
2. ibus、fcitx、none
3. 死键输入（如西班牙语）、CJK（如日语）、Emoji、Unicode Hex
4. ibus 版本 1.5.29、1.5.30、1.5.31（各自行为略有不同）

死键用例（`HACKING.md:294-313`）：西语布局下依次按 `'`、`a`，应显示 `á`；取消用例是 `'` → Esc → `a`，应显示不带音符的 `a`。注释说明 ibus 与 fcitx 会显示 preedit 而 none 不会，但送进 pty 的文本必须正确。

CJK 用例（`HACKING.md:315-333`）：按 `Ctrl+Shift` 切到平假名，美式物理布局下输入 `konn` 应在 preedit 看到 `こん`，Enter 后终端显示 `こん`；另需测试 preedit 激活时切换输入法应当提交文本。

`HACKING.md:272` 与 `:289-292` 自己标注这份清单是 work in progress、可能不完备。

## 常见坑 / 注意事项

1. macOS 上 `zig build` 的产物里没有 GUI 可执行文件。`app_runtime = .none` 时根本不产出 exe（`src/apprt/runtime.zig:6-8`），GUI 是 Xcode 构建的 app bundle。
2. 新增 action 要同步四个地方，漏改 `include/ghostty.h` 不会编译报错但会导致 ABI 错位（`src/apprt/action.zig:64-78`）；`Key` 的顺序即 C 枚举顺序，新项只能加在末尾。
3. action 未实现不会报错，只是那个平台没这功能（`src/apprt/action.zig:60-62`）——Zig 侧 69 个 key 对 Swift 侧 63 个 case。
4. 改了 `macos/` 之外的代码只跑 `macos/build.nu` 是不够的，底层库不会更新（`macos/AGENTS.md:4-6`）。
5. `Config` 的 `_` 前缀字段是 API 契约不是私有习惯，`key.zig` 与 `helpgen.zig` 都靠它过滤（`src/config/key.zig:15`、`src/helpgen.zig:39`）。
6. `finalize()` 里的 `loadTheme` 会 deinit 并整体替换 config，此前拿到的所有指针失效——源码里有大写 Warning 注释（`src/config/Config.zig:4625-4626`）。
7. `change_config` 与 `config_change` 传的都是只在消息期间有效的指针（`src/apprt/surface.zig:40-43`、`src/apprt/action.zig:284-296`）。
8. 新旧配置文件名（`config` 与 `config.ghostty`）会被同时加载，容易出现「改了没生效」的错觉（`src/config/Config.zig:4144-4147`）。
9. `performable:` 键绑定不会出现在菜单快捷键里，这是设计如此（`src/config/Config.zig:1789-1793`、`src/input/Binding.zig:2112-2117`）。
10. GTK 侧改 UI 需要 `blueprint-compiler` 0.16.0 或更新版本，且 `.blp` 要放进对应 libadwaita 版本目录并在 `gresource.zig` 的 `blueprints` 数组里登记，否则 comptime 报错（`src/apprt/gtk/build/gresource.zig:33-55`、`:103-123`）。

## 延伸阅读

- [HACKING.md](../HACKING.md) —— 额外依赖与输入栈手工测试清单
- [macos/AGENTS.md](../macos/AGENTS.md) —— macOS 构建纪律与 AppleScript 规范
- [AGENTS.md](../AGENTS.md) —— 仓库级 agent 指南（根 `CLAUDE.md` 是它的符号链接）
- `docs/architecture.md`、`docs/terminal-core.md`、`docs/rendering-and-font.md`、`docs/preview-manual.md`
