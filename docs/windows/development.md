# Windows：怎么动手

设计和取舍在 [design.md](design.md)；这里只讲怎么做，以及每一步做完拿什么证明它成了。

## 本章覆盖什么

- 复现那两个交叉编译实验（结论都是量过的，你应该自己再量一遍）
- 五处 POSIX 假设，逐条给出改法
- 分几步走，每一步的验收条件
- 宿主必须满足的契约

## 0. 先复现两个实验，别信这份文档

**实验一：Zig 能不能从 macOS 出 Windows 产物。**

```sh
zig build -Demit-lib-vt -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSmall -p /tmp/winxc
```

2026-08-31 在一台 macOS/arm64 上：**退出码 0**，产出 `bin/ghostty-vt.dll`、
`lib/ghostty-vt.lib`、`include/ghostty/vt.h`。**没装任何额外工具链。**

**必须走 `-gnu`。** `-Dtarget=x86_64-windows`（默认 msvc ABI）会失败：

```
compile lib simdutf ReleaseSmall x86_64-windows-msvc 2 errors
error: 'cstring' file not found
```

vendored 的 `simdutf` 是 C++，MSVC 目标要 MSVC 的 C++ 标准库，Zig 不带。要走 msvc
得另外准备 Windows SDK（`xwin` 之类）。**第一阶段不要碰这个，用 `-gnu`。**

**实验二：完整 libghostty 离编得过还差多远。**

```sh
zig build -Dtarget=x86_64-windows-gnu -Dapp-runtime=none -Drenderer=opengl \
  -Doptimize=ReleaseSmall -Demit-macos-app=false -Demit-xcframework=false -p /tmp/winlib
```

**退出码 1。编译阶段四类假设、5 个错误（`SIGKILL` 占两处），全部在 `src/poltergeist/` 里；四类修完后链接阶段还会再冒出一处 `localtime_r`，见 §1.5。**
Ghostty 核心编得过。

## 1. 五处 POSIX 假设（四处编译期，一处链接期）

编译期那四处都在插件宿主这一个子系统里——起插件、杀插件、写它的设置文件、记 pid。
链接期那一处（§1.5）溢出了 poltergeist。

### 1.1 `Plugin.zig` 的 `Settings.write` / `Settings.restrict` —— 文件权限

```zig
.permissions = .fromMode(0o600),
```

`fromMode` 是 POSIX 概念，Windows 的 `Permissions` 枚举没有它。

**这一行写的是插件设置文件**，而它旁边的注释说明了为什么是 `0o600`：参数「多数是
引用而不是密钥，**但不总是**——手写的文件可能放着字面量，而这里会重写这种文件」。
所以 `0o600` 不是随手加的严格，是防一个具体的情况。

Windows 上的等价物是 ACL，不是 mode。最省的改法是按平台分支：POSIX 保持原样，
Windows 用 ACL 限制到当前用户。**不要退化成默认权限就算了**——那会让上面那句注释
描述的保护在 Windows 上静默消失，而没有任何东西会提醒任何人。如果第一版确实先不
做 ACL，**必须在日志里说出来**。

实际做法：

```
取当前进程 token（OpenProcessToken, TOKEN_QUERY）
  → TokenUser 拿 SID（GetTokenInformation）
  → ConvertSidToStringSidW
  → 拼 SDDL:  D:P(A;;FA;;;<sid>)
  → ConvertStringSecurityDescriptorToSecurityDescriptorW
  → SetFileSecurityW
```

**四个不写下来下次一定重犯的点：**

1. **`D:P` 里的 `P`（protected）是关键，不是修饰。** 不加 `P`，父目录继承下来的
   条目仍然在，而「别再继承」正是 `0o600` 的意思。少这一个字母，这段代码就白写了。
2. **用 SDDL，不要手搓 ACL。** `InitializeAcl` / `AddAccessAllowedAce` 那条路多十几个
   调用、多十几种把字节数算错的方式，而系统对两者的解析结果一样。
3. **按路径而不是按句柄。** `SetSecurityInfo` 要求句柄上有 `WRITE_DAC`，而
   `createFile` 并没有这么申请；`SetFileSecurityW` 自己按名字开文件，带它需要的权限。
4. **时序是安全属性的一部分**：作用在**空文件**上、写 bytes **之前**。所以字面量密钥
   从来没有在宽权限下落过盘。这一点无法从代码顺序上一眼看出为什么不能反过来。

**失败是大声记日志、不是致命错误。** 理由——为此拒绝写文件，会让人在某台古怪机器上
彻底配不了插件，比「文件只剩目录给的权限」更糟。但 `log.warn` 必须点名文件并说清
后果，否则这层保护就是静默消失。

### 1.2 `Resident.zig` 的 `Stderr.make` / `makeWindows` —— `socketpair`

```zig
if (std.c.socketpair(
```

插件的 stdio 通道。Windows 没有 `socketpair`，等价物是**命名管道**
（`CreateNamedPipe` + `CreateFile`）或 loopback TCP。

**这是编译期那四处里最实的一处**，不是换个函数名的事。好在协议本身是行分隔的 JSON，
管道完全够用。

**但最难的部分不是换 API，是保住一个性质。** 原代码选 socketpair 不是随手选的：

> 插件的**孙进程**会继承写端（这是特性，不是 bug：子命令的报错属于插件的日志）。
> 所以靠「EOF 结束 drain 线程」在孙进程活着时**永远不会发生**，`join` 会挂住，
> Polter 就退不出去。原代码用 `shutdown(SHUT_RD)` 从**我们这一侧**结束读。

因此：**匿名管道不行，必须命名管道**——因为 **`DisconnectNamedPipe` 是服务端专有的**，
它才是 `shutdown(SHUT_RD)` 的对应物（粘性：之后再发起的 read 也立刻结束）。

还有两点：

- ⚠️ ~~**`hush()` 里 `DisconnectNamedPipe` 和 `CancelIoEx` 两个都要发**……只写一个都会漏。~~
  **这条被实验推翻了，而且推翻它的实验就在 `status.md` 第三节那张表里**：
  「删掉 `CancelIoEx`」那一行是 **3/3 通过**，而在此之前三轮都挂。
  **现在的代码是 `DisconnectNamedPipe` only**，`Resident.zig` 的 `hush()` 里写着
  「**Disconnect only. Never cancel.**」并说明了另一个为什么错。
  **保留这条划掉的原文，是因为它是祈使句**——照着做就是把已经修好的死锁改回去，
  而一个被删掉的错误建议，下一个人会重新想到它。
- **`FILE_FLAG_FIRST_PIPE_INSTANCE` + 实例上限 1 是安全要求，不是洁癖**：没有它，本机
  另一个进程可能抢先占住这个管道名，然后收走插件的 stderr。

### 1.3 `Resident.zig` 的 `collect` 和 `reap.zig` 的 `Reaper.run` —— `SIGKILL`

```zig
if (c.id) |pid| std.posix.kill(pid, std.posix.SIG.KILL) catch {};
```

Windows 没有信号。等价物是 `TerminateProcess`。语义上够接近——两边都是「不给它清理
机会，直接结束」。

### 1.4 `Resident.zig` 的 spawn 分支 —— pid 的打印

```zig
"started {s} as pid {d}",
```

**Windows 上进程 id 在 Zig std 里是 `HANDLE`（`*anyopaque`），不是整数**，`{d}` 编
不过。**按平台取一个可打印的值**——Windows 上 `Child.Id` 是 `HANDLE`，用
`GetProcessId(handle)` 换回真正的数字（公共实现在 `reap.pidNumber`）。

**不要用 `{any}`**：打印出来是个指针，没有人能拿它去任务管理器里查。

### 1.5 `localtime_r` —— 链接期才看得见的第五处

修完上面四类**编译**错误之后，链接阶段还会冒出来一条：

```
error: lld-link: undefined symbol: localtime_r
```

`localtime_r` 是 POSIX-only；mingw 只提供内联版，不导出符号。Windows CRT 的对应物是
`_localtime64_s`，而且**不是换个名字**：参数顺序相反、靠返回码而不是 null 报错、
它填的 `struct tm` 只有九个 POSIX 成员，没有 BSD 那两个（`gmtoff` / `zone`）。

