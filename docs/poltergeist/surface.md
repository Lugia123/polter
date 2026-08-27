# 工具面该覆盖到哪里

> 最后更新对应的 git commit：`3d1841296`
> 校验方式：`git log -1 --format='%H %h %ad %s'`
> 状态：**全部落地**。第四件查下来是多余的，第五件只做了一半，理由见下。
> GTK 侧的 `new_tab` 载荷**只做过静态核对，没编译过**——本机没有 gtk-4 与
> adwaita 的开发库。

## 本章覆盖什么

菜单栏上的每一项怎么经 MCP 开放给 AI。现有工具面见 [mcp.md](mcp.md)，
这一章只回答「还差什么、怎么补」。

## 本章不覆盖什么

- 已有工具的语义 —— 见 [mcp.md](mcp.md)。
- 群聊、监督、工作模式 —— 见 [supervisor.md](supervisor.md)。
- 插件配置那一套的安全论证 —— 见 [mcp.md](mcp.md)。**那一条仍然成立**，理由见本章末。

## 这一章是怎么来的

用户让总管开四个终端分派工作，总管发现自己做不到：Polter 没有建终端的工具。
它先试了 `osascript` 绕路，被拦下。

顺着这件事查下去，缺的不是一个工具，是一整面：**菜单栏上人能一键做的六十件事，
AI 一件也做不了。**

第一版规划把它们逐条筛了一遍，只放行三件。那个判断被否掉了，理由是对的：

> Polter 本来定义就是 AI 原生终端工具。

一个 AI 原生的终端，如果它的能力面是「人有六十件事可做，AI 有三件」，那它就
只是一个装了 MCP 的普通终端。**藏起来的那些能力并没有变得更安全 —— 它们只是
变成了 agent 要用 `osascript` 绕过去的东西**，而绕过去的路子既不受这套工具面
的权限约束，也不留任何记录。

## 一句话结论

**菜单上有的，工具面上都有。** 而且不是一条条抄过来，是把菜单**本来就在用的
那个分发器**开出来。

## 关键发现：不需要写五十个工具

菜单项在 macOS 侧绝大多数落到同一个函数：

```swift
ghostty_surface_binding_action(surface, "toggle_split_zoom", …)
ghostty_surface_binding_action(surface, "increase_font_size:1", …)
ghostty_surface_binding_action(surface, "inspector:toggle", …)
```

它背后是 `src/input/Binding.zig` 的 `Action.parse(str)`——一个字符串驱动的
动作分发器，**92 种取值**，是菜单的超集——菜单去掉分组标题后约六十项，且只是其中一部分的可视化。
执行入口 `Surface.performBindingAction`（`src/Surface.zig:5039`）就在 Zig 核心里，
而 Poltergeist 也在核心里。

三条好处，一条比一条重要：

1. **不必碰 macOS，也不必碰 GTK。** 全部在核心内完成，没有 apprt 动作要加，
   不用去动那个「以前漏过三轮」的穷举 `switch`。
2. **自动跟上上游。** 上游加一个键位动作，工具面当天就有，不用有人记得同步。
3. **和用户自己按键走的是同一条路。** 不存在「AI 专用的后门实现」和「人用的
   实现」两套代码各自跑偏——那正是 bug 藏身的地方。

## 要做的

### 一、`terminal_action(id, action)` —— 一个工具，整个菜单 ✅

在指定终端上执行一个 Ghostty 键位动作。`action` 就是配置文件里写的那个串：
`new_tab`、`copy_to_clipboard`、`increase_font_size:1`、`goto_split:left`、
`toggle_fullscreen`、`close_surface`……

参数形式和配置完全一致（冒号后跟参数），所以**用户已经知道怎么写，AI 也已经
在训练数据里见过 Ghostty 的键位配置**。不发明第二套词汇。

### 二、`terminal_actions()` —— 让它可被发现 ✅

把 `Action` 联合的字段名列出来，附上哪些需要参数。没有这一条，AI 只能猜动作名，
猜错了拿到一个解析失败。**一个不能被枚举的工具面等于没有工具面。**

清单在编译期从联合本身生成，不是手写的：手写的那份在上游第一次加动作时就会错，
而且是**静默地错**——那个动作按名字调得动，只是不出现在清单里，两头不落好。

落地时把两类失败分开了，因为它们要的下一步不同：**名字不存在**是调用方打错字
（`UnknownAction`，附上"看 `terminal_actions`"），**值不合法**是参数写错
（`BadParams`），**终端没接受**才是终端的事（`ActionFailed`）。原来这三种会挤成
一句"它不肯这么做"，害人往错的方向查。

