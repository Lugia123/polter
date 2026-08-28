# 写一个插件

> 最后更新对应的 git commit：`2502f71bc`
> 校验方式：`git log -1 --format='%H %h %ad %s'`
> 状态：**已实现**，本篇每条事实都对着代码核过。宿主在
> `src/poltergeist/Plugin.zig`，常驻那一类在 `Archive.zig` 与 `Cursor.zig`，
> 凭据解析在 `secret.zig`，工具面的拒绝规则在 `rpc.zig` 的 `Guard`。
> **本章若与代码不一致，以代码为准。**

## 本章覆盖什么

- 从零写一个最小可用的 `notify` 插件：每个文件的完整内容。
- **不启动 Polter 怎么测自己的插件** —— 手工喂一行，以及
  `plugins/chat-archive/archive.py` 的 `--self-test` 那种范式。
- `archive` 插件与 `notify` 的差别：常驻、游标、重启续上。
- 常见错误，以及每一个在宿主侧的确切表现。

## 本章不覆盖什么

- **契约本身**（清单字段的完整语义、两种生命周期的定义、权限声明、凭据引用
  的设计理由）—— 见 [plugins.md](plugins.md)。本篇是照着做的教程，那篇是规范。
- 存档插件的游标规则、往回翻、空窗口规则 —— 见 [storage.md](storage.md)。
- 工具面为什么这么拒 —— 见 [mcp.md](mcp.md)。
- 仓库里那两个插件的目录约定 —— 见 [../../plugins/README.md](../../plugins/README.md)。

## 一句话概括

一个插件是一个目录，里面一份 `plugin.json` 和一个可执行文件。Polter 把事件作为
JSON 写进它的 stdin，用退出码判断成败。**因此写插件的第一天就能脱离 Polter 单独
跑**——手上有一行 JSON 就够了，这是本篇最该记住的一条。

---

## 一、从零写一个 `notify` 插件

做一个 `desktop-say`：把通知念出来（macOS 的 `say`）。选它当例子是因为它**不
需要网络也不需要密钥**，你可以立刻跑通，然后再把 `deliver` 换成真正想发的地方。

### 1.1 目录放哪

用户自己的插件放在这里，Polter 启动时扫这个目录：

```text
$XDG_CONFIG_HOME/polter/plugins/desktop-say/
  plugin.json
  say.py          ← 要有执行位
```

查找顺序在 `src/App.zig:606` 的 `pluginSearchPath`，**两处，近的赢**：

1. `$XDG_CONFIG_HOME/polter/plugins/`（用户的）
2. `<resources>/ghostty/polter/plugins/`（随 Polter 装的）

所以放一个同名目录就能顶掉我们发的插件，不用动 app bundle。

> `$XDG_CONFIG_HOME` 没设时按 XDG 默认走 `~/.config`，本仓库的实现在
> `src/os/xdg.zig`。

### 1.2 `plugin.json`

```json
{
  "key": "desktop-say",
  "name": "Say it out loud",
  "kind": "notify",
  "version": "1.0.0",
  "description": "Reads the notice aloud with macOS `say`.",

  "exec": "say.py",
  "timeout_ms": 10000,

  "params": {
    "type": "object",
    "properties": {
      "voice": {
        "type": "string",
        "title": "Which voice",
        "description": "A name from `say -v ?`.",
        "enum": ["Alex", "Ava", "Daniel"]
      }
    },
    "required": ["voice"]
  }
}
```

四件容易写错的事，每一件都在 `Plugin.zig` 里有对应的行为：

- **`key` 写成和目录名一样。** 宿主不校验这一条，但查重按目录名，而下游全按
  `key`——设置文件是 `<key>.json`、游标是 `<key>.cursor`。不一致的后果是一个插件
  的设置文件叫着另一个名字。
- **`exec` 被直接当 `argv[0]`**（`Plugin.run`，`argv = &.{manifest.exec}`）。
  **没有 shell 兜底**：shebang 必须自己成立，文件必须有执行位，否则宿主记一句
  `could not start` 并把这次通知记为 `unstartable`。
