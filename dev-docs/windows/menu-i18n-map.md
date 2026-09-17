# Windows 菜单的中文字面量，和它们该用的 msgid

## 先说一条格式上的偏离

561 要求每行写成「文件:行号 | 中文原文 | 英文 msgid | 来源」。**这份表没有行号**，
两个理由：

* `windows/tools/line-number-references.py` 扫 `dev-docs/windows/*.md`，判据是「指向
  一行而不是指向一个名字的引用」有没有变多。这张表有 148 行，按 561 的格式写，
  这道闸从超基线 26 变成超基线 120。我实测过两次，数字就是这么来的。
* 行号当场就过期了。写这份表的这两小时里，W2 已经改掉了 `tabs.rs`（5→0）、
  `strip.rs`（23→12）、`settings_ui.rs`（3→2），HEAD 的行号在工作区里已经对不上。

所以键换成「文件 + 所在的表/函数 + 中文原文」。中文原文本身就是唯一键，而且
`grep` 得到——这比行号更好用，不是将就。如果你要行号，说一声，我加回去，但那道闸
会跟着红。

## 这件事做过一次，做完了，又被撤了

`b55204b5f`（09-08，标题 *The menus went into the catalogue*）把 `menu.rs` 的 63
条中文标签换成了英文 msgid + `n_`/`tr`。两小时后 `7361c3438` 把机制撤回字面量，
理由写在那个提交里：Windows 上 `build_config.i18n` 是编译期 `false`，`tr()` 在查
表之前就 `return msgid`，于是主菜单变英文、没转换的右键菜单还是中文，半英半中。

**那个前提今天是假的。** `src/build/Config.zig` 的 `i18n` 现在对 Windows 是
`true`；Windows 不链 libintl，改由 `src/os/i18n.zig` 自己读装好的 `.mo`。真机对照
也在：同机同二进制同时刻，`LANG=en_US.UTF-8` 的实例群聊窗口全英文、不设 `LANG`
的是中文——群聊走的就是这条 gettext 路径。

所以这一轮是**把 `b55204b5f` 重新装回去**，不是从零做一遍。

### 来源规则：b55204b5f + po，不是 MainMenu.strings

**硬要求，理由是时序**：`po/zh_CN.po` 里 b55 那 63 条 msgstr 还在（HEAD 的 po 从
没重新生成过）。msgid 与 b55 **逐字相同**，译文就精确复活；差一个字符（大小写、
`…` 与 `...`）那条就变成未译。构建里的 `msgmerge` 带 `--no-fuzzy-matching`，不会
假复活——漂移不会以「模糊匹配上了」的形式被掩盖，它会直接变成一条没人翻过的英
文。

> 我第一版是按 `macos/Sources/App/zh-Hans.lproj/MainMenu.strings` 的 object id 重
> 新定 msgid 的，那是错的方向，已作废。顺带那条「Windows 菜单中文与
> `MainMenu.strings` 逐字相同」的约定也不成立：`Reopen Closed Tab` 在 mac 是「重
> 新打开关闭的标签页」、Windows 是「重开关闭的标签」；`Float on Top` 在 mac 是
> 「窗口置顶」、Windows 是「置顶」。**这不是错，是有意的**——`7361c3438` 正文写
> 着 menu.rs 退回字面量时用的是「310 定下的措辞」，po 里的 msgstr 正是那一套。

### 核对：63 条 msgid ↔ po 的 msgstr ↔ 今天 menu.rs 的中文

逐条比过，**63/63 完全相同，0 处不一致**。这 63 条不是我「定」的，是解出来的：给
定「msgid 取自 b55」和「中文取自 HEAD」，po 把两者对上，没有留给措辞判断的余地。

另有三条是 b55 之后新增的行，po 里没有——**只有这三条需要你审措辞，也需要 W3 新
翻译**。

---

## 1. `menu.rs` — 66 条标签

W1 已改完。