### 三、`terminal_open(cwd, watch?)` —— 唯一需要另铺路的 ✅

`new_tab` 是无参动作（`Action` 里它的类型是 `void`），开出来的 tab 继承的是
父终端的目录，**没有办法指定**。而「四个终端各在各的目录」正是触发这一章的需求。

所以这一件要给 apprt 加一个带工作目录的动作，会碰 Zig 核心 + macOS + GTK 三侧。
GTK 那个穷举 `switch` 按发布记录以前漏过三轮，改的时候要专门核对。

`watch` 为真时顺手 `set_watch` 认领，省掉一次往返——总管开一个终端，多半就是
为了管它。

落地时改了 apprt 的 `new_tab`：它从无参变成带一个 `working_directory`，空串
表示「照原来那样继承」——键位和菜单传的都是空串，人按 ⌘T 的行为一个字没变。

**返回的 id 是「看」出来的，不是被告知的。** 造 surface 要出到 apprt 再回来，
macOS 上走的是通知，今天是同步投递但没有任何东西保证它一直是。所以前后各数一次
surface，动作返回时若已经多出来一个就报它的 id，没有就报空。**空不是失败**——
tab 还在路上，`terminal_list` 过一会儿就有。在这里等下去会把 socket 线程挂在
UI 线程要做的事情上。

### 四、`terminal_set_title(id, title)` —— **不做，已经有了**

原来的判断是「`Action` 里的 `set_title` 只作用于当前终端」。**那是错的**：
`terminal_action` 本来就带 id，作用的就是那个终端。而 `Binding.Action` 里
`set_surface_title` 和 `set_tab_title` 都是带字符串载荷的动作，`parse` 把第一个
冒号之后的整段当值，空格照收。

所以 `terminal_action(id, "set_surface_title:worker A")` 已经能做这件事，
再加一个工具就是本章红线第一条说的「第二套词汇」。

**但两者的区别要写进 skill**：`terminal_list` 读的是 surface title
（`rt_surface.getTitle()`），所以总管要给自己看的标签得用 `set_surface_title`；
`set_tab_title` 改的是屏幕上那个 tab 的名字，给人看的，进不了列表。

### 五、`config_get(key)` ✅，`config_reload` **不做，已经有了**

`reload_config` 本来就是键位动作，`terminal_action(id, "reload_config")` 即可。

`config_get` 是真新的。落地时改了取值方式：**App 并不保存 Config**——它在
`updateConfig` 里取走需要的几项就不再持有，而跨重载存一个 `*const Config`
是悬垂读，且时机最差（配置重载那一刻）。所以在 `updateConfig` 里把整份配置
按 `+show-config` 的格式渲染成文本存下来，`config_get` 从文本里按行取。
几十 KB、每次重载一次，而且不可能悬垂。

按行而不是按值取，是因为**一个键可以出现多次**（`poltergeist-notify` 每条渠道
一行），只返回第一条会静默丢掉其余的。匹配要求整个键名后面跟 ` =`，
否则 `poltergeist-watch` 会匹配上以后可能出现的 `poltergeist-watch-harder`。

## 权限：都在总管这一侧

五件全部走 `requiresSupervisor` 那条穷举白名单。理由不是「被监督终端不配」，
而是**被监督终端没有场景需要它**：它在自己的终端里干活，动别人的窗口布局、
开别人的 tab 都不属于它的职责。而那条白名单是穷举的，新增方法必须显式表态，
有一条逐方法核对的测试盯着。

## 仍然不给的两件，以及为什么它们不是同一类事

**放开菜单不等于放开一切。** 这两条和菜单无关，仍然成立：

1. **不替别的 agent 按授权提示（R2）。** 菜单上根本没有这一项——它不是 Polter
   的功能，是别人程序里的一个提示。给不了，也不该找路子给。
2. **插件配置不写 `cmd:` 引用。** 这条常被误读成「怕 AI 权力太大」，不是。
   `cmd:` 的特别之处在于它**创造一段将来才执行的新代码**，执行时刻在写它的那次
   工具授权早就结束之后，且每次插件重起都重新执行一遍。菜单动作不是这样：
   它当场发生、当场结束，和用户自己按下那个键完全一样。**一次性发生的动作和
   留在配置里将来自己跑的载荷，是两类东西。**

## 红线

1. **不发明第二套动作词汇。** 动作串就用键位配置那一套，参数形式一致。
   两套写法迟早会漂移，而漂移的那天没人会发现。
2. **不做「AI 专用」的旁路实现。** 走 `performBindingAction`，和人按键同一条路。
3. **动作要可枚举。** 加了 `terminal_action` 就必须同时有 `terminal_actions`。
