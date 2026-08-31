# demo-archive

**订阅 `chat`**：把每条群聊消息另存一份到文件系统，**一天一个文件，所有群排在
一条时间线上**。

**这是一个例子，而且是仓库里唯一一个。** 它不随构建装进 app bundle——`demo-`
前缀就是这个意思，见 [README.md](README.md)。要跑它得自己拷进配置目录，见下面
「它不预装」。它留在仓库里的理由是它是这棵树上**唯一一份完整的常驻协议实现**，
所以协议的测试就跑它（`Resident.zig`、`rpc.zig` 都嵌了它的字节）。

```text
~/.local/state/polter/archive/
  2026-08-28.jsonl
  2026-08-29.jsonl
```

代码在 `plugins/demo-archive/`，宿主一侧在 `src/poltergeist/Resident.zig` 与
`Feed.zig`。协议全文见 [../plugins.md](../plugins.md) 第二节。

## 它是「额外的一份」，不是记录本身

核心自己写流（`chat/chat.jsonl`）和记录（`chat/<群>/<日期>.jsonl`），**这两份
不因这个插件存在或缺席而改变，也不作为它的数据源**——插件拿到的是 `Feed.zig` 上
的实时事件，它不认识任何路径。所以：

- 插件掉线、写不进去、被关掉，**核心的记录照样完整**；
- 反过来，这一份丢了多少是被数着的（`Feed.Subscription.Stats.dropped`）。

设计依据是 [../boundary.md](../boundary.md) 第一节和
[../storage.md](../storage.md)。

## 为什么按天而不按群

核心的记录是 `<群>/<日期>.jsonl`，回答的是「那摊活说了什么」。这一份是另一刀：
**一个晚上按发生顺序发生了什么，全在一个文件里**，`tail -f` 就能看。

[../gaps.md](../gaps.md) 记着一条反对——「插件不该在另一个路径上再写一份同样形状
的平文件」。那条反对针对的是 `chat-archive` 的 `file` 后端（已随它一起退场）：
同样的布局、同样的字段、换个路径，等于什么都没加。这个插件不落在那条反对里，
因为它写的是**另一种切法**，而且默认落点是**给你改指到别处的起点**，不是「本地
有没有一份记录」的兜底——那件事是核心的，永远不依赖插件。

## 订阅声明

```json
"wants": { "events": ["chat"], "calls": [], "groups": ["*"], "network": false, "exec": [] }
```

**`events` 是它之所以是一个存档插件的全部**。从前这里写的是 `"kind": "archive"`，
而 `kind` 同时决定生命周期和契约，于是每加一种就要在若干处穷举一遍——那个 bug 出
过两次。见 [../plugins.md](../plugins.md) 第一节。

`calls` 是空的：这个插件不调工具面上的任何东西。空就是一个都不能调。

## 参数

| | |
| --- | --- |
| `dir` | 落点目录，绝对路径或 `~/` 开头。缺省 `~/.local/state/polter/archive`（有 `XDG_STATE_HOME` 就用它） |
| `sign_key` | **凭据**（清单里标了 `"secret": true`）。填了它每行带一个 HMAC-SHA256；拿到它的人能改写存档再签一遍，所以工具面不许往里写明文。写引用：`env:` / `file:` / `keychain:` |

签名覆盖的是这一行**除 `hmac` 之外**的规范形式（键排序、无多余空格、UTF-8 原样）。
校验一行：解析、去掉 `hmac`、按同样规则重新序列化、算 HMAC 比对。**这不是加密**
——正文照样是明文——而是**让被改过的副本说得出自己被改过**。这一份常常落在比 state
目录更没人管的地方（同步盘、移动硬盘、公司共享），而一份没人能验的记录，在真需要
拿它当证据的那天等于没有。

`sign_key` 是清单里唯一标了 `"secret": true` 的参数，它同时是本仓那条「工具面拒绝
明文凭据」的安全测试**唯一的验证对象**（`src/build/SharedDeps.zig` 把这份清单编进
二进制，`rpc.zig` 里那条测试读它）——所以这个标注掉了，不只是这个插件变松，是那条
规则失去被检验的对象。测试自己也会在名单空掉时失败。

## 它不预装

**它曾经预装即开，现在不是。** 例子和随构建装出去的插件放在同一个目录下，而构建
那一步是对整个 `plugins/` 目录做的 glob，所以这个例子曾经进了每一份 bundle。现在
`GhosttyResources.zig` 里写的是一份**显式清单**，`demo-archive` 不在上面。

