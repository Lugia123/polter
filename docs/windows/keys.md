# Windows 上按键实际去了哪里

真机调试很贵。这份文件的目的是让**大部分需求根本不必碰 GUI**，以及在必须碰的时候，
按键而不是点坐标。

## 这份文件的默认可信度：**没标就是只读过源码**

**凡是没有标记的结论，依据只有源码。** 这份文件里绝大多数内容是把 `Config.zig` 和
`keys.rs` 解出来的结果；真机上被按过一次的是少数。

| 标记 | 含义 |
|---|---|
| **（无）** | 只读过源码。**这是默认。** |
| ✅ **真机已验** | 有真机读数，而且读数直接支持这条陈述 |
| ◐ **有读数，但它证的不是这一条** | 真机上按过、行为也对——**但读数显示走的是另一条路**，所以这条陈述本身既没被证实也没被证伪 |

**第三档是被一次读数逼出来的，不是设计出来的。** 只有两档的时候，一条「行为对但路径
不同」的结论会被迫落进其中一档：标 ✅ 是把「结果对」当成「机制对」，不标是把一次真实
读数当成不存在。**两种都在丢信息，而丢掉的正好是最难重新获得的那一块。**

**声明写在最前面，是因为它必须在读者读到任何一条结论之前生效。**

**而且方向是这样定的，不是反过来。** 一份用「⚠️ 未验」去标例外的文件，会让**沉默变成
一种承诺**：读者看到某一条带着警告，就会推断没带警告的那些都验过了——**而真实情况正好
相反**。所以标的是**已验的那些**，没标的自动落回默认。

（同一条在别处的样子：`tools/` 里那道白名单式检查器也踩过——**新情况默认落在表外，
而表外看起来像「已排除」**。）

## 真源与「源」列

每一行都标了它是从哪读来的。**这一列不是注释，是维护指令**：改了对应的源，就要回来
改标着它的那几行。

| 源码 | 位置 |
|---|---|
| `核·共通` | `src/config/Config.zig` → `Keybinds.init()` 的平台无关部分 |
| `核·非mac` | 同上，`if (comptime !builtin.target.os.tag.isDarwin())` 块内 |
| `核·数字` | 同上，`alt+1..9` 的 `inline while` 块（非 mac 上 `mods = .alt`） |
| `核·win` | 同上，`if (builtin.target.os.tag == .windows)` 块内——**只有 Windows 有的绑定** |
| `宿主` | `windows/host/src/keys.rs` → `accelerator()` |
| `宿主·热键` | `windows/host/src/quick.rs` → `RegisterHotKey` |

本文所有「核心处理」的行，都是把 `Keybinds.init()` 按
`builtin.target.os.tag.isDarwin() == false`、`inputpkg.ctrlOrSuper() == ctrl`
（`src/input/key.zig` 的 `ctrlOrSuper`）解出来的结果。

> ⚠️ **在 macOS 上改这段代码：`zig build test` 全绿不代表你写的东西编得过。**
>
> 那些绑定在 `if (comptime !builtin.target.os.tag.isDarwin())` 里。在 mac 上构建时这个
> 条件是 comptime-false，**Zig 不分析走不到的分支**——所以我们平时用来确认「没写坏」的
> 那个动作，**在这段代码上什么都不证明**。
>
> **它比「测试没跑」更阴：这次是代码根本没有被编译。**
>
> 唯一能让它被分析的是交叉编译：
>
> ```
> zig build -Dtarget=x86_64-windows-gnu -Dapp-runtime=none -Drenderer=opengl
> ```
>
> **而且要在动手之前先跑一次。** 改完才第一次跑，编不过时分不清是自己写坏的、还是它
> 本来就不编——**一个没有地板的红，和一个有地板的红，值的信息量差一整轮排查。**

---

## 一、测试路径：先问「这需求需要 GUI 吗」

### ① 能用 `run_command` 就别碰 GUI

跑命令读输出，比任何 GUI 自动化都快、都可靠，而且不需要审批链（`run_safe_command`
是 L1）。真机上绝大多数问题的证据在**日志文件**里，不在屏幕上。

能用命令答掉的问题，举例：

| 想知道 | 命令 |
|---|---|
| 进程还在不在、有几个 | PowerShell：`Get-Process -Name 'polter*' -ErrorAction SilentlyContinue \| Select Id,ProcessName,StartTime` |
| 残留进程有没有窗口 | PowerShell：`Get-Process -Name 'polter*' -ErrorAction SilentlyContinue \| Select Id,ProcessName,MainWindowHandle,MainWindowTitle` |
| 某个 action 有没有触发 | `findstr /c:"[action]" <日志>` |
| 某个键有没有到 `handle_key_message` | `findstr /c:"[key]" <日志>` |
| 加速键有没有真的开火 | `findstr /c:"host accelerator" <日志>` |
| 窗口登记表数到几 | `findstr /c:"window(s) left" <日志>` |

> **这两行原来写的是 `Get-Process polter` 和 `tasklist /fi "imagename eq polter.exe"`，
> 两条都永远取不到东西。** 进程叫 `polter-host`，测试构建叫 `polter-wt-<commit>`，
> **而 `Get-Process polter` 不带通配符要求精确匹配**。一条永远返回空的检查，和一条通过
> 的检查，输出一模一样——**而空读起来就是「机器是干净的」**。
>
> 同一个错的另一个版本在真机上兑现过：整晚用 `taskkill /f /im polter-host.exe` 清场，
> 而产物有五六个名字，**两个实例活了四小时没被碰过**，每一次 `tasklist` 都说干净。
> 换成 `-Name 'polter*'` 之后一次全出来。
>
> **所以这一类命令有两条规矩**：**过滤条件要能覆盖你实际造过的所有名字**；
> **取不到时要出声，不许静默返回空**（`windows/tools/uia-tree-dump.ps1` 是这么写的：
> `if ($p.Count -eq 0) { throw "no $ProcessName process is running" }`）。
> 上面两行留了 `-ErrorAction SilentlyContinue` 是因为它们是**探查**，读的人在场；
> **写进脚本当判据时要换成 `throw`。**

**判据里写日志原文，不要写「界面上应该看到 X」。** 截图证明不了因果——它只说结果，
说不出是谁做的。日志里那行 `[key] ... -> surface_key=false` 才能把「核心不认这个键」
和「宿主表没这一行」分开。

### ② 要操作界面时走快捷键，不点坐标

Polter 是终端，本来就键盘驱动。快捷键不受窗口位置、DPI 缩放、遮挡、元素树缺失影响，
`ui_snapshot` 对自绘界面看不见的东西，键盘照样够得到。

用 `mcp__argus__key`，注意两条：

- **看返回值的 `sent` 数组，不要看 `success`。** `sent` 列出实际注入的每个键（含虚拟键码
  和扫描码）；`sent` 里没有的键就是没发出去的键。
- **被测对象读扫描码时加 `injection="scancode_only"`。** Polter 正是这一类，见第四节。

坐标点击只在「快捷键够不到」时用，且必须先确认截图 `capture_meta` 里没有
`scale_unknown: true`。

---

## 二、一个键在 Windows 上依次经过谁

`keys.rs::handle_key_message()` 的顺序，**每一步都不会大声失败**：

1. **TSF**（输入法）。消息泵先把键给 `ITfKeystrokeMgr`，被吃掉的键根本不会派发。
   → 所以中文输入法开着时，很多键连第 2 步都到不了。
2. **核心** `ghostty_surface_key`。核心先查绑定表；没有绑定就把键**编码进 pty**。
   两种情况都返回 `true`（已消费）。
3. **宿主加速键表** `accelerator()`——**只在核心返回 false 时才跑**。
4. 剩下的 `WM_SYSKEY*` 交回 `DefWindowProcW`（Alt+F4、系统菜单靠这个）。

**这就是分「宿主处理」和「核心处理」的原因，也是「源」列的由来。**

### 2.0 发键之前：先证明窗口是前台的

**先用真鼠标点一下被测窗口，再发键。**

只调 `SetForegroundWindow` 是不够的。**当前前台属于别的进程时，Windows 会拒绝这次前台切换，而且函数不抛异常**——调用方看到的一切都正常，脚本一路跑完，发出去的 `keybd_event` / `SendInput` 落到别人的窗口上。被测程序这边的表现是：**日志里一条 `[key]` 都没有**。

这个失败形态是最坏的一种，因为「一条 `[key]` 都没有」同时是下面三件事的样子：

- 键根本没被发出去（工具的问题）
- 键发出去了但被别人吃掉（前台在别处 ← 就是这一条）
- 键到了，而这个功能坏了（被测对象的问题）

**三者在读数上完全一样**，而它们的修法分别在三个不同的地方。

2026-09-03 一晚上它骗了两次：一次把「不组字按 `Ctrl+Shift+T`」的地板判成红（其实前台在上一条命令留下的窗口上），一次把新建分屏 / 切标签 / 关标签三个和弦一起判成「全无反应」（其实前一格刚点过另一个应用做焦点对照）。两次都是前一步动过前台。

**所以：凡是要发键的判据，第一步写成「点一下被测窗口」，不要写成「把窗口置前」。** 点击是真的会改变前台的，`SetForegroundWindow` 不一定。点击坐标要**从窗口矩形算**（`GetWindowRect` + 客户区偏移），不要从截图上量——截图报的 scale 是假的（说 1.0，实际 0.6），照缩略图坐标点会点在别处。

**地板**：如果一轮里出现「和弦毫无反应」，先补一次已知可用的和弦做正对照；那一条也没反应，问题在前台或在工具，不在被测的那个和弦。

### 2.0.1 确认状态的动作，不能是会改变状态的动作

§2.0 是这条的一个实例，判据 B 第 1 步是另一个。把它单独写出来，是因为这两次的
**成因不同、而症状完全一样**，所以按症状是认不出它的。

| 你以为在做的事 | 它实际做了什么 | 之后的读数 |
| --- | --- | --- |
| 「把窗口置前，确认它在前台」 | `SetForegroundWindow` 被系统静默拒绝，前台**没变** | 一条 `[key]` 都没有 |
| 「按个字母，确认能打出字」 | 输入法进入**组字态**，之后每个和弦都被 TSF 吃掉 | 74 条 `[key]`，0 条 `host accelerator` |

两条都是**前置步骤自己有副作用**，而副作用恰好落在被测的那条路上。

**写判据时的规矩**：确认一个前提，要用**读**的动作，不要用**做**的动作。
- 焦点：**点一下**（真的会改变前台），或者读回前台窗口句柄比对，**不要**只调置前函数。
- 输入法：读那一行的 **`composing=Some(false)`**，**不要**靠「打个字母看看」。

这一条和 §2.2「注入端发错了键」是**不同的两条**：那一条是**读**的时候认错了名字，
这一条是**写**的时候前置步骤本身改变了被测状态。

### 2.0.2 「日志里没有」是最弱的证据，除非先证明它本该出现

2026-09-03 这一句话骗了人两次，而两次的成因不同：

- 一次是**名字不对** —— 找的那个字符串和代码里打出来的不一样；
- 一次是**前提不对** —— 那一行在当时的状态下本来就不会出现（上面那张表的第二行）。

**两次的解法都不是「更仔细地读日志」。**

> **先证明这条日志在当前状态下应该出现，再把它的缺席当成证据。**

做法就是一次**正对照**：在同一轮里，先做一件**已知会产生这条日志**的事。它出现了，缺席
才有意义；它也不出现，那么这一轮关于「缺席」的每一条结论都作废，而问题在工具或状态里，
不在被测对象里。

那天拦住一次误报的，正是手上恰好有这样一个正对照 —— **恰好，不是安排。**
写进判据里，它就不再是运气。

**「缺席」这个输入，本身不携带成因。** 同一天它被映到了四个不同的结论：

| 谁 | 把「缺席」映到了 |
| --- | --- |
| 判据 A 的判读表 | **注入工具**故障 |
| 只枚举被测对象故障的分诊表 | **被测对象**故障 |
| 一次功能排查 | **功能不存在** |
| 判据 B 第一次跑 | **那四行是死代码** |

**任何把缺席直接映到一个结论的表格，都缺一个「先证明它应该出现」的前置格。**

#### 第 0 步（通则）

> **在任何键盘注入之前**：点一下 Polter 窗口取得前台；关掉输入法；按一个普通字母，
> **确认日志里出得来 `[key]` 行**。
> **这一步不出来，本轮作废，不进判读表。**

**它的位置就是它的力量**：它不是在判读表里补一行「如果什么都没有就是前台问题」，
而是**在进表之前就把「缺席」挡在外面** —— 缺席永远不会被解释成某一种成因，
**因为它根本到不了解释它的地方。**

**凡是靠读日志判定的判据都指回这里，不要各自抄一遍** —— 抄出去的那些会各自漂，
而漂了之后每一份看起来都同样权威。

### 2.1 排查顺序：**先问「这个键到了没有」，再问「谁要了它」**

**这一步以前不在这里，而它不在这里的时候，这一节把人指向了错的地方。**
原来写的是「按了没反应，就看 `-> surface_key=` 是 true 还是 false」。真机上出现过两种
情况，在这两种情况下**根本没有那一行可看**，而照着做的人会去查绑定表——**问题在更前面。**

#### 第一步：日志里有没有这个键的 `[key]` 行

**在断定「没有 `[key]` 行 = 这个键没进来」之前，先读下面这条，否则你会去查一个没坏的东西。**

> **`[key]` 行不是每个键都打的。** `keys.rs` 里的条件是
> `if n <= 20 || modded`，而 `modded` 只看 **Ctrl / Alt / Super**——
> **不看 Shift。**
>
> 所以：**开头 20 个键之后，不带 Ctrl/Alt/Win 的键一律不记**。`Enter`、方向键、
> **`Shift+Home`、`Shift+PageUp` 全都不记**。
>
> 真机上验到过这个：有五分钟一条 `[key]` 都没有，而那段时间 Enter 在执行命令、
> `Shift+Home`/`Shift+End` 在搬视口；紧接着的 `Ctrl+Shift+T` 有完整的 `[key]` 行。
> **日志路径是活的，只是那些键按设计不记。**

