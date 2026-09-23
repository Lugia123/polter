# 群里点名（mention）与直投

> 任务 575。这份是契约，动手前整份读完。与代码冲突以代码为准，
> 与这份冲突的旧说法作废。

## 要解决的

群消息**不会唤醒被监管的终端**。今天只有主管被打断（`Chat.waking`
按 role 一刀切），worker 全靠自己 `group_read`。于是一条发给某个人的
话，发的人看到 `ok`，而那个人什么时候看见全凭他自己什么时候去看。

这一晚它撞了三次：主管用群消息协调构建队列，三次有人在别人还占着树
的时候开跑，**因为那条协调消息对他们是到不了的**。

⚠️ 这和 574 是同一句话的两半：574 是「写了但没人读得到」，
这条是「发了但不唤醒」。**两者在发送方那一侧长得一模一样——都回 `ok`。**

## 一、点名是参数，不是文本

```
group_post(group, text, mention: ["0x2528…", "0xf95a…"])
```

**`mention` 是终端 id 的数组，不是正文里的 `@xxx`。**
⚠️ 不要去解析正文。解析出来的东西不准，而不准的方向是「点错人」——
那意味着往一个没被点名的终端里敲回车。

- **校验在 post 时做**：任一 id 不是本群成员 ⇒ **拒绝整条 post**，
  不入群、不投递。不要发出去之后再说「有人没收到」。
- **显示**：群里渲染成 `@<短 id> <title>`。title 单独不够——它随时会被
  改掉，而事后翻记录时要知道**当时**点的是谁。

## 二、送达

被点名的终端走 `terminal_send(submit = true)`——打字并回车，等效主管
发指令。**不是** notice（notice 只打字不回车）。

## 三、送不到要逐个回报，而且不许绕过那两道拒绝

`terminal_send` 会因两件事被拒，**它们在这里不是碍事，是唯一挡住
「往人手底下敲回车」的东西**：

| 拒绝 | 含义 | 会自己好吗 |
| --- | --- | --- |
| `UserPresent` | 十秒内有真实键盘输入到过 | 会 |
| `DraftInLine` | 输入框里有没提交的半行字 | **不会**，要有人按键 |

⇒ `group_post` 的返回要**逐个**说清谁送到了、谁没有、为什么。
⇒ ⚠️ **消息本身照常入群、照常算未读**。直投失败不等于消息没发出——
这两件事分开，否则又造出一个「发送方看到的成功」。

## 四、`Chat.waking` 加一条覆盖

今天：

```zig
waking(name, id, role) = switch (role) {
    .supervisor => unread,
    .watched, .none => 0,
}
```

加一条：**被点名的，无论 role 都算该被打断。**

⚠️ `unread`（能看见）和 `waking`（该被打断）是**故意分开的两个数**，
那段注释明写着不许合并。这条覆盖只动后者。
没被点名的人行为**完全不变**。

## 五、worker 点 worker：默认改写给主管

今天有标记的终端**只有主管碰得到**，worker 之间发不了消息。
直接放开点名等于开一条绕过它的路（见 `cross-process-authz.md` 的 X2）。

所以默认行为是**改写**而不是拒绝：

- worker A 点名 worker B ⇒ **实际点名的是 A 的主管**，
  正文里写明「A 想让 B 做什么」，由主管判断后自己转发。
- 主管点名 worker ⇒ 直投，照常。
- worker 点名主管 ⇒ 直投，照常。

**改写要在群记录里看得见**：读群的人应当能看出「这条本来是点给 B 的」，
而不是只看到一条点给主管的消息。

## 六、开关：每个主管一个，UI 两处

改写是默认。打开开关之后，**worker 可以直接点名 worker**，主管只是
照常知道群里有消息。

- **作用域是主管**，不是全局、不是每个群。MCP 这一侧知道某个 worker
  归哪个主管管（role 与监管关系都在 Bus 上），据此查这个开关。
- **UI 两处**：主管终端的 **tab 右键菜单** 和 **终端右键菜单**。
  ⚠️ 582 刚做过同一件事：那几项 agent 动作在**菜单栏 + 两处右键共三处**，
  而当时 Role 只在两处。这条也要三处齐，并且从共用 builder 出。
- 默认 **关**。
- ⚠️ **只在内存里，跟主管身份同寿**（`Bus.Entry.worker_mentions`）：
  `removeSupervisor` 会把它清掉，也没有任何东西把它写到盘上。重启后
  重新当上主管的终端，开关一律是关的——**它不会被持久化**，不要按「上次
  开过」去推断现在的状态。
- 只有用户能改（`Bus.setWorkerMentions(.., .user)`），和 `may_authorise`
  同一档：**没有默认快捷键，也不进命令面板**，因为 agent 能用
  `terminal_key` 打开别的终端的命令面板，给自己放权。

