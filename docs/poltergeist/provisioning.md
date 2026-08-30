# 供给：让各家 agent CLI 知道 Polter 在这儿

## 本章覆盖什么

- 一个 agent 跑在 Polter 的终端里，怎么才能真的用上 Polter 的工具
- 为什么这件事是插件，不是核心功能
- 八个宿主各自要什么形状，以及它们之间差在哪
- 为什么除了 Claude Code 之外**默认全部不开**
- 「这台机器上没装这个 CLI」和「装了但供给失败」怎么区分

## 本章不覆盖什么

- MCP 工具本身有哪些（[mcp.md](mcp.md)）
- 插件框架的通用协议、日志、通知（[plugins.md](plugins.md)）
- skill 的内容怎么写（`src/poltergeist/skills/`，以及 [mcp.md](mcp.md) 的 Skill 体系一节）
- 图形界面的 agent。Polter 是终端复用器，**跑不在终端里的东西不在射程内**

## 一句话概括

Polter 把 socket 和 token 放进每个终端的环境变量，这就是「够得着」的全部；
**但工具不会自己出现**——MCP 客户端只加载它被配置过的服务器。供给插件就是把
「Polter 在这儿」翻译成每一家各自认得的那种写法。

## 一、两件事，权重不一样

每个宿主要做的只有两件：

1. **注册 MCP 服务器** —— 之后 `terminal_*` / `group_*` / `task_*` 才会出现在
   那个 agent 的工具表里
2. **安装 skill** —— 把 `src/poltergeist/skills/*.md` 铺到那家的 skill 目录

**第 1 件是必须的，第 2 件是增强。** 这个权重和直觉相反，理由有两条：

- **skill 正文本来就能通过 MCP 拿到。** `skill_read` 是一个 MCP 工具，注册完就
  有。所以往目录里装文件，买的不是「读不读得到」，是**「会不会想起来去读」**。
- **`instructions` 是跨宿主的。** `initialize` 应答里的那张工具族地图（见
  [tasks.md](tasks.md) 第九节）是 MCP 协议字段，任何 MCP 客户端都吃。所以一个
  只有 MCP、没有 skills 的宿主，照样拿得到那张地图。

于是「这家不支持 skills」是一次降级，不是一次失败。**没有 MCP 才是失败。**

## 二、世界变了一次，把这件事的一半消掉了

2025 年 12 月 Anthropic 把 Agent Skills 开成标准（agentskills.io）；2026 年 1 月
起 OpenAI 的 Codex CLI、Google 的 Gemini CLI、GitHub Copilot 陆续原生支持。

**结果是 SKILL.md 的正文和 frontmatter 通用，每家只差一个目录。** 本来预期的
「每家一套模板」没有发生。真正的差异全部集中在两个地方：**skill 装到哪**，和
**MCP 怎么注册**。

## 三、宿主分三族

差异只在 MCP 那一侧，而且只有三种形状：

| 族 | 怎么注册 | 谁 |
| --- | --- | --- |
| **A. 有 `x mcp add` 子命令** | 调命令，不碰文件 | claude, codex, gemini, qwen, kimi, iflow |
| **B. 只能改 JSON 配置** | 读→合并→写 | opencode, deepseek |
| **C. IDE 专用** | **不做** | cursor, windsurf, kiro, cline, 通义灵码 IDE, 文心快码 |

**A 族优先，而且优先得有理由**：调一条命令是那家自己维护的接口，格式、锁、原子
性都是它的事；改用户的配置文件是我们替它维护它的格式，注释、并发写、schema 变
更全部变成我们的债。B 族要做，但它是**另一种东西**，不能和 A 族用同一份代码假装
一样。

## 四、八个宿主

已核实的部分来自各家官方文档（2026-08-30 查）。**没有一条是我实机跑过的**，
这一点在实现时必须重新验。

| key | 宿主 | 族 | MCP 落点 | 顶层键 | skill 目录 |
| --- | --- | --- | --- | --- | --- |
| `claude-code` | Claude Code | A | `~/.claude.json` | `mcpServers` | `~/.claude/skills/` |
| `codex` | OpenAI Codex CLI | A | `~/.codex/config.toml` | `mcp_servers` **(TOML，下划线)** | `~/.codex/skills/` |
| `gemini` | Google Gemini CLI | A | `~/.gemini/settings.json` | `mcpServers` | `~/.gemini/skills/` |
| `qwen-code` | 阿里 Qwen Code | A | `~/.qwen/settings.json` | `mcpServers` | 待核 |
| `kimi` | 月之暗面 Kimi CLI | A | TOML | 待核 | 待核 |
| `iflow` | 心流 iFlow CLI | A | `~/.iflow/settings.json` | `mcpServers` | 待核（文档有 Skill 页，没读到内容） |
| `opencode` | opencode | B | `~/.config/opencode/opencode.json` | `mcp` **(嵌套，不是 mcpServers)** | 待核 |
| `deepseek` | DeepSeek-TUI | B | `~/.deepseek/mcp.json` | 待核 | 待核 |

