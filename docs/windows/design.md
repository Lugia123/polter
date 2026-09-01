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

> **本章小节 2026-09-01 由 `4.1`–`4.7` 重编为 `1.1`–`1.7`。** 原来的编号和
> 下面那个内容无关的「四、」撞车，`§4.3` 这样的引用会把人领到别处去。
> **在这次改动之前写下的 `§4.x` 引用，把 4 读成 1 即可。**

我最初估的是「Zig 侧改约 20 行」。**那是错的**，因为我当时没读渲染那一侧。真实的
成本是三块，第二块是主体：

| | 大小 | 性质 |
| --- | --- | --- |
| 1. C API 加一个平台成员 | **~20 行** | 真的只有这么多 |
| 2. **渲染后端在 `embedded` 下的空缺** | **数百到两千行** | **主体工作** |
| 3. Polter 自己的 POSIX 假设 | **5 处** | 已定位到行；第 5 处要修完前 4 处才看得见 |
| 4. Rust 侧的壳 | **2 万 – 3 万行**（不含测试；中心 ~2.45 万） | 你要写的那部分 |

> **第 4 行这个区间和它 2026-08-31 之前的写法数值上接近，但两者没有共同的输入。
> 旧推导必须整段丢掉——留着它，换一个文件重来一遍就会得出错的数。**
>
> 旧推导是：数 `macos/` 里有多少行「碰平台框架」，把剩下的当作可移植的部分外推。
> 那个量**不但不等于「不能照搬的行数」，方向还不一致**（见下）。
> 新推导是：**拿两边都已经写完的功能面，直接比行数。**
> 这在 2026-08-31 之前做不到——那时 Windows 侧还没有任何一行跑起来的宿主代码。
> 今天 `windows/host/` 里已经有几千行真跑起来的东西，它就是对照组。
> **具体行数不写在这里**：它每天都在变，钉住的那一版在 §1.1 末尾，连同钉它的时刻。

### 1.1 四个已经两边都写完的功能面

**必须按功能面配对，不能按文件配对。** 两个平台把同一件事切在不同位置——
macOS 把死键和候选串放在 `keyDown` 里，Windows 放在 TSF 里；
按文件比会得出「键盘便宜 5 倍、输入法贵 3 倍」这样两个都不能用的数。

代码行 = 去空行、去 `//` 注释行。

| 功能面 | macOS | Rust | 比 | 方向为什么是这个 |
| --- | --- | --- | --- | --- |
| **输入法** | 184 | 573 | **3.11×** | macOS 实现 `NSTextInputClient` 十来个方法就够，候选窗定位系统代劳；TSF 要手写 `ITextStoreACP` 26 个方法，外加手搓 COM |
| **标签** | 334 | 574 | **1.72×** | AppKit 白送 `NSWindow` tab group 和整套标签 UI；Win32 一个都没有 |
| **全屏** | 261 | 60 | **0.23×** | macOS 要处理原生/非原生两套、Dock、菜单栏、刘海、跨屏；Windows 存一次 `WINDOWPLACEMENT` 就完了 |
| **键盘** | 736 | 136 | **0.18×** | 见 §1.2，这一条单独讲 |

**四个数方向不一致，而且大致抵消。** Win32 在 AppKit 白送的地方贵，
macOS 在自己独有的复杂度上贵。**任何一个「Windows 普遍贵 N 倍」的系数都是错的。**

把今天宿主覆盖的**全部**功能面加总（每一项都是数出来的，没有估计值）：

| 功能面 | macOS 代码行 | 出处 |
| --- | --- | --- |
| 键盘 | 736 | `Ghostty.Input.swift` 键相关 502 + `SurfaceView_AppKit` 的 keyDown/keyUp/performKeyEquivalent/flagsChanged/keyAction 234 |
| 输入法 | 184 | `NSTextInputClient` 扩展 155 + preedit 助手 29 |
| 标签 | 334 | `TerminalController` 里全部 tab 段 |
| 全屏 / 最大化 | 261 | `Helpers/Fullscreen.swift` |
| 窗口 / surface 宿主 / DPI | 186 | `SurfaceView_AppKit` 的 init/deinit/backingProperties/size/trackingAreas |
| 应用启动 | 145 | `AppDelegate` 的 init + willFinishLaunching + didFinishLaunching + 通知中心 + `main.swift` |
| 24 个 action（switch 份额 + 各自 handler） | 519 | 逐个加总；switch 按 24/72 折算 47 |
| 剪贴板（只算已实现的标题复制） | 17 | `copyTitleToClipboard` |
| **合计** | **2,382** | |

