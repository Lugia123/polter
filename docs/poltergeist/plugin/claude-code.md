# claude-code

**订阅 `provision`**：把 Polter 的 MCP 端点注册给 Claude Code，并把 Polter 的
skill 镜像到 `~/.claude/skills/polter-*`。

代码在 `plugins/claude-code/`。协议全文见 [../plugins.md](../plugins.md) 第二节，
这一步为什么是插件而不是核心的一部分见 [../boundary.md](../boundary.md) 第三节。

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

## 没有 `claude` 不是失败

`command -v claude` 找不到就直接回 `{"ok":true}`。这台机器上的 agent 可能是别的
东西，Polter 两种情况下都一样工作。回 false 会让每一个不用 Claude Code 的用户，
每次启动都看见一次退避重试。

## 读了再写

`~/.claude.json` 是那个用户 Claude Code 的全部配置，而 Claude Code 自己在跑的时候
也会重写它。所以先 `claude mcp get polter` 读一次，路径和版本都对得上就什么都不做。

**为什么要比版本号而不只比路径**：路径能抓到一次搬家或者重装到别处，抓不到一个
参数或协议变了而路径没变的构建——**而那是每一次原地升级**。`POLTER_REGISTERED`
这个 env 标记就是让「是另一个构建写的」变成看得见的东西。

## `polter-` 前缀是这个插件的命名空间

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
