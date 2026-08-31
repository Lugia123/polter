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

- **`hush()` 里 `DisconnectNamedPipe` 和 `CancelIoEx` 两个都要发**，因为 drain 线程可能
  在 `ReadFile` 的任意一侧：前者管「之后发起的读」，后者打断「已经卡在里面的那次」。
  只写一个都会漏。
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

`src/apprt/embedded.zig` 的 `Platform.init`（约 393 行）加一支，照 `.macos` 那支写。

**加在枚举末尾**：`action.zig` 顶上的注释说得很清楚——顺序直接映射到 C 枚举，为了
ABI 兼容，新成员一律加在最后。平台枚举同理。

**这一块确实只有二十行左右。** 别被它骗了，主体在下一节。

> **但 IME 定位那条缝不在这二十行里。** `embedded` 今天暴露的
> `ghostty_surface_ime_point` 是 **macOS 的形状：宿主给核心一个点**。
> TSF 要的是**反过来、而且是范围**——TSF 问宿主 `GetTextExt(start, end)`，
> 宿主答一个**屏幕矩形**（见 4.1）。这两者不是一回事。
> **具体还缺什么要等步5 接线才知道，记在步5 账上，别到时候当成新发现。**

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
| **A. 把 WGL 填进那 3 处** | 数百行 | OpenGL 后端本体已有 461 + `opengl/` 1084 行 |
| B. 写 D3D11 后端 | 一两千行 | `Metal.zig` 496 + `metal/` 2205 行 |

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
action_cb                    73 种 action 的分发，返回 bool（不支持就 false）
read_clipboard_cb
confirm_read_clipboard_cb
write_clipboard_cb
close_surface_cb
```

**73 种 action**（`src/apprt/action.zig`），前几个是这个味道：
`new_tab` `close_tab` `new_split` `toggle_fullscreen` `move_tab` `goto_tab`
`goto_split` `goto_window` `resize_split` `size_limit` `initial_size` `cell_size`
`scrollbar`……**可以只实现一部分**，不支持的返回 `false`。

**事件推进**：`ghostty_app_tick`、`ghostty_surface_key`、`ghostty_surface_mouse_*`、
`ghostty_surface_ime_point`、`ghostty_surface_draw`。

**参考实现就在仓里**：`macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift`
（`ghostty_surface_new` 在 409 行）和 `SurfaceView.swift`（639 行把 `NSView` 指针递
过去）。**Rust 侧要做的是同一件事，把 `NSView*` 换成 `HWND`。**

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
| 宽度表 / UTF-16↔UTF-8 | 探针 `doc.rs` 的 `char_cells()` 是权宜实现，接线时的已知欠账 |
| `RequestLock` 重入 | 实现时的设计约束，**未在真机上触发过 panic**——这是「写对了所以没炸」，不是「验过了炸不了」 |
| `OnLayoutChange` 要在滚动时发 | **推理，没有真机证据**（探针没有滚动） |

后两条留在文档里是因为**漏了代价大、写错了成本低**，但它们确实是推理不是实测。

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
完整握手**。**这条路上风险最高的一件已经拆掉，剩下的最大未知数是渲染（第 3 节）。**

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
  第三份实现。群聊和任务面板已经是 TUI（1,984 行 Zig），不用重做。
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