Rust 侧同一批：`ffi.rs` 149 + `load_api` 40 + 日志 52 + `main()` 283 + 两个 `wndproc` 118
+ `ime_*` 177 + `tsf.rs` 396 + `keys.rs` 136 + `cb_*` 159 + `tabs.rs` 各段 586 = **2,096**。

> **2,096 / 2,382 = 0.88 —— 在已经写完的功能面上，Rust 比 Swift 少 12%。**
>
> 这个分子里**已经含了 Win32 独有、Swift 侧根本不存在的 241 行**（手写 C ABI、
> `GetProcAddress` 逐个解析、日志）。所以 0.88 不是「移植折扣」，
> 是**净额**：多出来的和省下来的都算进去之后的比。

⚠️ **这个比值钉在一个具体状态上：`windows/host/src` 为 2,817 行 / 2,130 代码行
（2026-09-01 01:56）。** 之所以要钉住，是因为它在被改：同一天 02:07 那份是
3,037 行 / 2,285 代码行，`main.rs` +100、`tabs.rs` +55，**全部是黑屏排查的插桩**
（两个文件里 92 处 `logf!` / `log_line`），没有新增任何功能覆盖面。

**重量的人注意：分子只能算「有对应 macOS 功能面」的行。**
把插桩、临时探针、宿主自用的加速键表算进分子，比值会往上飘，
而分母不动——**得到的会是一个看起来更精确、方向却是错的数。**
重量之前先确认宿主实现的 action 数变了没有（这次没变，仍是 24）；
**没变就说明覆盖面没变，那么分子涨了就是杂质。**

### 1.2 键盘 0.18×：Windows 有时更便宜，而且便宜得有原因

这一段单独写，是因为这份文档其余部分的调子偏向「Windows 处处更贵」，而那是错的。

**macOS 侧那 736 行里，355 行在 Windows 上直接归零。**
`Ghostty.Input.swift` 的 `enum Key`（176 行）和 `var cKey`（179 行）是
**Swift 为 C 枚举做的一份镜像**，给 AppIntents、AppleScript 和快捷键 UI 用的。
全仓一共 5 个使用点，其中 2 个就是 AppleScript 和 App Intents——
**这两样 Windows 上本来就不做。**

**Rust 侧只用六行，是因为那张表核心已经带着了。**
`ghostty_input_key_s.keycode` 不是 `GHOSTTY_KEY_*`，核心拿它去查
`src/input/keycodes.zig` 的**原生列**，Windows 构建下那是第 3 列 —— IBM PC set-1
扫描码。而 `WM_KEYDOWN` 的 lParam 位 16–23 正是扫描码、位 24 是扩展标志。
**转换六行，核心自带的 673 行表干掉剩下的活。**

反过来写一张 VK→key 的表也能工作，但那会是**第二张要和 `keycodes.zig` 保持一致的表**，
而不一致的表现是「某个布局下某个键什么都不做」——不报错，没人会发现。
**这条便宜不是运气，是一次「先读核心怎么查表，再决定自己写什么」换来的。**

### 1.3 分档外推

`macos/Sources` 实测 **35,755 行 / 24,621 代码行**（注释+空行 31%）。

**在 Windows 上没有这个概念，不做 —— 2,543 代码行。**
**这份清单以前不在文档里，而它就是「能力对齐 macOS」这个目标的边界：**

| | 代码行 | 为什么 Windows 上不存在 |
| --- | --- | --- |
| AppleScript | 1,035 | macOS 的应用脚本桥。Windows 无对应物 |
| App Intents | 885 | macOS/iOS 的 Shortcuts 集成 |
| Custom App Icon | 293 | 换 Dock 图标。Windows 的任务栏图标是另一套机制（见 AppUserModelID） |
| Secure Input | 157 | `EnableSecureEventInput`，macOS 独有的键盘记录防护 |
| Services | 57 | macOS 的「服务」菜单 |
| `Helpers/Private`（CGS / Dock） | 82 | 私有 macOS API |
| Language | 34 | macOS 的按应用语言设置 |