**这一处溢出了 poltergeist。** 同一个 extern 在仓里被抄了三份：

```
src/os/main.zig        ← 规范的那份
src/poltergeist/daylog.zig
src/cli/chat.zig
```

只改前两份，重跑链接**仍报同一符号**——`src/cli/chat.zig` 也在链接图里。

### 1.6 还有两处只在「为 Windows 编译测试」时才会撞上

这两处**不影响步 1 验收**（`zig build` 不编测试），但步 6 要在真机跑测试就会撞上。
现在记下来，免得那时被当成新发现：

| 位置 | 假设 | 数量 |
| --- | --- | --- |
| `reap.zig` 的测试段 | `std.posix.kill(pid, SIG.KILL)` | 1 处 |
| `Resident.zig`、`login_path.zig` 的 `// -- tests` 之后 | `.permissions = .fromMode(0o755)` | 7 处 |

`reap.zig` 那处已顺手换成公共的 `reap.kill()`；7 处 `0o755` **没动**，那是测试要造
可执行脚本，语义上确实需要可执行位。

> 这五处**加起来不大，但它们不是「Windows 移植」的全部**——它们只是**编得过**的
> 门槛。编过之后插件宿主能不能真的在 Windows 上起进程、收行、杀进程，是另一件要
> 单独验的事。

## 2. C API 加一个平台

`include/ghostty.h`：

```c
typedef enum {
  GHOSTTY_PLATFORM_INVALID,
  GHOSTTY_PLATFORM_MACOS,
  GHOSTTY_PLATFORM_IOS,
  GHOSTTY_PLATFORM_WIN32,        // 加在末尾，保 ABI 兼容
} ghostty_platform_e;

typedef struct { void* hwnd; } ghostty_platform_win32_s;

typedef union {
  ghostty_platform_macos_s macos;
  ghostty_platform_ios_s   ios;
  ghostty_platform_win32_s win32;
} ghostty_platform_u;
```

`src/apprt/embedded.zig` 的 `Platform.init`（**406 行**）加一支，照 `.macos` 那支写。

**加在枚举末尾**：`action.zig` 顶上的注释说得很清楚——顺序直接映射到 C 枚举，为了
ABI 兼容，新成员一律加在最后。平台枚举同理。

**这一块确实只有二十行左右。** 别被它骗了，主体在下一节。

> **但 IME 定位那条缝不在这二十行里——虽然它比第一版写的浅得多。**
>
> **这段话本身被改过一次，值得留着当例子。** 初稿写的是
> 「`ghostty_surface_ime_point` 是 macOS 的形状：**宿主给核心一个点**」。
> **方向是反的**，而且是并入文档时没有核对签名造成的：
>
> - `include/ghostty.h` 的签名是 **四个 `double*`**，如果是宿主给核心，
>   应该是两个传值的 `double`
> - `embedded.zig` 的实现里四个全是 `x.* = …`，**只写不读**
> - 返回类型 `IMEPos { x, y, width, height }` **就是一个矩形**
> - `Surface.imePoint()` 取光标位置加 `preedit.width()`，用 `size.cell` 换算成像素
>
> **正确的说法**：`ghostty_surface_ime_point` 是**核心给宿主一个矩形**
> （四个出参，未缩放坐标，宿主要自己乘 content_scale），内容是光标 + 组合串。
>
> TSF 要的是**任意范围 → 屏幕矩形**（它问宿主 `GetTextExt(start, end)`）。
> **核心给的那一个覆盖了主用例**；任意子范围要宿主自己算——用 `cell_size`
> （走 action 回调拿）加 `ghostty_unicode_grapheme_width`。后者已经导出在
> `libghostty-vt` 里，头文件点名了 IME preedit 这个用例，并写明是
> **「终端自己用的同一张宽度表」**——所以「Rust 侧会长出第二套宽度表」这个风险
> **不存在，也不需要加 C API**。
>
> 代价只是打包：**宽度表在 `ghostty-vt.dll`，surface API 在 `ghostty-internal.dll`，
> 宿主要同时加载两个**（两个都已在真机 `LoadLibrary` 成功）。
>
> **仍未解决的是滚动**：`imePoint()` 里有核心自己的 TODO——
> 滚动时光标不在可见区域的情况没处理。

## 3. 渲染：这是主体，先走便宜的那条

今天 `src/renderer/OpenGL.zig` 里有 **4 处 `switch (apprt.runtime)`**，其中 **3 处**
有 `embedded` 分支而且是空的（第 4 处是 `displayRealized`，只有 GTK 会调，`else` 是
`@compileError`）：

```zig
apprt.embedded => {
    // TODO(mitchellh): this does nothing today ...
    // libghostty is strictly broken for rendering on this platforms.
},
```

两条路：

| | 要写多少 | 参照 |
| --- | --- | --- |
| **A. 把 WGL 填进那 3 处** | 数百行 | OpenGL 后端本体已有 582 + `opengl/` 1440 行 |
| B. 写 D3D11 后端 | 一两千行 | `Metal.zig` 502 + `metal/` 2205 行 |

**先做 A。** 要填的是三件事：在 `HWND` 上建 WGL 上下文、`wglMakeCurrent` 的线程归属、
`SwapBuffers` 的时机。注意 GTK 那支的注释说 **GTK 不支持线程化 OpenGL，所以它在渲染
线程里只做状态设置、真正的绘制放主线程**——Windows 上你可以让渲染线程持有上下文，
但这是个要明确决定的事，不能照抄 GTK。

`generic.zig`（3379 行）是共享实现，后端只要提供 `Target` / `Frame` / `RenderPass` /
`Pipeline` / `Buffer` / `Sampler` / `Texture` / `shaders` 那组契约，**A 方案里这些
都已经有了**，缺的只是上下文的生命周期。

**但空缺不止 `OpenGL.zig` 那一层，构建系统里还有一道。** `src/build/SharedDeps.zig`
原来是 `if (step.kind != .lib)` 才编译 glad，而 `embedded` 就是 `.lib` 产物——
**所以 libghostty 从来没链过 GL 加载器**。

也就是说，「`embedded` 只跟 Metal 配对」这件事**被固化在两个层面**：`OpenGL.zig` 里
那几支是空的，**以及构建系统根本不给 lib 产物编 GL 加载器**。**就算有人把那几支填了，
也照样链不上**，报的还是 `undefined symbol: gladLoaderLoadGLContext`——这个错误看起来
完全不像是「渲染后端没写」的后果，会把人引到错误的地方去找。

改法是把条件放宽成「exe，或者渲染后端是 OpenGL」。macOS 默认 metal
（`renderer/backend.zig` 的 `Backend.default`），条件退化成原样，行为不变。

## 4. Rust 侧的壳要满足什么

**6 个回调**（`ghostty_runtime_config_s`）：

```
wakeup_cb                    唤醒事件循环
action_cb                    72 种 action 的分发，返回 bool（不支持就 false）
read_clipboard_cb
confirm_read_clipboard_cb
write_clipboard_cb
close_surface_cb
```

**72 种 action**（`src/apprt/action.zig`），前几个是这个味道：
`new_tab` `close_tab` `new_split` `toggle_fullscreen` `move_tab` `goto_tab`
`goto_split` `goto_window` `resize_split` `size_limit` `initial_size` `cell_size`
`scrollbar`……**可以只实现一部分**，不支持的返回 `false`。

**事件推进**：`ghostty_app_tick`、`ghostty_surface_key`、`ghostty_surface_mouse_*`、
`ghostty_surface_ime_point`、`ghostty_surface_draw`。

**参考实现就在仓里**：`macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift`
（`ghostty_surface_new` 在 409 行）和 `SurfaceView.swift`（639 行把 `NSView` 指针递
过去）。**Rust 侧要做的是同一件事，把 `NSView*` 换成 `HWND`。**

