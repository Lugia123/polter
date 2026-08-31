# Windows：用 Rust 做壳，走 embedded 这条缝

## 本章覆盖什么

- 为什么是 Rust 写壳 + `embedded` apprt，而不是复用 GTK、也不是再写一个 Zig `Runtime`
- 这条缝今天是什么形状，缺哪几块
- 三处真实成本，以及它们各自有多大（**量过的，不是估的**）
- 为什么 Windows 的答案和 macOS、Linux 都不一样

## 本章不覆盖什么

- 怎么动手（[development.md](development.md)）
- Ghostty 核心怎么工作（`docs/architecture.md`）
- Polter 的监管模型（`docs/poltergeist/`）

## 一句话概括

macOS 已经证明了一件事：**一个外部宿主可以拥有应用生命周期，把 Ghostty 当成一个
被嵌进去的终端**。Swift 走通的那条路，Rust 可以照走；要补的是渲染后端在这条路上
的空缺，和 Polter 自己的几处 POSIX 假设。

## 一、先把结论摆前面：这条路可行，但比第一眼贵

我最初估的是「Zig 侧改约 20 行」。**那是错的**，因为我当时没读渲染那一侧。真实的
成本是三块，第二块是主体：

| | 大小 | 性质 |
| --- | --- | --- |
| 1. C API 加一个平台成员 | **~20 行** | 真的只有这么多 |
| 2. **渲染后端在 `embedded` 下的空缺** | **数百到两千行** | **主体工作** |
| 3. Polter 自己的 POSIX 假设 | **5 处** | 已定位到行；第 5 处要修完前 4 处才看得见 |
| 4. Rust 侧的壳 | ~~一两万行~~ 见下 | 你要写的那部分 |

> **第 4 行那个「一两万行」不可信，两个理由。**
>
> **基数错了**：它是参照 `macos/` 的 Swift 行数估的，本文原写 32,694，**实测 43,157**，
> 低了 32%。
>
> **构成更要命**：`macos/Sources` 170 文件 43,157 行里，**`import AppKit/SwiftUI/Cocoa`
> 的占 133 文件、33,111 行 = 92%**；不碰平台框架的只有 2,644 行 = 7%。
> **也就是说 Rust 侧能照搬的是思路，不是代码**，按总行数换算天然偏乐观。
>
> 唯一能几乎一一对应重写的是 `Ghostty.App.swift`——2,515 行里只有 44 行碰 `NS*`，
> 它基本就是「72 个 action 的 switch + C 调用」，**是全仓移植价值最高的一份参照**。
> 反过来 `Features/` 里 AppleScript 1,554、App Intents 1,158 等在 Windows 上用不上。
>
> **所以规模不该按总行数估，要按「必须实现的 action 数 × 每个的宿主侧成本」估。**
> 已量出来的分类：72 个 action 里 **14 个必须实现**（没有它窗口不成形、不能关、
> 看不出状态），**40 个是「对齐 macOS 能力」所需**（macOS 这 54 个全实现了），
> 剩 18 个可以先返回 `false`（其中 9 个 **macOS 自己也没实现**）。

第 2 块是我漏掉的。`src/renderer/OpenGL.zig` 里，`embedded` 那几支是空的，注释是
作者自己写的：

```zig
apprt.embedded => {
    // TODO(mitchellh): this does nothing today to allow libghostty
    // to compile for OpenGL targets but libghostty is strictly
    // broken for rendering on this platforms.
},
```

**今天 `embedded` 只跟 Metal 配对，OpenGL 只跟 GTK 配对。** 没有任何一条现成的路
是「外部宿主 + 非 Metal 渲染」。这正是 Windows 需要的那一格。

## 二、这条缝今天的形状

macOS 那一侧不是特例，是**通用机制的第一个使用者**：

