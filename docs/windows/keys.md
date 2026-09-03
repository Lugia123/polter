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
| `宿主` | `windows/host/src/keys.rs` → `accelerator()` |
| `宿主·热键` | `windows/host/src/quick.rs` → `RegisterHotKey` |

本文所有「核心处理」的行，都是把 `Keybinds.init()` 按
`builtin.target.os.tag.isDarwin() == false`、`inputpkg.ctrlOrSuper() == ctrl`
（`src/input/key.zig` 的 `ctrlOrSuper`）解出来的结果。

---

## 一、测试路径：先问「这需求需要 GUI 吗」

### ① 能用 `run_command` 就别碰 GUI

跑命令读输出，比任何 GUI 自动化都快、都可靠，而且不需要审批链（`run_safe_command`
是 L1）。真机上绝大多数问题的证据在**日志文件**里，不在屏幕上。

能用命令答掉的问题，举例：

| 想知道 | 命令 |
|---|---|
| 进程还在不在、有几个 | `tasklist /fi "imagename eq polter.exe"` |
| 残留进程有没有窗口 | PowerShell：`Get-Process polter \| Select Id,MainWindowHandle,MainWindowTitle` |
| 某个 action 有没有触发 | `findstr /c:"[action]" <日志>` |
| 某个键有没有到 `handle_key_message` | `findstr /c:"[key]" <日志>` |
| 加速键有没有真的开火 | `findstr /c:"host accelerator" <日志>` |
| 窗口登记表数到几 | `findstr /c:"window(s) left" <日志>` |

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

**从源码能答的**：宿主代码里能产生「只少 keydown」这个不对称形状的路**只有一条**——
消息泵里的 TSF 分支，因为 `TestKeyDown`/`KeyDown` 和 `TestKeyUp`/`KeyUp` 是分开问的。
其余可能吞键的路（弹出菜单的模态循环、浮层窗口自己的 `WM_KEYDOWN`）都是**对称**的，
会把两个一起吞掉。**而那唯一的一条路是有日志的**：`[key] TSF ate …`。

**从源码不能答的**：那三次里 TSF 到底有没有认领。日志能答，但要注意
`TSF_ATE` 的 40 次上限——**饱和之后「没有这一行」什么都不说明**。

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
| `Ctrl+Insert` | `copy_to_clipboard` | 核·非mac | |
| `Shift+Insert` | **`paste_from_selection`** | 核·非mac | ⚠️ 见 3.3(b) |
| `Ctrl+Shift+A` | `select_all` | 核·非mac | |
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
- **不检查 Alt/Win 有没有一起按下。** `accelerator()` 只看 `VK_CONTROL` 和 `VK_SHIFT`，
  所以 `Ctrl+Shift+Alt+M` 也会触发 `toggle_maximize`。
- **它们没有被真机验过。** 见判据 B——「核心不绑这个和弦」不等于「核心不消费这个键」，
  核心还可能把它编码进 pty（3.4）。

### 3.3 表上有、但行为不是你以为的那个 ⚠️

这一类比缺一行更坑人：按下去有反应，反应是别的事。

**（a）「移动标签」按成了「切换标签」。** ✅ **真机已验**（判据 C-a1–C-a4 四组读数）
`Ctrl+Shift+←/→` 和 `Ctrl+Tab` 都是 `previous_tab`/`next_tab`。要移动标签是
`Ctrl+Shift+PageUp/PageDown`。宿主表里原来有四行把 `Ctrl+Shift+←/→` 送去 `move_tab`，
已经删了——它们只在核心「因 performable 而拒绝」时才跑，也就是只剩一个标签时，于是
「只有一个标签时按了会移动标签，多个标签时按了会切换标签」。

**（b）同一个和弦被写了两次，后写的赢。** ✅ **真机已验**（判据 C-b1；菜单侧独立印证：
「关闭分屏」显示为空、「关闭标签」显示 `Ctrl+Shift+W`，而按下去关的正是标签）
`Binding.zig` 的 `Set.putFlags` 里那句 `gop.value_ptr.* = .{ .leaf = ... }` 是无条件覆盖：

| 和弦 | 先写的 | 后写的（**实际生效**） | 源 |
|---|---|---|---|
| `Ctrl+Shift+W` | `close_surface` | `close_tab:this` | 两条都在 核·非mac |
| `Shift+Insert` | `paste_from_clipboard` | `paste_from_selection` | 两条都在 核·非mac |
| `Shift+Home/End/PageUp/PageDown` | `adjust_selection` | `scroll_to_*` / `scroll_page_*` | 核·共通 → 核·非mac |

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

下面三条是我**最没把握**的三条，不是最好写的三条。三条问的都是「按下去发生了什么」，
不是「这个键有没有被绑定」——后者源码里就能读出来，不值得占一次真机。

### 判据 A —— Ctrl-C 悬案是不是被 argus v1.40 解掉了

**目的**：把「Polter 的 Ctrl-C 坏了」和「上一轮的注入工具没发扫描码」分开。

1. 确认真机 Argus Agent 版本 ≥ v1.40（低于此先升级，否则这条判据无意义）。
2. 起一个 Polter 窗口，在里面跑一个长命令（`ping -t 127.0.0.1`）。
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

**别用「ping 停了没有」单独下结论**：`sent` 里 scan 是 0 而 ping 也停了，说明还有第三条
路径在起作用，那本身是个发现。

### 判据 B —— 宿主表那四行是活的还是死的

**目的**：`accelerator()` 的四行是从「核心不绑这个和弦」推出来的，但核心还可能把这些键
**编码进 pty**（3.4）。真是那样的话，这四行和 F11 那行一样是死代码，而且不会有任何东西报告。

