# Windows 可访问性（UI Automation）

macOS 有 AppKit 的可访问性，Linux 有 ATK，**Windows 版一样都没有**。这不是少了一个
锦上添花的功能：它意味着**屏幕阅读器读不了这个终端**。这一篇记这块补上了什么、
没补上什么、以及怎么从外部证明它成立。

实现在 `windows/host/src/uia.rs`，入口是 `main.rs` 的 `wndproc` 里那条
`WM_GETOBJECT` 分支。

---

## ⚠️ 先读这一条：判据只能证到自动化那一层

**「UIA 客户端拿得到」不等于「屏幕阅读器会念」。**

下面那份判据走的是操作系统自己的 UI Automation 客户端 API，它能证明这棵树存在、
结构对、内容对、跨窗口不串。它**不能**证明 Narrator 或 NVDA 真的会把终端里的字念
出来——屏幕阅读器有自己的一套启发式（要哪些 pattern、认哪些 control type、什么时候
决定重念一遍），那一层这份判据一个字都没碰。

这块的价值主张是可访问性，判据只到自动化。**这中间的差距要让人知道，不能替他乐观。**
要证明后一半，只有一条路：真人开着 Narrator 听一遍。那件事还没做。

---

## 一、这棵树长什么样

```
Window          "Polter - cmd.exe"        ← 帧窗口，UIA fragment root
├── Tab         "Tabs"                    ← 标签条（strip.rs 自绘，没有自己的 HWND）
│   ├── TabItem "cmd.exe"                 ← 一个标签，有名字、有屏幕矩形
│   └── TabItem "vim"
├── Document    "Terminal: cmd.exe"       ← 一个标签的终端内容（ValuePattern）
└── Document    "Terminal: vim"
```

三层，和任务给的范围一致。几个不明显的选择：

**Document 是每个标签一个，不是「当前那个」一个。** 换标签时树的结构不变，只有
`HasKeyboardFocus` 变。反过来做（只暴露活动标签）会让每次切标签都改变树的形状，
而**我们不发结构变更事件**（见第四节），客户端手里那份就成了旧的。

**标签条是虚拟元素，没有 HWND。** `strip.rs` 是自绘的，标签在 Windows 眼里根本不
存在——这正是 UIA fragment 存在的理由，也是为什么这块只能靠 provider 而不能靠
「给标签建子窗口」蒙混过去。

**pane 的子窗口没有自己的 provider。** 每个 pane 是一个 `PolterSurface` 子窗口，
它们会以无名 `Pane` 元素出现在树里。这是噪声，不是重复——终端文字只从上面那个
`Document` 出来一次。

---

## 二、两条规矩，各自对应一个会写出来的 bug

这两条写在 `uia.rs` 顶部的 `//!` 里，这里只记结论和后果。

### 1. 持着 `tabs` 锁的时候绝不调 libghostty

`tabs::window()` 底下是不可重入的 `std::sync::Mutex`；读屏幕走
`ghostty_surface_read_text`，而它在 `src/apprt/embedded.zig` 里会拿**核心自己的**
`renderer_state.mutex`。两把锁，唯一挡住死锁的是它们永远同一个方向。

做法：**先取快照、丢掉 guard、再调 FFI。** `tabs::tab_infos` 和
`tabs::surface_of_tab_pane` 返回的都是 owned 值，就是为了让「不小心把借用带过 FFI
调用」这件事写不出来。

### 2. provider 存身份，不存 `Surface` 裸指针

UIA 客户端想持有 provider 多久就多久，而 pane 可能在两次调用之间被关掉。存下来的
`Surface` 指针到那时就是已释放的内存，**崩在 libghostty 里，栈上看不到这个文件**。

所以每个 provider 带的是 `(frame, TabId, PaneId)`，每次调用重新解析；解析不出来
返回 `UIA_E_ELEMENTNOTAVAILABLE`——**这和「终端是空的」是两个答案，必须保持不同**。
被告知「空」的屏幕阅读器会坐在那里读一个已经不存在的文档。

同一个道理是 `RuntimeId` 用 id 不用下标：客户端拿 RuntimeId 判断两个元素是不是同
一个，而标签被拖动重排之后，下标会安静地指向另一个标签。

### 多窗口

三种 provider 的第一个字段都是 `frame`。取数据只走 `tabs::window(frame)` /
`with_windows`，全文件没有任何「当前窗口」式的取法。frame 一律由
`winid::frame_of_window` 得出，**不是 `pane_of`**——原因见 `tabs.rs` 里 `pane_of`
的文档：pane 要到 `create_tab_with` 才登记，那之前它对一个完全正常的 pane 返回
`None`，已经写错并纠正过两次。