要跑它，把整个目录拷到配置目录下：

```sh
cp -R plugins/demo-archive ~/.config/polter/plugins/demo-archive
```

拷过去之后它自带的 `settings.json`（`{"enabled": true, "params": {}}`）就是它的
缺省，所以拷完即开。那只是**缺省**：`~/.config/polter/plugins/demo-archive.json`
存在就赢，**包括它写着「关」**。运行时永不写目录里那份。见
[../boundary.md](../boundary.md) 第二节与 `Plugin.Settings.readFirst`。

## `n` 和 `seq`：一个是游标，一个是幂等键

批次里每个事件带两个数，这个插件两个都用，用在不同的地方：

- **`n`** 是这个事件在宿主那条唯一的流里的位置。确认回去的是它，**去重也按它**
  （`n <= acked` 的直接跳过）。
- **`seq`** 是核心记下这条消息时盖的号，**写进文件里的是它**。`n` 只在这一次
  Polter 运行里有意义，一列 `n` 存在存档里是一个指向不了任何东西的外键。

## 握手要回话

宿主写的**第一行是握手**，而且它写之前就装上了 `timeout_ms` 的期限——所以握手
**也要回一行确认**（`{"ok":true}` 准备好了，`{"ok":false}` 现在还不行）。不回，
就是每 `timeout_ms` + 退避被杀一次、重起一次，无限循环，而插件自己看像在闲等。
这个插件有一版就是这么错的；接住它的是 `src/poltergeist/Resident.zig` 里那条测试
——它拿 `renderHello` 真正写出来的字节，跑**真正装出去的这个脚本**。

## python3，只用标准库

不用 pip、不用 venv、不用第三方库。理由按重要性：

1. **它必须真的解析 JSON，而 shell 做不对。** 要读的是 `events` 数组——嵌套对象、
   转义引号、CJK 的 `\uXXXX`、正文里可能含 `}`。用 `sed` 读它必然在某些输入上读
   错，而**读错的后果是回一个它其实没存的 cursor**，正是整套确认机制要防的那个
   静默的洞。
2. `jq` 能救 shell，但它是一个依赖，而且不在 stock macOS 里；`python3` 在。
3. 只用标准库意味着没有版本漂移，插件被拷到别人机器上仍然能跑。

## 确认之前先落盘

一批写完 `flush` + `fsync` 再回 `{"ok":true}`。**确认是一句承诺，而关于还在缓冲区
里的字节的承诺，这个进程自己退出一次就能毁掉。** 写到一半失败时只确认已经落盘的
那一条（`{"ok":true,"cursor":N}`，那个 N 取自这一批，按定义 ≤ `through`），一条都
没落就回 `{"ok":false}`——**宁可重发，绝不撒谎**。

## 不启动 Polter 怎么测

```console
$ ./archive.py --self-test
ok
$ echo "EXIT=$?"
EXIT=0
```

自测在 `mkdtemp()` 下跑，不会往真实目录里留东西；它验的是逻辑那一半：整批确认、
重发不重复写、心跳、**订阅之外的 kind 不落盘**、跨午夜的批次分文件、写到一半只
确认到落盘那一条、一条都没落就回 `{"ok":false}`、签名能被校验也能被改坏、以及
**清单里写的缺省值和代码里用的是同一个**。

手工喂一遍完整协议：

```console
$ printf '%s\n%s\n' \
  '{"hello":1,"plugin":"demo-archive","cursor":0,"events":["chat"],"groups":["*"],"calls":[],"params":{"dir":"/tmp/a"}}' \
  '{"cursor":0,"through":11,"events":[{"n":11,"kind":"chat","seq":110,"at_ms":1786819271275,"group":"build","author":"worker","text":"hi"}]}' \
  | ./archive.py > /tmp/x.log 2>&1; echo "EXIT=$?"
```

**stdout 只能出现确认行**——写别的会被宿主判成失当并杀掉进程。说话写 stderr，
那里进 Polter 日志。

## 多语言

`i18n/zh-Hans.json` 覆盖设置界面上要给人看的那几句；清单本身不变，值仍是英文
字符串。**MCP 的 `plugin_list` 一律用清单原文**，不跟随 locale——理由见
[../boundary.md](../boundary.md) 第四节。