| 所在表 | 中文原文 | 英文 msgid | 来源 |
|---|---|---|---|
| `FILE_ROWS` | 新建窗口 | `New Window` | `b55204b5f` |
| `FILE_ROWS` | 新建标签页 | `New Tab` | `b55204b5f` |
| `FILE_ROWS` | 重开关闭的标签 | `Reopen Closed Tab` | `b55204b5f` |
| `FILE_ROWS` | 向右分屏 | `Split Right` | `b55204b5f` |
| `FILE_ROWS` | 向左分屏 | `Split Left` | `b55204b5f` |
| `FILE_ROWS` | 向下分屏 | `Split Down` | `b55204b5f` |
| `FILE_ROWS` | 向上分屏 | `Split Up` | `b55204b5f` |
| `FILE_ROWS` | 关闭分屏 | `Close Split` | `b55204b5f` |
| `FILE_ROWS` | 关闭标签页 | `Close Tab` | `b55204b5f` |
| `FILE_ROWS` | 关闭窗口 | `Close Window` | `b55204b5f` |
| `FIND_ROWS` | 查找… | `Find…` | `b55204b5f` |
| `FIND_ROWS` | 下一个 | `Next` | `b55204b5f` |
| `FIND_ROWS` | 上一个 | `Previous` | `b55204b5f` |
| `FIND_ROWS` | 隐藏查找条 | `Hide the Find Bar` | `b55204b5f` |
| `EDIT_ROWS` | 复制 | `Copy` | `b55204b5f` |
| `EDIT_ROWS` | 粘贴 | `Paste` | `b55204b5f` |
| `EDIT_ROWS` | 全选 | `Select All` | `b55204b5f` |
| `EDIT_ROWS` | 查找 | `Find` | `b55204b5f` |
| `VIEW_ROWS` | 重置字号 | `Reset Font Size` | `b55204b5f` |
| `VIEW_ROWS` | 放大 | `Zoom In` | `b55204b5f` |
| `VIEW_ROWS` | 缩小 | `Zoom Out` | `b55204b5f` |
| `VIEW_ROWS` | 命令面板 | `Command Palette` | `b55204b5f` |
| `VIEW_ROWS` | 改标签标题… | `Rename Tab…` | `b55204b5f` |
| `VIEW_ROWS` | 改终端标题… | `Rename Terminal…` | `b55204b5f` |
| `VIEW_ROWS` | 只读 | `Read-only` | `b55204b5f` |
| `VIEW_ROWS` | 快速终端 | `Quick Terminal` | `b55204b5f` |
| `VIEW_ROWS` | 终端检查器 | `Terminal Inspector` | `b55204b5f` |
| `AGENTS_ROWS` | 终端群聊 | `Terminal Conversations` | `b55204b5f` |
| `AGENTS_ROWS` | 将此终端设为总管 | `Make This Terminal a Supervisor` | `b55204b5f` |
| `AGENTS_ROWS` | 监督此终端 | `Toggle Supervision of This Terminal` | `b55204b5f` |
| `AGENTS_ROWS` | 不让 agent 碰此终端 | `Keep Agents Out of This Terminal` | `b55204b5f` |
| `AGENTS_ROWS` | 允许总管替此终端点授权框（含「不再询问」） | `Let a Supervisor Answer Prompts Here` | **新定** |
| `AGENTS_ROWS` | 保持这个终端在岗 | `Hold This Terminal to Its Work` | `b55204b5f` |
| `AGENTS_ROWS` | 插件… | `Plugins…` | `b55204b5f` |
| `AGENTS_ROWS` | 语言… | `Language…` | `b55204b5f` |
| `GOTO_SPLIT_ROWS` | 上 | `Up` | `b55204b5f` |
| `GOTO_SPLIT_ROWS` | 下 | `Down` | `b55204b5f` |
| `GOTO_SPLIT_ROWS` | 左 | `Left` | `b55204b5f` |
| `GOTO_SPLIT_ROWS` | 右 | `Right` | `b55204b5f` |
| `RESIZE_SPLIT_ROWS` | 均分分屏大小 | `Equalize Splits` | `b55204b5f` |
| `RESIZE_SPLIT_ROWS` | 向上 | `Grow Up` | `b55204b5f` |
| `RESIZE_SPLIT_ROWS` | 向下 | `Grow Down` | `b55204b5f` |
| `RESIZE_SPLIT_ROWS` | 向左 | `Grow Left` | `b55204b5f` |
| `RESIZE_SPLIT_ROWS` | 向右 | `Grow Right` | `b55204b5f` |
| `WINDOW_ROWS` | 最小化 | `Minimize` | `b55204b5f` |
| `WINDOW_ROWS` | 最大化 | `Maximize` | `b55204b5f` |
| `WINDOW_ROWS` | 全屏 | `Full Screen` | `b55204b5f` |
| `WINDOW_ROWS` | 分屏缩放 | `Split Zoom` | `b55204b5f` |
| `WINDOW_ROWS` | 上一个分屏 | `Previous Split` | `b55204b5f` |
| `WINDOW_ROWS` | 下一个分屏 | `Next Split` | `b55204b5f` |
| `WINDOW_ROWS` | 选择分屏 | `Select Split` | `b55204b5f` |
| `WINDOW_ROWS` | 调整分屏 | `Resize Split` | `b55204b5f` |
| `WINDOW_ROWS` | 重置窗口大小 | `Reset Window Size` | `b55204b5f` |
| `WINDOW_ROWS` | 置顶 | `Float on Top` | `b55204b5f` |
| `HELP_ROWS` | Polter 帮助 | `Polter Help` | `b55204b5f` |
| `HELP_ROWS` | 检查更新… | `Check for Updates…` | `b55204b5f` |
| `HELP_ROWS` | 重新加载配置 | `Reload Configuration` | `b55204b5f` |
| `ROOT` | 文件 | `File` | `b55204b5f` |
| `ROOT` | 编辑 | `Edit` | `b55204b5f` |
| `ROOT` | 查看 | `View` | `b55204b5f` |
| `ROOT` | 智能体 | `Agents` | **新定** |
| `ROOT` | 窗口 | `Window` | `b55204b5f` |
| `ROOT` | 帮助 | `Help` | `b55204b5f` |
| `ROOT` | 设置… | `Settings…` | `b55204b5f` |
| `ROOT` | 快捷键… | `Keyboard Shortcuts…` | **新定** |
| `ROOT` | 关于 Polter | `About Polter` | `b55204b5f` |
### 那三条新定的