- **`timeout_ms` 缺省 10000**（`default_timeout_ms`）。超时即杀，判 `timed_out`。
- **`enum` 是唯一敢把已配置的值回显给 agent 的参数类型**——封闭集合装不下密码。
  它必须是字符串数组。注意它**只对字面量生效**：`env:VOICE` 会被放行，然后带着
  环境里的任何东西到达插件，所以**插件自己也要再校验一遍**。

这个例子故意不带凭据。真要带的时候，在那个参数上写 `"secret": true`——它必须是
**真正的 JSON 布尔值**，`"true"` 和 `1` 都被读成缺省的 `false`，而 `false` 正是
让「拒绝写明文」那条规则失效的东西。

### 1.3 插件读到什么

Polter 写**一行 JSON** 然后关闭 stdin。形状由 `notify.body`
（`src/poltergeist/notify.zig:149`）加上 `Plugin.call` 拼的 `params` 组成：

```json
{
  "event": "authorisation",
  "title": "worker-core needs a decision",
  "body": "It has been stopped on a tool authorisation prompt for 12 minutes.",
  "terminal": "0x9491465653644ed0",
  "terminal_name": "✳ Write retry.py",
  "at_ms": 1786819271275,
  "params": { "voice": "Ava" }
}
```

- **`event` 只有两个取值**：`"scheduling"` 和 `"authorisation"`
  （`notify.Reason`）。`scheduling` 是「继续 / 换方向 / 收工」这类总管自己也能
  答的问题，落在 `poltergeist-notify-window` 之外时根本不会发给你；
  `authorisation` 是有人停在授权提示上，**任何时候都发**，因为没人能替他按。
  收到不认识的 `event` 应当直接退出 0 并忽略——将来加事件只加取值，不改形状。
- **`params` 只有一个对象，没有第二个。** 里面每个值都已经过 `secret.resolve`，
  插件读到的都是可以直接用的值：配置里写的是 `cmd:op read …`，到这里已经是那条
  命令的输出。**插件永远不该看见引用本身。**
- `terminal` 是十六进制字符串，`at_ms` 是 Unix 毫秒。

### 1.4 `say.py`

**把「解析和判断」跟「真的发出去」分成两半**，这是下一节能自测的全部原因。

```python
#!/usr/bin/env python3
"""Say the notice out loud.

Polter writes one line of JSON on stdin and closes it. Exit 0 means the
message got to the user; anything else means it did not.
"""

import json
import subprocess
import sys


def deliver(notice, params):
    """Everything that touches the outside world lives here."""
    line = notice.get("title", "")
    if notice.get("event") == "authorisation":
        line = "Authorisation needed. " + line

    subprocess.run(["say", "-v", params.get("voice", "Alex"), line], check=True)


def handle(line):
    """Everything that does not. This is the half the self-test drives."""
    try:
        notice = json.loads(line)
    except ValueError as exc:
        sys.stderr.write("desktop-say: not JSON: %s\n" % exc)
        return 1

    params = notice.get("params", {})
    if "voice" not in params:
        sys.stderr.write("desktop-say: no voice configured\n")
        return 1

    try:
        deliver(notice, params)
    except Exception as exc:
        sys.stderr.write("desktop-say: could not speak: %s\n" % exc)
        return 1

    return 0
```

加上一个入口（自测部分在 §2.2）：

```python
if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        sys.exit(self_test())
    if sys.argv[1:]:
        sys.stderr.write("usage: say.py [--self-test]\n")
        sys.exit(2)
    sys.exit(handle(sys.stdin.readline()))
```

**Polter 从不传参数**（`Plugin.run` 的 `argv` 只有 `exec` 一项），所以「无参数
时说协议、有参数时是开发者在手动跑」这个划分是安全的，`archive.py` 用的就是它。

三条宿主侧的语义，写代码时按它们来：

| | |
| --- | --- |
| **退出码 0 = 送达**，非 0 = 失败 | `Plugin.run` 结尾：`if (code == 0) .done else .refused` |
| **stdout 被忽略** | `.stdout = .ignore`。插件没有话要对宿主说 |
| **stderr 进 Polter 日志** | `.stderr = .inherit`。想解释失败原因就写这里 |

