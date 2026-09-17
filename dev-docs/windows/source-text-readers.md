# 把源码当文本读的那些检查，和它们各自会不会为「看不懂」出声

## 这一类是什么

一个工具的**输入是另一个文件的源码文本**。它用模式去认那份源码里的某个东西——
一个标签、一个 `match` 臂、一个日志调用。模式里写死了那个东西**今天长什么样**。

任务 561/562 把 `windows/host/src` 的菜单标签从裸字面量包进了函数调用
（`"关闭标签页"` → `n_("Close Tab")`）。**一个转换动作，让所有假定「标签是一个
裸字符串字面量」的读取器同时失明。** 两个实例先后被撞见：

| 实例 | 症状 | 出声了吗 |
|---|---|---|
| `windows/tools/menu-actions-handled.py` | 88 行扫描 → **0 行**（在今天的工作区上；只改 `menu.rs` 时是 31 行） | **没有。rc 一直是 0** |
| `src/input/command.zig` 的 `menu labels reach the palette` | 标签右键菜单那张表 8 行 → **0 行** | 是——撞上它自己的 `min_rows = 8` 地板 |

两者都已修好，修法在下面。**这份文档存在的理由是第三个实例还没发生。**

## 判定标准：构造，不是历史

「562 有没有弄坏它」是历史；**「我构造一个它认不出的形状，它是红还是静默少扫」**
才是它的性质。下面每一行的「认不出时」那一列，都是构造出来的读数，不是推断：拿
一个这个读取器没见过的包装（`LOCALISE("…")`）塞进它的输入，看它说什么。

这条区分是硬的，因为这次没坏的三张表**是侥幸不是稳固**：`adjacentRows` 找的是
「两个相邻的带引号字符串」，包上 `n_(` 之后两个字符串仍然相邻、间隔仍是标点，所
以过得去；换一种包装写法（把标签拆到常量、或者 `concat`）照样会让它失明。规律
是：**包装函数只对「按精确分隔符切一行」的解析器致命，对「找相邻两个字符串」的不
致命**——这一次。

## 一、以用户可见文字为对象的读取器

这些是这一类里真正危险的：它们的判据本身就是一个标签。

| 读取器 | 读谁 | 工具链 | 认得什么形状 | 认不出时（构造判定） | 561/562 打瞎了吗 |
|---|---|---|---|---|---|
| `windows/tools/menu-actions-handled.py` | `menu.rs` `ctxmenu.rs` `strip.rs` | **`windows/tools` 下的 py，手工跑，CI 不跑** | 现在：整表逐元素解析；标签允许 `"…"`、`n_("…")`、`tr("…")` | **红**，点名文件:行号和读不懂的原文；自检里两个方向都钉死 | **是，而且静默**（88→0，rc 0）。已修 |
| `src/input/command.zig` `menu labels reach the palette` | 同上三个文件 + `po/zh_CN.po` + `synonyms.txt` | **`zig build test`** | `adjacentRows`（相邻两字符串）+ `pairedMatchRows`（两个 match 臂）；臂上现在允许 `"…"`、`n_("…")`、`tr("…")` | **红**：未知包装 → `error.MenuArmUnreadable` 并打出那一行原文；找不到 `fn label`/`fn action` → `error.MenuTableUnparsed` | **是，但出声了**（paired 那张表 8→0，撞 `min_rows`）。已修 |
| `windows/host/src/i18n.rs` `every_msgid_this_host_shows_has_a_translation` | `po/zh_CN.po` + 全部 host `.rs`（`build.rs` 走目录生成的清单） | **`cargo test`（只在 Windows 上编）** | `extract_msgids`：`tr(` / `n_(`，且有一条专门的负例测试挡住 `push_str(`、`concat_n_(` 这类名字尾巴相同的 | 第三种包装会**静默少报**：那些字符串既不被它统计，也确实到不了 gettext | 否——它是要求包装的那一侧，562 让它从 14 条涨到 144 条 |
| `windows/host/src/strip.rs` `the_colour_names_are_the_macos_ones` | `TerminalTabColor.swift` | `cargo test` | Rust 这一侧**读的是值**（`for (name, _) in TAB_COLORS`），Swift 那一侧按 `return "X"` 找 | 红：自带「这个文件已经不是 TerminalTabColor.swift 了」的地板 | **否，而且是结构性的免疫**——见下面「为什么只有它免疫」 |
| `windows/host/src/tabs.rs` `the_close_question_is_the_cores_own_wording` | `close_confirmation_dialog.zig` | `cargo test` | 同上：自己这侧读值，核那侧按 `i18n._("X")` 找 | 红：同样自带路径地板 | 否 |
| `tools/the-mac-strings-still-have-a-chinese-half.py` | `MainMenu.strings` `MainMenu.xib` `Localizable.strings` `command.zig` | `tools` 下的 py | 读 `.strings` 的 `"k" = "v";` 与 xib 的 `title=` | 未构造（不读 Rust） | 否（A/B 扫描输出逐字相同） |
| `tools/the-switch-is-in-the-menu-the-refusal-names.py` | `ctxmenu.rs` `strip.rs` `SurfaceView_AppKit.swift` `mcp.zig` `rpc.zig` | `tools` 下的 py | 找的是**动作名**（`poltergeist_toggle_authorise`）和 `TAB_MENU` 里的枚举成员，不是标签 | 未构造 | 否（A/B 输出逐字相同） |
| `src/build/GhosttyI18n.zig` | `windows/host/src/**.rs`（决定哪些文件交给 `xgettext`） | `zig build`（i18n 步骤） | 文件里含不含字面量 `crate::i18n` | **静默**：写成 `use super::i18n::tr;` 的文件会安静地掉出抽取名单，它的 msgid 从此不进模板，译者永远收不到 | 否——562 让 `menu.rs` 进了名单，方向是反的 |