| msgid | 出处 | 为什么这么定 |
|---|---|---|
| `Let a Supervisor Answer Prompts Here` | **不是我编的**：`macos/Sources/App/Base.lproj/Localizable.strings` 里这个键、以及 `MainMenu.xib` 的 `pgA-Au-Th1` 都已经是这一句 | Windows 的中文标签多了「（含「不再询问」）」那半句，mac 的英文没有。msgid 取 mac 已有的那句；括号里那半句是中文这一侧的事，由 W3 写进 msgstr。`SurfaceView_AppKit.swift` 里 `poltergeistToggleAuthorise` 那一行的注释原话就是「右键菜单：允许总管替此终端点授权框，含「不再询问」」——两边说的是同一行 |
| `Agents` | `0f7d4cc7d` 之前这一行的字面量**就是** `Agents`；mac 的 `pg0-Mn-Ma1` 也是 `Agents` | 那个提交把它改成中文「智能体」，等于把唯一一个还没本地化的词硬编成了另一种语言。现在它回到 msgid 的位置，中文由 catalogue 给 |
| `Keyboard Shortcuts…` | `d6e20fabc` 新增的行；mac 的 `Kb1-Nd-Ls1` 是 `Keyboard Shortcuts…` | 省略号用 U+2026，和 b55 那 63 条一致——b55 里没有一条用三个 ASCII 点（实测 `grep -c '\.\.\.'` = 0） |

⚠️ 其余 63 条**请不要审措辞**。改一个字符，就是把一条现成的译文变成未译。

### menu.rs 里另外 6 处

测试断言里写死了同一批标签，跟着改，不是新的 msgid：
`the_greyed_rows_are_the_three_that_are_not_built` 的 `want`（`Language…` /
`Check for Updates…` / `Polter Help`）、`the_two_title_rows_are_not_the_same_action`
的两条（`Rename Tab…` / `Rename Terminal…`）、
`one_row_is_greyed_by_state_and_it_is_the_reopen_one` 的 `Reopen Closed Tab`。

72 = 66 标签 + 这 6 条。

---

## 2. 后面 10 个文件 —— 给 W2

HEAD 上共 **82 条**中文字符串字面量。按「在不在 `#[cfg(test)]` 里 / 在不在
`write_fixture` 里 / 是不是日志」机械分诊：

| 性质 | 条数 | 怎么判的 |
|---|---|---|
| **可见**，要走 `tr`/`n_` | **60** | 其余三类之外的 |
| 测试 | 18 | 词法上落在 `#[cfg(test)]` 的大括号里 |
| 夹具 | 2 | 落在 `write_fixture` 里（`plugins.rs` 和 `project.rs` 各一条） |
| 日志 | 2 | `reload.rs` 的两条 `[reload] … will do nothing` |

60 这个数和你说的「W2 那 60 条」对上了。