所以「没有 `[key]` 行」有**三种**含义，它们看起来一样：

| 读数 | 含义 | 下一步 |
| --- | --- | --- |
| 没有 `[key]` 行，**且这个键不带 Ctrl/Alt/Win**，且已过开头 20 个键 | **正常**，按设计不记 | 换一个带 Ctrl 的键复现，或看别的证据（界面、pty 输出） |
| 没有 `[key]` 行，**但键带 Ctrl/Alt/Win** | 这个键**没走到** `handle_key_message` | 走第二步 |
| 有 `[key]` 行 | 键到了 | 走第三步 |

#### 第二步：带修饰键却没有 `[key]` 行——**先看 TSF 吃了没有**

```
findstr /c:"TSF ate" <日志>
```

`[key] TSF ate msg=0x.. vk=0x.. (not dispatched)` —— 消息泵把键先给了
`ITfKeystrokeMgr`，它认领的键不会被派发，`keys.rs` 也就没有机会记。

> ⚠️ **这条日志有上限 40 次**（`TSF_ATE`，进程内累计）。**如果它正好出现 40 次，
> 说明计数已经饱和，后面「没有这一行」什么都不说明。** 数一下再下结论。

**keydown 不见而 keyup 在**，这个不对称形状在宿主代码里**只有这一条路能产生**：
`TestKeyDown`/`KeyDown` 和 `TestKeyUp`/`KeyUp` 是分开问的，TSF 可以只要前者。
其它可能吞键的路都是**对称**的——弹出菜单的模态循环（`TrackPopupMenu`）跑起来时
我们的泵根本不转，浮层窗口（命令面板/搜索/设置/提示框）有自己的 `WM_KEYDOWN`，
**这两种会把 keydown 和 keyup 一起吞掉**，不会只少一半。

#### 第三步：有 `[key]` 行了，才轮到看 `surface_key=`

- `surface_key=true` 而界面没动 → 核心接了，问题在核心那半，或者它把键编进 pty 了。
- `surface_key=false` 且没有跟着一行 `host accelerator` → 两边都没人要这个键。

### 2.2 一个和这条排查同源的陷阱：**注入端发错了键，和「没绑定」长得一样**

真机上作废过一次读数：方向键/翻页键注入时没有加 `KEYEVENTF_EXTENDEDKEY`，于是发出去的
是**小键盘的孪生扫描码**，而 Windows 对「Shift+小键盘」会做 shift-cancellation
**把 Shift 摘掉**。日志里一目了然：作废那次 `mods=0x22`，修好之后 `mods=0x23`。

> **「这个和弦没绑定」和「我发错了键」长得一模一样。**

**那两个数字可以自己解开**（位定义在 `keys.rs` 顶部）：
`0x01` Shift、`0x02` Ctrl、`0x04` Alt、`0x08` Win、`0x10` CapsLock、`0x20` NumLock。

- `0x22` = `0x20` + `0x02` = **NumLock + Ctrl**，没有 Shift；
- `0x23` = `0x20` + `0x02` + `0x01` = **NumLock + Ctrl + Shift**。

**Shift 那一位就是被 shift-cancellation 摘掉的那一位**，而 NumLock 那一位是这次读数
自带的旁证：它说明发出去的确实是小键盘那一族的扫描码。

所以用工具注入按键时，**判据里要带上 `mods=` 的期望值**，而不只是「有没有反应」。

### 2.3 「keydown 被吞掉」是不是我们的缺陷——**可判的那一半和不可判的那一半**

真机上见过 `Ctrl+Shift+<字母>` 的 keydown 间歇性不见（`Ctrl+Shift+F` 一次、
`Ctrl+Shift+A` 两次，形状都是 keyup 在、keydown 不在；而 `C`/`V`/`T`/`W` 一直正常）。

**⚠️ 这一段最初写的是「只有一条路，而且它是有日志的」。那句话是错的，改正连同错法一起
留在这里，因为错法比结论更值得记。**

**能产生「只少 keydown」这个不对称形状的路有两条，不是一条：**

**第一条**：消息泵里的 TSF 分支，`TestKeyDown`/`KeyDown` 和 `TestKeyUp`/`KeyUp` 是分开
问的。**这一条有日志**：`[key] TSF ate …`。

**第二条，而且它完全没有痕迹**：我们用的是 `ITfMessagePump::PeekMessageW`，参数是
**`PM_REMOVE`**——TSF 把消息**从队列里摘走**之后，返不返回给我们是它的决定。一条被摘走
而没有返回的 keydown：`TestKeyDown` 从来没被问过（**没有 `TSF ate` 行**），没有派发
（**没有 `[key]` 行**），别处也没有任何地方记它。

**这不是假想**：真机上有一份 3530 行的日志，`TSF ate` **0 次**（上限 40 远未到），
**而 keydown 照样丢了两次**。

**错法值得记，因为它解释了那句话为什么读起来那么可信**：

> **我检查了分叉，没检查入口。**

我读了 `if eaten { … } else { dispatch }` 这个分叉，确认它两边都有交代——**而那部分是
完全正确的**：`eaten == false` 时代码必然派发，所以「进了泵、没被认领、却没派发」在代码
上确实不可能。我漏掉的是上一行：**消息是怎么走到这个分叉门口的。**

**（其余可能吞键的路仍然是对称的）**：弹出菜单的模态循环、浮层窗口自己的 `WM_KEYDOWN`，
它们会把 keydown 和 keyup 一起吞掉，不会只少一半。

**现在第二条也有仪器了**：泵被调用之前先用 `PeekMessageW(PM_NOREMOVE)` 看一眼队列里有没有
键消息，泵返回之后再看它还在不在——摘走了又没返回就记一行
`[key] pump swallowed …`，并且**进程退出时打一行 `[key] pump totals: seen=… returned=…
swallowed=… tsf_ate=…`**。`seen` 是那个零的意义所在：**没有它，`swallowed=0` 和「探针
根本没在看」是同一份输出。**

#### ⚠️ 读那两行的 `composing=` 之前先读这条：**`false` 不等于「不是组字」**

`[key] TSF ate …` 和 `[key] pump swallowed …` 都带 `composing=`，它是为「TSF 是不是因为
正在组字才抢键」这个假设加的。**但它对这个假设只能证实，不能证伪。**

原因是时序，不是接线：**一次组字的第一个键，被认领的那一刻组字还没开始**——组字正是
**因为**这个键才开始的。所以：

| 读到 | 能得出什么 |
|---|---|
| `composing=Some(true)` | **组字中被抢**，假设成立 |
| `composing=Some(false)` | **什么都得不出。** 可能真的没在组字，也可能这正是**要开启**组字的那一个键 |
| `composing=None` | 问不到（TSF 没起来，或那一刻 `RefCell` 正被借着） |

**判别器不在这一行上，在下一行**——而它已经在日志里了，不用加东西：

- 紧跟着出现 `[ime] OnStartComposition` → **那个被吞的键开启了一次组字**，假设成立。
- 前后都没有任何 `[ime]` 行 → **TSF 在没有组字的情况下认领了键**，这是另一回事，
  而且是更值得追的那一件。

**（接线本身是可靠的**：`TextStore` 就是 context owner，全进程一个 document manager，
在标签之间被重新指向——所以属于我们这个 context 的组字一定会经过
`OnStartComposition`/`OnEndComposition`。**假阴性来自时序，不是来自漏挂 sink。）**

**这条写在跑之前，因为它决定第一份读数会被怎么读。** 没有它，一行
`composing=Some(false)` 会被读成「不是组字」，而那正是「未检验被当成已排除」——
**一个用错时机的探针，它的阴性和真正的阴性长得一模一样。**

**从源码不能答的**：那几次里 TSF 到底走的哪一条。日志现在能答，而两条计数都不再静默
饱和——`TSF ate` 和 `pump swallowed` 到达上限时各打一行说「从此只计数不打印」，总数在退出
那行上。（**在此之前 `TSF_ATE` 是静默封顶的，饱和之后「没有这一行」什么都不说明**。）

**更不能答的**：注入那一侧发生了什么。keyup 在而 keydown 不在，也完全可能是**发的时候
就少了一半**；宿主这边看不见没发出来的消息。**这需要在发送侧加读数，不是读这份源码
能回答的。**

> **所以这一条的正确说法是**：宿主代码里有且只有一条路能造成这个形状，而它是有日志的；
> **查一下那行日志在不在（并确认计数没饱和），就能把「我们这边」和「发送侧」分开。**
>
> **不能说的是「我查过源码，没问题」**——那句话会被读成「不是我们的问题」，
> 而源码只排除了「有一条没被记录的路」，没有排除「那条被记录的路真的发生了」。

---

## 三、表

### 3.1 核心处理（Windows 默认绑定）

`performable` 的含义见 3.3(d)。

**剪贴板 / 编辑**

| 键 | 动作 | 源 | 备注 |
|---|---|---|---|
| `Ctrl+Shift+C` | `copy_to_clipboard` | 核·共通 | performable |
| `Ctrl+Shift+V` | `paste_from_clipboard` | 核·共通 | performable |
| `Ctrl+C` | `copy_to_clipboard` | 核·win | **本 fork 新增**，performable——**没选区时照常中断**，见 3.3(e) |
| `Ctrl+V` | `paste_from_clipboard` | 核·win | **本 fork 新增**，performable——**剪贴板有文字时 `C-v` 再也进不了 pty**，见 3.3(e) |
| `Ctrl+Insert` | `copy_to_clipboard` | 核·非mac | |
| `Shift+Insert` | **`paste_from_selection`** | 核·非mac | ⚠️ 见 3.3(b) |
| `Ctrl+Shift+A` | `select_all` | 核·非mac | |
| `Ctrl+Shift+X` | `close_surface`（关闭分屏） | 核·非mac | **本 fork 新增**，见 3.3(b) |
| `Ctrl+Shift+K` | `clear_screen`（清屏） | 核·非mac | **本 fork 新增** |
| `F3` | `navigate_search:next`（查找下一个） | 核·非mac | **本 fork 新增**，performable——**没搜索时 F3 照常进 pty**，见 7.1（四） |
| `Shift+F3` | `navigate_search:previous`（查找上一个） | 核·非mac | **本 fork 新增**，performable |
| `Ctrl+Shift+Home` / `Ctrl+Shift+End` | `adjust_selection:home/end` | 核·非mac | **本 fork 新增** |
| `Alt+Shift+PageUp` / `Alt+Shift+PageDown` | `adjust_selection:page_up/page_down` | 核·非mac | **本 fork 新增**。和上一行不同形，理由见 3.3(b) |
| `Ctrl+Shift+F` | `start_search` | 核·非mac | performable |
| `Escape`（裸键） | `end_search` | 核·非mac | ⚠️ performable，见 3.3(c) |

**字号**

| 键 | 动作 | 源 |
|---|---|---|
| `Ctrl+=` / `Ctrl++` | `increase_font_size` | 核·共通 |
| `Ctrl+-` | `decrease_font_size` | 核·共通 |
| `Ctrl+0` | `reset_font_size` | 核·共通 |

**标签**

| 键 | 动作 | 源 | 备注 |
|---|---|---|---|
| `Ctrl+Shift+T` | `new_tab` | 核·非mac | |
| `Ctrl+Shift+W` | **`close_tab:this`** | 核·非mac | ⚠️ 见 3.3(b) |
| `Ctrl+Tab` | `next_tab` | 核·共通 | **切换，不是移动** |
| `Ctrl+Shift+Tab` | `previous_tab` | 核·共通 | |
| `Ctrl+Shift+→` | `next_tab` | 核·非mac | performable。**切换，不是移动** |
| `Ctrl+Shift+←` | `previous_tab` | 核·非mac | performable。同上 |
| `Ctrl+PageDown` | `next_tab` | 核·非mac | performable |
| `Ctrl+PageUp` | `previous_tab` | 核·非mac | performable |
| `Ctrl+Shift+PageDown` | `move_tab +1` | 核·非mac | performable。**这才是「移动标签」** |
| `Ctrl+Shift+PageUp` | `move_tab -1` | 核·非mac | performable。同上 |
| `Alt+1` … `Alt+8` | `goto_tab 1..8` | 核·数字 | performable |
| `Alt+9` | `last_tab` | 核·数字 | performable |

**窗口**

| 键 | 动作 | 源 |
|---|---|---|
| `Ctrl+Shift+N` | `new_window` | 核·非mac |
| `Ctrl+Shift+Q` | `quit` | 核·非mac |
| `Alt+F4` | `close_window` | 核·非mac |
| `Ctrl+Enter` | `toggle_fullscreen` | 核·共通 |

**分屏**

| 键 | 动作 | 源 | 备注 |
|---|---|---|---|
| `Ctrl+Shift+O` | `new_split:right` | 核·非mac | 注意是 O 不是 D |
| `Ctrl+Shift+E` | `new_split:down` | 核·非mac | |
| `Ctrl+Shift+Enter` | `toggle_split_zoom` | 核·共通 | |
| `Ctrl+Alt+↑↓←→` | `goto_split:up/down/left/right` | 核·非mac | performable |
| `Ctrl+Win+[` / `Ctrl+Win+]` | `goto_split:previous/next` | 核·非mac | performable，要按 Win 键 |
| `Ctrl+Shift+Win+↑↓←→` | `resize_split ±10` | 核·非mac | performable，要按 Win 键 |

**滚动 / 选择 / 提示符**