---

## 三、文字是怎么读出来的，以及缓存对判据做了什么

**不直接读 Zig 的 screen buffer。** 核心已经公开了正确入口
`ghostty_surface_read_text`，它**自己持锁并复制一份**出来（`readTextLocked` →
`dumpTextLocked`）。所以拿到的是快照不是引用，「读到半行」这个失败形态由核心挡住，
宿主这边不需要新锁。核心自己的注释说这是昂贵操作、要求调用方缓存并限流；macOS 就
是这么做的（`SurfaceView_AppKit.swift`，500ms TTL）。这里照抄。

### 缓存差点把并发判据架空

原本的第 4 项判据是「一个 pane 里跑 `ping -t`，同时 dump 60 次，不崩不空」。
**但如果 dump 之间隔得比 TTL 短，那 60 次里只有一两次真的走到 FFI，其余是缓存在
答。** 这条判据会绿，而绿得毫无信息量——它测的是缓存能不能重复返回同一个字符串。

这和另一条已知的形状是同一个：脚本每次重走整棵树，恰好绕开了「不发结构变更事件」
这个缺陷。**判据的构造方式把它要抓的东西挡在了外面。**

处理方式，两件一起：

1. **不给缓存开测试旁路。** 带缓存的那条路是真实用户唯一会走的路（屏幕阅读器就是
   高频轮询的客户端）。旁路掉它，测的就是一条没人走的代码——仪器只许改速度、可见性
   和记录，不许改它经过哪些代码。
2. **加一个真实 FFI 调用计数**：每次真打到核心就写一行 `[uia] read_text #N`。判据
   的通过条件是**这些行的条数 ≥ 迭代次数**，不是「脚本没报错」。

只做「隔开 600ms」不够，那只是一个关于时序的**假设**；假设会静默失效（脚本被改快、
TTL 被调大），而失效的样子和通过一模一样。计数器是让这条判据能被证伪的那一半。

TTL 本身也由宿主打一行日志 `[uia] text cache ttl = Nms`，脚本读它并在间隔不高于
TTL 时**拒绝运行**，而不是照跑然后给一个绿。

### 别拿 `AutomationId` 当窗口的身份

窗口元素的 `AutomationId` 是 `w<n>`（`winid::tag`）。**它保证的比它看起来的少**，两条，第二条是**悄悄失去的性质**而不是新增的缺陷——后者更难查，因为没有任何东西记录它曾经成立过：

1. **只在一个进程生命周期内稳定。** 进程重启后 `w1` 是**新一轮**的第一个窗口。一个跨运行记住这个字符串的自动化脚本，会找到一个**存在的、看起来完全正常的**窗口，而它不是脚本要的那个。**不报错。**
2. **取值范围现在无界。** 在 `081bc0546` 之前这个号是登记表里的**位置**，所以永远不超过活窗口数；现在它是只增不减的计数器，长会话会走到 `w17`、`w200`。今天仓里没有把它格式化进定宽字段的东西（核过），但**「它是个小数字」这条保证已经没有了**。

（顺带：`081bc0546` 之前还有第三条，现在没了——那时关掉一个窗口会让后面所有窗口**改名**，因为号是下标。一个按 `"w1"` 定位的脚本会继续找到一个真实的、格式正确的、属于**另一个窗口**的元素，并且报告一切正常。）

**要定位元素，用结构（ControlType、树中位置）和内容（Name、document 的文字）。** 判据脚本 `windows/tools/uia-tree-dump.ps1` 就是这么做的，而且那里写了同一段——因为需要读到它的人打开的是那个文件，不是这一篇。

---

## 四、这一版**没有**做的，以及各自的代价

| 没做 | 代价 |
| --- | --- |
| **`TextPattern`** | 这是屏幕阅读器在终端上真正想要的那个。现在只有 `ValuePattern`：客户端拿到的是**可视屏幕的一整块文字**，不能按行、按词、按光标导航，也拿不到选区。 |
| **`SelectionItemPattern`** | 客户端能从 `HasKeyboardFocus` 读出哪个标签是活动的，但**不能激活一个标签**。 |
| **MSAA 回退** | `WM_GETOBJECT` 收到 `OBJID_CLIENT` 时仍走 `DefWindowProcW`。只认 MSAA 的老工具看不到这棵树。 |
| **滚动回溯（scrollback）** | 只读 viewport。屏幕上没有的内容读不到。 |