### 要往两个方向查 po，只查一个方向会漏

* **中文 → msgid**（拿中文原文比 `msgstr`）。下表最后一列就是这么查的，**26 条命
  中**。
* **英文候选 → msgid**（想好一个英文措辞去比 `msgid`）。这一步是必须的，因为 po
  的译文和 Windows 的标签**可能只差一个字**，中文方向就查不到：
  * `Close Other Tabs` 在 po 里有，msgstr 是「关闭其他标签**页**」，而 `strip.rs`
    写的是「关闭其他标签」——中文方向查不到，英文方向查得到。
  * `Close Tabs to the Right` 同理（po 是「关闭右侧标签**页**」）。
  * `Rename Tab…` 在 po 里有，msgstr 是「改标签标题…」，而 `strip.rs` 写的是「重
    命名标签…」。**这两个是不是同一行，得你判断**：如果是，用现成的 msgid，
    Windows 上那一行的中文就跟着变成「改标签标题…」。
  * `Change Window Title` 在 po 里有但 **msgstr 是空的**。有 msgid 不等于有译文。

两条查法写在第 5 节。

### 一条歧义留给 W2 —— 已定：`Reset Terminal`

`ctxmenu.rs` 的「重置终端」在 po 里**有两个** msgid 指向它：`Reset` 和
`Reset Terminal`。挑哪个决定英文那一侧显示什么。

**断它的不是措辞，是 po 里的 `#:` 来源行**：

- `Reset` 来自 `src/apprt/gtk/ui/1.2/surface.blp` 和 `.../1.5/window.blp`
  —— GTK 界面上的一个按钮。
- `Reset Terminal` 来自 `windows/host/src/settings_ui.rs` 和
  `src/input/command.zig` —— 是这个**动作**的名字。

右键菜单那一行是一个动作，取 **`Reset Terminal`**。
两条的 msgstr 都是「重置终端」，所以中文一个字不变。

**同一把尺断掉的第二处**：`监督此终端` 在 mac 的
`TerminalWindow.swift`（`configureTabContextMenuIfNeeded`）里叫
`Supervise This Terminal`，而 po 里是 `Toggle Supervision of This Terminal`
（来源 `windows/host/src/menu.rs` + `src/input/command.zig`）。
⚠️ **取 po 的那一条**，Swift 那个拼法**根本不在 po 里**。
写在这里是因为：看到 mac 源码的人会想去「对齐」，而对齐的结果是一条没有
译文的 msgid。


### `strip.rs` — 23 条

| 性质 | 中文原文 | po 里现成的 msgid |
|---|---|---|
| **可见** | 无颜色 | — |
| **可见** | 蓝 | — |
| **可见** | 紫 | — |
| **可见** | 粉 | — |
| **可见** | 红 | — |
| **可见** | 橙 | — |
| **可见** | 黄 | — |
| **可见** | 绿 | — |
| **可见** | 青 | — |
| **可见** | 石墨 | — |
| **可见** | 关闭标签页 | `Close Tab` |
| **可见** | 关闭其他标签 | — |
| **可见** | 关闭右侧的标签 | — |
| **可见** | 移到新窗口 | — |
| **可见** | 重命名标签… | — |
| **可见** | 将此终端设为总管 | `Make This Terminal a Supervisor` |
| **可见** | 监督此终端 | `Toggle Supervision of This Terminal` |
| **可见** | 不让 agent 碰此终端 | `Keep Agents Out of This Terminal` |
| **可见** | 标签颜色 | — |
| **可见** | 新建标签页 | `New Tab` |
| **可见** | 重开关闭的标签 | `Reopen Closed Tab` |
| **可见** | 命令面板 | `Command Palette` |
| 测试 | the colours follow 重命名标签… | — |

### `ctxmenu.rs` — 22 条