| 键 | 动作 | 源 | 备注 |
|---|---|---|---|
| `Shift+←→↑↓` | `adjust_selection` | 核·共通 | performable |
| `Shift+Home` / `Shift+End` | `scroll_to_top` / `scroll_to_bottom` | 核·非mac | ⚠️ 见 3.3(b) |
| `Shift+PageUp` / `Shift+PageDown` | `scroll_page_up` / `scroll_page_down` | 核·非mac | ⚠️ 见 3.3(b) |
| `Ctrl+Shift+↑` / `Ctrl+Shift+↓` | `jump_to_prompt -1 / +1` | 核·非mac | |

**其他**

| 键 | 动作 | 源 |
|---|---|---|
| `Ctrl+Shift+P` | `toggle_command_palette` | 核·共通 |
| `Ctrl+,` | `open_config` | 核·共通 |
| `Ctrl+Shift+,` | `reload_config` | 核·共通 |
| `Ctrl+Shift+I` | `inspector:toggle` | 核·非mac |
| `Ctrl+Shift+J` | `write_screen_file:paste` | 核·共通 |
| `Ctrl+Shift+Alt+J` | `write_screen_file:open` | 核·共通 |
| `Ctrl+Shift+Win+J` | `write_screen_file:copy` | 核·共通 |

### 3.2 宿主处理（`keys.rs::accelerator()`，只剩四行）

**只有核心不认的和弦才留在这里。** 每一行都在触发时打日志：

```
[key] host accelerator "toggle_maximize" -> binding_action = true (the core has no Windows bind for this chord)
```

| 键 | 动作 | 源 | 为什么核心不管 |
|---|---|---|---|
| `Ctrl+Shift+M` | `toggle_maximize` | 宿主 | Windows 无默认绑定 |
| `Ctrl+Shift+D` | `new_split:right` | 宿主 | 核心的分屏默认是 `Ctrl+Shift+O` |
| `Ctrl+Shift+Z` | `toggle_split_zoom` | 宿主 | 核心的 undo/redo 绑定在 mac 分支 |
| `Ctrl+Shift+=` | `equalize_splits` | 宿主 | 核心绑的是 `Super+Ctrl+=`，mac 分支 |

关于这四行的三条脾气：

- **只在 surface 有焦点时才可能跑。** `handle_key_message` 是 surface 的窗口过程。
  命令面板 / 搜索栏 / 设置页 / 提示框各有自己的 `WM_KEYDOWN` 处理（见 3.5）。
- **~~不检查 Alt/Win 有没有一起按下~~ —— 已修。** 从前 `accelerator()` 只看
  `VK_CONTROL` 和 `VK_SHIFT`，所以 `Ctrl+Shift+Alt+M` 也会触发 `toggle_maximize`，
  `Ctrl+Shift+Win+M` 同理——**而那些和弦在别的软件和输入法里是有主的**。现在多按任何
  一个修饰键都不再触发，**并且会打一行说明是哪一个**：

  ```
  [key] host accelerator "toggle_maximize" NOT fired: Alt also held (this table matches Ctrl+Shift exactly)
  ```

  **那行日志不是装饰。** 一个「收紧了条件、然后什么都不做」的改动，会把「这个键不工作」
  变成沉默，**而沉默和「这个键根本没进来」分不开**——后者在这个宿主上正是一个未定位的
  问题（见 2.3）。

  **修的时候差点引入第二个缺陷，记在这里**：第一版写成了「记一行然后 `return`」。
  但 `Alt` 会让这条消息变成 `WM_SYSKEYDOWN`，而本函数末尾**故意**把这类消息交给
  `DefWindowProcW`——吞掉它们会连 `Alt+F4` 和系统菜单一起拿走。现在这一支**只记不吞**，
  `consumed` 保持 false，消息照常走到它原本的结局。（那条不变量就写在几十行之外的注释里，
  是它把这次拦下来的。）
- **它们没有被真机验过。** 见判据 B——「核心不绑这个和弦」不等于「核心不消费这个键」，
  核心还可能把它编码进 pty（3.4）。

**判据 D（多按修饰键不再触发）——分两段写，因为其中一段今天验不了**

> **D1（今天能验）**：精确按 `Ctrl+Shift+M`，**必须**出现
> `[key] host accelerator "toggle_maximize" -> binding_action = true`，窗口最大化。
> **这一段不受丢键问题影响**：丢键是间歇的，没反应就重试，成功一次即为通过。
>
> **D2（今天验不了，要等 147）**：按 `Ctrl+Shift+Alt+M`，期望是**不最大化**，且出现
> `[key] host accelerator … NOT fired: Alt also held`。
>
> **⚠️ 一次「没反应」在今天读不出结论。** `Ctrl+Shift+<字母>` 的 keydown 会被间歇吞掉
> （147），所以「窗口没最大化」既可能是这条修复生效了，**也可能是那个键根本没进来**——
> **而这两者今天分不开。**
>
> **所以 D2 的通过条件不是「没最大化」，是「那一行 `NOT fired` 出现了」。** 没有那一行
> 就不算通过，只算没测到。**等 147 的新仪器给出 `seen` / `swallowed` 计数之后再跑，
> 或者先确认这一轮里同一个和弦的 `[key]` 行是在的。**

### 3.3 表上有、但行为不是你以为的那个 ⚠️

这一类比缺一行更坑人：按下去有反应，反应是别的事。

**（a）「移动标签」按成了「切换标签」。** ✅ **真机已验**（判据 C-a1–C-a4 四组读数）
`Ctrl+Shift+←/→` 和 `Ctrl+Tab` 都是 `previous_tab`/`next_tab`。要移动标签是
`Ctrl+Shift+PageUp/PageDown`。宿主表里原来有四行把 `Ctrl+Shift+←/→` 送去 `move_tab`，
已经删了——它们只在核心「因 performable 而拒绝」时才跑，也就是只剩一个标签时，于是
「只有一个标签时按了会移动标签，多个标签时按了会切换标签」。

**（b）同一个和弦被写了两次，后写的赢。** ✅ **真机已验**

> **读数取自这次补键之前的构建**：判据 C-b1，加上菜单侧独立印证——「关闭分屏」显示为空、
> 「关闭标签」显示 `Ctrl+Shift+W`，而按下去关的正是标签。
>
> **那个现象现在已经被改掉了**（`close_surface` 有了自己的键），所以**这条读数是历史，
> 不要拿去重跑**：今天再看，「关闭分屏」会显示 `Ctrl+Shift+X`。**留着它是因为它证明的
> 机制没变**（后写覆盖先写、反向表丢掉输的那个），变的只是这一个实例。

`Binding.zig` 的 `Set.putFlags` 里那句 `gop.value_ptr.* = .{ .leaf = ... }` 是无条件覆盖：

| 和弦 | 先写的 | 后写的（**实际生效**） | 输的那个今天有没有键 | 源 |
|---|---|---|---|---|
| ~~`Ctrl+Shift+W`~~ | ~~`close_surface`~~ | `close_tab:this` | **这一处已消除**：死绑定删了，`close_surface` 改到 `Ctrl+Shift+X` | 核·非mac |
| `Shift+Insert` | `paste_from_clipboard` | `paste_from_selection` | 有（`Ctrl+Shift+V`） | 两条都在 核·非mac |
| `Shift+Home/End` | `adjust_selection` | `scroll_to_top/bottom` | **有了**：`Ctrl+Shift+Home/End` | 核·共通 → 核·非mac |
| `Shift+PageUp/PageDown` | `adjust_selection` | `scroll_page_up/down` | **有了**：`Alt+Shift+PageUp/PageDown` | 核·共通 → 核·非mac |

> **后两行仍然是「被覆盖」，但不再是「没有键」。** 覆盖没有被拆掉——滚动那四个键是人已经
> 在用的，动它们不是补缺口而是改行为。所以做法是给选区**另找键**。
>
> **代价写在这里，因为它看起来像疏忽**：选区那四个键**不是一套**——行首/行尾是
> `Ctrl+Shift`，翻页是 `Alt+Shift`。原因是 `Ctrl+Shift+PageUp/PageDown` 已经被
> **移动标签**占了。**不要「顺手统一一下」**：唯一能统一的做法是把滚动从 `Shift+` 挪走，
> 那会改变现在就在用的行为，是另一个该被单独决定的取舍。（同样的话写在
> `Config.zig` 那几行旁边，因为改代码的人不一定读这份文件。）

**并且菜单上显示的快捷键是另一张表算出来的，两张表会给出不同的答案。**
`ghostty_config_trigger`（菜单快捷键那一半问的就是它，`keys.rs::shortcut_for`）读的是
**反向表**，它按 **action** 存，而且 `Binding.zig` 的 `Set.putFlags` 开头有一条：
`const track_reverse: bool = !flags.performable;` ——**performable 的绑定根本不进反向表**。

由此推出三条会让人吃惊的预测（**都没验过，判据 C 就是验它们的**）：

- 菜单「复制」显示的是 **`Ctrl+Insert`**，不是 `Ctrl+Shift+C`——后者 performable，不进反向表。
- 菜单「粘贴」**可能一个快捷键都不显示**：`Ctrl+Shift+V` performable 不进表；
  `Shift+Insert` 进了表又被 `paste_from_selection` 抢走（覆盖时会把旧 action 的反向项摘掉）。
- 菜单里 `close_surface` 那行**不显示** `Ctrl+Shift+W`（同样被摘掉了），
  而这个和弦按下去执行的是 `close_tab`。

**（c）裸 `Escape` 是一条绑定。** ◐ **有读数，但它证的不是这一条**

`Config.zig` 里 `Escape` → `end_search`，`performable = true`。照这条读：没在搜索时核心
让路、Escape 照常进 pty（vim 还能用），搜索开着时核心消费它。

**真机上按过了，行为是对的，但走的不是这条路：**

| 步骤 | 读数 | 说明 |
|---|---|---|
| 搜索栏**关着**按 Escape | 全库 `end_search` 出现 **1 次**，而那一次是启动时 `[menu] no shortcut for 31 of 48 core actions: … end_search …` 里的**字符串**，不是动作 | 失败条件没有发生，**这一半与本条相容** |
| 搜索栏**开着**按 Escape | 搜索栏关了，日志是 `[search] end_search -> binding_action = false` ＋ `w1 [overlay] search closed, focus returned to the surface` | **关掉它的是宿主的浮层，不是核心那条绑定** |

**第二行才是要点。** 按 3.5 那张表，`search.rs` 有自己的 `WM_KEYDOWN`，Escape 在浮层
那里就被吃掉了，**根本到不了核心的绑定表**。所以在这个宿主上「搜索开着时 Escape 归核心
的 `end_search` 管」并不成立——**归浮层管，浮层随后请核心也执行一次 `end_search`，
核心答了 `false`。**

> **一处由此暴露、尚未解释的分歧**：`binding_action = false` 意味着核心认为**没有搜索
> 可结束**（`end_search` 是 performable，条件不满足就答 false）。而当时宿主的搜索浮层
> 明明开着。**宿主和核心对「现在有没有在搜索」的看法不一致**——这不是本节的结论，是一个
> 没人问过的问题，记在这里以免下次被当成新发现。

**对使用者仍然成立的那句**：Escape 的行为取决于搜索栏开没开，测 vim 或退出全屏之前
先确认搜索栏是关的。**变的是「谁在管它」，不是「它会不会变」。**

**（d）`performable` 的含义。**
`Config.zig` 说得很直白：条件不满足时「Ghostty behaves as if the keybind was not set」。
所以 performable 的键会**掉到宿主加速键表**。上一轮就是这么出的事：`Ctrl+Shift+C` 在没有
选中文本时被核心拒绝，掉到宿主表，宿主把**窗口标题**塞进了剪贴板——人以为自己复制失败了。
凡是往宿主表里加行，先问「核心的哪条 performable 绑定会掉到我这里」。

> ⚠️ **「performable 拒绝之后会掉到宿主表」这条机制来自读源码，真机上没有被证实过。**
> 唯一一次相关读数（判据 C-a5：只剩一个标签时按 `Ctrl+Shift+→`）**没有走到这条路**：
> 核心并没有拒绝，而是接了并空转（`surface_key=true` ＋ `[action] goto_tab -2` ＋ 什么都没发生）。
> 所以这句话既没被证伪，也没被证实。
>
> **写在这里而不是收进某份「未知清单」，是因为要读到它的人正是此刻正在依赖这句话的人。**
> 它读起来完全像一条已确认的机制——而那正是它需要这行标注的原因。
>
> **并且它现在有了一处确定的反例，见 3.3(e)：中间还有一步。** 拒绝之后先走
> `encodeKey`，**编得出东西就到此为止**，宿主表根本不会被问到。`Ctrl+C` 就是这一类。
> 所以上面这句话的正确读法是「拒绝 **且编不出编码** 的键会掉到宿主表」——
> `Ctrl+Shift+C` 那次真机事故属于后者，而它看起来像是前者的证据。

**（e）`Ctrl+C` / `Ctrl+V`：一个键上的两种行为。**

`核·win` 那两行是本 fork 对上游的**有意分叉**，理由和滚轮读系统设置那次同类：
Windows 上的终端是个 Windows 程序，`Ctrl+C` 复制是这台机器上每个别的程序的行为。
连带 `selection-clear-on-copy` 的默认值在 Windows 上也改成了 `true`——**这两件事是一对，
不能只做一半**：选区留着，下一次 `Ctrl+C` 会再复制一遍同样的文字而不是中断，于是这个键
在用户想不到去点一下别处之前，悄悄不再是中断键。

| 状态 | `Ctrl+C` 做什么 | 怎么发生的 |
|---|---|---|
| 有选区 | 复制，并**清掉选区** | 绑定 performed → consumed，**不编码**，0x03 不发 |
| 无选区 | **中断**（0x03 进 pty） | 绑定拒绝 → `encodeKey` 编出 0x03 → consumed |