> **参照 macOS 的时候，有一件事不要从行数上推。**
> Swift 侧一个文件「碰不碰 `NS*`」和「这段能不能照搬」不是同一个量，方向还不一致——
> 转发表符号密度低是因为代价由被它转发的地方付；给脚本接口做的 C 枚举镜像
> 不碰平台符号但在 Windows 上整段归零。规模怎么估见
> [design.md 第一节](design.md)（拿两边都写完的功能面直接比行数，实测 0.88），
> 哪些不是估计误差而是**待人拍板**见
> [status.md 五之二](status.md)。
>
> **已经译完可以直接用的只有一份**：`windows/split-tree/`，分割树的算法，
> 零依赖、`cargo test` 在 macOS 上就能跑。它不依赖 Win32 也不依赖 libghostty，
> 只回答「谁在哪、多大」，窗口创建仍然是宿主的活。

### 4.1 输入法：宿主要满足的第二份契约（TSF）

除了 `ghostty_runtime_config_s` 那 6 个回调，Windows 宿主还要实现
**`ITextStoreACP`（26 个方法）**，否则中文/日文/韩文输入法根本起不来。

**这一块已经在步3 单独验过**（见步5 表格），结论是**约 470 行、不是主体**。
但下面四条是验的过程中撞出来的，**每一条写错都不会编译失败**，所以必须写在这里。

#### 候选窗定位是「被问」，不是「去设」

宿主**没有**「把候选窗放这儿」的 API。TSF 反过来问你三件事，你答的是**屏幕坐标**：

| 方法 | 你必须答对什么 |
| --- | --- |
| `GetTextExt(acpStart, acpEnd)` | 那段文字的包围盒 |
| `GetScreenExt` | 整块可视区域的包围盒 |
| `GetWnd` | 承载的 `HWND` |

也就是说**宿主必须持有一个 ACP（UTF-16 码元下标）→ 像素矩形的映射**。
对终端这反而容易：定宽网格，纯算术，不用问字体引擎。

#### 宽度表必须复用核心那一份，绝不在 Rust 侧留第二套

ACP 是 **UTF-16 码元**下标，而 CJK 一个码元占**两个单元格**。
上面那个映射要用**和渲染完全相同的宽度逻辑**。

**Rust 侧一旦自己写一份宽度表，就会和核心那份分歧**，症状是候选窗和光标错位，
而且**只在特定字符上错**——最难查的一类 bug。步3 的探针里 `char_cells()` 是个
手写范围表，那是探针的权宜，**接线时必须换掉**。

同理还有 **UTF-16 ↔ UTF-8**：ACP 索引 UTF-16，Ghostty 核心是 UTF-8，
这层换算错了同样表现为候选窗偏移，而不是明显的崩溃。

#### `RequestLock` 是重入的，任何借用都不能跨过它

`RequestLock` 不是「给我一把锁」，是**「你现在同步回调我一次，我在你的调用栈里
干活」**：宿主要在 `RequestLock` 里调 `sink.OnLockGranted()`，
**TSF 会在那个栈里反过来打 `GetText` / `SetText` / `SetSelection` / `GetTextExt`**。

Rust 里的具体后果：**任何 `RefCell` 借用都不能跨过 `OnLockGranted`**，否则运行期
直接 panic。授锁期间收到的异步锁请求还要排队、放锁后循环补发（返回 `TS_S_ASYNC`）。

**编译器不管这件事。写错了不会编译失败，只会在某个输入法某个时刻炸。**
这是整个 TSF 实现里最该 code review 的一处。

#### `OnLayoutChange` 必须在**滚动**时也发

窗口移动、改大小要发 `OnLayoutChange`，这个想得到。
**终端滚动时也必须发**，这个想不到：一滚，组合串在屏幕上的位置变了，
但**文档内容没变，TSF 不会自己来问**。
漏了的症状是「大部分时候对、一滚就错」。

#### 键盘必须手动转发给 TSF

`TranslateMessage` / `DispatchMessage` 不够。消息循环要走
`ITfMessagePump::GetMessageW`，且对 `WM_KEYDOWN` / `WM_KEYUP`
**先 `ITfKeystrokeMgr::TestKeyDown` 再 `KeyDown`，被吃掉就不再往下派发**。

少这一步组合串根本起不来，而症状是「输入法看着切过去了，就是打不出字」，
很难往这儿想。形状和 macOS 的 `interpretKeyEvents` 一致，可照抄思路。

**连带的产品决策**：组合串活跃时，输入法会吃掉 `Alt+F4` / `Ctrl+W` 这类快捷键
（步3 实测：组合中按 Alt+F4 关不掉窗口，要先 `Esc` 取消组合）。
这是 TSF 的正常语义，不是 bug，但 Ghostty 要决定是接受（和记事本一致）
还是在 `KeyDown` 前拦一层白名单。**写键盘路由时就要定，别拖。**

#### 上面这几条各自的证据强度

**不是每一条都验过，别一视同仁地信。**

| 内容 | 出处 |
| --- | --- |
| 候选窗被问 / `GetTextExt` 三件套 | 真机日志 `C:\app\tsf.log`，坐标可验算 |
| 组合中 `Alt+F4` 被吃 | 真机实测 |
| 宽度表 / UTF-16↔UTF-8 | 探针 `doc.rs`（TSF 探针程序，不在仓库里）的 `char_cells()` 是权宜实现，接线时的已知欠账 |
| `RequestLock` 重入 | 实现时的设计约束，**未在真机上触发过 panic**——这是「写对了所以没炸」，不是「验过了炸不了」 |
| `OnLayoutChange` 要在滚动时发 | **推理，没有真机证据**（探针没有滚动） |

后两条留在文档里是因为**漏了代价大、写错了成本低**，但它们确实是推理不是实测。

## 4.2 名字：什么叫 Ghostty，什么叫 Polter

这个 fork 的产品名是 **Polter**。规则不在任何文档里，但代码里是一致的，
**先读出来再照做，别自己发明**：

| 东西 | 叫什么 | 依据 |
| --- | --- | --- |
| 主可执行文件 | **`polter`** | `src/build/GhosttyExe.zig` 的 `.name` |
| macOS 应用、图标、脚本字典 | **Polter** | `Polter.sdef`、`Polter.icon` |
| Xcode 工程文件、Info.plist 等 | Ghostty | 仓库里原样 |
| 内部库 | `ghostty-internal.dll`、`ghostty-vt.dll` | 构建产物名，与上游一致 |
| 测试二进制 | `ghostty-test.exe` | 同上 |

**一句话：面向用户的一切是 Polter，内部文件名沿用 Ghostty。**
后半句不是懒惰——**改内部名会让每次跟上游 merge 都打架**，而那是这个 fork
要长期做的事。macOS 那边就是这么处理的，Windows 照同一条线走。

### Windows 特有的几处，容易漏

这些在 macOS 上没有对应物，所以照抄 macOS 的清单会漏掉：

- **窗口类名**（`RegisterClassExW` 的 `lpszClassName`）
- **窗口默认标题** —— shell 用 `set_title` action 改标题是正常终端行为，
  但**还没有标题时显示的那个必须是 Polter**
- **任务栏显示名与 AppUserModelID** —— 错了的表现是任务栏上出现两个图标、
  跳转列表串味，而且不会报任何错
- **单实例互斥体名**（如果将来做单实例）
- **注册表键**（如果将来写配置或做文件关联）

### 为什么现在就要定

Windows 宿主是从一个几百行的原型长起来的。**原型里的名字会被复制到它长出的
每一处**——等它到两万行再改，就是满地找。这一节写在这里，就是为了让写壳的人
在第一天看到它。

## 5. 分几步走，每步的验收条件

**别跳步，每一步的验收都是「拿得出来的东西」，不是「看起来对」。**

| 步 | 做什么 | 验收 |
| --- | --- | --- |
| **0** | 复现第 0 节两个实验 | 自己机器上退出码对得上 |
| **1** | 修五处 POSIX 假设 | `zig build -Dtarget=x86_64-windows-gnu -Dapp-runtime=none` **退出码 0** |
| **2** | 加 `GHOSTTY_PLATFORM_WIN32` | 头文件里有了，macOS 构建不受影响（全量测试仍绿） |
| **3** | **TSF 最小验证** ✅ **已完成** | 已验：微软拼音可组合上屏、候选窗贴在插入点。**TSF 胶水约 470 行，占 Rust 壳的 3~5%，不是主体。**详见 4.1 |
| **4** | WGL 上下文 | 一个 `HWND` 上出现一块能刷新的画面（先不接终端） |
| **5** | 接起来 | Windows 上跑出一个能敲命令、能看回显的终端 |
| **6** | 插件宿主 | 命名管道通了，插件能起能收能杀 |