```
Swift 应用                        libghostty (Zig)
  建 NSView                         embedded.zig  2328 行
  取裸指针  ────────────────────▶     其中 macos/ios 分支 ~15 行
  ghostty_surface_new()             ghostty.h     1301 行
  推事件 / 拉渲染  ◀───────────▶     渲染器往那个 view 上画
```

平台相关的东西被压成了一个联合体，**一共两个成员**：

```c
typedef struct { void* nsview; } ghostty_platform_macos_s;
typedef struct { void* uiview; } ghostty_platform_ios_s;
typedef union { ghostty_platform_macos_s macos;
                ghostty_platform_ios_s   ios; } ghostty_platform_u;
```

Windows 要加的就是第三个：`{ void* hwnd; }`。加上 `GHOSTTY_PLATFORM_WIN32` 和
`embedded.zig` 里 `Platform.init` 的一支——**这一块确实只有二十行左右**。

宿主要满足的契约也是明确的，不是散落的：

- **6 个回调**（`ghostty_runtime_config_s`）：`wakeup` / `action` / `read_clipboard` /
  `confirm_read_clipboard` / `write_clipboard` / `close_surface`
- **72 种 action**（`src/apprt/action.zig`）—— 开标签、改标题、弹菜单、进全屏……
  宿主可以只实现一部分，其余返回「不支持」
- 事件推进：`ghostty_app_tick`、`ghostty_surface_key`、`mouse_*`、`ime_point`、
  `ghostty_surface_draw`

**这份契约已经被 Swift 完整实现过一遍**，所以它不是纸上的设计，是有参考实现的。

## 三、为什么不复用 Linux 那份 Zig

`src/apprt/gtk/` 是 **54 个文件、23,669 行 Zig**。但那里面 Zig 只是语言：

```
gtk 599 处 · glib 283 · gdk 212 · adw 94 · gio 116
```

<sub>口径：`grep -rhoE "\b<lib>\.[A-Za-z_]" src/apprt/gtk --include='*.zig' | wc -l`，即「以 `<lib>.` 开头的符号引用」次数。**旧数（578/221/195/94/92）的口径无法复现**：同一棵树上只有 `adw` 对得上，而 `src/apprt/gtk/` 最后一次改动是 2026-08-30、早于本文写作日，所以差异不是代码增长造成的。这里改用上面这条明确命令，以后可复算。</sub>

窗口是 `GtkWindow`，标签是 `AdwTabView`，输入走 `GtkIMContext`，菜单是 `GMenu`。
**换成 Win32，这些一行都不剩。** 而且 `libadwaita`（94 处）是 GNOME 平台库，不发
Windows；`gtk4-layer-shell` 是 Wayland 专用。

「Linux 用 Zig 做的」和「这份 Zig 能复用」是两件事。前者对，后者不对。

## 四、为什么不用 Zig 再写一个 `Runtime`

技术上完全可以——`src/os/windows.zig` 里已经有 25 个 `extern "kernel32"`，
`WindowsPty`（166 行，在 **`src/pty.zig:326-491`**，不在 `src/os/windows.zig`——
后者放的是 `CreatePseudoConsole` / `ClosePseudoConsole` / `ResizePseudoConsole` 等
extern 声明）真接了 ConPTY 并且在跑。Zig 调 Win32 这个仓已经在做了。

**挡住它的是 COM。** Windows 的输入法走 TSF，那是 COM 接口，从 Zig 调等于手搓
vtable，没有投影层。而 IME（组合串、候选窗定位、re-conversion）是 Windows 终端最
难的一块，也是中文用户最先撞到的一块。

对照另外两个平台就清楚了：macOS 的 `NSTextInputClient` Swift 天然就有，Linux 的
IBus 是 D-Bus + C 接口 Zig 好接，**只有 Windows 的输入法是 COM**。

`windows-rs` 是微软第一方绑定，COM 支持是像样的。**走 embedded 这条路，输入法整个
在 Rust 侧，Zig 一行 COM 都不用碰。**

## 五、为什么不是 C#