**⚠️ 这一段同时修正 3.3(d)：performable 拒绝之后，下一站不是宿主表，是 `encodeKey`。**

`Surface.zig::keyCallback` 的顺序是 `maybeHandleBinding` → （performable 拒绝时返回
`null`）→ `encodeKey`。**只有 `encodeKey` 也交不出东西时**才 `return .ignored`，
`ghostty_surface_key` 才答 `false`，第 3 步的宿主表才轮得到。3.3(d) 把中间这一步漏掉了，
读起来像「拒绝 → 宿主表」。

**这一条改变的不是机制，是判据。** 无选区按 `Ctrl+C`：

- `surface_key` 是 **`true`**，不是 `false`——`Ctrl+C` 一定编得出 0x03。
- 所以**「日志里出现 `surface_key=false`」不能当成「performable 让路了」的证据**，
  它在这条路上永远不会出现。一份照 3.3(d) 写出来的判据，会在一个完全正常的构建上判红。
- 能分开「让路了」和「压根没绑上」的是**宿主的 `[clip] write` 行**（`main.rs`
  的 `cb_write_clipboard`）：有选区那次必须有，无选区那次必须没有。

**那么 `Ctrl+Shift+C` 当初是怎么掉到宿主表的？——这是推论，不是读数，标出来免得它被引用。**
按上面的顺序，它要掉下去就必须是 `encodeKey` **也**交不出编码。这说得通（`Ctrl+C` 编 0x03
是终端最基本的编码，`Ctrl+Shift+C` 编什么则取决于键盘协议），**但本轮没有核过 `encodeKey`
对 `Ctrl+Shift+C` 的行为，也没有真机读数**。

**已经确定的只有一半**：`Ctrl+C` 拒绝之后不会到宿主表。**没确定的那一半**是
`Ctrl+Shift+C` 为什么会。**同一个 `performable` 标志，两个键的下场可以不同,而差别落在
编码那一步**——这句话是这一段的用处，不是它已经证明的东西。

**`Ctrl+V` 的代价，写在这里因为它不可逆。** `paste_from_clipboard` 只在**没东西可粘**时
拒绝（`startClipboardRequest` 对 `.paste` 一律放行，返回值来自宿主的
`cb_read_clipboard`，而它只在剪贴板没有文本时返回 false）。所以**只要剪贴板里有文字，
`Ctrl+V` 就再也送不出 0x16**——`readline` / `emacs` 的 quoted-insert 没了。
这是 Windows 用户的预期，也是这条绑定存在的理由；要拿回来只能
`keybind = ctrl+v=unbind`。

**菜单不受影响，而这一条是特意去核过的。** `putFlags` 里 `track_reverse = !performable`，
这两条根本不进反向表，`shortcut_for("copy_to_clipboard")` 仍然答 `Ctrl+Insert`——
和加它们之前**一模一样**。（136/137 咬过一次的正是这里，所以它有一条断言：
`Config.zig` 的 `test "Keybinds: windows binds bare ctrl+c and ctrl+v"`。）

> ⚠️ **那条测试在 mac 和 Linux 上是 `SkipZigTest`，不是 pass。**
> `Keybinds.init` 的 `builtin.target.os.tag == .windows` 块在别的平台是 comptime-dead，
> Zig 不分析它。**这是量过的，不是推的**：把 `paste_from_clipboard` 故意打错一个字，
> `zig build -Dtarget=x86_64-windows-gnu -Dapp-runtime=none -Drenderer=opengl` 退 1，
> 而 mac 上的 `zig build` 退 **0**。
> **所以这两行代码在 mac 上没有任何自动检查**，改它必须交叉编译，最好再跑一次
> Windows 测试 exe。

### 3.4 核心把键编码进 pty —— 宿主表**永远**够不到

核心在 `Surface.zig::keyCallback` 里：绑定表没命中 → `encodeKey`；编出东西来就
`return .consumed`，`ghostty_surface_key` 返回 `true`，第 3 步不会发生。

**能编码的键，几乎是终端认识的全部**：F1–F12、方向键、Home/End/PageUp/PageDown、
Insert/Delete、Tab、Escape、`Ctrl+字母`、普通可打印字符。

所以：**给这些键写宿主加速键行等于写死代码。** 上一轮的 `F11 → toggle_fullscreen` 就是这样：
F11 编码成 `CSI 23~`，核心永远消费，那一行一次都没跑过，而且不会有任何东西报告这件事。

判断某一行是不是死的，唯一可靠的办法是真机按一次看日志：`surface_key=false` 才轮得到宿主。

### 3.5 有自己键盘处理的窗口

这些窗口开着并有焦点时，surface 的整条路径都不在跑：

| 窗口 | 源 | 吃掉的键 |
|---|---|---|
| 命令面板 | `palette.rs` 的 `WM_KEYDOWN` 分支 | `Esc`（关）、`Enter`（执行）、字符输入 |
| 搜索栏 | `search.rs` 的 `WM_KEYDOWN` 分支 | `Esc`、`Enter` |
| 设置页 | `settings_ui.rs`（三处 `WM_KEYDOWN if ... == VK_ESCAPE`） | `Esc` |
| 提示框 | `prompt.rs` 的 `WM_KEYDOWN` 分支 | `Esc`、`Enter` |
| 覆盖层 | `overlay.rs` 的 `WM_KEYDOWN` 分支 | `Esc`（转发给父窗口） |

### 3.6 没有键盘入口的动作

| 动作 | 源 | 状况 |
|---|---|---|
| 设置页 `__polter_plugin_page` | 宿主 | **无任何键盘入口**。原来的 `Ctrl+Shift+,` 被核心的 `reload_config` 占着（非 performable，核心每次都消费），那一行一次都没跑过，已删。要补就得挑一个核心不绑的和弦。 |
| `toggle_quick_terminal` | 宿主·热键 | 核心默认**不绑**。宿主用 `RegisterHotKey`（全局热键，Polter 不在前台也能触发），但只有用户在配置里绑了它才注册。 |
| `__polter_minimize` | `menu.rs` | 只在菜单里，核心没有这个 action。 |

---

## 四、扫描码：一条待验的线索

`keys.rs::keycode()` 从 `WM_KEYDOWN` 的 lParam 取**扫描码**（bit 16–23，bit 24 是扩展位），
不做任何 VK 映射，直接交给核心。核心 `src/input/keycodes.zig` 在 Windows 构建上读的正是
第 3 列（`native_idx = 3`，win 列，IBM PC set-1 扫描码）：

```
.{ 0x070006, 0x002e, 0x0036, 0x002e, 0x0008, "KeyC" }      -> win 列 = 0x2e
.{ 0x070029, 0x0001, 0x0009, 0x0001, 0x0035, "Escape" }    -> 0x01
.{ 0x07002b, 0x000f, 0x0017, 0x000f, 0x0030, "Tab" }       -> 0x0f
.{ 0x070044, 0x0057, 0x005f, 0x0057, 0x0067, "F11" }       -> 0x57
.{ 0x070050, 0x0069, 0x0071, 0xe04b, 0x007b, "ArrowLeft" } -> 0xe04b
```

**扫描码 0 在这张表里没有对应项**，会解成 `.unidentified`，于是既匹配不到绑定，也编码不出
任何东西 —— 键盘按下去什么都不发生。

**悬案：「Ctrl-C 在 Windows 上不生效」。形状正好是这个。**
argus v1.40 修了 `key` 注入的扫描码（修之前 `sent` 里 `scan` 全是 0）。如果那次测试用的是
修复前的 argus，注进去的 `Ctrl+C` 扫描码是 0，核心解成 `.unidentified`，Ctrl-C 就是不生效
—— 而 Polter 这边完全正常，一个人**手按**键盘是好的。

这条**没有验过**。判据 A 就是验它。

注意这条悬案的自我掩盖性：普通字母打得出来，不能用来排除本路径。`WM_CHAR` 回落会把可打印
字符打出来，IME 走的是 `surface_text` 另一条路。**控制键没有第二条路**——Ctrl-C 要么走
`handle_key_message`，要么不发生——所以它才是该看的那个键。

---

## 五、给 WT 的真机判据

下面这几条是我**最没把握**的几条，不是最好写的几条。它们问的都是「按下去发生了什么」，
不是「这个键有没有被绑定」——后者源码里就能读出来，不值得占一次真机。

**A / B / C 三条写在 §2.0 那批规矩之前，组 P 写在之后**，所以 5.0.1 那张回扫表对它们的
处置不一样。**组 P 是唯一一条「这个键有没有绑上」也必须占真机的**，理由不是绑定读不出来
（读得出），而是它在 mac 上**没有任何自动检查**——见 3.3(e) 末尾那条警告。

### 5.0 每一条判据都从这三步开始（**先于它自己的第 1 步**）

**这三步是 §2.0 / §2.0.1 / §2.0.2 的落地。下面每一条判据都写在那三节之前，所以它们
各自的第 1 步都不含这些**——一条新立的规矩不会自动追溯到已经写下的东西上，所以这里
补一次，统一适用。

1. **用真鼠标点一下被测窗口**（§2.0）。**不要**用 `SetForegroundWindow`，也**不要**用
   「打个字母看看」来确认焦点。
2. **把输入法切到英文**，然后按一个带 Ctrl 的和弦，**读那一行的 `composing=Some(false)`**。
   不是 false 就停下——后面每一格都会作废（§2.0.1）。
3. **正对照，每轮一次**：按一个**已知会打出 `[key]` 行**的键，确认那一行真的出现。
   **没有这一步，任何「日志里没有 X」都不是证据。**

**这三步就是 §2.0.2 的「第 0 步（通则）」**，在这里复述一次是为了让每条判据都够得着；
**它的正文在 §2.0.2，改要改那一处。**

**第 3 步不是形式**：`[key]` 行在头 20 个键之后只记带 Ctrl/Alt/Win 的键（§2.1），
真机上出现过五分钟一条都不记而键全都在工作。

### 5.0.1 回头扫一遍：既有判据对上面三条规矩的符合情况

**§2.0 / §2.0.1 / §2.0.2 是后立的，而下面每一条判据都写在它们之前。** 这张表是拿新
规矩回头扫一遍的结果，**包括哪几条本来就是干净的** —— 一张只列问题的表，读的人不知道
其余的有没有被看过。

三个问题：
① 前置步骤里有没有「做」而不是「读」的确认动作？
② 有没有依赖某条日志的缺席，而同一轮里没有正对照？
③ 引用的日志字符串在真机/源码上核过没有？

| 判据 | ① 前置动作 | ② 缺席+正对照 | ③ 日志字符串 | 处置 |
| --- | --- | --- | --- | --- |
| **A** Ctrl-C | ❌ 无点击步；「跑个长命令」要打字 | ❌ 判读表**不穷尽**，「一条 `[key]` 都没有」会被读进第四行 | ✅ 已对 `keys.rs` 里那条 `[key] msg=…` 格式串逐字段核过 | **已补**：第 0 步指向 §5.0；判读表补第五行 |
| **B** 宿主表四行 | ❌ 曾是「先按一个普通字母」 | ⚠️ 只有负向地板 | ⚠️ `findstr /c:` 带空格串不成立 | **已补**（本轮早些时候 + 正向地板 + 说明 `host accelerator` 没有独立正对照） |
| **C** 第一部分（菜单读文字） | ⚠️ 准备阶段要打字设标题 | ✅ **本来就干净**：它自己讨论了「一组全是预期为空的预测无法把『中了』和『没测』分开」，并放了一条预期非空的对照组 | ✅ 不读日志，用 `ui_snapshot` | 只补了「打字前先关输入法」 |
| **C-a** 移动/切换标签 | ⚠️ 同上 | ❌ C-a5 靠「没有跟着的 `host accelerator` 行」，无正对照 | ✅ 两个字符串都核过 | **已补**：指向 §5.0 第 3 步 |
| **C-b** 覆盖 | ⚠️ 同上 | ✅ **本来就干净**：有 `SENTINEL-Cb2` 正对照 | ✅ | 无需改 |
| **C-c** 裸 Escape | ⚠️ 同上 | ✅ **本来就干净**：已记录过两次修正（Escape 不进 `[key]`、`[search]` 行形状不同） | ✅ 已按真机原文改过 | 无需改 |
| **C-d** performable 让路 | ⚠️ 同上 | ✅ **本来就干净**：有「选中文字再按一次」的正对照 | ✅ | 无需改 |
| **P** `Ctrl+C`/`Ctrl+V` | ✅ 自带「点一下窗口」并写明不要用置前函数 | ✅ 自带：P1/P2 互为对照，且明写「只跑 P2 等于没跑」 | ✅ `[clip] write` / `[clip] read` 已对 `main.rs` 的字面量核过 | 写在规矩之后，无需回补 |
| **§六 / §七 的清单** | —— | ✅ **本来就干净**：明写「先做地板，每一轮一次」，并解释了为什么 | ✅ | 无需改 |

**读法**：❌ = 缺；⚠️ = 有但不完整，或被 §5.0 统一覆盖了；✅ = 本来就成立。

**这张表本身有一个前提，而它在 2026-09-03 当天就被说破了。** 判据 A 那一轮跑绿了，
而执行者报回来的是：

> 缺的那两步我这次都做了，**但不是判据让我做的，是判据 B 刚绊过我一次**。
> **所以这一轮的绿是有效的，但它证明不了判据 A 是完整的。一个刚被同一个坑绊过的人
> 会补上缺口，下一个人不会。**

**判据的完整性，不能靠执行者恰好记得。** 一条缺了前置步骤的判据，在一个刚栽过跟头的人
手里会通过 —— 而那次通过，读起来和「这条判据是完整的」一模一样。