**第 3 步的位置是有意的：它排在渲染之前。** TSF 是这条路上唯一不能靠读代码回答的
问题，也是中文用户最先撞到的一块。**如果它比预期难得多，那应该在写两万行壳之前就
知道，而不是之后。**

**结果：不比预期难，比预期容易。** `windows-rs` 的 COM 实现侧是像样的——26 个方法的
`ITextStoreACP` 首次编译只有 9 个错误，全是类型别名和参数形状的小错，没有一个是
vtable、引用计数或线程模型级别的问题；交叉编译的 exe 拷到测试机**第一次运行就完成了
完整握手**。**这条路上风险最高的一件已经拆掉。**

---

## 5.1 上面那张表只到「编得过」。真正的目标是 `polter.exe`

第 0–6 步是**编译层面的准备**，做完之后仍然**没有一个能用的东西**：
`-Dapp-runtime=none` 产出的是库，Windows 上**没有任何 apprt**——没有窗口，没有事件
循环，没有人调 `ghostty_surface_new`。

目标是：**一个 `polter.exe`，在 Windows 上能用，能力和 macOS 版一致。**
下面这张表是按真机数据排的，**不是按原文档的猜测**。

### 阻塞项，按「挡住多少别的东西」排

| | 是什么 | 规模（量过的） | 状态 |
| --- | --- | --- | --- |
| **B1** | **没有 Zig apprt** | 对照 `apprt/gtk` 23,669 行；**72 个 action 里要实现 54 个**才对齐 macOS 能力 | `src/apprt/` 下一行没写。**但 Windows 走的是 C API + Rust 宿主**，那条路上的应用壳已经在跑，见 `status.md` 二之四 |
| **B2** | **Polter 认证链断了** | `custom env vars` 测试失败 → `GHOSTTY_POLTER_TOKEN` 传不进子进程 → **agent 连不上 Polter** | 根因未定位 |
| **B3** | ~~**IPC 要换命名管道**~~ | 当时量的是 `Server.zig` 945 行里 19 处碰 `std.Io.net`、关停相关 98 行。协议/握手/token **没动**，如当初所说 | ✅ **已完成（#54）**。今天的 `Server.zig` 959 行里只剩 **3 处**提到 `net`（import、`has_unix_sockets` 分支、`UnixAddress.max_len`）；无插桩交付版 5/5 通过，见 `status.md` 第二节 |
| **B4** | **屏幕上没画出东西** | WGL 代码已就位、GL 4.3 已验；**缺的是 `HWND`，属于 B1** | 随 B1 解决 |
| **B5** | **插件起不来** | 出厂 8 个插件里 7 个是 `.sh`（`plugins/` 下第 9 个是 `_sdk`，那是库，不声明 `exec`）；另有 `NoDevice` 是本次移植自己的 bug | 见 5.3 |
| **B6** | **目录逃逸** | `Transcript` 防逃逸测试失败，Windows 的 `\` 也是分隔符 | **安全，不排队** |

### 里程碑，每个都以「拿得出来的东西」结尾

| | 做完能干什么 | 验收（观察得到，不是「看起来对」） |
| --- | --- | --- |
| **M0** | 知道 GL 能不能用 | ✅ **已完成**：真机 ICD 全硬件、core 4.3 创建成功 |
| **M1** | **屏幕上出现终端画面** | 一个 Rust 宿主开出窗口，`ghostty_surface_new` 成功，**画面刷新可见**（截图为证）。含 14 个必须实现的 action |
| **M2** | **能敲命令、能看回显** | 真机上跑起 `cmd.exe`，输入 `echo hi` 看到回显。**这是 ConPTY 第一次被端到端验证** |
| **M3** | **能打中文** | 微软拼音组合上屏，候选窗贴在插入点（步 3 的探针已证可行，这里是接进真终端） |
| **M4** | **Polter 监管层能用** | `server_test` 14 个在 Windows 上全绿；总管终端能看管另一个终端 |
| **M5** | **插件能起能收能杀** | 命名管道通、插件启动、stderr 收得到、能杀掉 |
| **M6** | **能力对齐 macOS** | 40 个「对齐所需」的 action 实现完；标签、分屏、全屏、配置、快捷键可用 |

**M1 和 M2 之间没有依赖**：`Pty.open` 发生在 io 线程、`Surface.init` 返回之后，
所以 **ConPTY 起不来不影响渲染出画面**，两条可以并行。

### 5.2 M1 之前必须知道的四件事（否则会画不出来且症状不指向原因）

**这四条是 `wgl.zig` 对宿主的隐含要求，代码里没写，违反了不会报错。**

1. **窗口类必须带 `CS_OWNDC`。** `wgl.init` 调一次 `GetDC(hwnd)` 并**把 HDC 持有到
   上下文销毁**。没有 `CS_OWNDC` 时 DC 来自系统的 5 个缓存 DC，用完必须还，
   跨帧持有是未定义行为。
2. **不能留默认背景刷，或者必须吃掉 `WM_ERASEBKGND`。** 否则 GDI 会在 GL 后缓冲
   之外把窗口刷成背景色，**表现为闪烁**。
3. **尺寸和 DPI 要宿主推。** `Surface.Options` **没有宽高字段**，`embedded.zig` 里
   硬编码 800×600。宿主必须在 `WM_SIZE` 调 `ghostty_surface_set_size`、
   DPI 变化时调 `ghostty_surface_set_content_scale`。

4. **上下文必须建在一个已经是最终尺寸的窗口上。**【实测，两个变量已拆开】
   `ghostty_surface_new` 内部就在**主线程**调 `wgl.init`，上下文当场创建，而
   `wgl.zig` 的 `clientSize`（`OpenGL.surfaceSize` 用它）是**问窗口要
   `GetClientRect`**。宿主如果先把窗口建成一个占位尺寸（子窗口很容易写成
   100×100 再 `layout` 里放大），**整段 GL 初始化照样全部成功**——`surface_new`
   返回非 null、`GetPixelFormat` 读得到格式、窗口照收 `WM_PAINT`——**但屏幕上
   一个像素都没有**，而且**事后调 `ghostty_surface_set_size` 补救不回来**
   （黑屏那一版日志里 `pushed size 984x631` 是打了的）。

   **可见性不在这条里，这是量出来的不是想出来的。** 一次只把窗口留在隐藏、
   但尺寸先设成最终值的对照运行**画面正常**。最初的归因（「必须先显示」）
   因此是错的，被这次对照推翻。

   **还没查清的是机制**：已证「先设成最终尺寸就没事」，**未证**「init 之后的
   resize 追不上」。如果是后者，那么**用户拖动窗口边缘也会撞上同一件事**——
   那就不是一条 init 期的约束，而是一个 resize 缺陷。判据很便宜：拖一次窗口
   看终端跟不跟。

> 步 3 的 TSF 探针**前两条都不满足**（`RegisterClassW` 里没有 `CS_OWNDC`，
> `hbrBackground` 是 `WHITE_BRUSH`）。**直接拿它接 WGL 会踩这两个坑。**

### 5.3 Windows 上插件用什么：**每个插件自己补一份**

出厂插件 8 个声明了 `exec`，**7 个是 `provision.sh`**（claude-code / codex / deepseek /
gemini / kimi / opencode / qwen-code），1 个是 `archive.py`。
Windows 不能直接执行 `.sh`，报 `error.InvalidExe`——真机上那几个插件测试全挂在这。

**决定：7 个各补一份 `.ps1`/`.cmd`。** 曾经考虑过的另外两条：要求用户装
git-bash/WSL（给每个 Windows 用户加前置依赖），或者让宿主按扩展名替插件选解释器
（插件一个不动）。

**没选「宿主按扩展名猜」，理由不是代价，是它把责任放错了地方**：

> **插件本来就该声明自己支持哪些系统，不支持的系统上根本不该被加载。**

宿主替插件猜解释器，等于把一件本该由插件明说的事藏进宿主——**能不能在这个系统上跑，
是插件的属性，不是宿主的推断。** 而这 7 个恰好都需要多系统支持，所以各补一份是本分。

**由此引出一个当前缺失的机制，和这 7 个脚本是两件事：**

| | 什么 | 什么时候 |
| --- | --- | --- |
| 现在 | 7 个插件各补一份 Windows 脚本 | M5 |
| **以后** | **插件清单里声明支持的系统，宿主按声明决定加不加载** | 未排期 |

第二条是**机制的缺口**：今天没有任何地方能表达「这个插件不支持 Windows」，
所以一个平台专属的插件只能在启动失败时才暴露，而那时它已经在用户的失败清单里了。
这不是这 7 个插件的问题，是插件模型缺一个字段。

## 5.4 UI 那一档（S3）的分解：七块，每块单独可交付

**背景**：`design.md` §1.3 把 UI 装饰放在 S3 档，系数区间 0.15–0.6，
用户 2026-09-01 裁决取 **0.6 端（接近 macOS 的精细度）**，折合约 **2,617 Rust 行**。
**那是一个数，不是一份任务。** 这一节把它拆成能单独做完、单独验收的块。

**先说三条贯穿全节的判断**，它们决定了下面每一块的形状：

1. **AppKit 白送的，Windows 全要手写**；反过来 **macOS 为自己的历史付的账，不要搬**。
   最典型的是标题栏标签：macOS 用了 **两套实现**（`TitlebarTabsVenturaTerminalWindow`
   469 行给 macOS 13–15，`TitlebarTabsTahoeTerminalWindow` 190 行给 macOS 26），
   合计 659 行，**占 Window Styles 的 46%**。Windows 只有一套非客户区自绘机制，
   **写一套**。
2. **「接近 macOS 的精细度」是关于观感的裁决，不是关于实现路径的。** 同样的观感，
   Win32 有些地方更贵（标签条的一切交互），有些地方更便宜（分屏的树遍历已经在
   `windows/split-tree/` 里了）。
3. **验收判据不能是「看起来对」。** 下面每一块的判据都写成可观察的东西。

### 各块的实测底数

macOS 侧代码行（去空行去 `//`），2026-09-01 实测：