C# 在组织上最顺（和 macOS 用 Swift 是同一个模式），上游维护者据说也倾向它。但对
**在 Mac 上开发**这个约束，它是出局的：**WinUI3 / Windows App SDK 在 macOS 上根本
构建不了**，需要一台 Windows 当开发机，而不只是测试机。

Rust 和 Zig 都能从 Mac 交叉编译，只需要一台 Windows 用来跑。

## 六、两个量过的事实

**Zig 从这台 Mac 交叉编译 Windows，零配置：**

```
zig build -Demit-lib-vt -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSmall
→ 退出码 0
→ ghostty-vt.dll / ghostty-vt.lib / include/ghostty/vt.h
```

一个坑：`-Dtarget=x86_64-windows`（默认 msvc ABI）**失败**，vendored 的 `simdutf`
是 C++，要 MSVC 的 C++ 标准库，Zig 不带。**走 `-gnu`，或者另外准备 Windows SDK。**

**完整 libghostty 编 Windows，编译阶段只差 4 类、全在 Polter 自己的代码里；
修完之后还有一处 `localtime_r` 的链接错误，那一处溢出了 poltergeist——
同一个 extern 在 `src/os/main.zig`、`src/poltergeist/daylog.zig`、
`src/cli/chat.zig` 里各抄了一份。**

```
zig build -Dtarget=x86_64-windows-gnu -Dapp-runtime=none -Drenderer=opengl
→ 5 个错误（其中一个重复）

src/poltergeist/Plugin.zig:898     .permissions = .fromMode(0o600)     POSIX 文件权限
src/poltergeist/Resident.zig:926   std.c.socketpair(...)               POSIX socketpair
src/poltergeist/Resident.zig:1164  std.posix.kill(pid, SIG.KILL)       POSIX 信号
src/poltergeist/reap.zig:136       同上
src/poltergeist/Resident.zig:1488  "started {s} as pid {d}"            Windows 上 pid 是 HANDLE
```

**这一条比什么论证都有说服力：Ghostty 核心为 Windows 编得过，编不过的是 Polter 的
插件宿主。**——**编译阶段**是。链接阶段还牵出一处三个文件共有的 libc 假设。
那四处都在同一个子系统里——起插件、杀插件、写它的设置文件、记它的 pid。

### 但「编得过」不是跨平台的证据

上面那段是这份文档最有说服力的一条，**它也是被推翻得最彻底的一条**——不是因为数错了，
是因为它拿编译当了跨平台的证据。

后来把**测试套件**也编到 Windows 并在真机上跑（Windows 11 26100 / x64，
`3872 passed; 83 skipped; 29 failed`）：

| 失败 | 数量 | 是什么 |
| --- | --- | --- |
| `server.zig` 的 Unix domain socket | **14** | 总管↔终端的 IPC，见下 |
| 插件起不来 | **11** | `error.InvalidExe`（`.sh` 在 Windows 不可执行）九个，`error.NoDevice` 两个 |
| `reap` 起不了子进程 | 3 | 同上一类 |
| `secret` 的 resolver | 1 | 同上一类 |
| **`Transcript` 防目录逃逸** | **1** | Windows 把 `\` 也当分隔符，**唯一一条安全性质的失败** |

**29 个失败全部在 `src/poltergeist/`。** 终端核心那一侧——VT、`PageList`、search、
snapshot、字体 shaping——**全过**，字体 sprite 测试还在真机上写出了它的 PNG。

所以这一节的结论要收窄成一句更难听但更准的话：

> **Ghostty 的终端核心为 Windows 编得过，也跑得起来。
> Polter 自己的监管层编得过，但跑不起来。**

`-Dapp-runtime=none` 产出的是**库**，而库只要链得上就算编过了。
监管层从来没有被执行过——直到测试套件第一次在 Windows 上跑起来。

**这也是本文档的通用教训**：本节标题叫「两个量过的事实」，量的都是**编译**。
编译、链接、运行、绘制是四层，**每一层都会挡住下一层的问题**，
而这份文档在写作时只穿透了第一层。

### Unix socket 那 14 个：三层，一层比一层深

这一条单独写，因为它有一个特别容易上钩的形状。

**第一层**，`net.has_unix_sockets` 是 Zig std 的**编译期常量**，由目标声明的最低
Windows 版本决定。默认 `x86_64-windows-gnu` 声明的是 `.win10`（10240，早于 1803），
跨越了 AF_UNIX 的引入点，`isAtLeast(.win10_rs4)` 返回 `null`，被 `orelse false` 关掉。
于是那 14 个测试**优雅失败**（`return error.UnixSocketsUnavailable`），套件跑完 3984 个。

**第二层**，把目标抬到 `x86_64-windows.win10_rs4-gnu`，那个常量变 `true`，代码走进
std 的 Windows AF_UNIX 实现——**第一个 socket 测试就当场崩溃，进程死亡，
后面 193 个测试一个没跑。**

**第三层**，带符号的 Debug 二进制给出了根因：

```
thread panic: reached unreachable code
  std/Io/Threaded.zig:12502   netAcceptWindows      ← .CANCELLED => unreachable
  std/Io/net.zig:1443         accept
  src/poltergeist/Server.zig:459   listenMain