**八条里有五条本来就是干净的**，而且干净的那几条**都带着自己的理由**（对照组、地板、
已修正的记录）——它们不是碰巧对，是写的时候就想到了。**缺的四处集中在最早写的两条**
（A 和 C-a），这和它们写在规矩之前是一致的。

**扫过的全部日志标签**（§五 及其后引用的 `[key]`、`[action]`、`[search]`、`[keys]`）
**都在源码里存在** —— 逐个对 `windows/host/src/*.rs` 的字面量比过，没有第二处名字不符。

### 判据 A —— Ctrl-C 悬案是不是被 argus v1.40 解掉了

**目的**：把「Polter 的 Ctrl-C 坏了」和「上一轮的注入工具没发扫描码」分开。

0. **先做 §5.0 那三步。** 尤其第 3 步：这条判据的判读表全靠 `[key]` 行，
   而它没有自己的正对照。
1. 确认真机 Argus Agent 版本 ≥ v1.40（低于此先升级，否则这条判据无意义）。
2. 起一个 Polter 窗口，在里面跑一个长命令（`ping -t 127.0.0.1`）。
   **这条命令用直出字符打，不要用真按键。** 真按键打这一串，在输入法开着时会进组字态
   —— **和判据 B 第 1 步是同一个坑**。它是在准备被测状态，不是在确认焦点（§2.0.1）。
3. `mcp__argus__key(combo="ctrl+c")`。**先看返回的 `sent` 数组**，记下 `ctrl` 和 `c`
   两项各自 `scan` 字段的原文。
4. 再跑一次，加 `injection="scancode_only"`，同样记 `sent`。
5. 两次都 `findstr /c:"[key]" <日志>`，取最后两行 `[key] msg=... vk=0x43 keycode=0x?? ...`。

**判读**（四种结果，含义完全不同）：

| `sent` 里 `c` 的 scan | 日志 `keycode=` | `surface_key=` | 结论 |
|---|---|---|---|
| `0x2e` | `0x2e` | `true` | **悬案解掉了**：注入正常、核心认、Ctrl-C 走通，ping 应被中断 |
| `0x2e` | `0x2e` | `false` | 注入正常但核心拒绝 —— **真缺陷，在核心侧**，与 argus 无关 |
| `0x2e` | `0x0` | 任意 | 注入正常但宿主没读到扫描码 —— 缺陷在 `keys.rs::keycode()` 或消息泵 |
| `0` 或缺失 | `0x0` | `false` | **注入工具仍未发扫描码**，本判据无效，先修工具 |
| 任意 | **日志里一条 `[key]` 都没有** | —— | **不要读进上面那一行。** 这是第五种，而它长得像第四种：键发出去了，落在别人的窗口上（§2.0）。回到 §5.0 第 3 步：正对照也不出现 → **这一轮作废，和扫描码无关** |

**上面那张表原来只有四行，而缺的正是第五行。** 四行的条件都建立在「日志里有那一行」
上，于是「一条都没有」被读成第四行的「缺失」，结论是去修一个没坏的注入工具。
**一张不穷尽的判读表，会把它没列的情况塞进最像的那一格。**

**别用「ping 停了没有」单独下结论**：`sent` 里 scan 是 0 而 ping 也停了，说明还有第三条
路径在起作用，那本身是个发现。

### 判据 B —— 宿主表那四行是活的还是死的

**目的**：`accelerator()` 的四行是从「核心不绑这个和弦」推出来的，但核心还可能把这些键
**编码进 pty**（3.4）。真是那样的话，这四行和 F11 那行一样是死代码，而且不会有任何东西报告。

1. 起一个窗口，**用真鼠标点一下它**取得焦点（§2.0；**不要靠打一个字母确认**，理由见下）。
2. **把输入法切到英文**（Shift 切换），然后按一个和弦，**判据是那一行的
   `composing=Some(false)`**。不是 false 就别往下走 —— 后面每一格都会作废。
3. 依次 `key("ctrl+shift+m")`、`key("ctrl+shift+d")`、`key("ctrl+shift+z")`、
   `key("ctrl+shift+=")`，每次之间 `wait_stable`。
4. 读日志，**用 PowerShell 而不是 `findstr`**：

   ```powershell
   Select-String -Path <日志> -SimpleMatch 'host accelerator'
   Select-String -Path <日志> -SimpleMatch '[key]'
   ```

   **`findstr /c:"host accelerator"` 在这里不成立**：带空格的串外层引号会被剥掉，
   实际执行成 `findstr /c:host accelerator <日志>`，它把 `accelerator` 当第二个文件名，
   报 `Cannot open accelerator`。**而那条报错混在输出里不显眼，读起来像「没有匹配」。**

**判读**：

- 四行 `host accelerator "..." -> binding_action = true` 全出现 → 四行都活着且动作成功。
- 某个和弦只有 `[key] ... -> surface_key=true`、**没有**跟着的 `host accelerator` 行
  → **那一行是死的**，核心把这个键编进 pty 了。把该和弦和 `keycode=` 的值原文报回来。
- 有 `host accelerator` 行但 `binding_action = false` → 行是活的，核心不认这个 action 名。
- **地板（负向）**：先按一个谁都不要的和弦（`Ctrl+Shift+Y`），确认它**不**产生
  `host accelerator` 行。连它都产生了，说明这条日志线索本身不可信，上面三条判读全部作废。
- **地板（正向）**：§5.0 第 3 步。**这一条不能省，而且它不能用这四个和弦里的任何一个**
  ——它们正是被问的对象。所以正对照证明的是 **`[key]` 行在记**，不是 `host accelerator`
  行在记；后者没有独立的正对照可用，**这一点要知道，不要假装它有**。

  2026-09-03 这条判据第一次跑出 **74 条 `[key]`、0 条 `host accelerator`**，读起来
  正是「四行全是死代码」。**拦住那次误报的是操作者手上恰好见过一次 `Ctrl+Shift+D` 会响**
  ——恰好，不是安排。写进这里之后就不再是。

**第 1 步为什么不能是「先按一个普通字母」** —— 这一步原来就是那么写的，而它在真机上
把整轮判据作废过一次：那台机器的输入法是**默认开着**的，按下字母就进入组字态，之后每一个
和弦都带 `composing=Some(true)` 被 TSF 吃掉。读数是 **74 条 `[key]` 行、0 条
`host accelerator`** —— **和「这四行全是死代码」一模一样**。

**那一步看起来是无害的确认，实际是一次会作废整轮判据的状态切换。**

（顺手记一下 `Ctrl+Shift+=` 那次 `sent` 里的 vk：`accelerator()` 匹配的是 `VK_OEM_PLUS`，
注入器若发的是小键盘 `VK_ADD`，匹配不上是工具问题不是代码问题。）

### 判据 C —— 菜单说的、和按下去做的，是不是同一件事

**目的**：验 3.3(a)(b) 那一整族。这是全表最危险的一类：按下去有反应，反应是别的事。
正向表和反向表是**两张表**，我对反向表那几条预测最没把握。

> **第一部分先跑，早于第二部分。** 它只用 `ui_snapshot`（L1，不用审批），不碰键盘，
> 便宜；而且三条预测里只要中了任何一条，第二部分要问的问题就变了。
>
> ✅ **这一部分已经跑过了：五条预测全中，含对照组。** 下面保留原样，因为**预测被证实
> 之后，这段的价值从「去验一下」变成了「一次成功的推理长什么样」**——它是从
> `Binding.zig` 的 `track_reverse` 和 `putFlags` 的覆盖行为推出来的，没有碰机器。
>
> 当时写在这里的提醒也留着，因为它对下一份预测仍然成立：
>
> **下面表格里「我的预测」一栏，是从源码推出来的推测，一条都没有在真机上验过。**
> 请把它读成「有人猜了三个数，去看看对不对」，**不要**读成「已知事实，去确认一下」——
> 这两种读法在结果不符时会导出完全相反的处置：前者是「预测错了，回去改源码的读法」，
> 后者是「机器坏了 / 我操作错了，再试一次」。三条全错也是一个干净的结果，照实报回来即可。
>
> **错标比缺标更坏**，所以这一条值得先跑：缺一行，人会去找；标错一行，人会照着按，
> 然后怀疑是自己记错了。一个在场且错误的标签是被相信的。

**准备**：**先做 §5.0 那三步**，然后一个窗口，开**三个**标签（`Ctrl+Shift+T` 两次），
三个标签标题必须能区分（各跑 `title 1` / `title 2` / `title 3`——**这要打字，所以输入法
必须已经关掉**）。只有一个标签时所有 performable 绑定都会拒绝，那样什么都测不出来。
停在标签 1（`Alt+1`）。

**第一部分（先跑）：菜单说什么**（纯读，不用按键，L1）

打开菜单，`ui_snapshot` 读「编辑」和「文件」两组的行文本**原文**（连快捷键那半一起，
没有就写「空」），回报下面五行：

菜单里这五行（`menu.rs` 的 `EDIT_ROWS` / `FILE_ROWS`）：

| 菜单行 | 它问核心的 action | 我的预测（**未验，来自读源码**） | 预测错了意味着 |
|---|---|---|---|
| 编辑 › 复制 | `copy_to_clipboard` | 显示 **`Ctrl+Insert`**，不是 `Ctrl+Shift+C` | performable 绑定其实进了反向表 |
| 编辑 › 粘贴 | `paste_from_clipboard` | **一个快捷键都不显示** | 覆盖时没有摘掉旧 action 的反向项 |
| 文件 › 关闭分屏 | `close_surface` | **一个快捷键都不显示** | 同上 |
| 文件 › 关闭标签 | `close_tab:this` | 显示 **`Ctrl+Shift+W`** | 反向表没接收覆盖者 |
| 文件 › 关闭窗口 | `close_window` | 显示 **`Alt+F4`**（对照组） | 连没有争议的行都错 → 整条链（`ghostty_config_trigger` → `getTrigger` → `reverse`）没走通，上面四行的结果全部作废 |

**最后一行是这一部分的地板。** 前四行里有三行的预测是「空」，而**一组全是「预期为空」的
预测，无法把「预测中了」和「测量根本没发生」分开**——三个空看起来像三条确认，实际可能是
同一条链断了一次，而这两者的处置完全相反。所以旁边必须站一条「预期非空」的。

**这条地板自己的地板**（已在源码核过，WT 不必再查，写在这里是为了让「它空了」可判读）：

- `Config.zig` 的 `Keybinds.init`：`close_window` 在 `!isDarwin` 块里绑的就是
  `.{ .physical = .f4 }, .mods = .{ .alt = true }`——**Windows 上确实有这条绑定**。
- 用的是 `set.put` 不是 `putFlags`，所以 **非 performable，进反向表**（`Binding.zig` 的 `track_reverse`）。
- 全树只有一处 `physical = .f4`（另一条 `close_window` 在 mac 分支，绑 `Super+Shift+W`），
  **没有第二条绑定会来覆盖它、摘掉它的反向项**。
- 渲染这一半也核过：`keyseq.rs::mods_label(alt)` → `Alt+`，
  `keyseq.rs::key_label(physical, F4)` → `F4`（`keyseq.rs` 的测试里就有这条断言）。
  所以标签**只能是** `Alt+F4`。

于是「关闭窗口」这一行是空的，只剩两种解释，处置相反：

| 观察 | 解释 | 处置 |
|---|---|---|
| 关闭窗口空，且**其余四行也全空** | 链断在更上游——`ghostty_config_trigger` 没导出、config 句柄是空、`shortcut_for` 根本没被调用。日志里会有 `[keys] ghostty_config_trigger not exported; menus will show no shortcuts`（`keys.rs::config_trigger_fn`） | **前四行的结果全部作废**，先修链，再重跑整个第一部分 |
| 关闭窗口空，而**另有非空的行** | 链是通的，单独这一条查不到——那么上面四条源码核查里有一条是错的，最可能是「反向表被别的东西摘了」 | 前四行的结果**可用**，但反向表的摘除逻辑比我读到的更宽，`close_surface` / `paste_from_clipboard` 那两个「空」要重新归因 |

**只有第一种才作废其他行。** 把「关闭窗口是空的」直接读成「整批作废」是过度反应，
而读成「和另外三个空一样」是漏报——两种都会走错，所以这一格要照上表分开报。

**第二部分（第一部分跑完、结果报回来之后再跑）：按下去做什么**

键去哪儿由 3.1–3.4 那几张表回答，这里不重复。**这一部分只问一件事：3.3 那四类
「表上有、但行为不是你以为的那个」，按下去到底发生了什么。**

**通用读法**：每一步之后 `findstr /c:"[action]" <日志>` 取真正触发的 action 名——
**日志里的 action 名是判据，界面是佐证**。界面用 `ui_snapshot`（L1）读文字，
**不要用截图判断标签顺序**：截图分不出「顺序没变」和「顺序变了但看起来差不多」。

每一组都写了**两种结果各自意味着什么**。一条只写了「期望值」的判据，在拿到别的值时
只能告诉你「不对」，不能告诉你**不对在哪一头**——而这四类的两头，处置完全相反。

---

### 组 C-a —— 3.3(a)：「移动标签」和「切换标签」

**准备**：**先做 §5.0 那三步**，然后一个窗口、**三个**标签，标题必须能区分
（各跑 `title 1` / `title 2` / `title 3`——**要打字，输入法必须已经关掉**）。停在标签 1。

| # | 按键 | 若 action 是 … | 若 action 是 … |
|---|---|---|---|
| C-a1 | `Ctrl+Shift+→` | `next_tab`：焦点到标签 2，**顺序仍 1,2,3** ← 表是对的 | `move_tab`：顺序变了 ← 宿主表那四行没删干净 |
| C-a2 | `Ctrl+Tab` | `next_tab`：焦点动，顺序不动 | 同上 |
| C-a3 | `Alt+1` | `goto_tab 1`：回到标签 1 | 没反应 → `goto_tab` 这一族整个没通，C-a1/C-a2 的读数也要重看 |
| C-a4 | `Ctrl+Shift+PageDown` | `move_tab 1`：**顺序变成 2,1,3**，焦点仍在原来那个标签上 | 只切了焦点 → 「这才是移动标签」这句话是错的 |

