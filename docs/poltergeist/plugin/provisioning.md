# 供给插件（七个，一份实现）

`claude-code` `codex` `gemini` `qwen-code` `kimi` `opencode` `deepseek`

七个插件做的是同一件事，实现只有一份：`plugins/_sdk/provision.sh`。每个插件本身
是一份**声明**——去 PATH 上找哪个二进制、这家怎么注册 MCP、它把 skill 放在哪。
`plugins/claude-code/provision.sh` 五十来行，其余的更短。

**为什么各家仍是独立插件而不是一个带宿主表的插件**：合成一个的话，第一个失败会
连坐其余六个，而且 `wants.exec` 得声明全部七个二进制——等于每台机器都在声明它用
不到的六个 CLI。共用的是实现，不是身份。各自有自己的开关、自己的日志、自己在插件
界面里的一行。

选型、各家的落点、以及为什么不做纯 IDE 的那些，见
[../provisioning.md](../provisioning.md)。

## 默认只有 Claude Code 是开的

`enabled` 本来就默认 `false`，七个插件各自带一份 `settings.json` 把意图写在文件
里。只有 `claude-code` 那份是 `true`。

代价是实打实的：**一个装了 Codex 的人打开 Polter，什么也不会发生，而且没有任何东
西告诉他本可以发生什么。** 这是个已知的缺口，补法在 [../provisioning.md](../provisioning.md)
第六节（探测到二进制就提示一次），**还没做**。

## 三种状态，写在日志里

`claude-code` 曾经在二进制不在 PATH 上时静默退出 0。一个插件时那是对的；七个之
后，日志里「你没装这个 CLI」和「装了但注册失败」长得一模一样——而那正是 Dock 启
动那个 bug 藏了几个月的地方。所以状态是有名字的，`grep` 得到：

| 日志 | 意思 | 用户会看到什么 |
| --- | --- | --- |
| `status=absent` | 二进制不在 PATH 上 | 什么都不用做，**不是问题** |
| `status=provisioned` | 真写了东西 | 没写就不出声，避免八行空话 |
| `status=failed step=<mcp\|skills>` | 二进制在，某一步没成 | **通知**，说清哪一步 |

只有 `failed` 会主动找到人，走 `polter_tell`，所以它必须写在本批次的应答之前。

## 两族：调命令的，和改文件的

| 族 | 怎么注册 | 谁 |
| --- | --- | --- |
| 有 `x mcp add` | 调命令，不碰文件 | claude-code, codex, gemini, qwen-code, kimi |
| 只能改 JSON | 读→改→原子换 | opencode, deepseek |

**这两件不是同一件事换个帽子。** 有子命令的 CLI 自己拥有那个文件——格式、加锁、
迁移都是它的事；没有子命令的，这些就成了我们的债。所以第二族走
`polter_json_edit`，它保证三条：

1. **解析不了就绝不写。** 因为读不懂而覆盖别人的配置，是唯一不可挽回、且确实是我
   们的错的那种结局。
2. **原子替换。** 临时文件写好再 `rename`。写了一半的配置是一个起不来的 CLI。
3. **文件不存在等于空对象，不是错误。** 装了 CLI 但从没配过的第一次。

解析用 `python3`。用 `sed` 手搓 JSON 编辑，就是一份配置在凌晨三点长出一个多余逗
号的过程，而这是用户的文件。没有 `python3` 时**大声失败**，不退而求其次：一个拿
不到 Polter 工具的 agent 只是失望，一个被写坏的配置是一台坏掉的机器。

## 三家形状不一样，抄错就静默失效

- **Codex**：TOML，表名是 `mcp_servers`（**下划线**），别家是 JSON 的 `mcpServers`。
- **opencode**：键是 `mcp`，条目里 `command` 是**数组**，不是 `command` 字符串加
  `args`。
- **Qwen Code 是 gemini-cli 的 fork**，所以和 Gemini CLI 同形。这不是可以高兴的
  巧合——**上游一变，这两家一起坏**。修好一个的人应该去看另一个。（iFlow CLI 是
  这一形状的第三家，2026-04-17 停止服务，插件随之删除。）

## skill 装不了不是失败

`qwen-code` `kimi` `opencode` `deepseek` 的 skill 目录**没有核实过**，所以
`host_skills_dir` 返回空，那一步跳过。**这是降级，不是失败**：

- skill 正文本来就能通过 `skill_read` 这个 MCP 工具拿到；
- `initialize` 的 `instructions` 里那张工具族地图是协议字段，**任何 MCP 客户端都吃**。

往猜出来的目录里写文件，比一个字都不写更糟——那是留在别人机器上的垃圾，而且没人
会来收。核实了再填，别提前填。

## 为什么需要它