**失败不重试。** 配了多个插件就是多条独立的路，任何一条通了就够了——这比在单条
路上重试更有用（[plugins.md](plugins.md)「失败怎么办」）。

### 1.5 打开它

Polter 只扫目录，**开没开在插件自己的设置文件里**：

```text
$XDG_CONFIG_HOME/polter/plugins/desktop-say.json
```

```json
{ "enabled": true, "params": { "voice": "Ava" } }
```

**没有这个文件就是没开。** `Settings.write` 建它时用 0600。

也可以让总管来开：`plugin_configure`。它能把插件**打开**、能设清单声明过的参数
——但不能关、不能写 `cmd:`、不能往标了 `secret` 的参数里写明文（见 §4）。

> **注意这个文件是被整份重写的。** `Settings.read` 只认得 `enabled` 和 `params`
> 里的**字符串**值；别的键、非字符串的值，读的时候被丢掉，写回去的时候就此消失。
> 手写时不会碰到（写的人就是读的人），但 `plugin_configure` 让 agent 也能触发它。

---

## 二、不启动 Polter 怎么测

**这是本篇对开发者最有用的一节。** 起 Polter、等一次真的通知、再看日志——这条
回路一轮几分钟，而且失败信息只有一句 `plugin desktop-say: ...`。不必这样。

### 2.1 最快的一层：手工喂一行

`notify` 插件的全部输入就是一行 JSON。所以：

```console
$ echo '{"event":"scheduling","title":"t","body":"b","params":{}}' | ./say.py
desktop-say: no voice configured
$ echo "EXIT=$?"
EXIT=1
```

> **退出码不要经过管道。** `./say.py | tail; echo $?` 拿到的是 `tail` 的退出码。
> 要么像上面这样让插件在管道末端，要么写
> `cmd > /tmp/x.log 2>&1; echo "EXIT=$?"`。

这一层能验的东西比看上去多：JSON 解析、参数缺失、退出码、stderr 上写了什么。
**把它写进你的 Makefile 或一个 `.sh`，每次改完就跑。**

### 2.2 第二层：插件自带 `--self-test`

手工喂一行验不了的是**分支**：凭据缺了怎样、下游抛异常怎样、重复的输入怎样。
仓库里的 `plugins/chat-archive/archive.py` 给了范式，**推荐照抄这个形状**：

- 它有一个 `--self-test`（`archive.py:1140`），无参数时才说协议
  （`main` 的第一行就是 `if not argv: return run()`）；
- 自测**只驱动纯逻辑那一半**，把真正落地的那一半换成桩
  （`archive.py` 里叫 `_Stub` / `_Thrower` / `_claiming`）；
- 每条断言有名字，失败时打印 `expected` / `got` 并**以非 0 退出**——所以它能直接
  进 CI；
- 所有落地目标都在一个 `tempfile.mkdtemp()` 之下，**在任何文件被打开之前**就先建
  好，自测跑完不会在真实目录里留下东西。

照着给 `say.py` 写一个：

```python
def self_test():
    ok = True

    def check(name, got, want):
        nonlocal ok
        if got != want:
            ok = False
            sys.stdout.write("FAIL  %s\n  want %r\n  got  %r\n" % (name, want, got))

    global deliver
    spoken = []
    deliver = lambda notice, params: spoken.append((notice["title"], params["voice"]))

    check("a well-formed notice is delivered",
          handle('{"event":"scheduling","title":"t","body":"b","params":{"voice":"Ava"}}'),
          0)
    check("and it reached the delivery half", spoken, [("t", "Ava")])

    check("a notice with no voice configured fails",
          handle('{"event":"scheduling","title":"t","body":"b","params":{}}'), 1)
    check("garbage on stdin fails rather than raising", handle("not json"), 1)

    def boom(notice, params):
        raise RuntimeError("the speech synthesiser is having a day")

    deliver = boom
    check("a delivery that throws is a failed notification, not a traceback",
          handle('{"event":"scheduling","title":"t","body":"b","params":{"voice":"Ava"}}'),
          1)

    sys.stdout.write("ok\n" if ok else "")
    return 0 if ok else 1
```