**要做，但不是移植（行数与 Swift 无关）—— 另计。**
Update 1,295 行是 Sparkle 专属，Global Keybinds 102 行是 macOS event tap。
Windows 侧分别是「自己的更新器」和 `RegisterHotKey`，
连同品牌六处（AppUserModelID / VERSIONINFO / 互斥体 / 注册表 / 崩溃上报）
一起估 **700 – 1,350 Rust 行**。

**其余 20,681 行走系数模型：**

| 档 | macOS 行 | 系数 | Rust 行 | 系数来自 |
| --- | --- | --- | --- | --- |
| S1 今天已覆盖 | 2,382 | **0.88** | 2,096 | 实测，已经写完了 |
| S2 纯算法（`SplitTree`） | 848 | **0.66** | 558 | 实测，见 §1.4 |
| S3 UI 装饰 | 4,362 | **0.6** | **2,617** | **已裁决**（2026-09-01，取 0.6 端），见 status.md 五之二；**已自底向上复核，见 §1.6** |
| S4 其余 | 13,089 | 0.7 – 1.0 | 9,162 – 13,089 | 以 S1 的 0.88 为中心；**有一个已量出来的盲区，见 §1.7** |

S3 = Window Styles 1,447 + `SurfaceView.swift` 912 + Plugins 视图 621 +
Command Palette 569 + Splits 三个视图 442 + About/Settings 371 = **4,362**。
S4 = Terminal 控制器、`Ghostty.Config`、AppDelegate 其余、Helpers、Plugins 逻辑、
QuickTerminal、Surface View 其余。

> **S3 底数订正**：原写 4,441，其中插件视图那一格是估计值 `~700`，**实测 621**，
> 高了 79。S4 相应从 13,010 变成 13,089（同一批行只是换了个档）。
> 分解与自底向上复核见 `development.md` 5.4。

合计 Rust 代码行 **15,100 – 19,700**（中心 ~17,400）。
按实测注释率折回总行数——宿主 25%、`split-tree` 36%，取 25–35%——
**20,200 – 30,300 行，中心 ~24,600。**

> **2026-09-01 的裁决把下沿抬高了约 2,000 行，上沿没动。**
> 原区间下沿 13,100 是「S3 取 0.15」那一端，而 S3 已定为 0.6，那一端不再可达。
> **这不是重新测量，是一个选择把区间的一半划掉了**——收窄的三成宽度里，
> 没有一行是靠量得更准得来的。QuickTerminal 裁决为「在 v1 内」，
> 而它本来就默认算在 S4 档，所以区间不变；连带升格的全局热键
> （`RegisterHotKey` 80–150 行）本来就在「要做但不是移植」那 700–1,350 行里。

加单元测试：`split-tree` 的测试/实现比是 431/558 = **0.77**，但那是纯算法模块；
**整份壳里能这样测的大概只有 15–20%**，其余是 Win32 交互，
落回「只能在 Windows 上跑的测试等于没人检查的测试」那条。
按此 **+2,200 – 4,300 行 → 含测试 22,400 – 34,600。**

### 1.4 唯一能一比一照搬的那个文件，和它教的事

`macos/Sources/Features/Splits/SplitTree.swift` 是全仓唯一一份纯数据结构：
分割树、方向、比例、遍历、找邻居、关闭叶子后的塌缩。已译成
`windows/split-tree/`（零依赖，`cargo test` 在 macOS 上就能跑，42 个测试）。

**1,413 行 / 848 代码行里，能搬的是 533 行 = 63%。** 搬不动的 315 行要分两类算：

- **真·平台绑定 ~145 行**：Combine 发布者 27、给 SwiftUI `.id()` 做结构 diff 的
  `StructuralIdentity` 82、读 `NSView.bounds` 的几何 ~35
- **Swift 语言设施 ~170 行**：`Codable` / `Equatable` / `Collection` / `Sequence` 的一致性实现。
  Rust 侧是 6 行 derive 和一个 `Vec`——**这不是工作量，是省下来的工作量**