**C-a5 是这一组里唯一问得出旧缺陷的那一步，不要跳过。**

> 关到只剩**一个**标签，再按 `Ctrl+Shift+→`。
>
> 从前的缺陷正是在这里：`next_tab` 是 `performable`，只剩一个标签时核心**拒绝**，
> 于是掉进宿主加速键表，而那张表当时把这个和弦送去 `move_tab`——
> **一个标签时移动、多个标签时切换**。C-a1–C-a4 全部问不到这个状态。
>
> - **期望**：什么都不发生；日志里有 `[key] ... -> surface_key=false`，
>   **而且后面没有跟着 `host accelerator` 行**。
> - **失败**：出现 `[key] host accelerator "move_tab..."` → 那四行还在。
> - **这一格靠「没有跟着的行」下结论**，所以 §5.0 第 3 步必须已经做过：
>   `[key]` 行本身不在记的时候，「没有跟着的行」什么都不说明。

### 组 C-b —— 3.3(b)：后写的绑定覆盖先写的

三个和弦，**每一个的判别读数都不是「有没有反应」，而是「反应是哪一种」**。

**C-b1 `Ctrl+Shift+W` —— `close_tab:this` 还是 `close_surface`？**

> **必须在一个有两个分屏的标签里按**，否则两个 action 看起来一模一样：
> 单分屏的标签上，关掉那个 surface 就等于关掉那个标签。
>
> 准备：一个窗口，两个标签；在标签 1 里按 `Ctrl+Shift+O` 造一个右分屏（现在标签 1 有两个 pane）。
>
> - **`close_tab:this`（表上说的）**：**整个标签 1 消失**，两个 pane 一起没了，剩标签 2。
> - **`close_surface`**：只关掉一个 pane，**标签 1 还在**，里面剩一个 pane。
>
> 这一条同时验掉了 3.3(b) 的「反向表」那半：如果第一部分里「关闭分屏」那行显示了
> `Ctrl+Shift+W`，而这里按出来的是 `close_tab`，那就是**菜单说的和按下去做的不是一件事**
> ——这一类的完整形态，也是这份文件写 3.3 的原因。

**C-b2 `Shift+Insert` —— `paste_from_selection` 还是 `paste_from_clipboard`？**

> **不要用「粘进来的是不是刚选中的那段」当判据。** Windows **没有**选择剪贴板，
> 而这个宿主明确声明不支持它（`cb_write_clipboard` 直接拒绝这一类，`menu.rs` 里
> 「粘贴选区」那行就是因此删掉的）。所以 `paste_from_selection` 在 Windows 上
> **很可能什么都粘不出来**——而「什么都没发生」和「按键没送到」长得一模一样。
>
> 所以判据要靠**系统剪贴板里一个已知的哨兵串**：
>
> 1. `set_clipboard("SENTINEL-Cb2")`（L1）。
> 2. 确保终端里**没有**选中任何文字。
> 3. 按 `Shift+Insert`。
>
> - **屏幕上出现 `SENTINEL-Cb2`** → 生效的是 `paste_from_clipboard`，**覆盖没有发生**，
>   3.3(b) 那张表的这一行是错的。
> - **什么都没出现** → 生效的是 `paste_from_selection`，覆盖发生了，表是对的——
>   **并且这条快捷键在 Windows 上实际是废的**，那是一条该记进 3.3 的可用性事实。
> - **地板**：同一轮里按一次 `Ctrl+Shift+V`，`SENTINEL-Cb2` 必须出现。
>   它不出现就说明剪贴板或按键注入本身没通，上面两条读数都作废。

**C-b3 `Shift+Home` —— `scroll_to_top` 还是 `adjust_selection`？**

> 准备：先让回滚缓冲里有足够多的内容（跑 `dir /s` 之类刷几屏），停在底部。
>
> - **`scroll_to_top`（表上说的）**：视口跳到**最顶端**，看到的是很早以前的输出。
> - **`adjust_selection`**：视口不动，出现一段**选中高亮**。
>
> 两者的差别是「画面换了」还是「多了高亮」，`ui_snapshot` 读不到高亮，
> **这一条是四组里唯一必须看截图的**——但它要区分的两种结果在画面上差异极大
> （整屏内容替换 vs 一条高亮），不属于「截图分不出来」的那一类。

### 组 C-c —— 3.3(c)：裸 `Escape` 是一条绑定

**这一组必须跑两次，条件相反，否则它证明不了任何东西。**

`Escape` 绑到 `end_search` 且 `performable`：没在搜索时核心让路，Escape 照常进 pty。
所以「Escape 能用」和「Escape 被搜索栏吃掉」**在不同条件下都是正确行为**，
单跑一次的结果两种解释都成立。

两次都是按 `Escape`，变的只有条件：

| # | 条件 | 期望 |
|---|---|---|
| C-c1 | 搜索栏**关闭** | **日志里没有 `end_search` 动作**；终端里 Escape 照常起作用（在 `vi` 里能退出插入模式，或屏幕上有 pty 侧的反应） |
| C-c2 | 先打开搜索栏 | 搜索栏关闭，且日志里有一行提到 `end_search`——**把那一行的原文抄回来**（是 `[action]` 还是 `[search]`，`binding_action` 是 true 还是 false，都要） |

> **这两条第一版写错了，改法本身是个教训。**
>
> C-c1 原来要的是 `[key] ... -> surface_key=true`。**那个读数不存在**：Escape 不带
> Ctrl/Alt/Win，而 `[key]` 行在头 20 个键之后只记带这三个修饰键的（见 2.1）。
> **一条判据要的读数根本不会出现，跑出来的「没看到」会被读成缺陷。**
>
> C-c2 原来写死了期望是 `[action] ... end_search`。真机上出现的是
> `[search] end_search -> binding_action = false`——**行的形状不同，而且它说的是另一回事**。
> 写死措辞的判据，会把「和我想的不一样」判成「失败」。所以现在要的是**抄原文**，
> 不是**对字符串**。
>
> （这两条都是「判据里的字符串是猜的」那一类：写在实现之前的精确措辞，开跑前得先对
> 真机日志核一遍——**判据的假阴性和真缺陷长得一模一样。**）

> **C-c1 失败（出现 `end_search`）意味着 `performable` 没有让路**——那么在 vim 里
> 按 Esc 会去关一个没开的搜索栏而不是退出插入模式，这是一条会天天咬人的缺陷。
> **C-c2 失败意味着搜索栏关不掉。** 两者都红只可能是 Escape 根本没送到，
> 那要先回去看 `[key]` 行在不在。

### 组 C-d —— 3.3(d)：`performable` 拒绝之后掉到宿主表

**这一类曾经真的伤到过人**：`Ctrl+Shift+C` 在没有选中文本时被核心拒绝，掉进宿主加速键表，
宿主把**窗口标题**塞进了剪贴板——人以为自己复制失败了，实际上剪贴板被换了内容。
那一行已经删了，**这一步问的是它有没有回来，或者有没有别的东西接住了这个和弦**。

> 1. `set_clipboard("SENTINEL-Cd")`（L1）。
> 2. 确保终端里**没有**选中任何文字。
> 3. 按 `Ctrl+Shift+C`。
> 4. `get_clipboard()`（L1）。
>
> - **剪贴板仍是 `SENTINEL-Cd`** ← 正确：核心拒绝了，宿主没有接手，什么都没发生。
> - **剪贴板变成了窗口标题**（或任何别的东西）← 那一行回来了，或者有别的东西接住了。
> - 日志佐证：应有 `[key] ... -> surface_key=false`，**且其后没有 `host accelerator` 行**。
> - **地板**：选中一段文字再按一次 `Ctrl+Shift+C`，剪贴板必须变成**那段文字**。
>   它不变就说明复制这条路整个没通，上面的「剪贴板没变」就不是通过，而是没测到。

---

### 组 P —— 3.3(e)：`Ctrl+C` 在同一个键上的两种行为

**这一组的形状和别的判据不一样，值得先说清楚。** 这里没有一格能单独证明什么：
P1 和 P2 **互为对照**。只看 P2（无选区、中断了、剪贴板没变）读起来像通过，但一个
**根本没绑上** 的构建给出的读数一模一样——键没绑，`Ctrl+C` 照样编码成 0x03 照样中断，
剪贴板当然也不变。**是 P1 把「没绑上」排除掉的。** 两格都过才算过；只跑 P2 等于没跑。

> ⚠️ **不要拿 `surface_key=false` 当判据，它在这条路上永远不出现。**
> 无选区按 `Ctrl+C` 时核心答的是 **`true`**（拒绝之后 `encodeKey` 编出了 0x03），
> 理由见 3.3(e)。C-d 那条判据里的 `surface_key=false` 是给 `Ctrl+Shift+C` 写的，
> **照抄到这里会在一个完全正常的构建上判红。**
>
> 这一组能分开「让路了」和「没绑上」的日志行是宿主的 **`[clip] write`**
> （`main.rs::cb_write_clipboard`）：P1 必须有，P2 必须没有。

**前置（照 §2.0 / §2.0.1 做，不要跳）**：**用真鼠标点一下被测窗口**，不要只调置前函数；
并确认这一轮里没有进过输入法组字态。

> **P1 —— 有选区：复制，并清掉选区**
> 1. `set_clipboard("SENTINEL-P1")`（L1）。
> 2. 终端里打出一行已知文字，**拖选其中一段**。
> 3. 按 `Ctrl+C`。
> 4. `get_clipboard()`。
>
> - 剪贴板 == **选中的那段**（不是 `SENTINEL-P1`，不是窗口标题）。
> - **选区在画面上消失**——这是 `selection-clear-on-copy` 在 Windows 上默认
>   `true` 的读数。**选区还在 = 分叉没生效**，而那样 P2 在第二次按时会失效。
> - 日志：有 `[clip] write ... -> ok`。
>
> **P2 —— 无选区：中断，剪贴板不变**（关键格）
> 1. `set_clipboard("SENTINEL-P2")`。
> 2. 跑 `ping -t 127.0.0.1`。
> 3. **不选任何东西**，按 `Ctrl+C`。
> 4. `get_clipboard()`。
>
> - `ping` **停了**（提示符回来）。
> - 剪贴板**仍是 `SENTINEL-P2`**。
> - 日志：**没有** `[clip] write` 行，**也没有** `host accelerator` 行。
> - `surface_key` 是 **`true`**，见上面那条警告。
>
> **P3（地板）—— `Ctrl+Shift+C` 没被弄坏**
> 重复 P1，但按 `Ctrl+Shift+C`。剪贴板必须变成选中的那段。
> **它不变，则 P1 的通过不能归给新绑定**——复制这条路整个就是通的或不通的，
> 而这一格是唯一能分开「新绑定生效」和「复制本来就好使」的对照。
>
> **P4 —— `Ctrl+V`**
> 1. `set_clipboard("SENTINEL-P4")`。
> 2. 在提示符上按 `Ctrl+V`。
> - 命令行上出现 `SENTINEL-P4`。日志有 `[clip] read ... completing`。
>
> **P5 —— 菜单没有跟着变**（136/137 的回归防护）
> 打开「编辑」菜单，看「复制」那一行。
> - 它必须仍然显示 **`Ctrl+Insert`**，**不是** `Ctrl+C`、也不是 `Ctrl+Shift+C`。
> - 显示成 `Ctrl+C` 说明 `performable` 没设上（或反向表逻辑变了），
>   **而那种构建的 P2 会失败**：键会被无条件消费，`ping` 停不下来。
>
> **P6（可选，划掉 `Ctrl+V` 那笔账的下界）—— 剪贴板为空时 `Ctrl+V` 仍进 pty**
> 把剪贴板清空（或放一张图片），在 `cat` 里按 `Ctrl+V`，期望**打出 `^V`**。
> 这一格证明的是取舍的**边界**：拒绝只发生在没东西可粘时，不是所有时候。
> 它红了不算功能坏，只说明 3.3(e) 里那段关于代价范围的描述要改。

**这一组里没有一格用截图当判据。** 唯一必须看画面的是 P1 的「选区消失」和 P5 的菜单
文字；两者都要在同一轮里连着 P2 一起做，因为它们共享同一个前台前提。

---

### 关于 C-b1 的那份日志：它的用途变了

**C-b1 的日志原文仍然单独报回来，但读它的方式已经不同了。**

这条读数原来是任务 127（关最后一个窗口的最后一个标签、进程不退）的**诊断材料**——
用来把「没数到 0」和「数到 0 却没退」两种缺陷分开。**那次诊断已经结束**：定案是
「没数到 0」，修法也落地了（`57c7384a9`、`ef243fdb2`）。

所以现在它是**验收侧的旁证**：问的是「修完之后关闭路径还对不对」，不是「这条红是什么」。
判读随之变化——不再需要去分辨两种缺陷，只需要确认关闭行为符合预期。

> ⚠️ **不要拿 C-b1 当 E8 用。** E8 是四条关闭路 × N∈{1,2} 共八次，C-b1 只走了其中一条路、
> 而且不涉及「关掉最后一个窗口」。**C-b1 全绿不构成对 E8 的任何证据。**

---

## 六、这张表会怎么变错，以及怎么发现

这张表是**副本**，副本一定会漂移，而漂移是静默的——没有断言会红，没有动作会失败，
只有一个人按了表上的键、得到别的结果。所以先写清楚「改哪里会让它过期」：