跑起来（这是本篇作者在本机实际跑过的输出，stderr 是插件自己写的，属于预期）：

```console
$ ./say.py --self-test
desktop-say: no voice configured
desktop-say: not JSON: Expecting value: line 1 column 1 (char 0)
desktop-say: could not speak: the speech synthesiser is having a day
ok
$ echo "EXIT=$?"
EXIT=0
```

**为什么这个形状值得抄，而不是去写一个 pytest**：插件是要被**复制到别人机器上**
的一个目录，`<resources>/ghostty/polter/plugins/` 里只装非 `.md` 文件
（`src/build/GhosttyResources.zig:150-154`）。自测藏在插件自己里面，意味着拿到插件的
人不用装任何东西就能验它还能不能跑——这在「凌晨三点通知没发出来」的时候是唯一
还能用的诊断手段。

### 2.3 第三层：真的发一次

前两层都过了，还剩一件只有真环境能答的事：凭据能不能解析、对面收不收。
总管的 `plugin_test` 干的就是这个——它**真的发一条**，用 Polter 自己的措辞，
**不管当时几点**。所以用一次，慎重地用，而且**要在你需要它的那一晚之前用**。

（`plugin_test` 对 `archive` 类不启动任何东西：它已经在跑并且握着游标，起第二份
会去推同一个游标。回来的是正在跑的那个的近况，那才是「为什么什么都没存档」的
答案。）

---

## 三、`archive` 类：常驻的那种

`kind` 改成 `"archive"` 之后，变的不是清单格式，是**你在跟什么东西对话**。
权威是 `src/poltergeist/Archive.zig` 和 `Cursor.zig`，[storage.md](storage.md)
是完整规则；这里只讲写插件时立刻会撞上的四件事。

### 3.1 它不退出

进程随 Polter 结束。stdin 是一条**行分隔 JSON 流**，一行一批；每读一行**回一行
确认**。所以：

| | `notify` | `archive` |
| --- | --- | --- |
| 生命周期 | 一次一进程 | 常驻 |
| stdin | 一行，写完即关 | 流，一行一批 |
| stdout | **被忽略** | **是协议通道** |
| 怎么判成败 | 退出码 | 每行的确认 |

**`archive` 的 stdout 只能出现确认行。** 写进去别的任何东西都会被判成失当并杀掉
进程——所以插件起的子进程（比如 `psql`）必须自己接管道读，**绝不能 inherit**。
stderr 仍然是 inherit 的，那才是插件说话的地方。

### 3.2 第一行是握手，不是数据

Polter 先写一行（`Archive.renderHello`，`Archive.zig:494`）：

```json
{"hello":1,"plugin":"chat-archive","cursor":0,"groups":["*"],
 "params":{"backend":"file","path":"/Users/you/archive/chat.jsonl"}}
```

（真实的握手是**一行**，这里为了排版折了行。）

- `hello` 是协议版本号，**是数字而不是标记**，这样不认识这个版本的插件可以直接
  退出，而不是去猜后面那行的形状。
- `cursor` 是**宿主认为**存到哪了。
- **`params` 在整场对话里只出现这一次**，后面每一批都不再重复。

> **示例里的 `params` 要写成真能跑通的一组。** 上面这行早先只有
> `{"backend":"file"}`，而 `chat-archive` 的 `file` 后端**要求 `path`**：绝对路径、
> 各段只含字母数字点杠下划线、以 `.jsonl` 结尾、**父目录必须已经存在**
> （`archive.py` 的 `resolve_config`，`RE_EXPORT` 在 `archive.py:74`）。缺了它
> `resolve_config` 抛 `ConfigError`，`Session` 接住之后写一行 stderr 并
> **`sys.exit(2)`——在回出任何握手确认之前就退了**。
>
> 值得注意的是**宿主这边不拦**：清单里 `required` 只有 `backend`，所以用户或
> `plugin_configure` 真的可以只配一个 `backend`，Polter 也真的会把上面那种残缺
> 的握手写出去，然后插件当场 exit 2。**是插件在拒，不是 Polter 不写。**
>
> 这条之所以值得单独记：那一行的作用是展示**握手行的形状**，读者不会去校验它的
> `params` 合不合法——正因为如此，一个不可能跑通的示例不会被任何人发现，直到有人
> 照抄它去搭测试桩，拿到一个 exit 2，而示例里没有任何东西提示他缺了什么。
> **示例代码是会被执行的文档**，按能跑通来写。
>
> 同一件事的另一半，写 archive 插件时必须知道：**宿主只把用户配了的键写进
> `params`，不补 schema 里的 `default`。** `Archive` 拿到的 `params` 就是
> `<key>.json` 里那份（`src/App.zig:946` 的 `.params = settings.params`），
> `Plugin.zig` 里没有任何读 schema `default` 的代码。所以上面这行里没有
> `stream` —— `chat-archive` 的 `"stream": "default"` 是**插件自己**在
> `resolve_config` 里补的（`archive.py` 的 `DEFAULTS`）。
> **清单里写 `default` 是给设置界面和读清单的人看的，不是给宿主执行的；
> 缺省值要在你自己的代码里兜。**

