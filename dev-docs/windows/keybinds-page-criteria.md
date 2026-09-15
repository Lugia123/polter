# 快捷键页（`PolterKeybinds`）的 UIA 判据

这一页是**只读清单**：`class=PolterKeybinds` 的窗口，一个 `ControlType=List` 的根
（`AutomationId=keybinds-list`），底下每个动作一个 `ListItem`。实现在
`windows/host/src/uia.rs` 的 `KeybindsRoot` / `KeybindsItem`，几何和行数据由
`windows/host/src/settings_ui.rs` 的 `kb_row_rect_at` / `kb_row_count` /
`kb_row` 发布。

⚠️ **这份判据原来只活在群消息里**（`windows-port`，log_seq 2252）。同一个晚上已经
有一份「分隔线判据 1–6」就是这么没的：群一压缩，全仓 grep 不到，只剩另一个任务标题
里半句话证明它存在过。所以它落在这里，和它保护的东西放在一起。下面 C0–C8 与
未覆盖那几条是群里那份的**逐字**内容；再往下两节是交付之后才变成事实的东西，单独
标出来了。

---

## C0–C8（逐字）

前提：起 Polter → 菜单 设置… → 快捷键（`class=PolterKeybinds`）。

**C0 地板：先证明这些判据今天会红。** 在**合并前的构建**上跑 C1，预期红：`ui_snapshot` 报「后代元素数 0」。如果旧 exe 上 C1 就绿了 ⇒ 你测的不是旧 exe，先核 exe 路径和时间戳，别往下走。

**C1 窗口有没有 provider。** `ui_snapshot` 定位 `class=PolterKeybinds`。
· 绿：根元素 ControlType=List，AutomationId=`keybinds-list`。
· 红·A（provider 没挂上）：仍是「后代元素数 0」，且没有 List。日志里应当**没有** `[uia] keybinds WM_GETOBJECT -> root provider`。
· 红·B（有根无子）：List 在、后代 0 ⇒ `kb_row_count()` 是 0，快照没发布，看 C3。
（A 和 B 的区分就靠那一行日志在不在。）

> ⚠️ **绿的那一行 argus 答不了，这一格永久标注为「工具够不到」。** `ui_snapshot` 只
> 枚举**后代**：显式查 `keybinds-list` 返回 0 个，`roles` 里也只有 `listitem`，
> **根元素的 `ControlType` / `AutomationId` 读不到**。要读它得写一个原生 UIA 客户端，
> 而那换来的只是这一格里的一个属性 —— **不做，写清楚它没被覆盖更重要。**
>
> **今天这一格的绿是这样得出的**：`[uia] keybinds WM_GETOBJECT -> root provider`
> 在日志里（判据自己说它**缺席**才是红·A），加上 **94 个后代**（排除红·B「有根无子」）。
> ⇒ **两条红都被排除了，但「根确实是一个 AutomationId 为 `keybinds-list` 的 List」
> 这一句没有被验过。** 出处：WT 在真机上跑的（`e745c55da`）。

**C2 子元素个数。**
· 绿：ListItem 个数 == 页脚显示的总数（今天参考值 93，来源 343 的 `rows()`；**以页脚为准**，行数会随核心绑定表变）。
· 红·A：0 个 ⇒ 见 C1·B。
· 红·B：**只有 18 个** ⇒ 树只报了可见那一屏。这不是可接受版本：设计是全部行都在树里、其中 18 行有矩形。
· 红·C：既不等于页脚也不是 18 ⇒ 快照和绘制读的不是同一份数据，两个数一起报。

**C3 每行三列读得出。** 取任意 5 行 Name。
· 绿：`动作名␠␠键␠␠备注`（两个空格分隔；无备注的行只有前两段）。
· 绿（无键的行）：单独找一个没绑键的动作，Name 中段必须是 `—`（U+2014）。
· 红·A：Name 为空或等于 AutomationId ⇒ `kb_row(i)` 返回 None 走了兜底。
· 红·B：只有动作名、键读不到 ⇒ 读这一页仍要回去看截图，等于这一单没做成。
· 红·C：中段是空白而不是 `—` ⇒ 「无键」和「provider 没答上来」在读数上分不开，按红处理。

**C4 AutomationId。**
· 绿：每行是动作标签（`new_window`、`toggle_secure_input` …），互不相同。
· 红·A：缺失/为空 ⇒ 只能按 Name 定位，而 Name 随界面语言变。
· 红·B：两行相同 ⇒ 数据源有重复行，记下是哪两行。
· 附加：切成中文再读一次 —— **AutomationId 必须一字不变，Name 应当变**。两个都不变 ⇒ 读到的是缓存，重开窗口再来。