---

## 四点五、事件：什么会被通知，什么不会

树每次 `Navigate` 都从新快照重算，所以**重走一遍树的客户端永远看到真相**。屏幕阅读器不重走：它建一次模型，然后**等着被告知**。

| 变更 | 发什么 | 为什么不是别的 |
| --- | --- | --- |
| 增 / 删 / **重排**标签 | `ChildrenInvalidated`，发在 **TabList 和根**两个元素上 | 一个标签在树里出现两次（TabList 下的 `TabItem`、根下的 `Document`），只通知一个会留下一份对不上的文档列表。不用 `ChildAdded`/`ChildRemoved`：那要求把**已经走掉的那个标签**的 RuntimeId 交出去，等于专门留一份我们刻意不保存的记录 |
| **切换**标签 | `HasKeyboardFocus` 的 `PropertyChanged` | **切换不是结构变更**。树的形状不变（Document 每标签一个正是为此），**发结构变更是在说一件没发生的事** |
| 改名 | `Name` 的 `PropertyChanged` | 任务名之外的一条，一起做的理由：树是新的而名字是旧的，**和这条缺陷本身同形** |

**没人在听时全部跳过**（`UiaClientsAreListening`）。这是**快一点，不是安全** —— 有客户端时一切照旧成立，所以锁序必须自己对。

### 发事件会同步回调进 provider —— 这是这块最大的一条

`UiaRaise*` 把控制权交给 UIAutomationCore，它**可能立刻回调进本文件的 provider 去读属性**，而每个 provider 方法都要拿 `tabs` 的锁。那是一把普通的 `std::sync::Mutex`，**同一线程拿两次不会 panic，会挂起**。

这比设置页那次的 `RefCell` 双借用更难查：双借用当场 abort 并留下点名两处的栈；**自锁留下的是一个冻住的主线程，而这个宿主已经为那个形状花过一轮**（关标签挂住主线程好几分钟）。再遇到的人会从上次开始的地方开始，那不是这里。

所以五个调用点**全部在锁释放之后**，并且 `windows/tools/borrow-across-dispatch.py` 现在认识这三个函数名 —— 把 raise 挪进锁里的人会被闸挡住，而不是被一次真机挂起挡住。

---

## 五、怎么证明它成立

脚本：`windows/tools/uia-tree-dump.ps1`。

**它不调我们自己任何一行代码**：走操作系统的 UI Automation 客户端，从桌面根开始按
进程 id 往下找。理由是——「树建起来了但工具看不见」和「树根本没建」，**从进程内部
看一模一样**，只有从外面才分得开。

必须用 **Windows PowerShell 5.1（`powershell.exe`）**，不是 `pwsh`：PowerShell 7
不带那两个 WPF 程序集，而 `Add-Type` 找不到 `UIAutomationClient` 的报错看起来像是
功能缺失，不像是用错了壳。

```powershell
# 0. 地板 —— 打补丁之前跑，读数留档
powershell.exe -File windows\tools\uia-tree-dump.ps1 -Mode floor

# 1. 单窗口：结构、名字、矩形、document 文字
powershell.exe -File windows\tools\uia-tree-dump.ps1 -Mode tree

# 2. 多窗口：开两个窗口，各自只列自己的标签，RuntimeId 不重叠
powershell.exe -File windows\tools\uia-tree-dump.ps1 -Mode windows

# 3. 并发：一个 pane 里跑 ping -t，dump 60 次，按日志核对真实读取次数
powershell.exe -File windows\tools\uia-tree-dump.ps1 -Mode concurrent
```

### 地板那一步是这份判据里最要紧的一项

补丁之前跑同一个脚本，预期是：**窗口找得到，底下没有 TabItem、没有 Document。**

没有这一步，一个坏脚本的空输出和「树建起来了但工具看不见」长得一模一样。这条读数
是测量，不是走过场——**跑完请把输出留档，不要扔。**

### 四项各自的通过条件

| | 通过条件 |
| --- | --- |
| 地板 | 窗口在，`TabItem=0 Document=0` |
| 单窗口 | 3 个标签 → 恰好 3 个 TabItem，名字等于标签条上显示的；1 个 Document per 标签，`ValuePattern.Value` 含刚打进去的那行 |
| 多窗口 | 枚举到两个顶层元素；各自的标签集合不交叉；**没有任何 RuntimeId 同时出现在两个窗口下** |
| 并发 | `[uia] read_text #` 的行数增量 **≥ 迭代次数**（否则说明测的是缓存）；没有一次读回空；进程还活着 |
| **事件**（`-Mode events`） | 开标签 / 关标签 / 重排 → `ChildrenInvalidated`；**切标签 → `HasKeyboardFocus` 的 PropertyChanged，且没有 StructureChanged**；改名 → `Name` 的 PropertyChanged；全程进程不挂 |