之后每一批（`Archive.writeBatch`，`Archive.zig:439`）：

```json
{"cursor":0,"through":5,"messages":[
  {"seq":3,"at_ms":1786819271275,"group":"build","author":"worker-core","text":"..."},
  {"seq":5,"at_ms":1786819281002,"group":"build","author":"polter","summary":true,"text":"..."}
]}
```

`summary` 只在为真时出现——它标记的是被 `group_compact` 压掉一段历史后留下的那条
概要。`messages` 已经按 `wants.groups` 筛过，插件没有第二条通道能拿到别的群。

确认行是 `{"ok":true}` / `{"ok":true,"cursor":N}` / `{"ok":false}`，一行，64KB
以内（`ack_max_bytes`）。

### 3.3 游标：重启之后怎么续上

游标写在 `$XDG_STATE_HOME/polter/plugins/<key>.cursor`，**跟设置文件分在两棵树
里**，这不是整理癖（`Cursor.zig` 开头讲得很清楚）：`<key>.json` 是配置，用户手
写、进 dotfiles 仓、在机器之间同步；游标不是——它是**这台机器**这个日志文件里的
一个位置，同步到另一台机器上会让那台机器静默跳过它自己还没存档的全部消息。放在
state 里还白拿一条：它和 `polter/chat/chat.jsonl` 在同一棵树下，用户清 state 时
两个一起没，**游标不可能比它指向的文件活得久**。

握手时插件可以在确认里回一个 `cursor` 来**纠正**宿主。规则只有一条，但它是整个
存档能不能信的地基：

> **游标只许往回，不许往前。**

往前是「我存了你没给我的东西」。宿主认下它就意味着中间那些消息**再也不会被交给
任何人，而且没有任何迹象**。所以插件启动时该做的是：问自己的后端「我实际存到
哪」，比宿主给的 `cursor` 小就回报，大就闭嘴。`archive.py` 的自测第 5、6 条
（「a handshake rewinds a cursor that ran ahead」/「a handshake behind ours is
answered without a cursor」）测的正是这两个方向。

### 3.4 重复是常态，去重是你的事

一批可能被重放（进程死在写确认之前，宿主并不知道它成没成）。
`archive.py` 的自测第 3 条是「a replayed batch is acknowledged and stored once」
——**照抄这条**。做法是让 `seq` 参与主键；`chat-archive` 还把 `stream` 参数放进
主键，这样两台机器写同一个库不会撞，本地日志被清掉之后也能从头再来。

`from` 字段**故意不在批次里**：它是 `Bus.Id`，只在一次进程运行内有效，存进数据库
就是一个指向不存在的东西的外键，还会引来第二天就错的 join。`author` 在日志被写下
那一刻就已经解析成名字了，它明天仍然是同一个意思。

### 3.5 还有几件不写就会踩的

- **心跳**：安静满 30 秒（`heartbeat_ms_default`）会喂一个空批次。这是轮询模型
  唯一的弱点的补丁——一个在没人说话时死掉的子进程，否则要等到有人说话才会被发现。
  **插件必须把空 `messages` 的批次也正常确认**，别当成错误。