**C5 每行有各自的矩形（328 那一族）。** 读前 18 行 BoundingRectangle。
· 绿：18 个矩形两两不等，`top` 单调递增，高度相等且 > 0。
· 红·A：18 行矩形全等 ⇒ 328 原样复发，照坐标点会点在同一行。
· 红·B：这些行明明在屏幕上而矩形全 0 ⇒ `ClientToScreen` 失败，或快照里的 dpi/width 是陈旧的。
· 红·C：矩形非 0 但落在窗口外 ⇒ 客户区坐标当成了屏幕坐标（328c 踩过的）。把窗口挪到副屏再读一次，偏移量若等于窗口原点就是这条。

**C6 屏外行（IsOffscreen）。** 读第 30 行（未滚动时它在屏外）。
· 绿：矩形全 0 **且** IsOffscreen=true。
· 红·A：矩形全 0 而 IsOffscreen=false ⇒ 「滚过去就能看」和「provider 答不上来」又混一起了，正是 328 修掉的歧义。
· 红·B：屏外行报了非 0 矩形 ⇒ 客户端会去点一个不存在的行。

**C7 滚动之后。** 按一次 PageDown，重读第 30 行和第 0 行。
· 绿：第 30 行有矩形、IsOffscreen=false；第 0 行矩形全 0、IsOffscreen=true。
· 红：读数一字不变 ⇒ 滚动没有重新发布快照。**注意**先 `wait_stable` 排除 `ui_snapshot` 给缓存这一种，再报红。

**C8 不该有的东西。**
· 绿：ListItem 上没有 Invoke、没有 SelectionItem（有意为之，只读清单，理由写在 `uia-patterns-declared.py` 认的注释里）。
· 红：若某客户端报告 Invoke 可用 ⇒ 有别的 provider 也在答这个窗口，记下来。

**未覆盖（别读成绿）**
· 新增的 5 条 Rust 几何测试**已编译、未运行**；哪天 Windows 上能跑 `cargo test`，先跑它们。
· UIA **事件**没做也没测（「这台机器收不到 UIA 事件」那条仍成立）：滚动不会发 StructureChanged，客户端要自己重读。
· 键盘可达性没做：元素读得到，但 Tab 走不到它们上面（页面不创建子窗口）。
· ⚠️ **C1 绿的那一行本身未验**：argus 只枚举后代，根元素的 `ControlType=List` /
  `AutomationId=keybinds-list` 读不到（见 C1 下面那段）。**排除了两条红 ≠ 验过那一条绿。**

---

## C0 的地板已经取到了，连同那一步**不能省的正对照**

WT 在 `004c58100`（这一页有元素树之前 2 笔）的旧包上实测，红成这样：

```
scanned:0 matched:0 returned:0
```

没有 List；显式按 `keybinds-list` 查也是 0 个。

⚠️ **同一时刻，对另一个窗口取树得到 12 个元素。** 这一步是这份判据里最容易被省掉
的，而省掉之后整份就废掉：

**「取到 0 个元素」有两种成因，读数一模一样**——被测对象没有 provider（真结果），
或者取树这条通道当时根本没在工作（工具没连上、窗口句柄不对、权限被挡、客户端起在
了另一个会话）。**只有同一时刻在另一个窗口上取到非零，才把第二种排除掉。**没有这
一格，C0 的红就只是「我没读到」，而「我没读到」和「它不存在」在报告里长得一样。

所以跑 C0 时：
1. 先在旧包上对 `class=PolterKeybinds` 取树 —— 期望 0。
2. **紧接着，不重启任何东西**，对另一个窗口（终端主窗口即可）取树 —— 期望非零，
   WT 那次是 12。
3. 两个数都记下来。**只有 (0, 非零) 这一对**才算 C0 通过。`(0, 0)` 是通道坏了，
   重来；`(非零, …)` 说明你测的不是旧包，回去核 exe 路径和时间戳。

出处：WT 在真机上取的，我（W2）没有复核——这台 mac 上跑不了 UIA。

## 判据里的键位以 `Config.zig` 的 `!isDarwin()` 分支为准

⚠️ **不要照 mac 的拼法写 Windows 判据。** 382 那份判据就是这么写错的：核心的默认
绑定在 `src/config/Config.zig` 的 `Keybinds.init` 里按平台分叉，Windows 走的是
`!isDarwin()` 那一支，和 mac 那一支不是同一组键。WT 在真机上核到的实际值：

| 动作 | Windows 上实际是 |
| --- | --- |
| 竖分屏 | `Ctrl+Shift+O` |
| 横分屏 | `Ctrl+Shift+E` |
| 切到下一个分屏 | `Ctrl+Alt+↓` |
| 改分屏大小（向下） | `Win+Ctrl+Shift+↓` |
| 新标签页/确认那一类 | `Ctrl+Shift+Enter` |

写任何一条要按键的判据之前，**先去 `Keybinds.init` 的 `!isDarwin()` 分支上核一遍**，
不要从 mac 的文档或菜单截图上抄。判据写错键位时的表现和功能真的坏了完全一样：按下
去没反应。

出处：WT 在真机上核的；这几个值我没有复核，核法写在上面那一句里——回 `Config.zig`
读那个分支。