移植时还发现原文件内部有一处真实的不一致：`calculateViewBounds`（Y-up，AppKit 视图坐标）
和 `spatialSlots`（Y-down）**对同一个 vertical split 给出相反的矩形**，各自在自己的
约定里都对。Win32 客户区坐标是 Y-down，所以只搬后者。

### 1.5 为什么「碰平台符号的行数」这个量被弃用了

三个文件，三个方向，**用符号密度外推方向都是错的**：

| 文件 | 碰 `NS*` | 实际 | 为什么 |
| --- | --- | --- | --- |
| `Ghostty.App.swift` | 2,515 行里 39 行（1.6%） | 它的便宜是**别人替它付的** | 它是转发表；那 60 个 handler 各自去 AppKit 里解析目标窗口 |
| `SplitTree.swift` | 几乎为零 | **37% 的代码行不能搬** | 它把数据结构和 SwiftUI 的 diff 缓存写在了一个文件里 |
| `Ghostty.Input.swift` | 几乎为零 | **355 行在 Windows 上归零** | 那是给 macOS 脚本接口做的 C 枚举镜像 |

顺带：本文档旧版那句「92%」今天**四种口径都复现不出来**（`import AppKit/SwiftUI/Cocoa`
在 `macos/` 下是 113 文件 28,114 行 = 65%，只算 `Sources` 是 94 文件 22,771 行 = 63%）。
不追这个差值——**这个量已经不用了。**

### 1.6 没有配对另一半时怎么估：**可数单位 × 实测单价**

§1.1 的方法（拿两边都写完的功能面比行数）有一个失效条件：
**当 macOS 侧的行数接近 0 时，没有另一半可配。** 这正是系数模型盲区的成因——
分母是 0，模型就分配 0 预算，而 Windows 那边的活一点没少。

失效时不要直接拍一个总数。**把工作拆成可以数出个数的单位，再给每个单位一个实测单价。**

#### 单价从哪来：`windows/host/src/tsf.rs` 是一个现成的实测点

它手搓了 `ITextStoreACP` + `ITfContextOwnerCompositionSink`，**已经写完并在真机上跑通**：

| | 值 |
| --- | --- |
| COM 方法总数 | **29** |
| 方法体合计 | **331 代码行** |
| 其中**实做**的（> 5 行） | 13 个，276 行，**平均 21.2 行/个** |
| 其中**桩**（≤ 5 行，返回 `E_NOTIMPL` 或空） | 16 个，55 行，**平均 3.4 行/个** |
| 每个 COM 对象的固定开销（结构体、状态、辅助函数、`use`） | **64 行** |

于是：

```
估算行数 ≈ COM 对象数 × 64 + 实做方法数 × 21 + 桩方法数 × 3.4
```

**注意 16/29 是桩** —— 这个比例本身是这条公式最有用的部分：
手搓一个大接口，**多数方法可以先返回 `E_NOTIMPL`**，代价不是按接口大小线性增长的。

> ⚠️ **这条公式还没有样本外验证。** 它是**从 `tsf.rs` 一个文件反推出来的**，
> 所以拿它去复算 `tsf.rs`（`64 + 13×21.2 + 16×3.4 = 394`，实际 396）**是循环，不是验证**。
> **第一次真正的检验，是谁先写完 `IDropTarget`**——公式预测 148 行，
> 写完之后把实际数记回来。**n = 1 的单价，用之前要知道它是 n = 1。**

#### 单位个数要数出来，不能凭记忆

接口有几个方法，**从 `windows-rs` 的源码里数**，不要靠印象：

```
grep -rl 'pub trait <接口名>_Impl' ~/.cargo/registry/src/*/windows-0.62.2/src/
# 然后在那个 trait 体里数 `fn `
```

#### 这条方法的适用边界

它只覆盖**「要实现一组已定义的接口方法」**这种形状。
`development.md` 5.4 的块 B（标签条交互：命中测试、拖拽重排、hover、溢出）
**不是这个形状**——它没有接口可数，那里的 280–360 是按「要处理的消息 × 状态数」
估的，**没有实测锚点，是 5.4 全节里最弱的一个数**。
它要拿到锚点的唯一办法，是**先做完块 B，然后把实际行数记回去**。