| 组件 | 代码行 |
| --- | --- |
| Window Styles（5 个文件） | 1,447 |
| `SurfaceView.swift`（surface 上的浮层） | 912 |
| 插件页 / 插件设置 / 插件菜单 | 621 |
| 命令面板（2 个文件） | 569 |
| Splits 的三个视图 | 442 |
| 关于 / 设置 / 配置错误 | 371 |
| **合计** | **4,362** |

> ⚠️ `design.md` §1.3 原写 4,441，**高了 79**：插件视图那一格当时写的是估计值
> `~700`，实测是 621。分档表里其余各格与实测一致。

---

### 块 A · 窗口外壳与标题栏（macOS 1,447 → 估 450–600 → **实际约 500 / 330 代码行**）【已完成】

> **回填（第四个数据点）**：`shell.rs` **452 行 / 292 代码行**，加上接线
> （`main.rs` +43、`strip.rs` +24/−3、`tabs.rs` +11/−18、`Cargo.toml` +1），
> 合计**约 500 行 / 330 代码行**——**落在 450–600 区间内**。
>
> **和块 B 的对比才是这个数据点的价值**：块 B 实际 701/523，估 280–360，超出
> 1.9~2.5 倍；块 A 落在区间内。**差别不在估算精度，在范围是否变过**——块 B 的溢出
> 策略是估完之后才裁的，双击改名要真输入法是实现时才浮现的；块 A 的范围没变。
> **所以「按倍率上调所有估算」是错的结论**：该问的是「这一块的范围还会不会变」。
>
> **不计入的脚手架**（在 `strip.rs` 里，属于验收机制不属于 UI）：
> `--striptest` 的 `script_step`/`synth_click`/`synth_drag` **164 行 / 111 代码行**，
> 状态行 `state_line`/`log_state` **56 行 / 38 代码行**。
> 这些是「宿主自己走完流程并把结果打成数」的代价，**它随验收方式走，不随 UI 面积走**。

**macOS 侧是什么**：`TerminalWindow` 607 行是基类（背景色与不透明度、明暗外观同步、
tab bar 出现/消失回调、标题栏字体、标签颜色指示、zoom 按钮、内联标题编辑、更新徽标）；
另外 840 行是**四种标题栏样式**，其中 659 行是同一个功能的两套版本适配。

**Windows 侧做什么**：
- 非客户区自绘：`WM_NCCALCSIZE` 吃掉标题栏 + `WM_NCHITTEST` 留出系统按钮区
- 明暗与标题栏配色：`DwmSetWindowAttribute` 的 `DWMWA_USE_IMMERSIVE_DARK_MODE`
  和 `DWMWA_CAPTION_COLOR`。**`CAPTION_COLOR` 需要 Win11 22000+，Win10 上没有**，
  要有 fallback（自绘整条 caption）。**这一项 macOS 靠 `NSAppearance` 白送。**
- 把标签画进非客户区（从现有的 `paint_strip` 升级）
- 内联标签标题编辑

**明确不做**：
- **第二套标题栏实现**（macOS 那 659 行的存在理由是 OS 版本差异，Windows 没有对应问题）
- **透明/模糊标题栏**：`DWM_BLURBEHIND` 和 `SetLayeredWindowAttributes` 与 WGL 在同一
  窗口上共存是老问题，而渲染路径已经硬性要求 GL 4.3。**单独立项，不进这一档。**

**验收**：
- 深色配置下截图，caption 区域的像素颜色与终端背景色一致（**取一个像素比对，不是目视**）
- Win10 与 Win11 各一张截图，两边都不出现「白色系统标题栏 + 深色终端」的撕裂
- 双击标签进入改名、按 Esc 取消、按回车提交，三种结局各一次

---

### 块 B · 标签条的交互（macOS ≈ 0 行 → 估 280–360）

**macOS 侧是什么：几乎没有行数。** 拖拽重排、关闭按钮、溢出、双击改名，
**全部由 `NSWindow` 的 tab group 白送。**

> **这一块暴露了系数模型的一个结构性缺陷，见本节末尾。**

**Windows 侧做什么**：命中测试（哪个标签／是不是关闭按钮）、拖拽重排与拖拽中的
视觉反馈、关闭按钮的 hover 态、标签过多时的溢出处理。

**⚠️ 这一块的结论是「模型要改」，是给 #73 的输入，不是 UI 侧能自己解决的**：

**拖拽重排不能用数组下标标识标签。** 拖拽是一个跨越多条消息的状态机
（`WM_LBUTTONDOWN` → 若干 `WM_MOUSEMOVE` → `WM_LBUTTONUP`），**中间每一帧都可能重排**，
下标在整个过程里都不稳定。要表达的是「**这个**标签移到那个位置」，
而「这个」在下标世界里没有名字。

- **需要**：`tabs.rs` 的 `Tab` 加一个稳定 id（`TabId(u64)`，永不复用），
  `Op::MoveTab` 从相对位移改成「把 id X 放到位置 N」
- **理由和 `windows/split-tree/` 里叶子用 `PaneId` 是同一条**，而且更强：
  分屏树只在一次操作里重建，拖拽跨越几十帧
- **顺带**：`split-tree` 的叶子已经是 `PaneId` 了，两者最好共用一个分配器，
  否则会出现两套 id 空间和一张映射表

**验收**：
- 三个标签，把第 1 个拖到第 3 个位置，松手后顺序是 2,3,1，**且三个标签的内容
  （各自的 surface）跟着走**——这一条是下标 bug 的直接探针，用下标实现会内容错位
- 拖拽过程中不松手、把指针移出窗口再移回来，顺序不乱
- 标签数超过窗口宽度时，活动标签始终可见

---

### 块 C · surface 上的浮层（macOS 912 → 估 520–710）

**这一块的实测结果推翻了一个推广。** `#74` 在 `SplitTree` 那轮的结论是
「SwiftUI 的结构在 Rust 里大部分归零」——**那条在这个文件上不成立。**
`SurfaceView.swift` 不是一个包装器，它是**一堆真的浮层功能**，SwiftUI 只是书写方式：