⚠️ 这个开关存在的理由是 **A/B**：两种模式都想真用一阵看效果，
所以两条路都要是**完整可用**的，不是一条正路加一条应急路。

## 七、分工与契约点

| | 谁 | 面 |
| --- | --- | --- |
| 核心 | `Chat.zig` / `Bus.zig` / `rpc.zig` / `wire.zig` / `cli/mcp.zig` | 参数、校验、改写、`waking` 覆盖、失败回报 |
| 开关的 action | `apprt/action.zig` / `embedded.zig` / `include/ghostty.h` | 追加在**末尾**，见下 |
| macOS | `macos/Sources/` | 三处菜单 |
| Windows | `windows/host/src/` | 同一套 |

⚠️ **action 枚举只许追加在末尾。** 581 那次插在中间，把 C ABI 的 tag
编号整体推移了——`apprt/action.zig` 旁边就写着这句，那道闸当场抓住了。
错位不会崩、不会有可疑日志，只会让 Windows host 把一个 action 派进
另一个的分支。

> <u>**本次（575）不新增 tag**：开关走的是 binding action
> `poltergeist_toggle_worker_mentions`（输入），状态搭在现有的
> `GHOSTTY_ACTION_POLTERGEIST_MARK` 上——`ghostty_action_poltergeist_mark_s`
> 里 `may_authorise` 之后加了 `bool worker_mentions`，落在**偏移 15，也就是
> 原来的 padding 字节**，sizeof 仍是 24，`persona` 仍在 16。理由：代码里
> `toggle_authorise` 就是这么做的。钉子有两颗：Zig 侧是
> `apprt/action.zig` 里 `PoltergeistMark.C` 的 `@offsetOf`/`@sizeOf` 断言，
> Rust 侧是 `ffi.rs` 里的同一组常量。上面那条规矩针对 tag 枚举，仍然成立。</u>

**核心先出契约贴群，另外三个人等它**；在那之前可以做不依赖它的部分
（菜单骨架、开关的存储位置）。

## 七之二、写死的形状（v1.1，以代码为准）

**请求**：`group_post(group, text, mention?)`，`mention` 是终端 id 数组
（`"0x…"` 或整数）。不带、或者是空数组 = 原来的行为。

**整条拒绝**（不入群、不投递）：`NotAMember`（message 点名是哪几个 id）、
`MentionSelf`、`TooManyMentions`（上限 `Chat.max_mentions` = 16）。

**成功**（带 mention 时）：

```
{"ok":true,"seq":N,"cut":null|{"given":n,"kept":n},
 "deliveries":[{"id","to","rewritten","delivered","code","message"}, …]}
```

每个不同的 id 恰好一行。`to` 是实际敲进去的终端，可能是 id 本身，也可能
是改写后的主管；`NotATerminal`（点了用户 `0x0`）/ `Shielded` /
`NoSupervisor` 这几种情况什么都没敲，`to` 为 null。其余 `code` 的取值和
`terminal_send` 的拒绝一样：`UserPresent`、`DraftInLine`、`ChildExited`、
`NoSuchTerminal`、`UnbracketedMultiline`、`UnsafeText`、`SendFailed`。

**群记录**：正文前面按每个名字加 `@<id 前 8 位十六进制> <title>`，title 取
发帖那一刻的值。改写的写成
`@<主管> <title> (↪ 原点名 @<B> <B title>：<A title> 想让 <B title> 做下面这件事，请主管判断后转发)`。

**敲进终端的一行**：`[poltergeist] <群> #<seq> @<作者> <作者 title>: <群记录里那份正文>`。
换行折成空格，内容与群记录是同一份，冻结在同一刻（`Chat.formatDelivery`）。

**顺序**（`App.chatPost`）：先入群，再逐个直投，最后跑通知扫描。直投成功的
终端会被 `Chat.markTold` 记一笔，免得扫描紧跟着再敲一行通知进去。
如果反过来先扫描，通知会留在被点名终端的输入框里，于是直投会被
`DraftInLine` 拒掉，而拒它的正是我们自己。

## 八、判据

- 点名不存在的成员 ⇒ 整条 post 被拒，**群里没有这条消息**。
- 被点名的终端**屏幕上出现了那段文字并被执行**——判据是屏幕，不是
  `group_post` 回了 `ok`。
- 有草稿的终端被点名 ⇒ 投递被拒、**草稿没被污染**、发送方拿到 `DraftInLine`。
- 没被点名的成员**不被唤醒**（正对照，防止把所有人都唤醒了还以为修好了）。
- 开关关着时 worker 点 worker ⇒ 主管被点名，**B 没有被投递**。
- 开关开着时 ⇒ B 被投递，主管只是未读 +1。