| 改了这个 | 本表哪部分过期 | 会不会有人发现 |
|---|---|---|
| `src/config/Config.zig` `Keybinds.init()` | 3.1 全部、3.3 的覆盖关系 | **不会**。加一条绑定不会让任何测试变红 |
| 同上，`builtin.target.os.tag == .windows` 那个块（3.3(e) 的两条） | 3.1 的 `核·win` 两行、3.3(e)、判据组 P | **不会，而且比上一行还坏一档**：那个块在 mac/Linux 上是 comptime-dead，`zig build` 连**语法以外的错都不报**——把动作名打错一个字，mac 上照样退 0（量过）。唯一的检查是交叉编译，或 Windows 测试 exe 上的 `test "Keybinds: windows binds bare ctrl+c and ctrl+v"` |
| `src/config/Config.zig` 的 `selection-clear-on-copy` 默认值 | 3.3(e)、判据 P1 | **不会**。它和 `ctrl+c` 是一对，但代码里没有任何东西把这两处绑在一起——只有两边的注释互相点名 |
| `src/input/Binding.zig` `putFlags()` 的覆盖 / 反向表逻辑 | 3.3(b) 的全部推论、判据 C 第一部分 | **不会** |
| `src/input/key.zig` `ctrlOrSuper()` | 3.1 里所有 `Ctrl+…` 的行 | 不会（Windows 上换成 super 就全错） |
| `src/input/keycodes.zig` 的 `native_idx` 或 win 列 | 第四节、判据 A | 不会 |
| `windows/host/src/keys.rs` `accelerator()` | 3.2 | **部分会**——见下 |
| `keys.rs::handle_key_message()` 的四步顺序 | 第二节、判据 A/B 的整个判读逻辑 | 不会 |
| `palette.rs` / `search.rs` / `prompt.rs` / `settings_ui.rs` / `overlay.rs` 的 `WM_KEYDOWN` | 3.5 | 不会 |
| `menu.rs` 的行表 | 3.6、判据 C 第一部分 | 不会 |
| **`keys.rs` 里决定「哪些键会被记进 `[key]` 行」的那个条件**（今天是 `n <= 20 \|\| modded`，而 `modded` 不看 Shift） | **本文里每一条以「日志里应该出现 / 不应该出现某行」写成的判据** | **不会，而且比上面几行更难发现——见下** |

### 6.1 一种和「留下谎话」镜像的漂移：**改一条规则，会在别处作废一批判据**

**已经记过的那一类是**：改了某个函数的行为，别处描述它的散文就变成了谎话。那一类还
算好找——**谎话和代码共享一个符号名**，`grep` 那个名字就能把它们捞出来（本文第 6 节
最初写下来的时候，作者自己就漏了五处，靠 grep 找回来）。

**这一格是它的镜像，方向相反**：不是代码变了、描述没跟上，而是**描述（规则）变了，
而依赖旧描述的判据没跟上**。

**它更难发现，原因很具体：那条规则和被它作废的判据之间没有任何共同的字符串。**
没有人会去 `grep`「哪些判据依赖『所有按键都会被记录』这个假设」——那个假设从来没有
被写出来过，它是判据作者当时脑子里的默认。

**这不是假想，本文里已经发生过一次。** §2.1 写下「`[key]` 行不是每个键都打」的那天，
判据 C-c1 已经存在，而它要求的正是一个**不会出现**的读数（Escape 不带 Ctrl/Alt/Win）。
**跑出来的「没看到那一行」会被读成缺陷。** 写规则的人和写判据的人是同一个，相隔一天。

**所以处置是一个动作而不是一条提醒**：**写下或改动一条「什么会被记录 / 什么不会」的
规则之后，立刻回头扫一遍本文所有判据，问「哪几条的读数依赖我刚改的这条」。**
这和「宣布一条检查项就当场跑它」是两个方向：那条管**我刚宣布的规则我自己遵守了吗**，
这条管**我刚宣布的规则作废了谁**。

**唯一已经自己会报告的那一格**，是 `keys.rs` 已经做对的事：宿主表每一行**触发时都打日志**，
所以「日志里某一行再也不出现」= 核心长出了这个和弦的默认绑定 = 该行可以退休。这是本仓
现成的模式，值得抄，不值得重发明。

**如果要给这张表加一道闸**（这仓已经有十道闸的先例），能验的和不能验的要分清：

- 能验：从 `Config.zig::Keybinds.init()` 抽出 Windows 默认集（按 `!isDarwin`、
  `ctrlOrSuper→ctrl` 解开），和本文 3.1 的行做**集合比对**，差集不为空就红。这道闸能抓住
  「核心加/删/改了一条默认绑定而本表没跟」，也就是上表里最大的那一格。
- 能验：本文 3.2 的四行与 `keys.rs::accelerator()` 的 `match` 分支做集合比对。
- **不能验**：3.4「这个键会不会被编码进 pty」。静态读不出来，只有真机按一次看
  `surface_key=` 才知道。所以判据 B 不是一次性的验收，是**每次动 `accelerator()` 都要重跑的那一步**。
- **注意**：闸对原始文本做正则时，本文件里写出的符号名（`copy_to_clipboard`、`VK_OEM_PLUS`…）
  会被当成代码扫到。闸要么排除 `docs/`，要么把本文件当成表的一侧而不是代码的一侧。

**最容易加、也最该加的一道，其实是「本文件里不许出现行号」。**
`file.rs:‹数字›` 这种引用会随着任何一次无关的编辑漂掉，而**漂掉的行号读起来和有效的
一模一样**——它不会 404，它会把人送到一段无关的代码前，让人以为自己读错了。
（这句话里的例子刻意没写真数字：一道对原始文本做正则的闸，会把**描述它自己的那句话**
也扫成违规——这仓已经踩过这个形状，见第六节开头那条注意事项。）

这不是假想：本文件第一稿里有 **12 处**行号引用，全是同一个人在同一天写的，其中一处
就在写下「不要写行号」这句话的同一份文件里。**所以这一条不属于「知道了就能做到」的
那一类**，它需要一道 `grep -n '\.\(rs\|py\|zig\):[0-9]'` 的闸，而这道闸的名字
恰好就是它查的东西——不会有 `settings-one-reader` 那种名实不符的问题。
指向符号名（`keyseq.rs::mods_label`、`Config.zig` 的 `Keybinds.init`）代价一样低，
而且改名时会被搜索找到，行号不会。

---

## 七、和 macOS 对账：哪些偏离是对的，哪些是漏的

**这一节回答的是另一个问题**，和 3.1–3.4 那几张表不同：那些说「Windows 上按键去哪儿」，
这一节说「同一个动作在两个平台上的键为什么不一样，以及哪些不一样是没道理的」。

**起因是一条很自然的规则**：mac 的键换算过来应该就是 `Cmd→Ctrl`、`Opt→Alt`。
**这条规则不成立，而它不成立的三种方式，正是这份对账的全部内容。**

**数据来自 `Config.zig::Keybinds.init` 的原文**（不是本文前面那几张表——那是副本，
副本会漂，见第六节），按 `builtin.target.os.tag.isDarwin()` 两个分支各解一遍：
**mac 85 个和弦，Windows/Linux 72 个。**

### 7.1 那条规则的三处失效

**（一）`Ctrl+字母` 不属于应用，属于终端。**
核心自己的清单在 `src/input/paste.zig`：`0x03 VINTR (Ctrl+C)`、`0x15 VKILL (Ctrl+U)`、
`0x1A VSUSP (Ctrl+Z)`、`0x17 VWERASE (Ctrl+W)` …… 这些是 termios 特殊字符。
把 `Cmd+W` 译成 `Ctrl+W`，拿走的是 shell 里「删除前一个词」。
**所以非 mac 分支整体改用 `Ctrl+Shift+字母`——这不是随意选的命名空间，是唯一没被占的那个。**

**（二）`Cmd+Ctrl+X` 译过去会丢掉一个修饰键。**
mac 分支里有 **6 条**用到 `Ctrl`，**没有一条是裸 `Ctrl`，全部是 `Cmd+Ctrl+X`**：

| mac | 动作 |
|---|---|
| `Cmd+Ctrl+↑ ↓ ← →` | `resize_split` |
| `Cmd+Ctrl+=` | `equalize_splits` |
| `Cmd+Ctrl+F` | `toggle_fullscreen` |

照规则译是 `Ctrl+Ctrl+X`，**两个修饰键塌成一个，变成 `Ctrl+X`**——正好落回第（一）条。
**这一类的问题不是「译错了」，是规则在这里根本不适用**，而这两种在报告里长得一样、
处置完全不同。

**（四）mac 用「加一个 Shift」表示反向，而这个习惯在非 mac 上活不下来。**

mac 说「反方向」的办法是加一个 `Shift`：`Cmd+G` / `Cmd+Shift+G`、`Cmd+[` / `Cmd+Shift+[`。
**翻过来就不成立了，因为 `Ctrl+Shift+<字母>` 里的那个 `Shift` 已经被花掉**——它正是用来
躲开第（一）条的。**再加一个 `Shift` 表示反向，两个 `Shift` 塌成一个。**

**这和第（二）条是同一件事**：非 mac 的命名空间**比 mac 少一个可用的修饰键**，而 mac 那些
「用修饰键表达配对关系」的习惯，翻过来时**第一个失效的就是它们**。

**而绕道 `Alt` 是堵死的，不是难走：**

- `Ctrl+Alt+<字母>` **就是 `AltGr`**。欧洲布局用它打第三层字符（`@`、`€`、`{`、`}` 等），
  绑了就是从那些用户手里拿走一个可打印字符。
- `Ctrl+Shift+Alt+<字母>` 是 `AltGr+Shift`，也就是有第四层的布局上的第四层。**更少见，
  而更少见意味着更难归因，不意味着更安全。**
- **而且我们分辨不出来。** `src/input/key_mods.zig` 的 `Mods.binding()` 只保留
  `shift/ctrl/alt/super` 四个笼统位，**把左右侧位丢掉了**——尽管 Windows 宿主其实知道
  AltGr 的签名是「左 Ctrl + 右 Alt」（`keys.rs::mods()` 会置 `MODS_ALT_RIGHT`）。
  所以 `AltGr+Shift+G` 和真按四个键，**在绑定匹配那一步是同一个和弦**。
- **危害的机制在我们自己的代码里**：`handle_key_message` 会先偷看 `WM_CHAR`，
  **一旦 `surface_key` 消费了这个事件就把它删掉**——用户失去的就是那个字符本身。

> **「`AltGr+Shift` 到底会不会产生第四层字符」这一条，仓里没有依据，我也没法在这台机器上
> 测，所以它是未答的。** 但上面那条机制**不依赖它成不成立**：只要有任何布局把某个字符放在
> 那儿，我们就会吃掉它，而且分辨不出来。**按「可能成立」处置。**

**所以「查找下一个/上一个」用的是 `F3` / `Shift+F3`。** 功能键**根本不参与修饰键命名空间的
争夺**，而且代价是**条件性**的：它们是 `performable`，没有搜索开着时核心让路，
F3 照常被编码进 pty（`Surface.zig`：`if (leaf.flags.performable and !performed) return null;`
之后 `keyCallback` 走到 `encodeKey`）。**「F3 归终端，除非搜索开着」——这是一句能讲给用户听
的话，而「在某些布局的某些字符上可能出问题」不是。**

（一个没验的前提：这依赖 `navigate_search` 在没有搜索时确实报告「没执行」。那是上游标它
`performable` 的用意，但我没有读它的实现。）

**（三）同一族动作在两边的和弦数不同。** 关窗族 mac 有四个、非 mac 只有两个：

| | mac | 非 mac |
|---|---|---|
| `close_surface` | `Cmd+W` | **无** |
| `close_tab:this` | `Cmd+Opt+W` | `Ctrl+Shift+W` |
| `close_window` | `Cmd+Shift+W` | `Alt+F4` |
| `close_all_windows` | `Cmd+Opt+Shift+W` | **无** |

**四个塌成两个，掉了两个动作**，而其中一个（`close_surface`）是被**同一个和弦的第二次
`put` 静默覆盖**的，不是「没写」。

### 7.2 乙类：漏掉的（有行动价值的一节）

**两种形态，第二种只能靠扫和弦重复找出来，看清单看不见。**

#### 形态一：同一个和弦写了两次，后写的赢，先写的那个动作没了键

`Binding.zig` 的 `putFlags` 里那句 `gop.value_ptr.* = .{ .leaf = ... }` 是无条件赋值。
非 mac 生效集里**有 6 处**：

| 和弦 | 被覆盖的 | 生效的 | 输的那个还有别的键吗 |
|---|---|---|---|
| ~~`Ctrl+Shift+W`~~ | ~~`close_surface`~~ | `close_tab:this` | ✅ **已补** `Ctrl+Shift+X`（死绑定已删） |
| `Shift+Home` | `adjust_selection:home` | `scroll_to_top` | ✅ **已补** `Ctrl+Shift+Home` |
| `Shift+End` | `adjust_selection:end` | `scroll_to_bottom` | ✅ **已补** `Ctrl+Shift+End` |
| `Shift+PageUp` | `adjust_selection:page_up` | `scroll_page_up` | ✅ **已补** `Alt+Shift+PageUp` |
| `Shift+PageDown` | `adjust_selection:page_down` | `scroll_page_down` | ✅ **已补** `Alt+Shift+PageDown` |
| `Shift+Insert` | `paste_from_clipboard` | `paste_from_selection` | 有（`Ctrl+Shift+V`） |

**前五行是五个动作在非 mac 上没有任何键。** mac 上它们都有（`Shift+Home` 等在 mac 分支
里没有被 `scroll_*` 覆盖，因为 mac 的滚动用的是 `Cmd+Home/End/PageUp/PageDown`）。

**用户看得见的后果**：在 Windows/Linux 上按 `Shift+Home` 不会「把选区扩展到行首」，
而是**跳到回滚缓冲的顶端**；`Shift+PageUp` 同理。这和 mac 的行为相反。