### 1.7 S4 的盲区量掉了：三个候选里两个是我判错的，第三个比说的严重得多

§1.3 的 S4 用的是同一个系数模型，所以有同一类盲区。
`development.md` 5.4 曾列出三个候选：右键菜单、拖放、无障碍。**逐个量过之后：**
（**后来加了第四类：标准库差异**，见本节末尾——它不在原来那三个候选里，
因为提出候选的人当时把「白送」只理解成框架。）

| 候选 | macOS 代码行 | 模型预算（×0.7–1.0） | 实际需要 | 判断 |
| --- | --- | --- | --- | --- |
| 右键菜单 | **190**（`menu(for:)` 58 + 菜单项处理 109 + `validateMenuItem` 23） | 133 – 190 | 150 – 240 | **不是盲区。** 略紧，不是数量级问题 |
| 拖放 | **201**（`NSDraggingDestination` 27 + `SurfaceDragSource` 174） | 141 – 201 | 190 – 230 | **不是盲区。** `IDropTarget` 只有 **4 个方法**，按 §1.6 的公式是 `64 + 4×21 ≈ 148` |
| **无障碍** | **58** | 41 – 58 | **450 – 900** | **是盲区，且是 8–16 倍** |

**两个是我判错的。** 判错的原因是同一个：我看到 macOS「靠框架白送」就默认它 Swift 行数为 0，
**而没有去数**。`NSMenu` 和 `NSDraggingDestination` 确实是框架给的，
**但用它们仍然要写不少 Swift**——白送的是机制，不是内容。

#### 无障碍为什么是 8–16 倍

macOS 那 58 行是 `NSView` 继承来的无障碍支持上**覆盖了 8 个方法**
（`accessibilityRole` / `accessibilityValue` / `accessibilitySelectedTextRange` 等）。
**继承来的那部分是零行。**

Windows 的 UI Automation 没有可继承的东西，**一个终端要暴露文本，得从零实现五个接口**
（方法数从 `windows-rs` 0.62.2 的 `_Impl` trait 里数出来的）：

| 接口 | 方法数 |
| --- | --- |
| `IRawElementProviderSimple` | 4 |
| `IRawElementProviderFragment` | 6 |
| `IRawElementProviderFragmentRoot` | 2 |
| `ITextProvider` | 6 |
| **`ITextRangeProvider`** | **18** |
| **合计** | **36** |

按 §1.6 的公式，两个 COM 对象（元素提供者 + 范围提供者），
实做/桩的比例按终端的实际需要拆：

- **下沿 450**：只做屏幕阅读器读出当前屏内容所必需的，`ITextRangeProvider` 的
  `FindAttribute` / `GetChildren` / `AddToSelection` 等一半以上打桩
- **上沿 900**：文本导航（按字/词/行/段移动）、选区双向同步、
  `GetBoundingRectangles` 的逐行矩形都做出来

**58 → 450–900，这是全份估算里比例最悬殊的一格**，
而它之所以一直没被看见，正是因为 **macOS 那边没人为它写过一行，也就没人想过这件事**。

#### ⚠️ 这一条不该由估算的人来定，它是产品决策

**无障碍在不在 v1 射程内，从来没有人问过。**
它的代价（450–900 行）和一整个 S3 块相当，而它的价值不是工程能判断的。

**这一条应当进 `status.md` 五之二「待用户裁决」，和 UI 精细度、QuickTerminal 并列。**
本次没有改 `status.md`（边界所限），**记在这里等一并处理**。三种可能的裁法：

| 裁法 | 代价 | 后果 |
| --- | --- | --- |
| v1 不做 | 0 | 屏幕阅读器用户完全无法使用；某些采购场景直接出局 |
| 只做最小可读 | 450 | 能读出屏内文本，不能按字词导航 |
| 做全 | 900 | 与 macOS 的实际可用性持平 |

#### ⭐ 第四类盲区：**标准库差异**，2026-09-02 在 UI-F 上撞到

前面三个候选问的都是「macOS 靠框架白送了什么」。**UI-F 暴露了一个更早的层：
语言的标准库。**