按行范围逐块数出来的（覆盖 912 行里的 907，差 5 行是块间零碎）：

| 子块 | 行范围 | 代码行 | 性质 |
| --- | --- | --- | --- |
| `SurfaceRepresentable`（`NSViewRepresentable` 桥） | 544–574 | 11 | **SwiftUI 机械开销 → 归零** |
| Environment / FocusedValue 键 | 1129–1194 | 47 | **SwiftUI 机械开销 → 归零** |
| `SurfaceConfiguration` + `withCValue` | 575–695 | 75 | **不是 UI，是 FFI**——Rust 侧已在 `ffi.rs` 做过 |
| 搜索浮层 | 326–543 | 197 | 真能力（含角落吸附、拖动、按钮样式） |
| 键序列指示器（`KeyStateIndicator` + `KeyCap` + `PendingIndicator`） | 696–912 | 186 | 真能力 |
| `SurfaceWrapper.body` 的组合链 | 7–173 | 116 | 约六成是 modifier 堆叠，四成是「何时显示哪个浮层」的真逻辑 |
| 只读徽标 + 说明气泡 | 984–1077 | 74 | 真能力 |
| 缩放浮层（显示 `80x24`） | 220–325 | 68 | 真能力 |
| 高亮浮层 | 930–983 | 50 | 真能力 |
| 渲染器不健康 / 错误视图 | 174–219 | 40 | 真能力（低频） |
| 焦点移动的延迟调度 | 1078–1128 | 30 | 真能力 |
| 响铃边框 | 913–929 | 13 | 真能力 |

**912 行里只有 128 行（14%）是纯 SwiftUI 机械开销**（`SurfaceRepresentable` 11 +
环境键 47 + `body` 里约六成的 modifier 堆叠 70），**75 行（8%）是 FFI 不是 UI**，
**真能力 658 行（72%）**。而 Win32 画浮层（自绘子窗口或直接在 GL 上画）
**比 SwiftUI 的声明式写法贵**，不便宜。

**所以 0.6 这个系数在这个文件上偏低**：912 × 0.6 = 547，
**而真能力本身就有 658 行**——系数给的预算比要照抄的能力还少两成。

> ### P1 实际数（2026-09-02，已交付未运行）
>
> `search.rs` **416 代码行**、`keyseq.rs` **332**（实现 286 + 测试 46）、
> 新增共享的 `overlay.rs` **21**，另加 `main.rs` +79、`ffi.rs` +34。
> **P1 合计 769 代码行，估的是 320–430——高了 79%–140%。**
>
> **范围没有变过**（P1 从头到尾就是这两项），所以**这是第二个干净的数据点**，
> 和块 E 一样可以用来判系数。块 B 的 701 行不算——它高出去的大头是
> 估算之后才进范围的工作（溢出策略 C、双击改名），**那测的是范围划得准不准，
> 不是系数准不准**。
>
> **差在哪，两条**：
>
> 1. **我按 macOS 行数打了折**（搜索 197 → 估 210–280 只加了一成半），
>    理由写的是「Win32 稍便宜，不需要声明式样式层」。**那条理由是错的**：
>    省掉的样式层是几十行，而 Win32 要自己加的是**跨线程收件箱**
>    （`search_total` / `search_selected` 从核心线程来、`start_search` 的
>    `const char*` 只在回调期间有效）、**子类化 `EDIT` 的键盘拦截**、
>    **三种计数状态的区分**（未答 / 答 0 / 答 n）。SwiftUI 侧这些全在框架里。
> 2. **键序列指示器的键名映射不在估算里**。核心没有 key→名字的 API，
>    macOS 用 SwiftUI 的 `KeyboardShortcut` 白拿，Windows 得自己做。
>    实际靠三段连续区间（字母 20..=45、数字 6..=15、F1–F12 121..=132）
>    把 176 条表压成了算术 + 14 条命名键，**但仍然是估算里没有的一整块**。
>
> **两次干净回填都偏高（块 E +37%~83%、UI-C P1 +79%~140%），
> 而且偏高的原因是同一种**：把「用现成控件/框架」当成净省，
> 却没算目标平台要补的那一圈。**这开始像系数问题而不是单块问题了**，
> 但两点仍不足以定论——第三个干净回填之前不要动 0.6。

**按优先级分三批，允许分批交付**：

| 批 | 内容 | 估 | 为什么是这个优先级 |
| --- | --- | --- | --- |
| P1 | 搜索浮层（macOS 197） | 210–280 → **实际 416** | 终端必需功能，不是装饰 |
| P1 | 键序列指示器（macOS 186） | 110–150 → **实际 332**（含 46 行测试，实现 286） | **有 chord 键位就必须有**：否则用户按下前半个键位后没有任何反馈，无法判断自己在什么状态 |
| P2 | 缩放浮层 + 响铃边框 + 只读徽标（macOS 155） | 130–180 | 有可观察的用途，但缺了不影响用 |
| P3 | 高亮浮层 + 错误/不健康视图（macOS 90） | 70–100 | 低频 |

**验收**：
- 搜索：输入一个词，命中数与 `ghostty_surface_search_*` 返回的一致（**比数字，不比外观**）；
  浮层在窗口四角各吸附一次，缩放窗口后不越界
- 键序列：配一个两段 chord，按下前半段后指示器出现并显示已按的键，
  超时或按下无效键后消失——**三种结局各一次**
- 缩放浮层：拖动窗口边缘，浮层显示的行列数与 `ghostty_surface_size` 一致

---

### 块 D · 分屏的绘制与分隔线（macOS 442 → 估 160–220）

**这一块明显比系数模型便宜**，因为 442 行里的树遍历部分**已经做完了**：
`windows/split-tree/` 的 `layout(bounds)` 直接给出每个 pane 的矩形。

**Windows 侧只剩**：把矩形喂给 `SetWindowPos`、画分隔线、分隔线的命中区与拖拽改比例、
拖拽时的光标形状（`IDC_SIZEWE` / `IDC_SIZENS`）、zoom 时只显示一个。

macOS 的 `SplitView.Divider.swift` 106 行里相当部分是 SwiftUI 手势识别；
Win32 要自己做命中测试，但不需要手势框架。

**验收**：
- 四个 pane 的 2×2 布局，四个子窗口的客户区矩形之和等于内容区面积
  （`split-tree` 已有同名测试 `layout_covers_the_bounds_exactly`，这里是它的真机对应）
- 拖动分隔线，比例变化与 `resize` 的夹紧值一致（**0.1 / 0.9 两端各撞一次，撞不过去**）
- zoom 后只有一个子窗口可见，取消 zoom 后布局与 zoom 前逐像素相同

---

### 块 E · 命令面板（macOS 569 → 估 300–400 → **实际 548，已交付未运行**）

> **2026-09-01 实际数**：`windows/host/src/palette.rs` **776 行 / 596 代码行**，
> 其中实现 **548**、单元测试 48。另加 `main.rs` +14 行（模块声明、一个 action 分支、
> 一行 init）和 `ffi.rs` +4 行（`ACTION_TOGGLE_COMMAND_PALETTE = 11`）。
> **估 300–400，实际 548，高了 37%–83%。**
>
> 差在哪：估的时候把「原生 `EDIT` 控件能省掉自绘和光标管理」算成了净省，
> 但**省下的是文本编辑，没省下列表**——模糊匹配、打分、滚动、命中测试、
> 键盘导航、GDI 绘制这些一行没少。**「用现成控件」省的是控件那一块，
> 不是它周围的那一圈。**
>
> ⚠️ **未在真机运行**（全站离线）。已验证的是：交叉编译 `cargo check
> --target x86_64-pc-windows-gnu` 退出码 0、零 warning，且模糊匹配的 8 个单元测试
> 在 macOS 上跑过（5 处变异注入全部被抓）。**其余部分未运行。**

高频交互，**优先级高于插件页和设置**。要做：无边框子窗口、输入框、模糊匹配、
列表绘制与滚动、键盘导航、执行 action。

**一个判断**：输入框用原生 `EDIT` 控件能省掉自绘和光标管理，
**但它自带一份和终端不同的 IME 行为**——命令面板打开时 TSF 的焦点归属要明确交出去
再收回（`ime_focus(false)` / `ime_focus(true)`），否则会出现「面板里打不了中文」
或「面板关了终端的输入法不回来」。**这一条现在没人验过。**

