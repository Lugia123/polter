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
| 4. Rust 侧的壳 | 一两万行 | 你要写的那部分 |

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
  建 NSView                         embedded.zig  2269 行
  取裸指针  ────────────────────▶     其中 macos/ios 分支 ~15 行
  ghostty_surface_new()             ghostty.h     1293 行
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
- **73 种 action**（`src/apprt/action.zig`）—— 开标签、改标题、弹菜单、进全屏……
  宿主可以只实现一部分，其余返回「不支持」
- 事件推进：`ghostty_app_tick`、`ghostty_surface_key`、`mouse_*`、`ime_point`、
  `ghostty_surface_draw`

**这份契约已经被 Swift 完整实现过一遍**，所以它不是纸上的设计，是有参考实现的。

## 三、为什么不复用 Linux 那份 Zig

`src/apprt/gtk/` 是 **54 个文件、23,669 行 Zig**。但那里面 Zig 只是语言：

```
gtk 578 处 · glib 221 · gdk 195 · adw 94 · gio 92
```

窗口是 `GtkWindow`，标签是 `AdwTabView`，输入走 `GtkIMContext`，菜单是 `GMenu`。
**换成 Win32，这些一行都不剩。** 而且 `libadwaita`（94 处）是 GNOME 平台库，不发
Windows；`gtk4-layer-shell` 是 Wayland 专用。

「Linux 用 Zig 做的」和「这份 Zig 能复用」是两件事。前者对，后者不对。

## 四、为什么不用 Zig 再写一个 `Runtime`

技术上完全可以——`src/os/windows.zig` 里已经有 21 个 `extern "kernel32"`，
`WindowsPty`（166 行）真接了 ConPTY 并且在跑。Zig 调 Win32 这个仓已经在做了。

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

## 七、Windows 的答案为什么和另外两个都不一样

Ghostty 的规矩不是「每平台用自己的语言」，而是：

> **Zig 写终端本身；平台的壳用那个平台最省力的语言写。**

| 平台 | 壳 | 为什么 |
| --- | --- | --- |
| Linux | **Zig** + GTK4 | GTK 是 C 库，Zig 直接绑；**没有强制的打包签名链** |
| macOS | **Swift** + AppKit，32,694 行 | AppKit 只有 ObjC/Swift；**打包、签名、公证、Sparkle 全绑在 Xcode 上** |
| Windows | **？** | Win32 是 C API（像 Linux），**但输入法是 COM**（不像任何一个） |

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

1. **渲染是唯一真正的未知数。** `embedded` + OpenGL 今天是空壳。两条路：把 WGL 在
   `HWND` 上的上下文创建和线程模型填进 `OpenGL.zig` 的 3 处 `embedded` 空分支
   （**便宜**，OpenGL 后端本体 461 + `opengl/` 1084 行都在），或者写一个 D3D11 后端
   （**贵**，参照 `Metal.zig` 496 + `metal/` 2205 行）。**先试前者。**
2. **上游收不收。** 给 `ghostty_platform_u` 加成员是改公共 ABI，得他们同意。不过
   加二十行扩一个已有联合体，比塞进来两万行新 apprt 容易接受得多——他们自己说过
   「那些 fork 里也许有些能被 upstream」。
3. **Polter 的监管界面得第三次实现。** 现在锁在 Swift 里的是菜单项、tab 标识位、
   右键菜单。好消息：**群聊和任务面板已经是 TUI**（1,984 行 Zig，跨平台），
   `src/poltergeist/` 那 33,710 行核心也是跨平台的。
4. **TSF 到底多痛，没人验过。** 这是唯一不能靠读代码回答的问题，也是最该先做最小
   验证的一件——它的结果比这份文档里所有推理都更能决定要不要开工。

## 延伸阅读

- [development.md](development.md) —— 怎么复现上面两个实验，五处 POSIX 假设怎么改，分几步走
- `include/ghostty.h` —— 宿主要消费的那份契约
- `src/apprt/embedded.zig` —— 「宿主拥有生命周期」那条路
- `macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift` —— 参考实现
