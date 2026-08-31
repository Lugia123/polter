# 随构建装出去的插件

一个插件一篇。**协议、清单格式、权限声明、凭据、怎么照着写一个**，全在
[../plugins.md](../plugins.md)；这里只讲装出去的插件各自是什么、参数是什么、
怎么在不启动 Polter 的情况下验它。

| | 订阅 | 做什么 |
| --- | --- | --- |
| [archive.md](archive.md) | `chat` | 把每条群聊消息另存一份到文件系统，一天一个文件，所有群一条时间线 |
| [provisioning.md](provisioning.md) | `provision` | **八个**：把 Polter 的 MCP 端点和 skill 装给 Claude Code / Codex / Gemini / Qwen Code / Kimi / iFlow / opencode / DeepSeek-TUI。一份实现，八份声明；**默认只开 Claude Code** |

装出去的是 `src/build/GhosttyResources.zig` 里写出来的一份名单，不是对 `plugins/`
做 glob——理由见 [../plugins.md](../plugins.md)。

**没有随构建装出去的通知插件。** 通知渠道有几十种，内置任何一种都会立刻过时，
所以那一类从第一天起就是用户自己放进 `$XDG_CONFIG_HOME/polter/plugins/` 的东西；
照着写一个见 [../plugins.md](../plugins.md) 第九节。

薄客户端（连 socket、发首行、一行一个 JSON）在 `plugins/_sdk/`：`polter.py` 只用
标准库，`polter.sh` 需要一个会说 unix socket 的 `nc -U`。**两份都没有一个按工具
命名的函数**，理由见 [../plugins.md](../plugins.md) 第三节。