| 性质 | 中文原文 | po 里现成的 msgid |
|---|---|---|
| **可见** | 复制 | `Copy` |
| **可见** | 粘贴 | `Paste` |
| **可见** | 全选 | `Select All` |
| **可见** | 查找… | `Find…` |
| **可见** | 新建标签页 | `New Tab` |
| **可见** | 关闭标签页 | `Close Tab` |
| **可见** | 向右分屏 | `Split Right` |
| **可见** | 向左分屏 | `Split Left` |
| **可见** | 向下分屏 | `Split Down` |
| **可见** | 向上分屏 | `Split Up` |
| **可见** | 重置终端 | `Reset` / `Reset Terminal` |
| **可见** | 终端检查器 | `Terminal Inspector` |
| **可见** | 只读 | `Read-only` |
| **可见** | 改标签标题… | `Rename Tab…` |
| **可见** | 改终端标题… | `Rename Terminal…` |
| **可见** | 将此终端设为总管 | `Make This Terminal a Supervisor` |
| **可见** | 监督此终端 | `Toggle Supervision of This Terminal` |
| **可见** | 不让 agent 碰此终端 | `Keep Agents Out of This Terminal` |
| **可见** | 允许总管替此终端点授权框（含「不再询问」） | — |
| **可见** | 命令面板 | `Command Palette` |
| 测试 | 复制\tCtrl+Shift+C | — |
| 测试 | 复制\tAlt+Y | — |

### `plugins.rs` — 11 条

| 性质 | 中文原文 | po 里现成的 msgid |
|---|---|---|
| 夹具 | a \"quoted\" value, a backslash \\, and 中文 | — |
| 测试 | {"name":"简体"} | — |
| 测试 | 简体 | — |
| 测试 | {"name":"从 zh 来","description":"只有 zh 有这句"} | — |
| 测试 | {"name":"从 zh-Hans 来"} | — |
| 测试 | 从 zh-Hans 来 | — |
| 测试 | {"name":"从 zh 来"} | — |
| 测试 | 存到哪 | — |
| 测试 | 存档 | — |
| 测试 | 存档 | — |
| 测试 | 存到哪 | — |

### `keybinds.rs` — 7 条

| 性质 | 中文原文 | po 里现成的 msgid |
|---|---|---|
| **可见** | 这几条是你对 agent 的开关，键由产品定，暂不支持自行更改。 | — |
| **可见** | Windows 上不自动开启，需手动打开 | — |
| **可见** | 菜单里不显示这个快捷键（键仍然有效） | — |
| **可见** | 尚无快捷键 | — |
| 测试 | 手动 | — |
| 测试 | 菜单 | — |
| 测试 | 尚无 | — |

### `tabs.rs` — 5 条

| 性质 | 中文原文 | po 里现成的 msgid |
|---|---|---|
| **可见** | {}里还有正在运行的程序。关掉它会一并结束那些程序。\n\n要关闭吗？ | — |
| **可见** | 确认关闭 | — |
| **可见** | 这个标签页 | — |
| **可见** | 这个窗口 | — |
| **可见** | 这一格 | — |

### `prompt.rs` — 4 条

| 性质 | 中文原文 | po 里现成的 msgid |
|---|---|---|
| **可见** | 改终端标题 | — |
| **可见** | 改标签标题 | — |
| **可见** | 改窗口标题 | — |
| **可见** | 另存为项目 | — |

### `settings_ui.rs` — 3 条

| 性质 | 中文原文 | po 里现成的 msgid |
|---|---|---|
| **可见** | 快捷键 | — |
| **可见** | 这里列的是「动作」，共 {} 个；有的动作还没有分配快捷键。 | — |
| **可见** | {}–{} / {}    ↑↓ PgUp PgDn 滚动    Esc 关闭 | — |

### `project.rs` — 3 条

| 性质 | 中文原文 | po 里现成的 msgid |
|---|---|---|
| 夹具 | a \"quoted\" title, a backslash \\, and 中文 | — |
| 测试 | 写 retry 装饰器 | — |
| 测试 | 写 retry 装饰器 | — |

### `main.rs` — 2 条

| 性质 | 中文原文 | po 里现成的 msgid |
|---|---|---|
| **可见** | 要粘贴的内容有 {} 行，其中可能含有会立即执行的字符。\n\n{}\n\n确定要粘贴吗？ | — |
| **可见** | 确认粘贴 | — |

### `reload.rs` — 2 条

| 性质 | 中文原文 | po 里现成的 msgid |
|---|---|---|
| 日志 | [reload] RegisterClassW failed; «重载配置» will do nothing | — |
| 日志 | [reload] CreateWindowExW failed: {e:?}; «重载配置» will do nothing | — |
> **W2 已经自行做掉的三处以 W2 的为准**：`tabs.rs` 关闭确认句、`settings_ui.rs`
> 页脚、`strip.rs` 十个颜色名。十个颜色名的出处是
> `macos/Sources/Features/Terminal/TerminalTabColor.swift` 的 `localizedName`，
> 既不是 `MainMenu.strings` 也不在 po 里（`strip.rs` 里 `TAB_COLORS` 上方的注释
> 自己点了名）。
>
> `keybinds.rs` 的「手动 / 菜单 / 尚无」看起来像三个短标签，其实是
> `each_state_says_a_different_thing` 里的 `assert!(...contains(...))`，跟着上面
> 四条 `note` 的措辞改，不单独定 msgid。这一条我第一版判错过。