### 为什么只有那两条 `cargo test` 的地板是免疫的

它们跑在**被测代码自己的 crate 里**，所以自己那一侧读的是 `TAB_COLORS` / `Subject::title()` 的**值**。`n_` 是恒等函数，值不变，包装对它们不存在。

`menu-actions-handled.py` 和 `command.zig` 读的是**文本**，因为它们在那个 crate 外面
（一个是 Python 工具，一个是 Zig 测试）。**这不是谁写得糙，是位置决定的**：从
crate 外面问「这张表有哪些行」，除了读文本没有第二条路。所以这一类的正确目标不是
「让文本解析器不可能出错」，而是**「让它在读不懂的时候必须出声」**。

## 二、其余的读取器：机械普查，而不是逐个推断

不去猜哪些可能受影响，而是把**同一批工具在两棵树上各跑一遍再逐字比对**：

* **A** = 干净 HEAD 的隔离 worktree。
* **B** = 同一个 HEAD 打上今天工作区的全部改动（561 的 `menu.rs`、562 的
  `ctxmenu.rs`/`strip.rs`/…、W3 重新生成的 `po/`、W4 的 `language.rs`）。
* 两边都跑 `tools/*.py` 和 `windows/tools/*.py` 共 **73 个**，各自存下 stdout+rc，
  然后 diff。两边用的是**同一份工具代码**（B 里的 `menu-actions-handled.py` 换回
  了 HEAD 版），否则比的就是我的改动而不是它们的失明。

结果：**43 个逐字相同，30 个有差异。** 30 个里：

| 类别 | 个数 | 例子 |
|---|---|---|
| **失明**（读到的变少而 rc=0） | **1** | `menu-actions-handled.py`：88 行 → 0 行 |
| 读数真的动了（该动） | 6 | `translated-strings-reach-the-user` 14→144 条走 `tr`/`n_`；`translations-still-attach` 模板 371→404；`one-form-per-message` po 变大；`a-gated-line` 80→81；`line-number-references` 95→98；`settings-one-reader` 4→5 处文件读取 |
| 噪声（文件数 42→43、字节数、行号位移、耗时） | 23 | `read 42 file(s)` → `read 43 file(s)`（W4 新增 `language.rs`） |

「没被打瞎」这一栏对那 43+23 个来说不是我看了一眼的印象，是两棵树上跑出来的
逐字相同。

⚠️ 但按上面那条「构造 > 历史」的标准，**这 66 个只是这次没被打瞎**。它们里绝大多
数的对象是标识符、`match` 臂、日志调用，不是标签，所以 561/562 碰不到；换一种改动
它们各自还有各自的脆弱面。这份普查回答的是「这次」，不是「永远」。

## 三、改了某个文件，该跑哪几条判据

这个映射今天只活在各人脑子里，**而且已经漏掉过两次**：两次都是「我改的是 `.rs`，
所以我跑 Rust 那边的判据」，而守着那张表的是一个 Zig 测试和一个 Python 闸。

**一个文件同时是两条工具链的输入；判据集合和改动集合是两个不同的集合，靠语言或目
录去猜前者，猜漏的部分不会有任何东西提醒你。**

改到 `windows/host/src` 的菜单表时，至少要跑这些：

```
menu.rs      → windows/tools/menu-actions-handled.py
               windows/tools/poltergeist-close-and-hold-are-wired.py
               zig build test -Dtest-filter="menu labels reach the palette"
ctxmenu.rs   → windows/tools/menu-actions-handled.py
               tools/the-switch-is-in-the-menu-the-refusal-names.py
               zig build test -Dtest-filter="menu labels reach the palette"
strip.rs     → windows/tools/menu-actions-handled.py
               tools/the-switch-is-in-the-menu-the-refusal-names.py
               windows/tools/a-swallowed-action-says-so.py
               windows/tools/log-record-is-one-write.py
               windows/tools/the-quiet-path-beside-the-loud-one.py
               zig build test -Dtest-filter="menu labels reach the palette"
```