```

`listenMain` 阻塞在 `accept` 上，关停时要把它唤醒，走的正是取消路径；
而 std 断言「accept 的 AFD 请求不可能被取消」。**连接建得起来，关不掉。**

> **所以：抬高构建目标不是修复，单独做的话是退化**——把一个能跑完的测试套件
> 换成一个跑不完的。
>
> 这个形状值得记住：`has_unix_sockets` 从 `false` 变 `true` 看起来像进步，
> **而且确实进了一层**，只是同时把一个安静的错误换成了一次崩溃。

**第四层**，那个 `unreachable` 不是孤例，也不是我们用错了 API——**是 std 违反了它
自己的契约**。`net.Server.AcceptError` 里有这个变体，注释是 std 自己写的：

```zig
/// Either `listen` was never called, or `shutdown` was called (possibly while
/// this call was blocking). This allows `shutdown` to be used as a concurrent
/// cancellation mechanism.
SocketNotListening,
```

「possibly while this call was blocking」「concurrent cancellation mechanism」——
**契约明说这是受支持的用法，并且给了专门的错误码**，而 Windows 实现把它写成了
`.CANCELLED => unreachable`。`server.zig` 做的正是被背书的那件事，它的注释同样清楚：
`// Closing the listener is what unblocks accept.`

**而且不是一处，是一类**：`Threaded.zig` 里同样形状的断言共 **27 处**，
其中在关停路径上的至少五处——`netAcceptWindows` 两处（已撞）、
**`netReadWindows`**（连接线程阻塞在读上，`stop()` 第二段拆连接时必撞）、
`netWriteWindows`、`netShutdownWindows`。

### 结论：不走 AF_UNIX，改用命名管道

不是因为 Windows 不支持 AF_UNIX——**系统层面完全支持**。是因为：

- **accept 那两处有绕法**（自连一个假连接唤醒，再 join，再关句柄——顺序要和现在反过来，
  约 30 行），**但 `netReadWindows` 那处没有**：自连能造出一个新连接，
  **造不出「让一个已阻塞在 read 上的线程醒过来」**，而那正是 shutdown/close 的职责，
  两条路在 Windows 上都通向 `STATUS_CANCELLED`。
- **我们改不动 std**：Ghostty 钉死 Zig 版本，vendor 一份打过补丁的 std 不是产品级方案。
  **提 upstream 是该做的**（契约、实现、复现、一行修法都齐了，
  `.CANCELLED => return error.SocketNotListening` 语义完全吻合已有错误码），
  **但把发布计划挂在一个上游 issue 上，比自己写一份命名管道传输层贵得多。**