#### 形态二：从来没绑过

| 动作 | mac | 非 mac | 处置 |
|---|---|---|---|
| `clear_screen` | `Cmd+K` | ✅ **`Ctrl+Shift+K`** | 已补 |
| `navigate_search:next` / `:previous` | `Cmd+G` / `Cmd+Shift+G` | ✅ **`F3`** / **`Shift+F3`** | 已补。**不是 `Ctrl+Shift+G` 一系**——理由见 7.1（四） |
| `close_all_windows` | `Cmd+Opt+Shift+W` | 无 | **有意不绑**：mac 自己就放在四修饰键上——那是留给「不常用且误触代价高」的动作的位置 |
| `undo` / `redo` | `Cmd+Z` / `Cmd+Shift+Z` | 无 | **有意不绑**：终端里「重做」几乎没有语义；这个宿主的「撤销」实际是「重开关闭的标签」，两者不成对 |
| `scroll_to_selection` | `Cmd+J` | 无 | **有意不绑**：很少用，鼠标滚一下就到 |
| `search_selection` | `Cmd+E` | 无 | **有意不绑**：要先有选区，属于「知道的人会去菜单里找」的那类 |
| `equalize_splits` | `Cmd+Ctrl+=` | **核心无**，宿主 `Ctrl+Shift+=` 顶着 | ⚠️ 见 7.5：对用户不是缺口，但是一枚定时器 |

> **⚠️ 「查找下一个/上一个」绑上了，但菜单里仍然不会显示这两个快捷键。**
> 它们是 `performable`，而 performable 的绑定**不进反向表**（3.3(b)），菜单快捷键那一半
> 读的正是反向表。**macOS 上同样不显示**——上游行为，不是这次改动带来的。**键能用，
> 只是菜单不写出来。**

**这一族要分清两句话，因为它们只有一句是理由**：
「`Ctrl+K`/`Ctrl+Z`/`Ctrl+E`/`Ctrl+G` 被终端占了」**解释了为什么直译的和弦不能用**；
**它没有解释为什么没有给一个 `Ctrl+Shift+…`**。前者是甲，后者是乙——
**同一行里可以同时成立，而只看前半句就会把整行归成「刻意偏离」。**

### 7.3 甲类：偏离是对的（按理由分组，不逐条列）

逐条列会让这一节变成那张没人读的表。**理由只有四条，覆盖了 31 条「译不过去」里的大部分。**

| 理由 | 覆盖 | 说明 |
|---|---|---|
| **`Ctrl+字母` 属于终端** | `start_search` `close_tab` `new_tab` `new_window` `quit` `select_all` `new_split` `inspector` `goto_split` … | mac 的 `Cmd+X` → 非 mac `Ctrl+Shift+X`。**唯一没被占的命名空间。** |
| **数字用 Alt 不用 Ctrl** | `goto_tab 1..8`、`last_tab` | mac `Cmd+1..9` → 非 mac `Alt+1..9`。这是 Linux 终端一贯的做法。 |
| **平台自己的惯例更强** | `close_window`：`Cmd+Shift+W` → **`Alt+F4`** | Windows 上关窗就是 `Alt+F4`，照译成 `Ctrl+Shift+W` 反而不合习惯（而且那个和弦已经被占了）。 |
| **底层按键本来就能直接打出来** | `Cmd+→/←/Backspace`（`\x05` `\x01` `\x15`）、`Opt+←/→`（`ESC b` / `ESC f`） | 这五条在 mac 上是**别名**：macOS 用户按 `Cmd+→` 表示「到行尾」。在 Windows/Linux 上 `Ctrl+E` `Ctrl+A` `Ctrl+U` `Alt+B` `Alt+F` **本来就直接可用**，不需要别名。**它们的缺席是对的。** |

### 7.4 丙类：没有理由的不一致

**（一）滚动在两边是两套键，而且和选区那套撞了。**
mac 用 `Cmd+Home/End/PageUp/PageDown` 滚动，`Shift+…` 留给扩展选区；
非 mac 把滚动放到了 `Shift+…` 上，于是把扩展选区那四条挤掉了（见 7.2 形态一）。
**这不是平台约束——`Ctrl+Home` 之类在非 mac 上并没有被占。** 两边行为相反，且是静默的。

**（二）`move_tab` 只有非 mac 有。** `Ctrl+Shift+PageUp/PageDown`，mac 没有对应绑定。
这是「多出来的」而不是「缺的」，无害，但它是一处不对称，记在这里以免下次被当成新发现。

**（三）`Ctrl+Shift+D` 在两边指向不同的东西。**
mac `Cmd+Shift+D` = `new_split:down`；非 mac 的 `new_split:down` 是 `Ctrl+Shift+E`，
而 `Ctrl+Shift+D` 在 Polter 里是**宿主加速键表的「右分屏」**。
**照 mac 直觉去按，方向是错的。**

### 7.5 Windows 上要按 Win 键的和弦——七条，这一节最该有人看

非 mac 分支里有 **7 个和弦用到 `super`**，而在 Windows 上 `super` 就是 **Win 键**：

| 和弦 | 动作 |
|---|---|
| `Ctrl+Win+[` / `Ctrl+Win+]` | `goto_split:previous` / `:next` |
| `Ctrl+Shift+Win+↑ ↓ ← →` | `resize_split` |
| `Ctrl+Shift+Win+J` | `write_screen_file:copy` |

**在 macOS 上 `Cmd` 是应用的修饰键；在 Windows 上 `Win` 是操作系统的修饰键。**
这一族是「把 mac 的 `super` 原样搬过来」的结果，而不是为 Windows 选的。

**这里不下结论，因为「系统会不会吃掉它」是可测的事实而不是意见**——见 7.6 第二块，
七条全部进 WT 的待验清单。

### 7.6 冲突检查：三块，可信度不同，分开写

**混着三种可信度的一份报告，读的人会按最高的那一档去信全部，而错的那部分正是他最会
照着做的。** 所以分块，每块开头写明它是哪一类。

#### （甲）终端会吃掉的——**有仓内证据**

`src/input/paste.zig` 的清单，逐字：
`0x03 VINTR (Ctrl+C)`、`0x1C VQUIT (Ctrl+\)`、`0x15 VKILL (Ctrl+U)`、`0x1A VSUSP (Ctrl+Z)`、
`0x11 VSTART (Ctrl+Q)`、`0x13 VSTOP (Ctrl+S)`、`0x17 VWERASE (Ctrl+W)`、`0x16 VLNEXT (Ctrl+V)`、
`0x12 VREPRINT (Ctrl+R)`、`0x0F VDISCARD (Ctrl+O)`，外加 `0x04 EOT`、`0x1B ESC`、`0x7F DEL`。

**当前默认集里没有任何一条占用这些和弦**，这是这一块的结论：非 mac 的
`Ctrl+Shift+…` 选择是有效的。

#### （乙）系统会不会吃掉——**待验，不是未验**

这些是**事实，而且在那台机器上按一次就知道**，所以不写结论，写清单（见 7.7）。
要问的是同一件事：**这个和弦到不到得了我们的窗口**——判据是日志里有没有那一行
`[key] ...`（3.4 说过：静态读不出来）。

#### （丙）平台习惯——**这是意见，不是发现，一句话，可以被推翻**

> Windows 用户对 `Ctrl+C/V/X/Z/A/F/S/N/T/W` 的期待很强，而其中 `Ctrl+C` `Ctrl+V`
> `Ctrl+Z` `Ctrl+S` `Ctrl+W` 在终端里另有含义——**这正是 `Ctrl+Shift+` 这套存在的原因，
> 也是这条冲突无法两全的地方**：让 `Ctrl+C` 复制，就拿走了中断。

**写成意见是因为我们测不了它，也不该假装能测。** 用户可以一眼推翻它。

### 7.6b 判据 E：这批新绑定（**两段，第一段不过第二段不算数**）

**八个新和弦，每一个都要跑两段。** 第一段问「这个键到得了我们的窗口吗」，第二段才问
「它触发了正确的动作吗」——**因为这一列的「系统/终端会不会截走」全部是待验的**，而一次
「没反应」在第一段没过的时候读不出任何结论。

**先做地板，每一轮一次**：按一个**已知能用**的和弦（`Ctrl+Shift+T` 新建标签），确认它
产生了 `[key]` 行。**没有这一步，「新键没有 `[key]` 行」可能只是那一轮日志没在记**——
真机上出现过五分钟一条 `[key]` 都没有而键全都在工作（见 2.1）。

| 和弦 | 第一段：到达 | 第二段：动作 |
|---|---|---|
| `Ctrl+Shift+X` | 有 `[key] … vk=0x58 … ` 行 | 当前**分屏**关闭，标签还在（在一个有两个分屏的标签里按） |
| `Ctrl+Shift+K` | 有 `[key] … vk=0x4b …` 行 | 屏幕清空 |
| `F3` | 有 `[key] … vk=0x72 …` 行 | **先开搜索并有匹配**，跳到下一个匹配 |
| `Shift+F3` | 同上 | 跳到上一个匹配 |
| **`F3`（没有搜索时）** | 有 `[key]` 行 | **必须照常送进终端**——这是 performable 让路那一半，**没有它，「F3 归我们了」就是永久的**。在 `vi` 之类会回应 F3 的程序里按一次 |
| `Ctrl+Shift+Home` / `Ctrl+Shift+End` | 有 `[key]` 行 | **出现选区高亮**（不是视口跳动） |
| `Alt+Shift+PageUp` / `Alt+Shift+PageDown` | 有 `[key]` 行，**且 `mods=` 含 `0x01`(Shift) 和 `0x04`(Alt)** | 选区按页扩展 |

> **`Alt+Shift+PageUp` 那一行的 `mods=` 是必看的**，理由见 2.2：翻页键要带
> `KEYEVENTF_EXTENDEDKEY` 才不会走成小键盘孪生扫描码，而 Windows 对「Shift+小键盘」会做
> shift-cancellation **把 Shift 摘掉**。**摘掉之后这个和弦就不是我们绑的那个了**，而
> 「没反应」和「和弦没绑」长得一模一样。

> **`Alt+Shift+PageUp/PageDown` 是这批里唯一带 Alt 的**，Alt 会让它成为 `WM_SYSKEYDOWN`。
> 这条链路已经从源码上确认过（`tabs.rs` 的窗口过程把四种键消息一起交给
> `handle_key_message`，`WM_SYSKEYDOWN` 也算 `is_down`），**但没有真机读数**——
> 所以它是这批里最该先跑的一条。

**反向对照（不做就分不出「绑上了」和「什么都没变」）**：按 `Ctrl+Shift+W`，**必须仍然是
关闭标签**。这一条同时确认那条被删掉的死绑定没有把 `close_tab` 一起带走。

### 7.7 待验清单（交 WT，不混进结论）

**每一条都是「按一次就知道」的事实**，判据：按下去，看日志里有没有对应的
`[key] msg=… vk=… keycode=… -> surface_key=…` 行。

> ⚠️ **这个判据只对第 1–5 条成立，因为它们都带 Ctrl 或 Alt。**
> `[key]` 行在头 20 个键之后**只记带 Ctrl/Alt/Win 的键**（见 2.1），所以**第 6 条
> （`Shift+Home` / `Shift+PageUp`）根本不会有这一行**——它要用别的读数，见表内。
>
> （这一格是 6.1 那条的现场：写下 2.1 那条日志规则的同一天，本文里已经有两条判据
> 在等一个不会出现的读数。**这是扫出来的第二条**，第一条是 C-c1。）

| # | 和弦 | 问什么 |
|---|---|---|
| 1 | `Ctrl+Win+[` / `Ctrl+Win+]` | Windows 有没有截走 |
| 2 | `Ctrl+Shift+Win+↑ ↓ ← →` | 同上（`Win+↑↓←→` 是贴靠，`Ctrl+Win+←→` 是切换虚拟桌面——**加了 Shift 之后还归不归系统，我不知道，这正是要按的原因**） |
| 3 | `Ctrl+Shift+Win+J` | 同上 |
| 4 | `Ctrl+Shift+Esc` | 系统保留（任务管理器），预期**到不了**我们的窗口——**这一条是这份清单的地板**：它必须是「没到」，否则说明这份清单的读法本身不成立 |
| 5 | `Alt+F4` | 预期到达并关窗（它是我们绑的） |
| 6 | `Shift+Home` / `Shift+PageUp` | 确认 7.2 那五行的实际行为是「滚动」而不是「扩展选区」。**读数不是 `[key]` 行**（Shift-only 不记）：先让回滚缓冲里有几屏内容、停在底部，按下去后看**视口有没有跳到顶端**（滚动）还是**出现一段高亮**（扩展选区）。这一条要看画面，而它要分辨的两种结果在画面上差异极大，不属于「截图分不出来」那一类 |

**第 4 条是地板，不要跳过。** 一份全是「预期能到达」的清单，无法把「都到达了」和
「这个读法根本不起作用」分开。

### 7.8 宿主加速键表的交叉检查

`keys.rs::accelerator()` 那四行（`Ctrl+Shift+M/D/Z/=`）与核心默认集**今天不冲突**。

**但 `equalize_splits` 是一枚已经排好队的哑弹**：核心在非 mac 上没有绑定它，
宿主用 `Ctrl+Shift+=` 顶着。**核心哪天补上这个绑定，宿主那一行就会静默变成死代码**
——不报错、没有日志、菜单照常显示，只是某天开始不响应。今晚在
`F11 → toggle_fullscreen` 上刚见过一模一样的死法（3.4）。

**所以 7.2 形态二里给 `equalize_splits` 补键这件事，必须连宿主那一行一起处理**，
否则修好一处会静默弄坏另一处。