`macos/Sources/Features/Plugins/` 那 621 行**不含 JSON 解析**，因为 Swift 有
`JSONSerialization`。Win32 没有等价物，Rust 的标准库也没有。做 UI-F 的分解时
这一整块因此**在 macOS 侧计为 0 行**，而 Windows 侧必须有——
**和 §1.7 前三条是同一个形状，只是白送方从框架换成了标准库。**

做那份分解的人（我）当时只想到了框架差异：

> 「macOS 靠框架白送」这句话在脑子里对应的是 `NSMenu`、`NSWindow`、`NSAccessibility`。
> **`JSONSerialization` 也是白送的，但它不长得像一个「框架能力」，所以没被数进去。**

**排查这一类的问法，比排查前三类多一步**：不要只问「macOS 用了哪个框架」，
要问「**这一条在 macOS 侧一行都不用写的原因是什么**」——答案是框架、是标准库、
还是「macOS 应用必须有菜单栏所以入口是免费的」，三种都会让分母变成 0。

##### ⚠️ 但这一类的大小取决于一个决定，不取决于平台

**这条限定不能省，否则这一段会被当成「Windows 又贵了 200 行」。**

Rust 的标准库确实没有 JSON，**但它有 crates.io**。同一件事：

| 做法 | 我们的行数 |
| --- | --- |
| 手写解析器 + 自己的单元测试 | 190 – 240 |
| `serde_json` | 约 25 |

**差 200 行，而平台一样。** 所以「平台不给」和「我们决定自己写」在行数上长得完全一样，
在成因上不是一回事——**前者是盲区，后者是选择**。

那次选依赖不是因为省事，理由记在 `windows/host/Cargo.toml` 里：
**手写解析器加自己的测试，只证明它和自己同意；而这个文件是我们写、`Plugin.zig` 读，
会出事的是两个实现不一致。** 判据换成一份跨实现的 fixture 之后，
两种做法的风险一样了，行数差还在——**那才是选依赖的理由。**

**推论**：给这一类估行数之前，先问「有没有现成的东西」。
**没问就估，估的是「我们手写要多少」，而那从来不是必须付的价钱。**

#### 顺带量到的一个中等盲区

**窗口/会话恢复**：macOS 是 `TerminalRestorable.swift` 150 + `+InteralState` 21 +
`LastWindowPosition` 36 = **207 行**，但**触发时机、持久化容器、生命周期都由
`NSWindowRestoration` 承担**，应用只提供 encode/decode。
Windows 没有对应框架，**这三样都要自己写**（何时存、存哪、怎么区分崩溃退出和正常退出、
启动时怎么重建）。估 **270 – 350**，模型预算 145 – 207。
**盲区约 100–150 行，不大，记在这里免得又变成一个「候选」。**

#### 排查过、确认不是盲区的两项

- **`.xib` 文件**：全仓 10 个、867 行 XML、**零 Swift 行**——形状上完全符合盲区定义。
  但其中 9 个各 28–31 行，只是 `NSWindowController` 的载入桩；唯一有内容的是
  `MainMenu.xib`（591 行，103 个菜单项）。**而那 103 项在 Windows 上不用重写**：
  核心自己通过 `ghostty_config_command_list_s` / `ghostty_command_s`
  （`action_key` / `action` / `title` / `description`）供命令列表，
  宿主只要渲染它给的东西。**macOS 有菜单栏是因为 macOS 应用必须有，Windows 终端没有。**
- **主菜单栏本身**：同上，不做。那 103 条命令通过命令面板（S3 块 E）和右键菜单到达。

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

> ⚠️ **以下 `文件:行号` 是 2026-08-31 排查时的状态，五处均已修复，行号已失效；
> 保留为当时的证据。** 例如 `fromMode(0o600)` 已移到 `Plugin.zig:912` 并包进
> `switch (builtin.os.tag)`，`reap.zig` 的 kill 旁边已经有 `TerminateProcess` 分支。
> 见「未决问题」第 1 条。

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
| `Server.zig` 的 Unix domain socket | **14** | 总管↔终端的 IPC，见下 |
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
`.CANCELLED => unreachable`。`Server.zig` 做的正是被背书的那件事，它的注释同样清楚：
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
「本机任何进程都能连」引进来，而 `Server.zig` 的模块头正是为了避免这个才选了 unix socket：