三点要记住：

- **Codex 的键是 `mcp_servers`，别家是 `mcpServers`**，而且它是 TOML。照着别家
  抄一定错。Codex 另外要一个 `openai.yaml` 放 UI 元数据，别家会忽略它。
- **opencode 的键是 `mcp`，结构也不同**，不是换个文件名的 `mcpServers`。
- **Qwen Code 和 iFlow 都是 gemini-cli 一系**，形状和 Gemini CLI 一样。这不是巧
  合，是这三家共用一份上游——**也意味着上游一变，三家一起变**。

### DeepSeek 是个例外，要单独说

**DeepSeek 没有官方 CLI。** 2026 年 8 月发的 V4-Pro 是模型。终端 agent 全是第三
方的：`DeepSeek-TUI`（Hmbown，`deepseek` 命令，`~/.deepseek/mcp.json`）、
`DeepSeekCode`（Claude Code 的 fork）、`Deep Code CLI`。我们对着
DeepSeek-TUI 写。

**这一条的风险和别的不是一个量级**：第三方项目改配置形状不会通知任何人，坏了我
们才知道，而用户会以为是 Polter 坏了。所以它的失败必须比别家更响。

## 五、设计：SDK 出实现，插件出答案

379 行 × 8 份是不能接受的，但「八个插件合成一个」也不行——一个失败会连坐其余七
个，而且 `wants.exec` 是按二进制声明的，合起来就得声明全部八个。

所以：**`plugins/_sdk/provision.sh` 是实现，每个宿主插件退化成一份声明。**

一份宿主声明要回答的，就是第三节那张表里的那几格：

```sh
POLTER_HOST_BIN=codex                     # 拿它判断这台机器上有没有装
POLTER_HOST_FAMILY=mcp-add                # 或 json-merge
POLTER_HOST_MCP_ADD='codex mcp add …'     # A 族：怎么注册
POLTER_HOST_SKILLS_DIR="$home/.codex/skills"   # 空 = 这家不支持，跳过且不算失败
```

各家仍是独立的 `plugin.json`：各自声明自己的 `wants.exec`，各自能在插件界面里单
独开关，各自一份日志。**共用的是实现，不是身份。**

幂等与版本戳沿用现在的做法，两样都与宿主无关，不必每家重来：MCP 条目上带
`POLTER_REGISTERED=<version>` 环境变量，skill 的 frontmatter 里盖一行
`polter-build:`。

## 六、默认只开 Claude Code

八个插件全开会让每台机器上有六七个在「静默地什么都没做」——那不是坏，但它会把
日志变成噪音，而噪音里藏不住真正的失败。

**所以默认只有 `claude-code` 是开的，其余七个装了但关着。**

代价必须说清楚：**默认关 = 在用户找到那个菜单之前，对任何非 Claude Code 用户都不
生效。** 一个装了 Codex 的人打开 Polter，什么也不会发生，而且没有任何东西告诉他
本可以发生什么。

所以配一条：**供给插件在启动时看一眼各家二进制在不在 PATH 上，发现了就通过通知
系统说一次**——「检测到 codex，插件 → Codex CLI 可以打开」。用的是已有的插件通知
通道（[plugins.md](plugins.md)），说一次，不重复。**探测是免费的，注册不是**：
前者只是看 PATH，后者会写用户的配置文件，两者的门槛不该一样。

## 七、「没装」不是「失败」，这两件事现在分不开

`claude-code` 现在在 `claude` 不在 PATH 上时**静默退出 0**，理由写在它自己的注释
里：这台机器上的 agent 可能压根是别的东西。一个插件时这是对的。八个插件之后就不
对了——任何一台机器上都会有几个「静默地没做事」，而日志里**「你没装这个 CLI」和
「装了但注册失败」长得一模一样**。

所以 SDK 里要有一个明确的三态，写进日志也写进 `plugin_list`：

| 状态 | 什么时候 | 用户该看到什么 |
| --- | --- | --- |
| `absent` | 二进制不在 PATH 上 | 什么都不用做，**不是问题** |
| `provisioned` | 注册成功，版本戳是当前的 | 什么都不用做 |
| `failed` | 二进制在，但注册或装 skill 失败 | **通知用户**，说清哪一步 |