**命名管道换得起，因为要动的不是协议**：协议是行分隔 JSON、客户端先说话、
**传输层无关，一行不用改**；鉴权模型也**不变**——管道 DACL ≈ socket 文件权限，
都限制到本用户。**这一点是它比 loopback TCP 强的关键**：TCP 会把
「本机任何进程都能连」引进来，而 `server.zig` 的模块头正是为了避免这个才选了 unix socket：

> *Unix socket only, never a network port: otherwise any process on the machine
> could type into every terminal the user has open.*

**代价（量过的）**：`server.zig` 945 行里直接碰 `std.Io.net` 的调用点 **19 处**；
关停相关的 `stop` / `closeListener` / `stopConnections` / `failInflight` / `listenMain`
合计 **98 行**。要重写的是这些，**协议、握手、token、Bus 一律不动**。

> **但这仍然是下限。** 14 个 socket 测试**只跑了第 1 个**，后面 13 个从未被执行过；
> `netReadWindows` 那一层是**推断**出来的，它后面还有什么，**没有任何数据**。

## 七、Windows 的答案为什么和另外两个都不一样

Ghostty 的规矩不是「每平台用自己的语言」，而是：

> **Zig 写终端本身；平台的壳用那个平台最省力的语言写。**

| 平台 | 壳 | 为什么 |
| --- | --- | --- |
| Linux | **Zig** + GTK4 | GTK 是 C 库，Zig 直接绑；**没有强制的打包签名链** |
| macOS | **Swift** + AppKit，43,157 行 | AppKit 只有 ObjC/Swift；**打包、签名、公证、Sparkle 全绑在 Xcode 上** |
| Windows | **？** | Win32 是 C API（像 Linux），**但输入法是 COM**（不像任何一个） |

> ⚠️ **`macos/` 的 43,157 行是重量的结果，旧值 32,694 偏低 32%。**
> 这个数在本文里有论证作用——第一节表格「4. Rust 侧的壳 · 一两万行」那一格是参照它估出来的。
> **基数变了，那个估计需要重看**（本次只改数字，估计本身未改）。量法见文末附录。

分水岭不在语言，在**有没有一条强制的平台工具链**，以及**输入法长什么样**。Windows
在第一条上像 Linux，在第二条上谁都不像——这就是它三年没定的原因。

## 取舍记录

| 方案 | 为什么没选 / 为什么选 |
| --- | --- |
| 复用 `apprt/gtk` | `libadwaita` 94 处，GNOME 专用，不发 Windows。而且换掉 GTK 等于重写 |
| Zig 写第三个 `Runtime` | 两万行 Zig，且 TSF 是 COM——手搓 vtable，正好压在中文输入上 |
| C# + WinUI | **Mac 上构建不了**，要整台 Windows 开发机 |
| Rust + winit 等跨平台 GUI | 那是 WezTerm 的路。Ghostty 的卖点就是**原生观感**，用跨平台工具箱等于放弃它 |
| **Rust 走 `embedded`** | **选这个。** C API 侧只加 ~20 行，COM 有 `windows-rs`，可从 Mac 交叉编译 |

## 未决问题

**这一节写于开工之前。下面每一条后面都跟着一行「后来怎样」——保留原文是因为
被推翻的判断比修正后的结论更有用：它说明了当时是凭什么下的判断。**

1. ~~**渲染是唯一真正的未知数。**~~ `embedded` + OpenGL 当时是空壳。两条路：把 WGL
   填进 `OpenGL.zig` 的 3 处 `embedded` 空分支（**便宜**，OpenGL 后端本体 582 +
   `opengl/` 1440 行都在），或者写一个 D3D11 后端（**贵**，参照 `Metal.zig` 502 +
   `metal/` 2205 行）。**先试前者。**

   > **后来：走了 A，而且它不再是最大的未知数。** WGL 已填进那三处，编得过、链得上，
   > 产物导入表里有 `wglCreateContext` / `SwapBuffers` / `OPENGL32.dll`，不是死代码。
   > 目标机器的 GL 能力也实测过：**ICD 全硬件，legacy 4.6 / core 4.3 创建成功**——
   > 这一步值得单独做，因为远程桌面会话下 Windows 的 OpenGL 会退化成软件 1.1，
   > 而渲染路径硬性要求 4.3。**屏幕上仍然没画出东西，但缺的是窗口不是渲染**：
   > 没有任何 Windows apprt，没有人创建 `HWND`。**新的最大未知数是 apprt 本身**，
   > 对照组 `apprt/gtk` 是 23,669 行。