### 那两条日志，顺手改字面量（不是加 `tr`）

`tr()` 的输出跟着用户的 `LANG` 走。日志是给排查的人读的，中文机器和英文机器抓出
来的日志 grep 不到同一行。所以 `reload.rs` 那两条不包 `tr()`——**但它们句子里的
`«重载配置»` 引用的是一个菜单行的名字，而那一行现在叫 `Reload Configuration`
了**。把字面量改过去，让日志和菜单说同一个词。

### 那两条夹具，一个字都别动

`plugins.rs` 和 `project.rs` 的 `write_fixture` 写出来的文件是 Zig 那边的测试要
读的。改掉里面的中文，跨实现的那个测试就在检查一份没人发的文件。

---

## 3. 验收

| 格 | 命令 | 结果 |
|---|---|---|
| release 构建 | `CARGO_TARGET_DIR=/tmp/ct-w1 cargo build --release --target x86_64-pc-windows-gnu -p polter-host` | exit 0 |
| i18n 闸 | `python3 windows/tools/translated-strings-reach-the-user.py` | **exit 0**。自带自检先打 `probe self-test: OK (off, on, else-true and unreadable are told apart)`，再打 `build_config.i18n for a Windows target: on` |
| 抽取 | `xgettext --language=C --keyword=tr --keyword=n_` 单跑 `menu.rs` | **66 条 msgid 全部抽出**，含带转义引号的那条 |
| 单元测试（`menu::`） | Windows 真机，`--test-threads=1 menu::` | **35 passed / 0 failed** |
| 单元测试（全量） | 同上不带过滤 | 261 passed / **9 failed**，见下 |
| 判据会红 | 把 `Reopen Closed Tab` 拼成 `Reopen Closd Tab` 重编，跑 `menu::` | **34 passed / 1 failed**，红在 `menu::tests::one_row_is_greyed_by_state_and_it_is_the_reopen_one`，原文 `left: ["Reopen Closd Tab"] / right: ["Reopen Closed Tab"]` |

`cargo test -p polter-host` **在 mac 上跑不了**：那是 host-target 构建，
`windows-future` / `windows-threading` 在 darwin 上编不过。所以测试是
`cargo test --no-run --target x86_64-pc-windows-gnu` 交叉编出 exe，传到 Windows
真机（argus agent `windows-3ca43aeed1cc`）上跑的。

构建和测试都在 `git worktree add --detach` 出来的隔离树里做——共用树里同时有 W2、
W4 没写完的文件，我第一次在共用树里构建，红在 `strip.rs` 的一个 `tr` 未导入上，
那不是我的。

### 全量那 9 条红的，不是我造成的

先量地板：**HEAD 上不动任何东西，同样的跑法是 13 条红。** 我的改动之后是 9 条—
—少的 4 条都在 `menu.rs` 里，是 HEAD 上就红着的陈旧计数，顺手改对了（见下节）。
剩下 9 条一条不多一条不少，全在别人的文件里：

```
pairing_wording_tests::the_reason_names_the_side_that_failed_and_says_it_failed
tabs::deadlock_detector_tests::d0 / d1 / d2 / d3
test_log::the_redirect_is_in_force_for_the_body_and_gone_afterwards
winid::invariant_floor::it_speaks_when_tabs_has_one_and_winid_has_none
winid::invariant_floor::it_speaks_when_winid_has_one_and_tabs_has_none
winid::invariant_floor::the_harness_captures_a_line_it_is_given
```

其中 `test_log::…` 单独跑是**绿的**（`--test-threads=1 test_log::` → 2 passed），
所以它是「整包一起跑时日志重定向只能初始化一次」的次序问题；另外 8 条单独跑仍然
红，是真的，且与 561 无关。

### menu.rs 里 HEAD 就红的 4 条，我改了

都在我这个文件里，其中两条不改交不了（我加了一行，计数必然变）：

* `HOST_ACTIONS` 少了 `"__polter_keybinds"`。`run_host` 一直有那条 arm，只有这个
  清单没有——`all_host_rows_are_handled` 和 `assert_actions_exist` 就是为这个形
  状建的，两条都在 HEAD 上红着。
