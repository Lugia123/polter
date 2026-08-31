# 随构建装出去的插件

一个插件一篇。**协议、清单格式、权限声明、凭据、怎么照着写一个**，全在
[../plugins.md](../plugins.md)；这里只讲装出去的插件各自是什么、参数是什么、
怎么在不启动 Polter 的情况下验它。

| | 订阅 | 做什么 |
| --- | --- | --- |
| [provisioning.md](provisioning.md) | `provision` | **八个**：把 Polter 的 MCP 端点和 skill 装给 Claude Code / Codex / Gemini / Qwen Code / Kimi / iFlow / opencode / DeepSeek-TUI。一份实现，八份声明；**默认只开 Claude Code** |

## 例子：`demo-` 前缀的不装出去

| | 订阅 | 做什么 |
| --- | --- | --- |
| [demo-archive.md](demo-archive.md) | `chat` | 把每条群聊消息另存一份到文件系统，一天一个文件，所有群一条时间线 |

`plugins/` 下面 `demo-` 开头的目录是**例子**：它们留在仓库里给人照着写，**不进
app bundle**。装出去的名单是 `src/build/GhosttyResources.zig` 里写死的一份清单，
不是对 `plugins/` 做 glob——写死是因为漏加一行的后果（新插件不装、一眼看得见）比
漏排除一行的后果（例子被装进每个人的 bundle、看不见）小得多，而后者真的发生过。

要跑一个例子，把它整个目录拷进 `$XDG_CONFIG_HOME/polter/plugins/`；配置目录下的
插件和 bundle 里的插件加载方式完全一样。

**没有随构建装出去的通知插件。** 通知渠道有几十种，内置任何一种都会立刻过时，
所以那一类从第一天起就是用户自己放进 `$XDG_CONFIG_HOME/polter/plugins/` 的东西；
照着写一个见 [../plugins.md](../plugins.md) 第九节。

薄客户端（连 socket、发首行、一行一个 JSON）在 `plugins/_sdk/`：`polter.py` 只用
标准库，`polter.sh` 需要一个会说 unix socket 的 `nc -U`。**两份都没有一个按工具
命名的函数**，理由见 [../plugins.md](../plugins.md) 第三节。