2. **上游收不收。** 给 `ghostty_platform_u` 加成员是改公共 ABI，得他们同意。不过
   加二十行扩一个已有联合体，比塞进来两万行新 apprt 容易接受得多——他们自己说过
   「那些 fork 里也许有些能被 upstream」。

   > **后来：那二十行落地了**（`GHOSTTY_PLATFORM_WIN32` 加在枚举末尾，
   > `{ void* hwnd; }` 进 union，Swift 侧只有两行碰这些类型且都走命名构造器，
   > union 宽度未变）。**上游收不收仍未知。**

3. **Polter 的监管界面得第三次实现。** 现在锁在 Swift 里的是菜单项、tab 标识位、
   右键菜单。~~好消息：**群聊和任务面板已经是 TUI**（2,197 行 Zig，跨平台），
   `src/poltergeist/` 那 34,046 行核心也是跨平台的。~~

   > **后来：那句「好消息」一半是假的，见 §六。**
   > TUI 的**渲染层**确实跨平台——`vaxis` 有真的 `WindowsTty`（约 500 行，
   > `GetConsoleMode` / `ENABLE_VIRTUAL_TERMINAL_PROCESSING` / `INPUT_RECORD` 翻译，
   > 不是桩）。**但它连不上服务器**：`chat.zig` 和 `mcp.zig` 用的是 `net.UnixAddress`。
   > **「跨平台」描述的是画面，不是功能——画得出来，连不上。**
   > 而「`src/poltergeist/` 34,046 行核心也是跨平台的」这句，被 29 个失败直接证伪。

4. ~~**TSF 到底多痛，没人验过。**~~ 这是唯一不能靠读代码回答的问题，也是最该先做最小
   验证的一件——它的结果比这份文档里所有推理都更能决定要不要开工。

   > **后来：验了，不痛。** 约 470 行，占本文对 Rust 壳估计的 3~5%，不是主体。
   > `ITextStoreACP` 26 个方法首次编译只有 9 个错，全是类型别名和参数形状，
   > 没有一个是 vtable、引用计数或线程模型级别的。交叉编译的 exe 拷到真机
   > **第一次运行就完成了完整握手**，候选窗落点与算术一致（含「一个 CJK 码元占两格」
   > 这个最容易错的情形）。**这一条是本文档里唯一一个「先验证再开工」的决定，
   > 而它恰好是回报最大的那个。**

5. **（新）真正的主体是什么，本文档从头到尾没说对。** 原文把它押在渲染上。
   实测下来，挡在 `polter.exe` 前面的是两样别的：**没有任何 Windows apprt**
   （从零，对照 GTK 23,669 行，需实现 72 个 action 中的 54 个才能对齐 macOS 能力），
   以及 **Polter 自己的监管层在 Windows 上跑不起来**（§六那 29 个失败）。

6. **（新）Polter 的认证链在 Windows 上是断的。** `Command: custom env vars` 这个
   测试失败，看起来只是一个上游测试，但 `Surface.zig` 正是靠环境变量把
   `GHOSTTY_POLTER_SOCKET` 和 `GHOSTTY_POLTER_TOKEN` 下发给子进程的，
   而 `Server.zig` 的鉴权模型是「持有该终端的令牌即证明身份」。
   **自定义环境变量传不进去 = 没有令牌 = 任何 agent 都连不上 Polter**，
   socket 通了也没用。根因未定位。