**验收**：输入两个字符后列表条目数与预期一致；上下键选中项跟随；回车执行的 action
与选中项一致（**读日志里的 action 名，不看界面**）；打开面板 → 输入中文 → 关闭 →
在终端里输入中文，两次都成。

---

### 块 F · 插件页 / 设置 / 关于（macOS 992 → 估 300–420）

**判断：这一档整体降级，且关于框应该大幅缩水。**

- **关于框**：macOS 的 263 行里有 40 行是循环图标动画。Windows 上一个自绘对话框
  显示版本、提交、许可就够，**30–50 行**。
- **设置**：`SettingsView` 26 行只是个壳（真正的配置是编辑文件），
  `ConfigurationErrorsView` 55 行是配置错误列表——**后者要做**（配置写错了要看得见），
  前者做成「打开配置文件」一个按钮即可。**50–70 行**。
- **插件页** 621 行是真的 UI，**220–300 行**。

**验收**：故意写坏一行配置，重载后错误列表里出现该行的行号与消息；
插件页列出的插件数与 `plugins/` 下的数量一致。

---

### 块 G · QuickTerminal（macOS 877，属 S4 不属 S3 → 估 300–400 + 全局热键 60–100）

用户裁决「在 v1 射程内」，连带全局热键。**它是独立可交付的一块，顺手在此分解。**

**真正归零的只有约 38 行，不是一大块**——这一条我第一次写的时候说过头了，
逐个文件核过之后收回：

| 文件 | 行 | 在 Windows 上 |
| --- | --- | --- |
| `QuickTerminalSpaceBehavior` | 28 | **归零**，Windows 没有 Spaces 这个概念 |
| `QuickTerminalScreen` | 29 | **大部分要做**：三种模式里 `main` / `mouse` 在 Windows 上同样成立，只有 `macos-menu-bar` 那支（约 10 行）归零 |
| `QuickTerminalScreenStateCache` | 78 | **完全要做**。它按稳定的显示器 UUID 记住每块屏上一次的窗口位置——**Windows 有一模一样的问题**（多显示器、显示器会插拔），只是键要换成 `GetMonitorInfo` 的设备名或 `DISPLAYCONFIG` 路径 |
| `QuickTerminalController` 等其余 | 742 | 要重写，不是丢掉 |

**Windows 侧做什么**：`WS_POPUP` 无边框窗口、从屏幕边缘滑入的动画、失焦自动隐藏、
`RegisterHotKey` 的全局热键（**注意它和 macOS event tap 不同：`RegisterHotKey` 是
系统级独占，注册冲突会静默失败，返回值必须查**）。

**验收**：热键按下 → 窗口从配置的边缘滑入并取得焦点；再按 → 滑出；
点击别处 → 自动隐藏；**热键被别的程序占用时，启动日志里有一行明确的失败**
（不是静默）。

---

### 加总核对：2,617 这个数碰巧对，但它对的方式有问题

| 块 | 估算 |
| --- | --- |
| A 窗口外壳与标题栏 | 450 – 600 → **实际约 500 / 330 代码行** ✅ |
| B 标签条交互 | 280 – 360 |
| C surface 浮层 | 520 – 710 |
| D 分屏绘制 | 160 – 220 |
| E 命令面板 | 300 – 400 |
| F 插件 / 设置 / 关于 | 300 – 420 |
| **S3 合计** | **2,010 – 2,710**（中心 ~2,360） |

`design.md` §1.3 的 S3 是 4,362 × 0.6 = **2,617**，落在这个区间的上半。
**但这是巧合，构成对不上：**

- **D 只有 442 × 0.37**（树遍历已在 `split-tree` 里做完），**F 只有 992 × 0.36**
  （关于框和设置页在 Windows 上本来就该小）——这两块加起来比系数模型少约 **600 行**
- **B 在系数模型里的预算是 0**，因为它在 macOS 侧的行数**接近 0**（AppKit 白送），
  而 Windows 要写 **280–360 行**

**高估的部分抵消了漏掉的部分**，于是总数看起来对。

> ### ⚠️ 系数模型有一个结构性盲区，S4 也一样
>
> **以 macOS 行数为分母的模型，对「macOS 行数接近 0、但 Windows 必须手写」的项天然看不见。**
> 块 B 是最干净的例子：整整 280–360 行完全在模型之外。块 A 里的
> `DWMWA_CAPTION_COLOR` 与 Win10 fallback 同理——macOS 靠 `NSAppearance` 白送。
>
> **这个盲区不限于 S3。** `design.md` §1.3 的 S4（13,089 行 × 0.7–1.0）用的是同一个模型，
> 所以它也漏掉了同一类项。**已知的 S4 盲区候选**：右键菜单（macOS 的
> `menu(for:)` 58 行 + `NSMenu` 白送 vs Win32 的 `TrackPopupMenu` 全手写）、
> 拖放（`NSDraggingDestination` vs `IDropTarget` 手搓 COM）、
> 无障碍（macOS 的 `NSAccessibility` 覆盖 vs Windows 的 UIA 提供者）。
>
> **不要因此把区间整体上调**——那是拿一个没量过的修正去改一个量过的数。
> **正确的做法是：每完成一块，把实际行数记在这里，用真实数替换估算。**
> 上一轮的教训是「结论对、推导错，两件事都成立」；这一轮是同一个形状的第二次出现。

### 交付顺序

**B → A → D → C(P1) → E → C(P2) → F → G**

理由：**B 排第一是因为它的结论是「模型要改」**——`TabId` 越晚加，越多代码要跟着改，
而它挡着 A（标题栏里的标签要能拖）。D 排在 C 前面是因为 `split-tree` 已经写完了，
接线成本最低、能最早拿出一个可见成果。C 的 P1 两项（搜索、键序列指示器）是功能不是装饰，
排在 E 之前。F 和 G 都可以并行插队，互不挡路。

## 6. 交叉编译与测试

```sh
# Zig 那一半（从 macOS，零配置）
zig build -Dtarget=x86_64-windows-gnu -Dapp-runtime=none -Drenderer=opengl

# Rust 那一半
rustup target add x86_64-pc-windows-gnu
cargo build --target x86_64-pc-windows-gnu     # 需要 mingw-w64
```

**两半都用 `-gnu` ABI，别混。** 一半 msvc 一半 gnu 链不到一起。

**只有测试需要 Windows 机器。** 编译全在 macOS 上。

### 会让你把失败读成通过的五件事

这五条都是真踩到的，而且它们是**同一类东西：工具沉默地给你一个看起来合理的错误答案**。
不是报错、不是崩溃——是一个能读、能信、而且是错的结果。这次移植里这类事出了五次，
所以判断「成了没有」时，**先问工具凭什么知道，再看它说了什么**。

#### 编译错误会挡住链接错误——「还差 N 处」永远是下限

修完 5 个编译错误才看得见 `localtime_r`（§1.5）。**在编译阶段通过之前，任何
「只差 N 处」都是被编译阶段挡住的下限，不是全貌。** design.md §六 那个「只差 4 类」
的结论就是这么产生的。这句对步 4 / 步 5 同样成立。

#### 这个 shell 是 zsh：`${PIPESTATUS[0]}` 是空值

```sh
zig build ... 2>&1 | tail -25; echo "EXIT=${PIPESTATUS[0]}"   # 打印 "EXIT="，读起来像成功
```

正确做法三选一：`${pipestatus[1]}`（zsh 数组小写、下标从 1）、
`set -o pipefail`、或者**别用管道**：`cmd > x.log 2>&1; echo "EXIT=$?"`。
并且**不要只 `tail`**，失败信息经常在中间。

#### 测试日志里的 `failed command:` 不一定是失败

```
failed command: ./.zig-cache/o/.../ghostty-test --cache-dir=... --listen=-
```

根因在 `src/main.zig` 的 `test {}` 块注释里（`src/lib_vt.zig` 有同样一份）：

> Zig 0.16.0 has made test logging more strict. Now, *anything* that gets printed to
> stderr results in a "failed command" message, even if the tests ultimately passed.