* `the_root_has_six_groups_and_two_tail_items`：名字和断言都写 2，`ROOT` 里是 3
  （`快捷键…` 和 `关于 Polter` 加进来时没改这个数）。561 再加一行语言，变 4。改
  名成 `..._four_tail_items`，并补一条 `tail[1].action == "__polter_language"` 钉
  住新位置。
* `the_three_readiness_buckets_are_what_we_think`：`54/45/5/4` → `57/48/5/4`。561
  只挪行不增删行，所以只订正陈旧的那一半。

这些在 macOS 上看不出来：这个 crate 的测试只为 Windows target 编译。

---

## 4. 数是怎么数的

扫描器逐字符走 Rust 源码，认行注释、块注释（含嵌套）、普通字符串（含 `\` 转义）
和 raw string，**只收字符串字面量里的汉字**（`[一-鿿]`）。注释里的汉字不
算——`menu.rs` 的文档注释里就有好几处 `«重开关闭的标签»`。

HEAD 逐文件计数：

```
menu.rs 72(66 标签 + 6 测试断言)  strip.rs 23  ctxmenu.rs 22  plugins.rs 11
keybinds.rs 7  tabs.rs 5  prompt.rs 4  settings_ui.rs 3  project.rs 3
main.rs 2  reload.rs 2
```

后 10 个文件合计 **82**，和 W2 的读数闭合，逐文件也一条不差。总数 72+82 = 154。

和 561 最初给的数字有两处差 1，都不是漏：`plugins.rs` 11 vs 12（有一条 raw string
里并排两句中文）；`main.rs` 2 vs 3（第三条是 `"\n…"`，粘贴预览的截断标记，只有一
个省略号，没有汉字——也不该翻）。

---

## 5. 查 po 的两条命令

中文 → msgid：

```sh
python3 - '关闭其他标签' <<'EOF'
import re,sys
po=open('po/zh_CN.po',encoding='utf-8').read()
u=lambda x:''.join(re.findall(r'"((?:[^"\\]|\\.)*)"',x))
for m in re.finditer(r'(?m)^msgid ((?:"(?:[^"\\]|\\.)*"\s*)+)^msgstr ((?:"(?:[^"\\]|\\.)*"\s*)+)',po):
    if u(m.group(2))==sys.argv[1]: print(repr(u(m.group(1))))
EOF
```

英文候选 → msgstr（子串匹配，方便试措辞）：

```sh
python3 - 'Close Other' <<'EOF'
import re,sys
po=open('po/zh_CN.po',encoding='utf-8').read()
u=lambda x:''.join(re.findall(r'"((?:[^"\\]|\\.)*)"',x))
for m in re.finditer(r'(?m)^msgid ((?:"(?:[^"\\]|\\.)*"\s*)+)^msgstr ((?:"(?:[^"\\]|\\.)*"\s*)+)',po):
    k=u(m.group(1))
    if sys.argv[1] in k: print(f'{k!r:40} {u(m.group(2))!r}')
EOF
```

### ⚠️ 别用 `grep -F 'msgid "..."'` —— 长条目是折行的

上面两条命令都带续行解析，**这不是讲究，是必须**。`xgettext` 会把长条目
折成多个引号行，于是它在文件里**根本不作为一个可搜索的字符串存在**。例如
粘贴确认框那句正文，在 `po/zh_CN.po` 里长这样：

```
msgid ""
"Pasting this text into the terminal may be dangerous as it looks like some "
"commands may be executed."
msgstr "将以下内容粘贴至终端内将可能执行有害命令。"
```

`grep -F 'msgid "Pasting this text into the terminal may be dangerous...'`
一条都匹配不到，于是这句**已经翻译好的**话看起来像「po 里没有、要新定」。
W2 第一次查 main.rs 就是这么漏的。

**越长、越值得复用的句子，越容易被这种查法漏掉**——因为越长越会被折行。

---

## 5b. 三条落地时才发现的规矩（W2）

### 省略号分菜单行和框标题，核心自己就在这么做

`src/apprt/gtk/class/title_dialog.zig` 给同一个框起标题用的是
`Change Terminal Title` / `Change Tab Title` / `Change Window Title`，
**都不带省略号**；而菜单行那一侧是 `Change Terminal Title…`（U+2026）。
省略号的意思是「点了会再开一个东西」，所以它属于菜单行，不属于那个被打开
的框。

`prompt.rs` 的三条按这个规矩取了不带省略号的那组。`另存为项目` 同理定成
`Save as Project`——mac 的 `Save as Project...` 是**菜单行**，不是这个框。

⚠️ 由此产生两组「看起来像重复、其实必须并存」的 msgid，**不许合并**：

| 并存的两条 | 各自是谁 |
|---|---|
| `Rename Tab...`（ASCII 句点） | `strip.rs` 标签条自己的行，就地改名（`rename_tab`） |
| `Rename Tab…`（U+2026） | `ctxmenu.rs` / `menu.rs` 的行，开浮层（`prompt_tab_title`） |
| `Keyboard Shortcuts` | 设置页的页标题，以及 `uia.rs` 的无障碍名 |
| `Keyboard Shortcuts…`（U+2026） | 菜单行，省略号表示会开窗口 |

这两组的分辨全靠一个**肉眼看不见**的字符。想统一它们的人会在 po 里同时
看到两条——所以理由写在 po 的 `#.` 译者注里，不要只写在这里。
（`Rename Tab` 那一组是产品层面的缺陷：两个不同操作的标签几乎一样。已另开
issue，不在 i18n 这一轮解决。）

