# 跨进程控制与它的授权面

**这份文件回答一个问题：一个不在被测实例里的进程，能不能列出本机的 Polter
实例、指定其中一个、并驱动它？答案是能，今天就能，零改动。**

这是好消息也是坏消息。好消息是「验证不再依赖某个 agent 恰好跑在被测实例
里面」这件事不需要新协议；坏消息在下一节的那一句话里。

> 这条发现的真正形状：`GHOSTTY_POLTER_TOKEN` 保护的是「不是这台机这个
> 用户」，**不是**「不是这个 agent」。
>
> `roles.md` 一直默认它两件都保护了。那是设计文档要改的地方，不只是一个
> 待办。

## 量到的三件事

**一、发现不需要凭据。** POSIX 上 `transport_posix.defaultName` 把端点写成
`<state_dir>/polter-<hex>.sock`，一个实例一份，state_dir 是
`~/.local/state/polter/`。列目录就是列实例。分死活也不需要凭据：对着 socket
发一行 `{"method":"auth","params":{"token":""}}`，

* 活的实例答 `{"ok":false,"code":"BadToken","message":"token not recognised"}`；
* 只剩文件的死端点在 `connect` 就 `ECONNREFUSED`。

**这套语义仓里已经有了，外部控制端应当照抄而不是另发明一套。**
`Server.zig` 的 `sweepStale` 干的就是这件事：`isSocketName` 认
`polter-*.sock`，`probe` 用一次 `connect` 分死活，`CONNREFUSED` 是**唯一**
允许判死的答案，其它一切（权限错、读不懂的 errno、连上了）一律算活。那段
注释把理由写得比这里清楚：「活着的实例的 socket 就是一个普通的零字节文件，
和八月死掉的进程留下的那个在磁盘上没有区别，唯一能分开它们的是去连一下。」

⚠️ **但 `sweepStale` 只在启动时跑一次**，所以目录的干净程度取决于最近一次
有没有实例启动过——实测这一点：同一目录十分钟内从 7 个条目变成 2 个，中间
没有人删文件，只是有一个实例起来了、顺手扫掉了邻居。**外部发现端不能指望
这个**，它必须自己探活。

⚠️ **目录里的条目数不等于实例数。** 上面那次 7→2 之后，剩下的 2 个里仍然
只有 1 个是活的——崩溃或被杀的实例不走 `transport.unlink`，文件留在原地，
而下一次扫除要等到下一次有实例启动。所以任何「列实例」的实现都必须探活，而且**不许在探不到时回退到
另一个还活着的实例**：那样「打到了错的实例」和「打对了」在输出上完全同形。

**二、token 在 environ 里，同 uid 全可见。** macOS 上 `ps eww -p <pid>` 会打出
同一 uid 别的进程的完整环境块。在三个属于别人终端的 shell 上，
`^GHOSTTY_POLTER_TOKEN=` 各出现 1 次；负对照是 Polter 直接起的
`provision.sh`（不是 surface 的子进程，环境里本就没有这个变量），出现 0 次
——所以那个 1 不是恒真。**取值这一步没有做，也不需要做**：命题「同 uid 的
任何进程都能拿到别人终端的 token」在数到 1 的那一刻就成立了。

**三、`Server.zig` 的 token 只回答「我是哪个终端」。** `mint` 生成 32 字节
随机数、进内存 map、**从不落盘**，只经 pty 环境下发给这个实例自己的终端。
`authenticate` 把字节换成一个 `Bus.Caller`，而 `Bus.Caller` 只有两种：
`terminal` 和 `plugin`。协议里没有地方让调用方**声称**自己是谁，这一半是
对的、也是这份设计里最好的部分。缺的是另一半：**没有地方问「你可不可以
驱动第三方」**，因为从没有过第三方。

## 一个借来的 token 能做什么，实测

上面第二件事说 token 同 uid 可读。**但读到它并不等于接管那个实例**——这是
用一个自建的测试实例（`open -n` 起的，绝不碰用户那个）当场量出来的，比第一版
结论窄，也更让人安心：

一个借来的终端 token，握手后被认成**那一个终端**，带着**那个终端的角色**。
测试实例是新起的，14 个 surface 全是 `role: none`、`duty: off`、未 shield。
拿它们之一的 token 连上去：

* **读全都放行**：`me`（回的是这个实例自己的终端 id `0x0b0c…`，不是用户实例的
  `0xf95a…`——这一条本身就是「指对了实例」的判据，指错了会回另一个 id）、
  `terminal_list`（14 个）、`terminal_read`（可见屏幕）、`config_get`、
  `session_recall`、`notices`。
* **跨终端打字放行**：`terminal_send` 到**另一个未标记**的 surface，成功。
  实测：向目标 surface 发 `echo <marker>`，`{"ok":true}`，1.5s 后
  `terminal_read` 目标可见屏幕，`<marker>` 出现两次（命令回显 + shell 输出）
  ——先读一次确认新 marker 不在，再读一次确认在，before/after 分明。**这是一条
  真正在别的终端上执行了的命令。**
* **一切实例级的改动全部 `NotPermitted`**：`group_create` / `notify_user` /
  `terminal_open` 回的都是原文 `not permitted: only a supervisor may do this`。
  机制在 `rpc.requiresSupervisor`：这些方法要求 caller 是 supervisor，而一个
  普通终端不是。