Polter 把 socket 路径和 token 放进每个终端的环境，这是 agent **够得着**它所需的
全部。但那不会让工具出现：一个 MCP 客户端只加载它被配置过的 server，所以一个在
没人注册过的目录里的 agent，拿着 socket、拿着 token，两样都用不上。skill 同理
——runtime 拿用户说的话去匹配它认识的 skill，一个它从没听说过的匹配不上。

**它是插件而不是核心里的 Zig**，因为「哪种形状是这个 runtime 认识的」对每个
agent CLI 都有不同的答案，而写死在核心里时，别人没有地方放他那个的答案。

## 它现在是常驻的

从前它是「启动时跑一次，看退出码」。现在没有 `kind` 了，
`"wants": {"events": ["provision"]}` 就是它之所以是一个 provisioning 插件的全部，
于是形状变成每个插件都有的那一个：

```text
host -> {"hello":1,"plugin":"claude-code","cursor":0,
         "events":["provision"],"groups":[],"calls":[],"params":{…}}
this -> {"ok":true}
host -> {"cursor":0,"through":3,"events":[{"n":3,"kind":"provision",
         "exe":"/path/to/polter","version":"1.2.3",
         "version_key":"POLTER_REGISTERED","home":"/Users/you",
         "skills":[{"name":"supervising","path":"/…/supervising.md"}]}]}
this -> {"ok":true}
```

**代价，明说**：退出码非零从前会在第一个终端被构建的过程中，把一句话直接放到那块
屏幕上。现在没有任何同步的东西了，失败通过三条路到人那里——Polter 的日志、
`plugin_list` 的 `note`（说得出 `backing_off` / `dormant`，而且 agent 读得到）、
以及同步的 `plugin_test`。**没换来的是那句不请自来的屏幕提示。**

**换来的是重试**：答 `{"ok":false}` 之后宿主会退避并把同一个事件再给它一次。
从前一个 `claude` 正在升级的机器，会整个会话都没有 provisioning。

## 参数

| | |
| --- | --- |
| `scope` | `user`（缺省）把 server 写进 `~/.claude.json`，对每个目录都生效；`local` 只写这台机器的项目条目。**`user` 才是做这件事的意义**——项目 scope 恰恰是本来就能用的那种情况 |
| `skills` | `yes`（缺省）把 Polter 的 skill 镜像进 `~/.claude/skills/polter-*`；`no` 只注册 MCP server |

## 没有那个二进制不是失败

`command -v claude` 找不到就直接回 `{"ok":true}`。这台机器上的 agent 可能是别的
东西，Polter 两种情况下都一样工作。回 false 会让每一个不用 Claude Code 的用户，
每次启动都看见一次退避重试。

## 读了再写

`~/.claude.json` 是那个用户 Claude Code 的全部配置，而 Claude Code 自己在跑的时候
也会重写它。所以先 `claude mcp get polter` 读一次，路径和版本都对得上就什么都不做。

**为什么要比版本号而不只比路径**：路径能抓到一次搬家或者重装到别处，抓不到一个
参数或协议变了而路径没变的构建——**而那是每一次原地升级**。`POLTER_REGISTERED`
这个 env 标记就是让「是另一个构建写的」变成看得见的东西。

## `polter-` 前缀是这一族的命名空间

装而不删不叫同步。**一个从 Polter 里删掉的 skill 会继续活在每一台曾经装过它的
机器上**：三个 `mode-*` skill 随着它们描述的工作模式一起消失了，几个月后仍然躺在
`~/.claude/skills/` 里，仍然在被拿去匹配用户说的话，仍然在告诉 agent 去调一个已经
不存在的工具。没有任何东西会把它们拿走。

所以 `polter-` 前缀被当作**这个插件的命名空间**，而不只是一种避免撞名的办法。那
是一个比「我们不会覆盖你的文件」更宽的主张，而它是故意做的：另一条路——只删带着
我们今天才开始写的标记的条目——删不掉当初引出这件事的那三个 skill，也就是说它修
不了它被写出来的那个 bug。

三道检查把这个主张收窄到这个插件真正写过的东西上。一个目录里除了一个 `SKILL.md`
还有别的东西，或者它的 frontmatter 里写的名字不是它自己的目录名，那就是别人的，
即使在前缀之下也不动。

**清理只在一次干净的安装之后跑，而且只在那一行真的解析出了一个 skill 列表时跑**：
一个空列表远比「这个发行不带任何 skill」更可能是一次失败的解析，而照着它动手会
删掉这台机器上的每一个 skill。

## frontmatter 里的名字要跟着改

装进去的是**整个文件，frontmatter 一起**——一个没有 frontmatter 的 Claude Code
skill 根本不会被加载。早一版只装正文，产出五个在目录列表里看着没问题、实际什么都
不干的文件。

frontmatter 里的 `name:` 要和目录名一致，否则 runtime 会用一个用户打不出来的名字
列出它。**只改 frontmatter 里的那一行**：正文里的 `name:` 是正文。