### 返回 msgid、由画它的那一处调 `tr`，签名不用改

`keybinds.rs` 的 `note()` 和 `prompt.rs` 的 `scope_of()` 都返回
`&'static str`，而 `tr` 返回 `String`。看起来必须改签名，**其实不用**：让
它们返回 `n_(...)` 的 msgid，只在真正画出来的那一处调 `tr`。

三个好处：调用点一个都不用动；`prompt.rs` 里那 8 条日志继续打英文 msgid，
而日志本来就该是**不随读者语言变化**的可搜索标识；同理
`strip.rs`/`ctxmenu.rs` 把 label 打进日志的那两行也自动变成稳定英文。

### ⚠️ `settings_ui.rs` 里有个局部变量叫 `tr`

画 `note()` 的那一段里，装矩形的局部变量正好叫 `tr`（一个 `RECT`），
把 `tr` 函数遮住了。那里必须写全路径 `crate::i18n::tr(note)`。
遮蔽不会报错，只会让人以为「这里 `tr` 用不了」。

---

## 6. 「语言…」挪了位置

561 第三条：`语言…` 从 `AGENTS_ROWS` 末尾挪到 `ROOT` 里 `设置…`（`open_config`）
的下一行。`enabled: Enable::No` 和 `ready: Ready::HostGap` 原样不动——背后的语言
选择器是 W4 在做，接通那一步由 W4 自己改。

`the_root_has_six_groups_and_four_tail_items` 里新加的
`assert_eq!(tail[1].action, Some("__polter_language"))` 是钉这个位置的那一行：它
挪回去，这条会红。

写这份表时工作区里有一份没提交的改动，正在把 mac 的 `pg7-La-Ng1` 从智能体菜单挪
到「设置…」下面——同一个方向。我没有把「mac 现在把它放在哪」写进 `menu.rs` 的注
释：那是另一棵树的事，抄过来就是一句会过期而不会变红的话。

---

## 7. 一个副作用：i18n 构建步骤会多 12 条警告

`src/build/GhosttyI18n.zig` 只扫**含 `crate::i18n` 字样**的 host 文件。`menu.rs`
现在含了，于是进了扫描列表——而 `xgettext` 以 `--language=C` 读它，Rust 的
`&'static str` 在 C 词法里是一个没闭合的字符常量。

实测（`xgettext --language=C --from-code=UTF-8 --keyword=tr --keyword=n_`）：
`menu.rs` → 66 条 msgid 全抽出，同时 **12 条「未结束的字符常量」警告**，行号全落
在带 `'static` 的行上。对照：已经在扫描列表里的 `settings_ui.rs` → **0 条警告**。

那份构建文件的注释里写着，当初把整个 host 目录交给 C 词法读产生了 59 条警告，
「是一条没人会去读的步骤，真警告就是这样被漏掉的」，过滤才加上的。现在这个过滤按
设计放行了 `menu.rs`，12 条跟着回来了；W2 那 10 个文件接上之后还会更多。

**不该在 `menu.rs` 里治**——治它要么为迁就一个词法器改 `&'static str` 的写法，要
么在构建文件那一侧处理。记在这里，因为起因在这一步而现象在别人的文件里。