### `-Mode events` 是唯一一个「有客户端在听」的模式，这件事要说出来

前四个模式都在 `UiaClientsAreListening()` 为**假**的路径上跑 —— 它们连一次都不会触发上面那条同步回调。**所以在 `-Mode events` 之前，那条锁序在真机上从来没有被走过一次。**

**这不是那四项的缺陷**，它们各自验的东西都验到了。但它是一个必须被说出来的覆盖空洞，否则「UIA 四项全过」会被读成「UIA 这块验过了」。`-Mode events` 里「全程进程不挂」那一格，**是那条锁序唯一的判据**。

### 这份判据的仪器自己要先被证明

`-Mode events` 在订阅我们的事件之前，先订阅一个**系统自己会发的**焦点变更，收不到就当场退出并拒绝给出读数。理由：**「没收到事件」和「订阅根本没建立」打印出来一模一样。**

自检**刻意不用我们自己的事件** —— 拿被测对象证明测量装置，会让「宿主一个事件都没发」同时弄坏两者，而你分不清坏的是哪一个。

### 这两个脚本的任何改动，在真机解析过之前都是「未验证」——**包括只改注释的那种**

这条是付过代价的。`6d1ad109e` 里一次**只改注释**的提交让 `uia-tree-dump.ps1` **整个解析不过**（15 个语法错，任何模式都跑不了），而提交前做过检查：块注释配对、大括号平衡，两项都是脚本核的、都绿。

**它们在构造上看不见这一类错。** 它们数符号，而这是上下文相关的：
```powershell
$x = @{ Type = $e.Name -replace '^A\.', '' }               # 0 错
$s.Add([pscustomobject]@{ Type = $e.Name -replace ... })    # 5 错
$s.Add([pscustomobject]@{ Type = ($e.Name -replace ...) })  # 0 错
```
**同一个表达式，在方法调用的括号里才致命** ——报错说的是「Missing ')' in method call」，一个字都没提哈希表。（这三行是量出来的：第一版的解释说「在赋值里合法、在 `@{}` 里不合法」，**用解析器一试就是错的**。）

现在有一道闸：`windows/tools/ps1-parses.py`，用本机 `pwsh` 的**真解析器**跑，带双向自检。**`pwsh` 不在就 exit 1 而不是跳过** ——「我看了没发现」和「我没法看」不能打印同一句话。

**但它只能说语法。** 这些脚本要在 **Windows PowerShell 5.1** 上跑，而 5.1 的程序集（`UIAutomationClient`、`System.IO.Pipes`）那个解析器一个都不认识。**所以闸绿只是把「跑不了」缩小到「不是语法问题」，不是「能跑」。**

### `-Mode events` 需要消息泵，而这一条写在它自己的报错里

UIA 的客户端回调是跨套间 COM 调用，**通过线程的消息队列到达**。停在 `Start-Sleep` 里的线程不泵消息，回调排在后面永远不来——**而「什么都没收到」正是这个模式要产出的读数**，所以这个失败会伪装成结果。

第一版就是 `Start-Sleep`。真机上仪器自检连续失败三次，试了三种不同的聚焦动作之后才有人怀疑到「等」而不是「点」。现在循环里 `DoEvents`，**而且失败信息按顺序写明了该改什么**：先换到交互式控制台（Polter 的一个标签就是），再查套间是不是 STA，**最后才怀疑点击**。

**一个需要特定运行方式才能工作的工具，如果不在失败时说出那个方式，等于把使用条件藏在作者脑子里。**

### 这份判据不覆盖什么

- **屏幕阅读器是否真的会念**（见开头那条，这是最大的一条）。
- COM 引用计数与泄漏；窗口关闭后客户端仍持有 provider 的那条路径（并发模式跑 60 次
  只是弱证据）。
- `inspect.exe` / `accevent.exe` 属于 Windows SDK，测试机上不一定装了；所以主判据用
  PowerShell。机器上恰好有的话，作为第二意见更好，但不是必需。

---

## 六、往上游走？

ghostty 上游没有 Windows 的可访问性实现，这块原则上是可以回馈的。**本仓有一条规矩
是不建 issue 不建 PR**，所以这件事由用户决定，不由写这块的人自己动手。