1. 起一个窗口，surface 拿到焦点（先按一个普通字母，确认能打出字）。
2. 依次 `key("ctrl+shift+m")`、`key("ctrl+shift+d")`、`key("ctrl+shift+z")`、
   `key("ctrl+shift+=")`，每次之间 `wait_stable`。
3. `findstr /c:"host accelerator" <日志>` 和 `findstr /c:"[key]" <日志>`。

**判读**：

- 四行 `host accelerator "..." -> binding_action = true` 全出现 → 四行都活着且动作成功。
- 某个和弦只有 `[key] ... -> surface_key=true`、**没有**跟着的 `host accelerator` 行
  → **那一行是死的**，核心把这个键编进 pty 了。把该和弦和 `keycode=` 的值原文报回来。
- 有 `host accelerator` 行但 `binding_action = false` → 行是活的，核心不认这个 action 名。
- **地板**：先按一个谁都不要的和弦（`Ctrl+Shift+Y`），确认它**不**产生 `host accelerator` 行。
  连它都产生了，说明这条日志线索本身不可信，上面三条判读全部作废。

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

**准备**：一个窗口，开**三个**标签（`Ctrl+Shift+T` 两次），三个标签标题必须能区分
（各跑 `title 1` / `title 2` / `title 3`）。只有一个标签时所有 performable 绑定都会拒绝，
那样什么都测不出来。停在标签 1（`Alt+1`）。

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

**准备**：一个窗口，**三个**标签，标题必须能区分（各跑 `title 1` / `title 2` / `title 3`）。
停在标签 1。

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
| `src/input/Binding.zig` `putFlags()` 的覆盖 / 反向表逻辑 | 3.3(b) 的全部推论、判据 C 第一部分 | **不会** |
| `src/input/key.zig` `ctrlOrSuper()` | 3.1 里所有 `Ctrl+…` 的行 | 不会（Windows 上换成 super 就全错） |
| `src/input/keycodes.zig` 的 `native_idx` 或 win 列 | 第四节、判据 A | 不会 |
| `windows/host/src/keys.rs` `accelerator()` | 3.2 | **部分会**——见下 |
| `keys.rs::handle_key_message()` 的四步顺序 | 第二节、判据 A/B 的整个判读逻辑 | 不会 |
| `palette.rs` / `search.rs` / `prompt.rs` / `settings_ui.rs` / `overlay.rs` 的 `WM_KEYDOWN` | 3.5 | 不会 |
| `menu.rs` 的行表 | 3.6、判据 C 第一部分 | 不会 |

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
| `Ctrl+Shift+W` | `close_surface` | `close_tab:this` | **没有了** |
| `Shift+Home` | `adjust_selection:home` | `scroll_to_top` | **没有了** |
| `Shift+End` | `adjust_selection:end` | `scroll_to_bottom` | **没有了** |
| `Shift+PageUp` | `adjust_selection:page_up` | `scroll_page_up` | **没有了** |
| `Shift+PageDown` | `adjust_selection:page_down` | `scroll_page_down` | **没有了** |
| `Shift+Insert` | `paste_from_clipboard` | `paste_from_selection` | 有（`Ctrl+Shift+V`） |

**前五行是五个动作在非 mac 上没有任何键。** mac 上它们都有（`Shift+Home` 等在 mac 分支
里没有被 `scroll_*` 覆盖，因为 mac 的滚动用的是 `Cmd+Home/End/PageUp/PageDown`）。

**用户看得见的后果**：在 Windows/Linux 上按 `Shift+Home` 不会「把选区扩展到行首」，
而是**跳到回滚缓冲的顶端**；`Shift+PageUp` 同理。这和 mac 的行为相反。

#### 形态二：从来没绑过

| 动作 | mac | 非 mac | 备注 |
|---|---|---|---|
| `close_all_windows` | `Cmd+Opt+Shift+W` | 无 | |
| `equalize_splits` | `Cmd+Ctrl+=` | **核心无** | ⚠️ 见 7.5 |
| `clear_screen` | `Cmd+K` | 无 | |
| `undo` / `redo` | `Cmd+Z` / `Cmd+Shift+Z` | 无 | |
| `scroll_to_selection` | `Cmd+J` | 无 | |
| `search_selection` | `Cmd+E` | 无 | |
| `navigate_search:next` / `:previous` | `Cmd+G` / `Cmd+Shift+G` | 无 | |

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

### 7.7 待验清单（交 WT，不混进结论）

**每一条都是「按一次就知道」的事实**，判据统一：按下去，看日志里有没有对应的
`[key] msg=… vk=… keycode=… -> surface_key=…` 行。**没有那一行 = 这个和弦没到达我们的窗口。**

| # | 和弦 | 问什么 |
|---|---|---|
| 1 | `Ctrl+Win+[` / `Ctrl+Win+]` | Windows 有没有截走 |
| 2 | `Ctrl+Shift+Win+↑ ↓ ← →` | 同上（`Win+↑↓←→` 是贴靠，`Ctrl+Win+←→` 是切换虚拟桌面——**加了 Shift 之后还归不归系统，我不知道，这正是要按的原因**） |
| 3 | `Ctrl+Shift+Win+J` | 同上 |
| 4 | `Ctrl+Shift+Esc` | 系统保留（任务管理器），预期**到不了**我们的窗口——**这一条是这份清单的地板**：它必须是「没到」，否则说明这份清单的读法本身不成立 |
| 5 | `Alt+F4` | 预期到达并关窗（它是我们绑的） |
| 6 | `Shift+Home` / `Shift+PageUp` | 确认 7.2 那五行的实际行为是「滚动」而不是「扩展选区」 |

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
