# archive

**`archive` 类插件的参考实现**：订阅实时事件，把每条群聊消息另存一份到文件系统，
**一天一个文件，所有群排在一条时间线上**。

```text
~/.local/state/polter/archive/
  2026-08-28.jsonl
  2026-08-29.jsonl
```

## 它是「额外的一份」，不是记录本身

核心自己写流（`chat/chat.jsonl`）和记录（`chat/<群>/<日期>.jsonl`），**这两份
不因这个插件存在或缺席而改变，也不作为它的数据源**——插件拿到的是 `Feed.zig` 上的
实时事件，它不认识任何路径。所以：

- 插件掉线、写不进去、被关掉，**核心的记录照样完整**；
- 反过来，这一份丢了多少是被数着的（`Feed.Subscription.Stats.dropped`）。

设计依据是 [docs/poltergeist/boundary.md](../../docs/poltergeist/boundary.md) 第一节。

## 为什么按天而不按群

核心的记录是 `<群>/<日期>.jsonl`，回答的是「那摊 Kairos 的活说了什么」。这一份是
另一刀：**一个晚上按发生顺序发生了什么，全在一个文件里**，`tail -f` 就能看。

[gaps.md](../../docs/poltergeist/gaps.md) 记着一条反对——「插件不该在另一个路径上
再写一份同样形状的平文件」。那条反对针对的是 `chat-archive` 的 `file` 后端（已随
它一起退场）：同样的布局、同样的字段、换个路径，等于什么都没加。这个插件不落在
那条反对里，因为它写的是**另一种切法**，而且默认落点是**给你改指到别处的起点**，
不是「本地有没有一份记录」的兜底——那件事是核心的，永远不依赖插件。

## 预装即开

目录里带一份 `settings.json`（`{"enabled": true, "params": {}}`）。那是**发行带的
缺省**，只在你没有自己那份文件时生效；`~/.config/polter/plugins/archive.json`
存在就赢，**包括它写着「关」**。运行时永不写发行那份。见
[boundary.md](../../docs/poltergeist/boundary.md) 第二节与 `Plugin.Settings.readFirst`。

## 参数

| | |
| --- | --- |
| `dir` | 落点目录，绝对路径或 `~/` 开头。缺省 `~/.local/state/polter/archive`（有 `XDG_STATE_HOME` 就用它） |
| `sign_key` | **凭据**（清单里标了 `"secret": true`）。填了它每行带一个 HMAC-SHA256；拿到它的人能改写存档再签一遍，所以工具面不许往里写明文。写引用：`env:` / `file:` / `keychain:` |

签名覆盖的是这一行**除 `hmac` 之外**的规范形式（键排序、无多余空格、UTF-8 原样）。
校验一行：解析、去掉 `hmac`、按同样规则重新序列化、算 HMAC 比对。

## 握手要回话

宿主写的**第一行是握手**，而且它写之前就装上了 `timeout_ms` 的期限——所以握手
**也要回一行确认**（`{"ok":true}` 准备好了，`{"ok":false}` 现在还不行）。不回，
就是每 `timeout_ms` + 退避被杀一次、重起一次，无限循环，而插件自己看像在闲等。
这个插件有一版就是这么错的；接住它的是 `src/poltergeist/Archive.zig` 里那条测试
——它拿 `Archive.renderHello` 真正写出来的字节，跑**真正装出去的这个脚本**。

## 不启动 Polter 怎么测

```console
$ ./archive.py --self-test
ok
$ echo "EXIT=$?"
EXIT=0
```

自测在 `mkdtemp()` 下跑，不会往真实目录里留东西；它验的是逻辑那一半：整批确认、
重发不重复写、心跳、跨午夜的批次分文件、写到一半只确认到落盘那一条、一条都没落
就回 `{"ok":false}`、签名能被校验也能被改坏、以及**清单里写的缺省值和代码里用的
是同一个**。

手工喂一遍完整协议：

```console
$ printf '%s\n%s\n' \
  '{"hello":1,"plugin":"archive","cursor":0,"groups":["*"],"params":{"dir":"/tmp/a"}}' \
  '{"cursor":0,"through":11,"messages":[{"seq":11,"at_ms":1786819271275,"group":"build","author":"worker","text":"hi"}]}' \
  | ./archive.py > /tmp/x.log 2>&1; echo "EXIT=$?"
```

**stdout 只能出现确认行**——写别的会被宿主判成失当并杀掉进程。说话写 stderr，
那里进 Polter 日志。

## 多语言

`i18n/zh-Hans.json` 覆盖设置界面上要给人看的那几句；清单本身不变，值仍是英文字符串。
**MCP 的 `plugin_list` 一律用清单原文**，不跟随 locale——理由见
[boundary.md](../../docs/poltergeist/boundary.md) 第四节。

## 相关

- 协议全文：[docs/poltergeist/storage.md](../../docs/poltergeist/storage.md)
- 宿主契约：[docs/poltergeist/plugins.md](../../docs/poltergeist/plugins.md)
- 照着写一个：[docs/poltergeist/writing-a-plugin.md](../../docs/poltergeist/writing-a-plugin.md)
- 宿主一侧的代码：`src/poltergeist/Archive.zig`、`src/poltergeist/Feed.zig`