* 另外两条边界：打自己的 id 回 `SelfTarget`；`terminal_read` 带 `lines` 回
  `NotImplemented`（只给可见屏幕，不给 scrollback）。

**所以一个泄漏的终端 token 的爆炸半径，是「那一个终端的身份与角色」，不是
整个实例。** 这把 X2 收窄了，但没有消掉它，原因有两条：

1. `terminal_send` 到未标记终端**已经是**跨终端注入——我在一个 surface 里让
   另一个 surface 执行了命令。同实例内终端互打本就是设计允许的，可一旦攻击者
   是「同 uid 的任意进程」而不是「实例内的某个 agent」，这条边界的假设就变了。
2. 上面量的是一个**没有 supervisor** 的新实例。真实会话里有终端是 supervisor
   或被授予了 standing——借**那一个**的 token，就连带继承了它的 supervisor
   权限，`group_*`、`notify_user`、`set_watch`、时钟全部打开。**攻击者会挑
   token 挑角色最大的那个终端借**，而他能看见每个终端的角色（`terminal_list`
   的 `role` 字段，读操作放行）。

## 缺的 X

三条要一起，任何一条单独补都不够。

**X1 一个不靠环境变量传递的凭据通道。** token 一旦在 `environ` 里就是同
uid 全可见，这是操作系统的性质，不是实现的疏忽。要么换成 fd 传递（socket
已经在手上），要么 environ 里只放一张一次性的换取券，换完即失效。

**X2 「驱动第三方」本身的授权位。** 现在 `rpc.authorize` 按 `Caller` 分
`terminal` / `plugin`，没有第三类。一个外部控制者不是终端也不是插件，它
需要自己的身份类型，和一份它**能**调用的方法集——而不是借用某个终端的
token 后拿到那个终端的全部权限。

**X3 被驱动方的可见性与撤销。** 现在「被外部进程驱动」和「被自己里面的
agent 驱动」在被驱动的终端上长得一模一样。用户看不出区别，也没有一个可以
撤销的把手。

## 判据，以及它们各自红在哪

四条，每条都先证明会红，错误码是原文：

| 情形 | 输出 | 退出码 |
| --- | --- | --- |
| 指一个不存在的实例 id | `NoSuchInstance: no instance '<id>' under <state_dir>` | 3 |
| 指一个存在但已死的 socket | `InstanceNotListening: <path> (Connection refused)` | 4 |
| 活实例 + 错 token | `{"ok":false,"code":"BadToken","message":"token not recognised"}` | 5 |
| 活实例 + 真 token（正对照） | `{"ok":true,...}` | 0 |

前两条是控制端自己的具名拒绝，后两条是 `Server.handshake` 的原文。四个退出
码两两不同，所以「只看退出码的调用方」也读不错。

⚠️ 第二条不是第一条的弱化版本，它是这里最容易被跳过而最该做的一格：本机
当时列出的两个端点里，字典序在前的那个恰好是**死的**——一个按位置挑而不
按名字挑的实现，在这台机器上会当场红，但换一天就可能侥幸绿。**用名字，
不用位置。**

## 正对照：这条路已经走通过

`dev-docs` 之外的证据：本轮第一条结论是从一个终端里的 python 直接连
`~/.local/state/polter/polter-<hex>.sock`、握手、发 `group_post` 发出去的，
不经过 `+mcp` 的工具面。回执是 `{"ok":true}`，而**效果由另一条通道核实**
——群日志文件当场多出一行，内容与发出的 1075 字一字不差。回执自己说 ok 不
算数，落盘那一行才算。

**完整链条也在一个非用户实例上走通了一遍**（自建的测试实例，见上一节）：
列实例 → 按 socket hex 指定 → `terminal_send` 让它的一个 surface 执行
`echo <marker>` → `terminal_read` 读回该 surface 的可见屏幕，marker 出现。
三步都成，且「按名字指定」而不是按位置/pid——`me` 回的实例自有 id 与用户
实例不同，是指对了实例的判据。

## Windows 差在哪（未实现，先说清楚）

`transport_windows` 用命名管道，`defaultName` 给出
`\\.\pipe\polter-<hex>`，`unlink` 是空操作。于是：

* **发现的机制不同，但不是没有。** 管道名活在内核命名空间里，磁盘上什么都
  不留，所以「列目录」这条路在 Windows 上直接不存在。对应的做法是枚举
  `\\.\pipe\` 这个伪目录（`FindFirstFileW("\\\\.\\pipe\\*")`）并按
  `polter-` 前缀过滤。
* **死端点的问题反过来了，而且是好的方向。** 管道随进程消失，所以
  Windows 上不会有「文件还在、没人听」这一格——第二条判据在那边换成
  `ERROR_FILE_NOT_FOUND`，而不是 `Connection refused`。
* **网络面在 Windows 上是真实存在的。** `\\host\pipe\name` 会经 SMB 提供给
  这台机器肯认证的任何人，所以管道是带一条只认本用户的 DACL 建的
  （`Listener.sd`，`w.OwnerOnly`）。这道门 unix socket 侧从来没开过。
* **⚠️ 第二条测量在 Windows 上没有做。** 「同 uid 的进程能读到别人的
  environ」在那边要 `ReadProcessMemory` 读 PEB，不是一条 `ps`。同用户非提权
  进程通常拿得到那个句柄，但**这是推断不是读数**，要在真机上量过才能写进
  结论。在量之前，X1 的必要性在 Windows 上属于未检验，不属于已排除。