**外加 13 个不点名、扫全部 host `.rs` 的**，它们对任何一个 `.rs` 改动都适用：
`a-gated-line-says-what-its-silence-means`、`a-position-is-not-an-identity`、
`borrow-across-dispatch`、`lock-reentry`、`manifest-parses`、
`paint-requests-are-answered`、`post-op-has-a-target`、`settings-one-reader`、
`stacked-badges-do-not-depend-on-order`、`stdio-verdict-survives-its-own-defect`、
`the-log-has-one-writer`、`uia-answers-what-clients-filter-on`、
`window-tagged-logs`。

再加 `cargo test -p polter-host`（**只在 Windows 上编得过**——`windows-future` /
`windows-threading` 在 darwin 上编不了，所以是 `cargo test --no-run --target
x86_64-pc-windows-gnu` 交叉编出 exe 再上真机跑），因为 `i18n.rs`、`strip.rs`、
`tabs.rs` 里那三道 `include_str!` 地板只在那儿跑。

> 这张表是从工具源码里「显式写出的文件名」机械抽出来的，所以它**会漏**：一个工具
> 如果只用 glob 而不点名，就只出现在上面那 13 个里。CI（`.github/workflows/test.yml`）
> **不跑这些闸中的任何一个**，所以这份清单是手工纪律，不是自动网。

## 四、`-Dtest-filter` 是加法不是过滤

验证「某条 Zig 判据真的跑到了」不能看 rc，要看计数差：

```
zig build test -Dtest-filter="zzz no such test" …   →  87/87 passed, rc 0   ← 负对照
zig build test -Dtest-filter="menu labels reach the palette" … →  88/88 passed, rc 0
```

**87 涨到 88 才证明那条测试被加进来跑了。** 只看 rc=0 的话，两次读数一模一样。
（都带 `-Demit-xcframework=false -Demit-macos-app=false`；不带前者会去起
`xcodebuild`，那一步在这台机器上是红的，和被测的东西无关。）

## 五、两处的修法

### `menu-actions-handled.py`

不再是「找符合某个形状的行」，改成**逐元素清点每一张行表**：把
`const NAME: &[…] = &[…]` 的元素在深度 0 的逗号上切开，每个元素解析成
`Row { … }` / 调用 / 元组 / 名字四种形状之一，标签表达式必须归约成一个字面量——
允许的包装写在 `LABEL_WRAPPERS` 里，**每一项带着它为什么安全的理由**，其余一律报
错。灰行检查从同一次遍历取数，不再有自己的一套正则（原来的失明是双份的：行读不
到，灰也读不到，两处合起来只发出零次警告）。

自检里两个方向都跑：带注释的、包装的和裸的标签都要读对；把包装换成没教过的名字
必须变红且少一行。`fn enabled(self)` 的两种形状之外的第三种也一样。

读数（三棵树，同一份工具）：

| 树 | scanned / handled / greyed-by-state |
|---|---|
| 干净 HEAD | **88 / 46 / 1**（重开关闭的标签） |
| HEAD + 561 的包装 | **88 / 46 / 1**（Reopen Closed Tab）—— 旧版是 31 / 15 / 0 |
| 今天的工作区（561+562+W4） | **88 / 46 / 1**（Reopen Closed Tab）—— 旧版是 **0 / 0 / 0，rc 0** |

顺带把灰行那一行的分母也打出来了：`0 of 3 greyed by a decision have no reason`。
原来只打分子，而「0 条没写理由」在一棵读不到任何东西的树上同样成立——那正是这次
它打印出来的东西。

### `src/input/command.zig`

`armPair` 原来认的是 `" => \""`——箭头和引号焊在一起。现在箭头和值分开读，值可以
是裸字面量或 `label_wrappers` 里的调用；`pairedMatchRows` 把「不是一条臂」和「是
一条臂但读不懂」分开，后者报 `error.MenuArmUnreadable` 并把那一行原样打出来，找
不到 `fn label`/`fn action` 报 `error.MenuTableUnparsed`。

**修解析器而不是压平那张表**，理由是那个文件自己的注释：

> **Taught as a second shape rather than asked to be flattened.** … reshaping
> somebody's data to suit a scanner is the scanner winning an argument it
> should not be in.

它当初就是为了不压平那张表才写了第二个解析器；这次遇到第三种形状，照同一条规矩再
教一次。

三格读数：真过滤器 **88/88 rc 0**；假过滤器负对照 **87/87 rc 0**（计数差证明它跑
到了）；把一条臂换成没教过的包装 **87/88，1 failed，rc 1**，并打出
`this match arm is a row and cannot be read: TabCmd::Close => LOCALISE("Close Tab"),`。