- **`{"ok":false}` 是「现在不行」**，是插件的权利。但连着三次
  （`max_soft`）之后宿主会降速，不再全速重投同一批。
- **`timeout_ms` 只界定一次交换**（写一行 + 读一行），不是整场会话的寿命；交换
  之间宿主会把 deadline 撤掉。
- **`wants` 必须写。** 没有 `wants` 的清单等于什么都不要，而且不是悄悄不干活：
  存档插件会**根本不启动**，并被点名警告。缺省当成 `["*"]` 会让一份什么都没声明
  的清单拿到全部群，权限声明存在的意义当场归零。
- **`wants` 是插件级而不是后端级的，所以写并集。** `chat-archive` 选 `file` 后端
  时既不联网也不起 `psql`，声明仍然照最大能力写——会随配置缩水的声明，审计没法拿
  它当依据。

---

## 四、常见错误

按「第一次写插件最容易撞上」的顺序排。每条都给了在宿主侧的确切表现，这样你能从
日志反推回来。

### 4.1 参数没在清单里声明

**表现**：手写设置文件时它照样被传给插件（`Settings` 读什么就传什么），但
`plugin_configure` **拒绝设一个清单没声明过的名字**。原因不是洁癖：一个不在
schema 里的名字**无法被判定是不是 secret**，放行它等于给出一条绕过明文规则的路。
同理，清单完全没声明 `params` 的插件，通过工具面**一个参数都不能设**。

**另一面**：`params` 写坏了不会让插件消失。`params` 不是对象、`properties` 不是
对象、某一项不是对象、名字是空串、声明超过 64 个（`max_specs`）——宿主一律读成
「少声明了一些」，打一句 warn，插件照常加载（`Plugin.specsOf`）。这条是往安全那
一侧倒的：**没被声明的参数是工具面不会去设的参数**。但对插件作者来说它很难发现，
所以**改完清单看一眼 Polter 的日志有没有 warn**。

### 4.2 凭据写了明文

**手写自己的文件里明文完全合法**，没人拦你——总有人只想把 webhook 贴进去就用。
但**工具面不许**，而这条不对称正是工具面的要点：**同一个文件、同一个解析器，
区别在于是谁的手。**用户往自己机器上自己的文件里写自己的密码，是他的事；一个
agent 替他决定把一段明文落到盘上，不是。

`plugin_configure` 遇到标了 `"secret": true` 的参数收到明文时，回的是
`Guard.refusal.plaintext_secret`（`rpc.zig:1501`），话说完整了：给一个引用，
`env:NAME` / `keychain:service/account` / polter 目录下的 `file:`；用户还没把密码
放到任何地方的话，**让用户去放，那是他的事不是 agent 的事**。

读那一侧另有一条兜底：**明文值一律不回显**，不看 `secret` 标没标（枚举参数除外，
而枚举装不下密码）。也就是说 `secret` 只用来**收紧写入**，从不用来**放宽读出**
——一个作者漏标的参数，最坏是能被 agent 写进明文，而不是能被 agent 读出来。

### 4.3 `cmd:` 被拒

**四种引用前缀里，`cmd:` 是唯一一个工具面不写的**（`secret.Prefix` 四个取值：
`env` / `file` / `keychain` / `cmd`；拒绝在 `rpc.zig:1558`）。

理由值得完整读一遍，因为它不是「命令危险」这种笼统的话：**`cmd:` 是 Polter
稍后自己去执行的一条命令，执行的那一刻，授权这次工具调用的东西早就结束了。**
搬运数据和引入新代码不是一回事。所以正确的做法是**把那一行描述出来，让用户自己
写**——`Guard.refusal.cmd` 的最后一句就是这个意思。

**手写的文件里 `cmd:` 完全正常，而且是推荐写法**：它一条就覆盖了全部密码管理器
（1Password 的 `op`、pass、Bitwarden 的 `bw`、gopass、`security`、`secret-tool`），
Polter 不需要为其中任何一个写适配。`keychain:` 单独列出来只是因为它是零依赖的
默认选项，它的实现本身就是 `cmd:` 的一个内置特例。

同一族的另外三条拒绝，撞上的时候别以为是 bug：