第三态就是 2026-08-30 那次栽的：`claude` 在 `~/.local/bin`，不在 Dock 启动继承的
系统 PATH 里，插件按设计静默退出 0，**skill 没同步、MCP 没刷新，什么都不报**，而
之前每次真机验证都从终端启动，每次都「通过」。PATH 拓宽已经修了（`login_path.zig`），
但**「静默退出 0」这个形状本身仍在**，八个插件会把它放大八倍。

## 八、分两步做，顺序不能反（已做完，记在这里因为顺序才是重点）

**第一步：把实现提到 `_sdk/provision.sh`，用它重写 `claude-code`，别的一个不加。**
这是唯一有风险的一步——它动的是当时**唯一在工作**的那个。

这一步顺手证明了仓库里那条端到端测试是真的：`Resident.zig` 有一条测试把随构建
装出去的 `provision.sh` 写进临时目录**真跑一遍**，然后读它装出来的 skill 文件。
重构之后它立刻断了，因为脚本要 source `../_sdk/provision.sh` 而临时目录里没有。
修法不是绕开它，是**让临时目录照 bundle 的样子摆**（`claude-code/` 和 `_sdk/` 并
列），这样测的就是真实布局。

之后对 SDK 做了两条负对照，两条都红：拿掉 `polter-build` 戳记、拿掉「只在内容不
同时才写」的判断。所以那条测试断言的是 SDK 的行为，不只是「脚本退出 0」。

**第二步：七份声明。** 每份几十行，默认关。

反过来做——先加七个再重构——就是拿七个没验过的东西去压一个正在工作的。

### 第二步没有真机，所以验的方式是把协议手工驱动一遍

七家里没有一家装在这台机器上，所以「注册完那个 agent 真能看到 polter」一条都没
验过。能验的是脚本本身：按协议往 stdin 喂两行（问候 + 一批 `provision` 事件），
用一个假的 CLI 顶在 PATH 上，然后看它写了什么。

`claude-code` 这样验过四条：同版本跑两次第二次一个字节都不写、换版本重写且戳记跟
着走、`absent` 时的日志、`failed` 时 `{"tell":…}` 排在 `{"ok":false}` 之前。

`opencode` 验的是改文件那三条性质，外加一条：**配置文件坏掉时原样保留**，日志里
给出 python 的原话（`cannot parse …: line 1 column 3`）。这条一开始是坏的——SDK 用
`>/dev/null 2>&1` 调注册，**把唯一说明白原因的那句吞掉了**。现在只吞 stdout。

## 取舍记录## 取舍记录

| 方案 | 为什么没选 / 为什么选 |
| --- | --- |
| 每家一份完整脚本 | 379 × 8。而且共同的那部分（幂等、版本戳、清理过期 skill、日志）会分叉成八个版本 |
| 一个插件带一张宿主表 | 一个失败连坐七个；`wants.exec` 得声明全部八个二进制，等于每台机器都在声明它用不到的东西 |
| **SDK 出实现 + 每家一份声明** | **选这个。** 共用实现，独立身份、独立开关、独立日志 |
| 八个全默认开 | 噪音淹掉真正的失败 |
| **只开 Claude Code + 探测到就提示一次** | **选这个。** 探测只读 PATH，注册要写用户的文件，门槛不该一样 |
| 先加七家再重构 | 拿七个没验过的去压一个正在工作的 |

## 未决问题

1. **七家一家都没有真机验过。** 表里每一行都只来自官方文档。每一家都需要在装了
   那个 CLI 的机器上验一次「注册之后那个 agent 真的看得见 polter 的工具」——**只
   看配置文件写进去了不算**，那只证明我们会写文件。
2. **五家的 skill 目录仍然是空的**（`qwen-code` `kimi` `iflow` `opencode`
   `deepseek`）。`host_skills_dir` 返回空串，那一步整个跳过。这是可接受的降级，
   补法是核实一家填一家，**不要猜**：写进猜出来的目录是留在别人机器上的垃圾。
3. **第六节那条「探测到就提示一次」还没做。** 没有它，默认关就意味着装了 Codex
   的人永远不知道这里有东西。这是目前最大的一个缺口，而且它和插件本身无关——它
   属于宿主那一侧。
4. `deepseek` 对着的是第三方的 DeepSeek-TUI。它改配置形状不会通知任何人，届时用
   户会以为是 Polter 坏了。没有别的办法，只有让它失败得响一点。

## 延伸阅读

- [plugins.md](plugins.md) —— 插件协议、日志、通知
- [mcp.md](mcp.md) —— 工具清单、可达性、自指
- [tasks.md](tasks.md) 第九节 —— `instructions` 为什么是跨宿主的那一层
