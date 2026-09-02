# Windows 上按键实际去了哪里

真机调试很贵。这份文件的目的是让**大部分需求根本不必碰 GUI**，以及在必须碰的时候，
按键而不是点坐标。

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

**这就是分「宿主处理」和「核心处理」的原因，也是「源」列的由来。** 照表按键的人遇到
「按了没反应」时，第一件事是看日志那行 `-> surface_key=` 是 true 还是 false：

- `surface_key=true` 而界面没动 → 核心接了，问题在核心那半，或者它把键编进 pty 了。
- `surface_key=false` 且没有跟着一行 `host accelerator` → 两边都没人要这个键。

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

**（a）「移动标签」按成了「切换标签」。**
`Ctrl+Shift+←/→` 和 `Ctrl+Tab` 都是 `previous_tab`/`next_tab`。要移动标签是
`Ctrl+Shift+PageUp/PageDown`。宿主表里原来有四行把 `Ctrl+Shift+←/→` 送去 `move_tab`，
已经删了——它们只在核心「因 performable 而拒绝」时才跑，也就是只剩一个标签时，于是
「只有一个标签时按了会移动标签，多个标签时按了会切换标签」。

**（b）同一个和弦被写了两次，后写的赢。**
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

**（c）裸 `Escape` 是一条绑定。**
`Escape` → `end_search`，`performable = true`。没在搜索时核心让路，Escape 照常进 pty
（vim 还能用）。但这意味着 Escape 的行为**取决于搜索栏开没开**——测 vim、测退出全屏
之类的东西时，先确认搜索栏是关的。

**（d）`performable` 的含义。**
`Config.zig` 说得很直白：条件不满足时「Ghostty behaves as if the keybind was not set」。
所以 performable 的键会**掉到宿主加速键表**。上一轮就是这么出的事：`Ctrl+Shift+C` 在没有
选中文本时被核心拒绝，掉到宿主表，宿主把**窗口标题**塞进了剪贴板——人以为自己复制失败了。
凡是往宿主表里加行，先问「核心的哪条 performable 绑定会掉到我这里」。

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
| C-c1 | 搜索栏**关闭** | `[key] ... -> surface_key=true`，**且日志里没有 `end_search`**——核心让路之后把它编码进了 pty |
| C-c2 | 先 `Ctrl+Shift+F` 打开搜索栏 | 搜索栏关闭，日志里**有** `[action] ... end_search` |

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