**只要测试往 stderr 打了任何东西，这行就会出现，哪怕全部通过。**
（本仓的正常噪声：keychain 查不到、测试 spawn 的 `/bin/sh`、`claude-code: status=provisioned`。）

**判据**：别看这行，也别只信退出码，**加 `--summary all` 看计数**：

```sh
zig build test -Demit-xcframework=false --summary all > full.log 2>&1; echo "EXIT=$?"
→ Build Summary: 86/86 steps succeeded; 3975/3991 tests passed (16 skipped)
```

#### 「编过了」和「你的代码被编到了」是两件事

两个可操作的负对照：

1. **测试过滤器要先量地板。** 不存在的过滤器**也退 0**：

   ```
   -Dtest-filter="zzz-no-such-test-qqq"  → 84/84 passed    ← 地板（匿名 test 块）
   -Dtest-filter="daylog"                → 94/94 passed    ← 多出 10 个才算跑到
   ```

   **单独一个「filter=X → EXIT=0」是零信息量的。**

2. **平台分支要查产物，不能只看编过。** `switch (builtin.os.tag)` 在编译期折叠，
   只分析命中的那一支——所以「Windows 编过了」不等于「Windows 分支被编了」。
   查导入表最直接：

   ```sh
   strings -a zig-out/lib/ghostty-internal.dll | grep -x CreateNamedPipeW
   ```

   同理，要确认某个 `switch (apprt.runtime)` 的分支真被分析到，最省的办法是往里塞一个
   `@compileError` 再编一次——报出来才说明它在分析范围内。

#### 写在「没人引用的类型」内部的测试，永远不会执行

**而测试计数和退出码都不会告诉你。**

`embedded.zig` 里那个锁 C 头文件的 ABI 守卫 test **嵌套在 `PlatformTag` enum 容器内**。
在 `src/apprt.zig` 的 test 块里写 `_ = embedded;` **不足以启用它**——那只够到文件的
顶层容器，而 **Zig 只分析被真正引用到的容器**，嵌套容器里的 test 根本不存在。

实测（2026-08-31）：

```
方案甲 _ = embedded;               → 3975/3991，总数纹丝不动
   负对照（故意改坏头文件）        → 依然 EXIT=0
   3991 个测试名 grep PlatformTag  → 0 次命中      ← 三条证据一致：什么都没启用

方案乙 _ = embedded.PlatformTag;   → 3976/3992，正好 +1，零既有失败
   负对照                          → EXIT=1，报得出是哪个 key 错位
```

`action.zig` 那批同样嵌套的 `test "ghostty.h ..."` 之所以能跑，是因为
`Target.Key` / `Action.Key` 被 C API 代码真实引用了——**不是因为写法不同，
是因为恰好有人引用**。

**推论：在这个仓库里，把测试写进一个没人引用的类型内部，它永远不会执行。**
要确认一个 test 真的在跑，看**测试总数有没有增加**，别看退出码。

### 在 Windows 上自动化测试输入法：两个会让你下错判断的坑

#### 坑一：`type_text` 这类工具绕过输入法

远程控制工具（argus 的 `type_text`、以及大多数 `SendKeys` 类封装）**打出来的字
不经过输入法**。它们用 `SendInput` + `KEYEVENTF_UNICODE` 合成 `VK_PACKET`，
**直接产生 `WM_CHAR`**——这条路径**在设计上就跳过 IME**。

步3 实测：托盘明明显示「中」，`type_text "nihao"` 的结果是
`WM_CHAR U+006E/0069/0068/0061/006F` 五个字母直落缓冲，
**没有组合串、没有候选窗**。

**如果只用这类工具测，你会得出「TSF 没接通」的错误结论。**

正确做法：用**发真实虚拟键/扫描码**的接口（argus 的 `key`），**逐个字母**敲。
换成 `key n` 之后，`OnStartComposition` / `SetText` / 候选窗立刻全都出来了。

#### 坑二：`println!` 重定向到文件是块缓冲，不是行缓冲

Rust 的 stdout 在**不是终端**的时候按块缓冲（约 8KB），不是行缓冲。
把探针的日志重定向到文件时，**跑了半天文件还是 0 字节是正常的**。

**不要据此判断「回调没发生」。** 要么让程序把状态也画在窗口上（步3 的探针就是
这么做的，屏幕那份是实时的），要么显式 `flush()`。

## 7. 已知不解决的

- **Polter 的监管界面**：菜单项、tab 标识位、右键菜单现在锁在 Swift 里，Windows 是
  第三份实现。群聊和任务面板已经是 TUI（2,197 行 Zig），不用重做。
- **上游合入**：改 `ghostty_platform_u` 是动公共 ABI，要他们点头。
- **msvc ABI**：`simdutf` 那个坑没解，`-gnu` 绕过去了。哪天要发 msvc 版本得回来处理。
- **一个既有的 flaky 测试，和 Windows 移植无关**：
  `poltergeist.Resident` 里的
  `test "a plugin can say something to the user, once, and it cannot draw with it"`
  是**顺序/seed 相关的偶发失败**——同一个测试二进制原地重跑，1 次红 2 次绿。
  这次移植撞到过，记在这里免得下一个人以为是自己弄坏的。
- **`apprt.embedded` 的 ABI 守卫测试还没启用**：在 `src/apprt.zig` 的 test 块加
  **`_ = embedded.PlatformTag;`**（注意：`_ = embedded;` 无效，已实测——原因见第 6 节
  「写在『没人引用的类型』内部的测试，永远不会执行」）。代价已验证为零——3991→3992，
  仅新增该测试，无既有失败被暴露（2026-08-31 实测）。

## 延伸阅读

- [design.md](design.md) —— 为什么是这条路，四个被否掉的方案
- `include/ghostty.h` —— 契约本体
- `src/apprt/embedded.zig` —— 宿主拥有生命周期那条路
- `src/renderer/OpenGL.zig` —— `surfaceInit` / `threadEnter` / `threadExit` 那 3 处 `embedded` 分支

## 附录：这份文档里的数字是怎么量的

2026-08-31 复量（任务 #60 延伸）。**只列可量的数字**；结论和实验记录不在此列。

| 数字 | 量法 | 旧值 → 新值 |
| --- | --- | --- |
| `Platform.init` 所在行 | `grep -n "pub fn init" src/apprt/embedded.zig` | 约 393 → **406** |
| apprt action 数（两处） | `src/apprt/action.zig` 的 **`Action.Key`**（408–485 行）成员数；用 `Action = union(Key)`（63–553 行）反向核对，两侧同为 72、双向差集为空。<br>**旧值 73 的来源是把 21 行的 `Target.Key` 混进来了——那个 enum 只有 `app`/`surface` 两个成员。** | 73 → **72** |
| `OpenGL.zig` / `opengl/` 行数 | `wc -l src/renderer/OpenGL.zig` / `find src/renderer/opengl -name '*.zig' -exec cat {} + \| wc -l`（含步4 新增的 WGL） | 461 → **582** / 1,084 → **1,440** |
| `Metal.zig` / `metal/` 行数 | 同上 | 496 → **502** / 2,205（**未变**） |
| 群聊 + 任务 TUI 行数 | `wc -l src/cli/chat.zig src/cli/chat_layout.zig`（1,970 + 227） | 1,984 → **2,197** |
| `generic.zig` 3,379 行 | `wc -l src/renderer/generic.zig` | **未变，已复核** |
| `ghostty_surface_new` 在 409 行 | `grep -n` on `SurfaceView_AppKit.swift` | **未变，已复核** |
| `SurfaceView.swift` 639 行递指针 | `grep -n nsview` | **未变，已复核** |
| `ghostty_runtime_config_s` 6 个回调 | 数结构体里的 `*_cb` 字段 | **未变，已复核** |
| `ITextStoreACP` 26 个方法 | 步3 探针按 `windows-rs` 生成的 trait 逐个实现 | **未变** |

**未改动的：** 第 0 节和第 6 节里带日期的实验记录（`3975/3991`、地板对照、
`_ = embedded.PlatformTag` 的 +1 等）是**某次运行的观测值**，不是对当前树的断言，
照原样保留。