> *Unix socket only, never a network port: otherwise any process on the machine
> could type into every terminal the user has open.*

**代价（当时量过的）**：`Server.zig` 945 行里直接碰 `std.Io.net` 的调用点 **19 处**；
关停相关的 `stop` / `closeListener` / `stopConnections` / `failInflight` / `listenMain`
合计 **98 行**。要重写的是这些，**协议、握手、token、Bus 一律不动**。

> **已经做完了（#54），所以上面那两个数是当时的形状，不是现在的。** 今天的
> `Server.zig` 是 **959 行**，整份文件里出现 `net` 的只剩 **3 处**——`const net =
> std.Io.net` 这个 import、`net.has_unix_sockets` 的分支判断、`net.UnixAddress.max_len`。
> 交付验收见 `status.md` 第二节（无插桩交付版 5/5 通过）。

> **但这仍然是下限。** 14 个 socket 测试**只跑了第 1 个**，后面 13 个从未被执行过；
> `netReadWindows` 那一层是**推断**出来的，它后面还有什么，**没有任何数据**。

## 七、Windows 的答案为什么和另外两个都不一样

Ghostty 的规矩不是「每平台用自己的语言」，而是：

> **Zig 写终端本身；平台的壳用那个平台最省力的语言写。**

| 平台 | 壳 | 为什么 |
| --- | --- | --- |
| Linux | **Zig** + GTK4 | GTK 是 C 库，Zig 直接绑；**没有强制的打包签名链** |
| macOS | **Swift** + AppKit，35,755 行 | AppKit 只有 ObjC/Swift；**打包、签名、公证、Sparkle 全绑在 Xcode 上** |
| Windows | **？** | Win32 是 C API（像 Linux），**但输入法是 COM**（不像任何一个） |

> ⚠️ **这个数改过两次，第二次是往回改的。**
> 32,694 → 43,157 → **35,755**。中间那个 43,157 是
> `find macos -name '*.swift'` 数出来的，而它**扫进了 `macos/build/` 下的构建产物**
> （同一份 735 行的 `GeneratedAssetSymbols.swift` 有四份副本，共 2,940 行）
> **以及 4,462 行测试**。源码是 `macos/Sources` 的 **35,755 行 / 24,621 代码行**。
> **一次没限定范围的 `find`，就是「基数错了 32%」这个结论本身的来源。**
> 规模估计现在不再依赖这个基数，见第一节。

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
| `macos/` Swift 行数 | 旧口径 `find macos -name '*.swift'` **扫进了 `macos/build/` 的产物 2,940 行和测试 4,462 行**。源码口径：`find macos/Sources -name '*.swift' -exec cat {} + \| wc -l` | 32,694 → 43,157 → **35,755**（源码；代码行 24,621） |
| 宿主 Rust 行数 | `wc -l windows/host/src/*.rs`；代码行 = 去空行去 `//` | **2,817 行 / 2,130 代码行**（2026-09-01，#73 合并后） |
| 宿主已实现 action 数 | `sed -n '422,575p' windows/host/src/main.rs \| grep -oE 'ACTION_[A-Z_]+' \| sort -u \| wc -l` | 14 → **24** |
| `Ghostty.App.swift` 碰 `NS*` 行数 | `grep -c 'NS[A-Z]' macos/Sources/Ghostty/Ghostty.App.swift` | 44 → **39**（代码变了；**这个量已弃用，见 §1.5**） |
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

2. ~~**第一节表格「4. Rust 侧的壳 · 一两万行」未改**~~ —— **2026-09-01 已重写，见第一节。**
   当时写的是「改这个估计要连着真机数据一起重写」，那个条件现在满足了：
   `windows/host/` 已经有几千行跑起来的宿主代码（钉住的那一版见 §1.1 末尾），
   可以拿它和 macOS 的同一批功能面直接比。
   **新区间 1.75 万–3 万行和旧的「一两万行」数值上接近，但没有一个共同的输入**——
   旧的靠符号密度外推，新的靠已完成功能面的实测转换率。**结论对、推导错，两件事都成立。**