| 情形 | 拒绝 |
| --- | --- |
| `file:` 指到 polter 的 config / state 目录之外 | `file_outside` |
| `file:` 用了打头的 `~/` | `file_tilde` —— 展开发生在调用时，而检查发生在写入时，一个此刻判不了的条件只能拒绝。**手写的文件里 `~/` 会被正常展开**（只认打头的 `~/`） |
| 把一个已经配好的凭据参数**指到别处** | `repointing` —— `env:NOT_A_REAL_NAME` 是个格式完好的引用，每条规则都过，失败在几小时后到达：一条静静没发出去的通知。那和把通道关掉是一回事 |

还有两条形状相同的：**关掉插件**（`switching_off`）和**清空一个 required 参数**
（`clearing_required`）都被拒，因为后者是前者换个名字。通知是用户在挂机场景里
唯一的知情通道，让 agent 能掐掉它，等于让它能给自己关灯。

> **诚实的残余**：一个同时能写文件的 agent 不受这些约束中的任何一条——它直接改那个
> JSON 就是了。这些拒绝买到的不是「挡住能写文件的 agent」，而是一条不变量：
> **装一个 MCP server，绝不会因此多出一份它自己的 harness 本来放在授权闸后面的
> 权限。**

### 4.4 退出码不为 0

**`notify`**：这次通知记为失败，写日志，**不重试**，**不影响别的插件**。配了多个
插件就是多条独立的路。所以插件里**任何异常都要接住并转成一个非 0 退出码加一行
stderr**，别让 traceback 走到底——traceback 也会让退出码非 0，但它写在 stderr 上
的东西是给写插件的人看的，不是给凌晨三点看日志的人看的。

**`archive`**：进程退出就是它死了。宿主会重起它，退避从 1 秒开始
（`backoff_start_ms_default`）、封顶 60 秒（`backoff_max_ms`）；连续失败 10 次
（`max_failures`）之后转入休眠，15 分钟后再试
（`dormant_retry_ms_default`）。**休眠不是永久的**：存档插件起不来的常见原因
——数据库down 了、笔记本掉线了、vault 锁了——都会自己好，而要求用户重启 Polter
才能恢复，等于「存档坏掉的时长正好等于没人看着的时长」。**日志在这期间不丢**，
游标没动，重起之后从原地续上。

另外：**活够 60 秒（`settle_ms_default`）才算「起来过」**，退避才会被重置。一个
握完手就死的插件，否则能把退避永远压在 1 秒。

### 4.5 其余几条小的

- **`exec` 没有执行位，或者 shebang 不成立** → `unstartable`，日志一句
  `could not start`。没有 shell 兜底。
- **两个目录声称同一个 `key`** → 后一个被跳过并警告。两份拷贝会共用设置和游标。
- **`kind` 写了个宿主不认识的值** → 跳过这个插件并警告，**不是致命错**。这是
  故意的：为将来的 kind 写的清单，在今天的构建上应当被跳过而不是让启动失败。
- **插件目录里放了 `.md` 以外你不想发出去的东西** → 仓库的 `plugins/` 是被整个
  装进 `<resources>/ghostty/polter/plugins/` 的，**只排除 `.md`**
  （`src/build/GhosttyResources.zig:150-154`）。
- **超时** → 判 `timed_out` 并杀进程。一个连不上网的插件会一直挂着，而挂机场景里
  没人会去发现它。

---

## 交付前自检

- [ ] `plugin.json` 里 `key` == 目录名。
- [ ] `exec` 有执行位，shebang 成立，`./<exec> --self-test` 能跑。
- [ ] 无参数时说协议；**Polter 从不传参数**。
- [ ] 每个凭据参数标了 `"secret": true`，而且是**真布尔值**。
- [ ] `wants` 写的是**并集**，不是当前配置能用到的那部分。
- [ ] 所有异常都被接住并转成非 0 退出码 + 一行 stderr。
- [ ] `archive`：stdout 上除了确认行没有任何东西；子进程的 stdout 没有 inherit。
- [ ] `archive`：空批次（心跳）被正常确认；重放的批次只存一次；游标只往回报。
- [ ] 改完清单看过 Polter 日志有没有 warn。