7. **（新）Windows 上插件用什么解释器，是产品决策。** 出厂插件 9 个声明了 `exec`，
   其中 **8 个是 `provision.sh`**，1 个是 `archive.py`。Windows 不能直接执行 `.sh`
   （`error.InvalidExe`）。三条路：每个插件加一份 `.ps1`/`.cmd`（双份维护）、
   保持 `.sh` 但要求 git-bash/WSL（给用户加前置依赖）、宿主按扩展名选解释器
   （改一处，插件不动）。**这不是技术问题，影响插件作者和文档，要人拍板。**

## 延伸阅读

- [development.md](development.md) —— 怎么复现上面两个实验，五处 POSIX 假设怎么改，分几步走
- `include/ghostty.h` —— 宿主要消费的那份契约
- `src/apprt/embedded.zig` —— 「宿主拥有生命周期」那条路
- `macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift` —— 参考实现

## 附录：这份文档里的数字是怎么量的

2026-08-31 复量（任务 #60 延伸）。**表里只有可量的数字**；结论性判断不在此列。

| 数字 | 量法 | 旧值 → 新值 |
| --- | --- | --- |
| `embedded.zig` 行数 | `wc -l src/apprt/embedded.zig` | 2,269 → **2,328** |
| `ghostty.h` 行数 | `wc -l include/ghostty.h` | 1,293 → **1,301** |
| apprt action 数 | `src/apprt/action.zig` 里 **`Action.Key`**（408–485 行）的成员数；用 `Action = union(Key)`（63–553 行）反向核对，两侧同为 72、双向差集为空 | 73 → **72** |
| `apprt/gtk` 文件数 / 行数 | `find src/apprt/gtk -name '*.zig' \| wc -l` / `-exec cat {} + \| wc -l` | 54 / 23,669（**未变**） |
| gtk 各库引用次数 | `grep -rhoE "\b<lib>\.[A-Za-z_]" src/apprt/gtk --include='*.zig' \| wc -l` | 见正文小字 |
| `os/windows.zig` 的 extern | `grep -c 'extern "kernel32"' src/os/windows.zig` | 21 → **25** |
| `WindowsPty` 行数 / 位置 | `src/pty.zig` 第 326–491 行 = 166 行 | 166（**未变**）；位置更正 |
| `macos/` Swift 行数 | `find macos -name '*.swift' -exec cat {} + \| wc -l` | 32,694 → **43,157** |
| `OpenGL.zig` / `opengl/` | `wc -l` / `find ... -exec cat` | 461 → **582** / 1,084 → **1,440** |
| `Metal.zig` / `metal/` | 同上 | 496 → **502** / 2,205（**未变**） |
| 群聊 + 任务 TUI 行数 | `wc -l src/cli/chat.zig src/cli/chat_layout.zig`（1,970 + 227） | 1,984 → **2,197** |
| `src/poltergeist/` 行数 | `find src/poltergeist -name '*.zig' -exec cat {} + \| wc -l` | 33,710 → **34,046** |
| `ghostty_runtime_config_s` 回调数 | 数结构体里的 `*_cb` 字段 | 6（**未变，已复核**） |

**两处刻意没改，需要另行决定：**

1. **第六节那五处 `文件:行号` 引用已经全部失效**——#54 已经把那几处 POSIX 假设修好了，
   行号漂了、代码也变了（例如 `fromMode(0o600)` 从 `Plugin.zig:898` 移到 **912** 并已包进平台分支；
   `reap.zig` 的 kill 现在在 **52** 行，**48** 行旁边已经有 `TerminateProcess` 分支）。
   照新行号改会让那一节看起来在说「这些地方现在还是坏的」，而它们已经修了。
   **这一节是当成历史实验记录保留，还是改写成现状，是框架问题不是数字问题，留给文档作者。**

2. **第一节表格「4. Rust 侧的壳 · 一两万行」未改**——它依赖上面那个 `macos/` 基数，
   而基数偏低了 32%。**改这个估计要连着真机数据一起重写，不在本次范围内。**
