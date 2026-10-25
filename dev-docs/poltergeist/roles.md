# 角色：一个终端里的 agent 手上有什么

> 最后更新对应的 git commit：`6899e05aa`
> 校验方式：`git log -1 --format='%H %h %ad %s'`
> 状态：**第一至第十节是热换装那一半的设计；第十一节是角色库与「用角色
> 启动」（v2，分支 `feature/roles-v2`），其中第七节的第 1 条被用户的决定改掉了，
> 改动和理由都留在原处。**
> 落到线协议与 ABI 那一层的取舍在
> [personas-contract.md](personas-contract.md)——**那一份是实现的事实源，
> 本章是它的理由**；两者冲突时，形状以契约为准，理由以本章为准。
> 代码里这套东西叫 `persona`，本章和界面上叫「角色」。
> 凡是说「宿主怎样」的，都标了证据等级。
> **本章若与代码不一致，以代码为准。**

## 本章覆盖什么

- 实测：七个 agent CLI 里，哪几家能在**已经跑起来之后**改掉 agent 手上的
  工具和技能，哪几家只能重启。每条怎么复跑。
- 一条把方案砍掉一半的硬约束：**只有工具面是按终端的，文件不是。**
- 为什么**不聚合**：一个上游一个槽位，授权和命名都归各自的服务器。
- Polter 自己维护什么、只显示不动什么，这条线画在哪。
- 角色的数据形状，以及「选了角色之后又单独改了一项」这个状态怎么表达。
- 热 / 温 / 冷三级，以及为什么冷的那几家**不许长得像已经生效**。
- 权限：角色曾经是用户定义的闭集，以及为什么现在总管和用户同权（第七、十一节）。
- **角色库与「用角色启动」**：CLI 适配插件、`+launch`、角色库窗口、`role_*` 工具（第十一节）。

## 本章不覆盖什么

- 插件框架本身（清单、常驻协议、凭据、权限声明）—— 见 [plugins.md](plugins.md)。
  本章新增的东西**是**插件，遵它的规矩。
- 各家 CLI 怎么注册 MCP、skill 目录在哪 —— 见 [provisioning.md](provisioning.md)。
  本章依赖那张宿主表，不重复它。
- 监督关系、按住、护盾、通知时段 —— 见 [supervisor.md](supervisor.md)。
- 工具面清单与可达性规则的论证 —— 见 [mcp.md](mcp.md)。

## 一句话概括

**角色是「这个终端里的 agent 手上有哪些工具、哪些技能、开场读到哪段提示词」，
由用户在 tab 上定，Polter 按终端兑现。** 兑现的手段不是重新起一个 agent——
在支持的宿主上，它是 Polter 改变自己对这个终端暴露的东西，然后发一条
`notifications/tools/list_changed`，正在跑的 agent 当场换装。

## 术语：这里的「宿主」是 agent CLI

本章的「宿主」沿用 [provisioning.md](provisioning.md) 的用法，指 **agent CLI**
（claude-code、codex、gemini…）。`_spec.md` 术语表里定义的是**「宿主终端」**，
那个指 Ghostty，是另一个词。两个词差两个字，而本章通篇在讲前者。

**面向用户的界面文案里两个都不要用**，一律写「agent」——用户没读过这两份
文档，这个词对他们是纯行话，而且正好是会被理解反的那一类行话。

---

# 一、实测：谁能后改

**这一节的每一格都是跑出来的或读源码读出来的，证据等级逐条标注。**
起因是一次方向性的错误：第一版方案把角色做成**启动参数**
（`claude --mcp-config … --plugin-dir … --append-system-prompt-file …`），
而真实场景里总管是用户自己在终端里敲 `claude` 起来的，什么参数都没有。
**启动参数对一个已经在跑的 agent 没有任何用**，整套方案因此重做。

| 宿主 | MCP 工具中途增删 | skill 中途增删 | 证据 |
| --- | --- | --- | --- |
| `claude-code` | ✅ **热** | ✅ **热** | 🔬 真机实测 |
| `gemini` | ✅ 热 | — | 📖 源码 |
| `codex` | ❌ **冷** | ？未测 | 🔬 真机实测（有效阴性） |
| `opencode` | ⚠️ 收到了没人消费 | — 无 skill 概念 | 📖 源码 |

> `qwen-code`（温）、`kimi`、`deepseek` 三家的插件 2026-10-25 摘掉了（task 2207）；
> 下面凡提到它们的地方都是当时读源码的读数，留着是因为它讲过的话仍然成立。

后四家在 [provisioning.md](provisioning.md) 的宿主表里 `host_skills_dir()`
本来就返回空串——Polter 从不往那儿装 skill，所以「技能」这一维对它们
本来就不存在，表里的「—」不是没测，是没有这件事。

## 1.1 Claude Code：两条路都是热的

**MCP 工具。** 探针服务器（附录 A）第一阶段只暴露 `probe_alpha`；它被调用后
服务器换成 `probe_beta` 并发一条 `notifications/tools/list_changed`。
客户端**立刻重新发 `tools/list`**，随后 `probe_alpha` 调不到、`probe_beta`
调得到。服务器侧日志逐条对得上：`tools/list` → `tools/call(probe_alpha)`
→ `FLIP` → `tools/list` → `tools/call(probe_beta)`。
测的版本是 `2.1.274`。

> 网上有 issue 说 Claude Code 不处理这条通知
> （`anthropics/claude-code#13646`）。**那条在这个版本上不成立。**
> 这正是本节每格都要标证据等级的原因：宿主行为会随版本静默变化，
> 而「读到一条说不支持的 issue」和「今天真的不支持」长得一样。

**skill。** 会话跑着的时候往 `.claude/skills/` 放一个新 skill，下一轮它就在
清单里；删掉目录后 agent 去调，得到 `Unknown skill: zzz-late-skill`。
**增和减都真生效。**

> **这里栽过一次，值得照抄进判据。** 第一次测「减」，我问的是
> 「你还有这个 skill 吗」，答 YES，看起来像没减掉。实际上那是**第一轮的
> 清单还留在上下文里**——每一轮都会注入一份新清单，但旧的那份并不会消失。
> 换成「真去调用它」才分得开。**这个现象会原样出现在产品里**，见第八节。

## 1.2 codex：冷，而且第一次测出来的阴性不算数

第一次跑的结果是「没有 `probe_beta`」，**那一次无效**：工具调用被审批拦在
外面，`probe_alpha` 根本没到服务器，服务器从没换过工具列表。
判据是服务器日志里只有 `tools/list` 一条，没有 `tools/call`。

从二进制里查出 `mcp_servers.<name>.default_tools_approval_mode`
（取值 `auto` / `prompt` / `approve`），设成 `approve` 后重跑：
alpha 真执行了、FLIP 真发了、通知真送出去了，**codex 没有重新拉
`tools/list`**。这才是有效阴性。

顺带两个对本设计有用的发现：

- codex 的 MCP 配置原生有 **`enabled` / `enabled_tools` / `disabled_tools`**
  ——「这台只暴露这个服务器的这几个工具」在 codex 侧是现成的，**重启时**
  的角色兑现可以直接落到它上面。
- 二进制里有 `McpServerRefresh`、`SkillsListt`、`SkillsConfigWrite`、
  `SkillsExtraRootsSet` 这些 app-server RPC，说明**刷新在 codex 是个显式
  动作**。TUI 里怎么触发没查，这是一条没走完的线。

## 1.3 gemini / qwen / opencode：只有源码

- **gemini**：`setNotificationHandler(ToolListChangedNotificationSchema, …)`
  里直接 `await this.refreshTools()`，旁边注释写着「没声明 `listChanged`
  也照听，图个稳」。**没能实测**——本机 Google 账号被 `IneligibleTierError`
  挡住。
- **qwen-code**：主 MCP 客户端里没给这条通知注册处理器（只有一个转发用的
  proxy 接了）。但它有 `/skills` 对话框，存盘后 `reloadCommands()` +
  `notifyConfigChanged()`；`qwen serve` 还暴露
  `POST /workspace/extensions/refresh` 和 `enableExtension`。
  **运行时通道存在，只是不在 MCP 这条线上。** 没能实测——403。
- **opencode**：收到通知只做一件事，`Bus.publish(MCP.ToolsChanged, …)`；
  全二进制里 `subscribe(MCP.ToolsChanged` 出现 **0 次**。事件发出去没有
  内部订阅者。没能实测——本机 `opencode auth list` 是 0 credentials。

**「源码看着支持」和「真的支持」不是一回事**，这三家在拿到可用账号之前
都该当成待核。附录 A 的探针就是为了让这件事随时能重测。

---

# 二、硬约束：只有工具面是按终端的

这条约束把方案砍掉一半，而且它在第一版设计里是隐形的。

**Polter 知道每个 MCP 连接来自哪个终端。** `Server.issueToken(id)` 给每个
surface 发一个 token，`Surface.zig` 把它和 socket 路径一起放进子进程环境
（`GHOSTTY_POLTER_SOCKET` / `GHOSTTY_POLTER_TOKEN`）。agent 拿着它连上来的
那一刻，身份就定了。**所以 Polter 给谁看什么工具，可以逐终端不同。**

**skill 是文件，文件不按终端分。** `~/.claude/skills/` 是全局的，
`<项目>/.claude/skills/` 是按目录的。同一台机器上开三个终端，动 skill 目录
会同时动到三个。

> 第 1.1 节那个「热加热减都成立」的实验用的是**项目级**目录。它证明了
> 热改成立，**它不能证明按终端换装成立**——这两件事第一版里混在一起了。

于是：

| | 能按终端热改吗 | 怎么做 |
| --- | --- | --- |
| Polter 自己的工具 | ✅ | 按 token 算可见集 |
| 经 Polter 槽位的上游 MCP 工具 | ✅ | 同上 |
| **Polter 自己的 skill** | ✅ | **走工具面，不摆文件**（见下） |
| 宿主全局的 skill | ❌ | 运行时无解，只能重启 |
| 宿主全局的 MCP | ❌ | 运行时无解，只能重启 |

**角色技能走工具面而不是摆文件**，这是这条约束逼出来的结论，而现状代码里
已经有它的形状：`skill_read` 就是「技能通过工具面交付」。
把它的清单按终端变，角色技能就按终端了，一个文件都不用动。

---

# 三、不聚合：一个上游一个槽位

## 3.1 聚合方案被否掉了

通用 MCP 网关的标准做法是**聚合**：把 N 个上游并成一个虚拟服务器，工具改名
加前缀避免重名。Polter 这边否掉它，理由两条，第一条是决定性的：

1. **授权会被一次性吞掉。** 宿主的权限规则是按服务器分的
   （Claude Code 是 `mcp__<server>__*`，codex 是
   `mcp_servers.<name>.default_tools_approval_mode`）。聚合之后所有上游
   共用一个服务器名，**用户一个一个授权的能力就没了**——放行 Polter 等于
   放行它背后的一切。这不是体验问题，是把用户的安全模型抹平了，和 P2
   「不替对方按 yes」是同一类错误。
2. **改名会让上游自己的文档失准。** 重名必须加前缀，加了前缀之后上游服务器
   自己的提示词、README、skill 里写的工具名就都对不上了。

## 3.2 换成：槽位

**一个上游一个槽位，每个槽位在宿主配置里是一个独立的 MCP 服务器条目。**

```
宿主配置里                 实际连到
  polter          ──────►  Polter 自己的工具面
  polter:argus    ──────►  槽位进程 ──(按角色决定要不要拉起)──► argus 的 MCP
  polter:kanban   ──────►  槽位进程 ──(这个角色没有它，暴露空工具集)
```

槽位进程启动时从环境里拿到 socket 和 token，因此**它知道自己在哪个终端**。
它向 Polter 问「这个终端的角色要不要我」：

- 要 → 拉起上游，把上游的 `tools/list` 原样转出去，**不改名**。
- 不要 → 暴露空工具集，**上游进程根本不启动**。
- 角色中途改了 → Polter 通知槽位，槽位发一条
  `notifications/tools/list_changed`，热的宿主当场换装。

这样一来：

- **授权还是一个一个的**，跟现在一模一样：用户在 Claude Code 里放行
  `mcp__polter:argus__*`，放行的就只是 argus。
- **不用改名**，因为每个服务器有自己的命名空间。
- **哪些槽位存在**是启动期的事（新增一个上游要重启）；**每个槽位暴露什么**
  是运行期的事。角色切换只动后者，所以是热的。

## 3.3 槽位在 Polter 之外怎么办

用户在 Ghostty 之外直接跑 `claude`，槽位进程拿不到 socket 和 token。
**这时它必须原样透传上游的全部工具**，否则「装了 Polter 之后我在别处的
终端就少了工具」。这条是必须的，不是可选的。

### 「从没拿到过答案」和「拿到过之后断了」是两件事

**这一段是后补的，补它是因为上面那句话会被实现成一个漏洞。** 写着
「拿不到 socket/token 就透传」，最自然的实现是「连不上就透传」——而那两件
事只在第一次连接时重合。之后它们分岔：

| 时刻 | 槽位该做什么 |
| --- | --- |
| **启动时从未拿到过答案**（没有 socket/token，或首次询问连不上、答不上） | **透传。** 这时没有任何依据去拿走用户的工具 |
| **拿到过答案之后连接断了**（Polter 重启、idle 超时、槽位满） | **保持当前状态不变**，重连重试，**绝不升级成透传** |

不分开的后果：一个**明确写了不给 argus** 的角色，只要 Polter 抖一下断线，
槽位就把 argus 的全部工具交了出去，**而且没有任何东西会报错**。

这是一条「写反了也跑得通、只是把闭集漏了」的条款，所以它在这里有自己的
一节，而不是上面那段里的一个从句。

## 3.4 一个上游要怎样才归槽位管

**用户显式把它交给 Polter，一次一个，可撤销。** 界面上是「让 Polter 管这个
MCP」：把宿主配置里的 `argus` 换成 `polter:argus`，命令行和环境原样搬过去。

这件事**动的是用户的全局配置**，所以：它是用户点的，不是 Polter 自己做的；
它影响这台机器上所有会话（宿主的 MCP 配置就是全局的），界面上要说清楚；
撤销要能把原条目原样放回去。

**没交给 Polter 的上游，Polter 一根手指都不碰**，见下一节。

---

# 四、边界：维护什么，只显示什么

**规则一句话：谁发出去的，谁才收得回。**

| | Polter 的态度 |
| --- | --- |
| Polter 自己的工具面 | **维护。** 按角色、按终端决定暴露什么 |
| 交给槽位的上游 MCP | **维护。** 同上 |
| Polter 自己的角色 skill | **维护。** 通过工具面交付 |
| 宿主全局 / 项目的 MCP | **只读。** 列出来给用户看，不改、不关、不代理 |
| 宿主全局 / 项目的 skill | **只读。** 同上 |

「只读」是什么意思要说死：角色编辑器里**看得见**这台机器上 Claude Code 装了
哪些 plugin、哪些 skill、哪些 MCP，用户能知道「我这个射手角色虽然没给他
argus，但 argus 是全局装的，他还是有」。**看得见，是为了让用户知道角色没
覆盖到哪里，不是为了让 Polter 去改它。**

## 4.1 为什么不「Polter 全都接管」

技术上做得到：provision 时把用户 `~/.claude.json` 里的 MCP 全搬到槽位后面，
宿主只剩 Polter 一族服务器，从此一切都能热改。否掉，三条：

1. 动的是用户的全局配置文件，而且是**全部**，不是用户挑的那几个。
2. **同机所有终端一起受影响**，包括用户自己那个读邮件的、`shielded` 的 tab
   ——而 `shielded` 的全部意义就是「谁都不许碰这个终端」。
3. Polter 一崩，所有终端的所有工具一起没了。现在 Polter 崩了只是少了
   Polter 的工具。**故障面从「一个能力层」扩大到「全部能力」。**

## 4.2 skill 和 MCP 在这件事上不对称

**上游的工具能代理，上游的 skill 不能。**

argus 的 16 个 skill 是 Claude Code plugin 里的 markdown。Polter 理论上能读
出来、通过自己的工具面重新发一遍——但**宿主自己那份还在**，于是同一个技能
出现两份，agent 不知道听谁的。**重复暴露比缺失更糟。**

所以这条路堵死：**Polter 只发自己的 skill。** 别人的 skill 只有一条处理
路径，就是重启换装时用宿主自己的开关（Claude Code 的
`--settings '{"enabledPlugins":{…}}'`，**已实测有效**：基线列出 16 个
`argus:*`，加这一个参数后同一个问题答 `NONE`）。

---

# 五、角色是什么

## 5.1 数据形状

一个角色是一份 CLI 中立的声明，用户可改、可加、可版本化（P6 那一半）：

```jsonc
{
  "key": "archer",
  "name": "射手（侦察 / 只读调研）",
  "prompt": "archer.md",        // Polter 自己的角色提示词，通过工具面交付
  "skills": ["reading-a-terminal", "archer-recon"],  // Polter 自己的 skill
  "mcp": ["argus"],             // 槽位名，不含 polter: 前缀
  "hint": {                     // 只在「冷」宿主重启时才兑现的部分
    "disable_host_plugins": ["kanban@bestfunc-kanban-plugins"],
    "model": "sonnet"
  }
}
```

`polter` 自己那一项**永远隐式在内**，不写也在，写了也不许去掉——把 Polter
自己关掉的角色，等于一个失联的终端。

## 5.2 预设，加上偏离

用户选一个角色 → 这个终端的**技能和 MCP 一次性切过去**。切完之后还能单独
改某一项（临时给他加一个 MCP，临时关掉一个 skill）。

于是一个终端上有两个东西，不要混：

- **角色**：用户选的那个预设的 key。
- **生效集**：这个终端此刻实际暴露的工具与技能。

选角色 = 把生效集重置成角色的声明。单独改 = 只动生效集。两者一旦不一致，
**界面上必须看得出来**——tab 和菜单里写「射手（已改）」，而不是「射手」。

> 这条是从 P5 那段被否掉的旧设计里学来的：**一个只在设定那一刻存在的状态
> 等于没有状态。** 生效集是常驻的，角色 key 只是它的来历。

## 5.3 角色标记什么时候该闭嘴

角色是用户对这个终端的**意图**，不是对里面跑着什么的**测量**。用户在同一个
tab 里自己敲了别的命令，标记就开始撒谎，而**一个过期的标记和一个正确的标记
长得一模一样**。

所以：标记只在那个终端里确实有 agent 连着 Polter 的时候显示
（`Server.agentPresent(id)` 已经能回答这件事）；没有 agent 连着的时候，
角色仍然存着，但 tab 上不显示成「是射手」。

---

# 六、热 / 温 / 冷，以及不许撒谎

| 级别 | 谁 | 换装怎么发生 |
| --- | --- | --- |
| **热** | claude-code、gemini | 槽位改工具集 + `list_changed`，**当场生效** |
| **温** | （无随包插件） | 走它自己的运行时接口（`/skills`、`serve` 的扩展刷新）——qwen-code 是这一类，2026-10-25 摘掉了插件，级别还在 |
| **冷** | codex、opencode | **只能重启** |

**冷的那几家，菜单上直说「下次启动生效」。** 不要让它长得像已经生效了。
这和 [provisioning.md](provisioning.md) 第七节那个
`absent` / `provisioned` / `failed` 三态是同一条原则：
**「这里没事可做」和「这里出事了」必须长得不一样**，这里是
**「已经换好了」和「等下次启动」必须长得不一样**。

冷宿主的重启换装落在启动命令行上，各家已知的抓手：

| 宿主 | 抓手 | 证据 |
| --- | --- | --- |
| claude-code | `--settings`（`enabledPlugins`）、`--strict-mcp-config --mcp-config`、`--plugin-dir`、`--append-system-prompt-file` | 🔬 前三个实测过 |
| codex | `-p/--profile`、`-c mcp_servers.*.enabled/enabled_tools/disabled_tools` | 📖 help + 二进制 |
| gemini | `-e/--extensions`、`--allowed-mcp-server-names` | 📖 help |
| opencode | `--standalone`、`OPENCODE_CONFIG_CONTENT`（`permission` 里 deny 掉 skill 和 `<server>_*`，模型写进 `model`；2.0 没有 `-m`）、`--prompt`、`-s` | 🔬 实测（#1777 在 1.2.10，#1806 在 2.0.32，`test/opencode-adapter/hooks-against-opencode.py`） |

**重启会丢上下文。** `claude --continue` 能带着同一段对话用新参数重开，
如果成立，冷宿主的换装体验会完全不同。**没验证过**，是第十节的待定项。

---

# 七、权限

**能给一个终端换装的工具，等于能给那个终端扩权。** 一个总管如果能自己编角色，
它就能给 worker 配一个用户从没同意过的 MCP，再借 worker 之手用它。

所以：

1. ~~**角色是用户定义的闭集。** 工具面只暴露「列出角色」和「把某个终端设成
   某个角色」，**没有任何工具能新建或修改一个角色**。~~
   **2026-09-22 用户改了这一条：总管对角色库的权限和用户完全同等**——增、删、
   改，包括额外启动参数；并且可以用角色开新终端（第十一节）。当时摆在用户面前
   的三个选项是「只能收窄（额外参数只有用户能改）」「完全同等」「每次要用户
   确认」，用户选了第二个。
   这条被划掉而不是删掉，因为它的理由没有失效，只是被用户权衡掉了：**能改
   角色的总管，能给 worker 配一个用户从没点过头的参数**（比如
   `--dangerously-skip-permissions`）。剩下的约束是程序里的两条：只有一个写者
   （`PersonaStore.put`），每次写都过读文件的同一个解析器；以及角色里能挑的
   skill 和 MCP 只来自这台机器上那个 CLI 已经装了的东西——**角色只能让 agent
   手上的东西变少，额外参数是唯一能让它变多的地方。**
2. **`shielded` 的终端拒绝一切换装**，对总管也一样。这不需要新规则,
   沿用 `rpc.zig` 里现有的那条就行。
3. **换装不是一条新的执行通道。** 现状里 `terminal_send` 打得了字按不了
   回车（paste 路径把控制字节换成空格，见 `rpc.zig` 里 `terminal_send` 的
   那段注释）。热换装根本不碰键盘，所以它绕开了那道门**却没有绕开那道门要
   防的东西**——它能做的只有「在闭集里选一个」。
   **冷宿主的重启换装不一样**：那要真的往终端里敲一条命令并回车。
   **那条路必须是用户点的，不能给总管。**
   （第十一节的 `role_launch` 也敲一行并回车，但只敲进它**自己刚开的新
   标签页**，敲的是一行只含两个 key 的固定命令；它不往任何已有终端里敲，
   所以不是这一条说的那条路。）

---

# 八、陈旧信念

能力立刻被收走，**agent 的记忆不会**。

每一轮都会注入一份新清单，但上一轮那份还躺在对话历史里。所以一个刚被撤掉
argus 的 agent，会先去调一次，撞一次墙，才知道自己变了。第 1.1 节那个
「问它有没有 → 答 YES → 真去调 → `Unknown skill`」就是这件事的实物。

补救用现成通道：`report.zig` 那条应答通道让每个工具回话都能带文字。
换装之后，这个终端第一次调 Polter 任何工具时，回话里挂一句
「你的工具面刚被改成〈射手〉，此前清单作废」。

**这一句是为了省掉那次撞墙，不是为了让换装生效——换装已经生效了。**

---

# 九、被否决的方案

| 方案 | 为什么否 |
| --- | --- |
| 角色 = 启动参数 | 总管是用户自己敲 `claude` 起的，没有参数。**对已经在跑的终端完全无效**，而那正是唯一的场景 |
| 聚合成一个虚拟 MCP 服务器 | 把宿主「按服务器授权」的能力一次性吞掉；且重名必须改名，改名让上游自己的文档失准 |
| Polter 接管全部上游 MCP | 动用户全部全局配置、影响同机所有终端（含 `shielded` 的）、故障面从一个能力层扩到全部能力 |
| 角色 skill 摆成文件 | skill 目录是全局或按项目的，**做不到按终端**；且和宿主自带的同名 skill 会重复暴露 |
| Polter 转发上游的 skill | 宿主那份还在，同一技能两份，agent 不知道听谁的 |
| `CLAUDE_CONFIG_DIR` 每终端一份 | 🔬 实测：凭据也跟着搬走，直接 `Not logged in`。要用得先摆凭据，等于动用户登录态 |
| 用 `--disable-slash-commands` 关掉全部 skill 再加回来 | 它是全有全无，加不回单个；且和「只读别人的东西」这条线冲突 |

---

# 十、待定

**1 和 2 已经有答案了，答案记在下面，因为一条被划掉的待定项和一条从没
存在过的待定项，在清单上长得一样。**

1. ~~**槽位进程是 Zig 写还是复用插件框架？**~~ **已定：Zig，`polter
   +mcp-slot <槽位> -- <上游命令>`**（`src/cli/mcp_slot.zig`）。没有走插件
   框架，因为槽位要的是「按 token 认出自己在哪个终端」，而那正是核心已经
   有的东西。
2. ~~**上游崩了算谁的。**~~ **已定：四态**——`transparent`（从没拿到过
   答案）/ `granted` / `withheld`（上游进程根本不起）/ `broken`。`broken`
   时暴露**一个**工具 `polter_slot_unavailable`，描述里写「这不是你的角色
   没给你它，是那个服务器本身没跑起来」。这一条正是本节原来那句
   「不要让『上游挂了』和『这个角色没有它』长得一样」要的东西。
   ⚠️ 而它随后又长出一条同形：`broken` 和「够不到 Polter」也都落进
   `broken`，所以它带一个 `reason`（`upstream` / `no_polter`），两条各自
   的措辞——**收紧一个同形的时候，要回头看它有没有造出下一个**。
3. **`claude --continue` 能不能带着对话换参数重开。** 如果能，冷宿主的换装
   就不掉记忆。**仍然没验证过。**
4. **codex 的 `McpServerRefresh` 在 TUI 里怎么触发。** 如果有路子，codex 能
   从「冷」升到「温」。
5. **gemini / qwen / opencode 三家需要可用账号复测。** 现在全是读源码的
   结论，而源码看着支持和真的支持不是一回事。
6. **角色要不要跟项目走。** 「射手」在这个仓库和在另一个仓库是不是同一份。
7. **真机上没有人用眼睛看过菜单和编辑器。** 两端都有不需要 GUI 的测试，
   钉住了结构、勾选、启用态和那几条不许撒谎的措辞——**但它们看不见布局、
   看不见图标、看不见一行太长被截断**。这一条只能由人看，而且要照一张
   逐条可判的清单看：「看看对不对」换回来的是「还行」，那等于没验。

---

# 十一、角色库与「用角色启动」（v2）

## 11.1 为什么要有这一半

前十节做的是**给正在跑的 agent 换装**，而用户实际遇到的是另外三件事，一件
都做不了：没法新建角色（Polter 没有写 `personas.json` 的代码）；编辑器里没有
任何地方能挑 skill 和 MCP（宿主装的那些只读、只列名字）；没法「选一个角色，
直接起一个 agent」。另外，宿主清单那条线是空壳：`ghostty_app_persona_hosts`
写死返回 `{"stale":true,"hosts":[]}`，`inventory.zig` 没有调用者，而且 Swift
和 Zig 两边对它的 JSON 形状理解不一致。

用户对这一半的要求，按原话的顺序：

1. 能新建、编辑、删除角色；选这个角色用哪个 agent CLI（先做 Claude Code），
   列出这个 CLI 下**全部** skill 和 MCP，**说明写全**，由用户勾选。
2. 同等能力通过 MCP 给总管。
3. 右键 / 标签页 / 菜单里选一个角色，有多个 CLI 时再选一个，**直接启动**。
4. **「角色应该基于插件」**：新增一个 CLI 不该再写一套核心代码。插件声明自己
   是某个 CLI 的管理插件，并各自负责「怎样按角色指定 MCP 和 skill 去启动」。

## 11.2 实测：Claude Code 按会话关掉单项的开关

角色要落到启动参数上，而**不许动用户的文件**（第四节那条线在这里同样成立）。
claude 2.1.278 上实测，每条都有对照（基线能调到；同一批里没关的那一项仍能调到）：

| 要关掉的 | 有效的开关 | 无效的开关 | 证据 |
| --- | --- | --- | --- |
| 个人 / 项目 skill | `--settings '{"skillOverrides":{"<name>":"off"}}'` | — | 🔬 报 `disabled for model invocation in skillOverrides settings` |
| 插件的 skill（`argus:xxx`） | `--disallowedTools "Skill(argus:xxx)"`（bypassPermissions 下也挡）；整只关用 `enabledPlugins`，见 11.2.2 | `skillOverrides`，写 `argus:xxx` 或 `xxx` 都不行（2.1.283 上复测仍然如此） | 🔬 报 `blocked by permission rules`；同插件别的 skill 照常 |
| MCP 服务器 | `--disallowedTools mcp__<server>` | — | 🔬 探针服务器日志 0 次 `tools/call`，agent 说不在清单里 |
| 插件的 MCP | `--disallowedTools mcp__plugin_<plugin>_<server>` | — | 📖 本机工具名 `mcp__plugin_argus_argus-files__…` |

⚠️ **两个 `--settings` 不合并，后一个整个盖掉前一个**（🔬：同一次实验里第一轮
带了两个，skillOverrides 就没生效）。所以角色的额外参数里如果用户自己写了
`--settings '<json>'`，适配插件把它**并进同一个对象**；写的是文件路径时并不了，
就原样留着并在 `notes` 里说出来。

三条都不读 `env` 块里的值，也不写任何文件。

### 11.2.1 claude.ai 同步下来的东西埋深一层

开关对不对是一回事，**清单看不看得见**是另一回事：清点不到的项，
`Selection` 连问都问不到它，角色再怎么写也关不掉。2026-09-27 在本机量到的：
一个把本机全部 20 个自有 skill 都关掉了的总管角色，启动参数里一个 claude.ai 的
skill 都没有，`design` 插件的 7 个 skill 也全在。

原因是路径。别的东西都在一层：

```text
~/.claude/skills/<skill>/SKILL.md
~/.claude/plugins/cache/<市场>/<插件>/<版本>/…
```

claude.ai 同步下来的**多一层「账号桶」**：

```text
~/.claude/skills/synced/<账号>/<skill>/SKILL.md
~/.claude/plugins/synced/<账号>/<插件>/.claude-plugin/plugin.json
```

停在 `skills/<skill>` 的遍历，看见 `synced/` 底下没有 `SKILL.md`，就跨过去了。

两件跟着来的事，都是量出来的不是读出来的：

- **同步的 skill 吃 `skillOverrides`，按裸名。** 对照：`claude -p "调用
  theme-factory"` 调得到；同一句加
  `--settings '{"skillOverrides":{"theme-factory":"off"}}'` 报
  `Skill theme-factory is disabled for model invocation in skillOverrides settings`。
  和用户自己那份是同一个开关，所以同名的两份在清单里合成一行。
- **同步的插件不看 `enabledPlugins`。** 本机 `design@knowledge-work-plugins`
  在 `~/.claude/settings.json` 里是 `false`，它的 7 个 skill 照样在会话里。
  那个开关是给从市场装的插件用的，同步来的不走它——所以适配器**无条件列出**
  `plugins/synced/` 下每个带 `.claude-plugin/plugin.json` 的目录。

`synced` 是个普通名字，用户自己完全可以有一个叫这个的 skill 或插件。所以两边
适配器都先看这个目录自己像不像一个（有没有 `SKILL.md` / `plugin.json`）：像，
那它就是，没有桶。

### 11.2.2 「挡住调用」和「从清单里拿掉」是两件事

上面那张表里的开关分两类，而**它们的区别只有在 agent 的上下文里才看得出来**：

| 开关 | 调用会怎样 | 清单里还在不在 |
| --- | --- | --- |
| `skillOverrides: "off"` | 报 `disabled ... in skillOverrides settings` | **不在**（官方文档：`off` = Listed to Claude 为 Hidden） |
| `--disallowedTools Skill(p:x)` | 报 `blocked by permission rules` | **还在**——描述照样注入，照样花 token |
| `enabledPlugins: {"p@市场": false}` | 报 `Unknown skill: p:x` | **不在**，连该插件的 MCP 工具一起没了 |
| `disableBundledSkills: true` | 报 `Unknown skill: <名字>` | **不在** |

2026-09-27 的返工就是这条：同步的 skill 补上之后，角色确实把自有的和同步的都
隐藏了，但**插件的 80 多个 skill 全都还列在 agent 眼前**——`--disallowedTools`
只挡调用。用户看到的是「还是不太行」。

所以适配器现在分三档：

1. **一个插件的项全灭 → 整只关**，写 `enabledPlugins[<name>@<市场>] = false`，
   不再逐条 `Skill(...)`。实测（claude 2.1.283，每条带对照）：
   - `{"enabledPlugins":{"argus@argus-plugins":false}}` → 调 `argus:agent-inventory`
     得 `Unknown skill`，`mcp__plugin_argus_*` 一个不剩；同一次里 `kairos:…` 照跑。
   - `{"enabledPlugins":{}}` → `argus:…` 仍在。所以角色写的是**并进**用户的
     `enabledPlugins`，不是整个替换掉它——点名一个插件不会顺手关掉别的。
2. **只关一部分 → 还是逐条 `--disallowedTools`。** 这是「整只关」的粒度代价：
   留一个就没法整只关。同步来的插件也走这里，它没有第 1 档：
   `enabledPlugins` 写 `design` 或 `design@<市场>` **都无效**（两种写法都实测过）。
3. **Claude Code 自带的那些**（`code-review`、`run`、`init`、`artifact-design`……）
   ——`disableBundledSkills: true`，一个布尔，**全有或全无**。

⚠️ **自带的那一档在清单里是一行，不是十几行。** 它们在二进制里，磁盘上没有，
任何走目录的清点都列不出来（`claude --help` 也没有列 skill 的命令）。写死一张
名单会随版本过期，而这个布尔不会。所以适配器凭空造一行
`{"kind":"skill","id":"skill:.bundled","source":"claude-code"}`——`id` 不可能和
真 skill 的 `skill:<名字>` 撞，因为点号打头的目录在读之前就被跳过了。
实测：`disableBundledSkills` 开着时 `keybindings-help` 是
`Unknown skill`，而用户自己的 `ponytail` 照常。

> `skillOverrides` 其实有**四档**不是两档：`on` / `name-only`（只给名字不给描述）/
> `user-invocable-only`（agent 看不见，用户还能打 `/`）/ `off`。角色现在只用
> `on` 和 `off`。`name-only` 是个省 token 但保留可发现性的中间档，**还没做**。

## 11.3 形状：插件出答案，核心只认契约

```
plugin.json                               核心
  "agent_cli": {                          agent_cli.zig
     "label": "Claude Code",               discover()  沿 Plugin.searchPath 找声明了 agent_cli、
     "bin": "claude",                                  开着、能在本系统跑的插件
     "adapter": "adapter.py",              ask()       起一次适配器，问一个问题
     "adapter_windows": "…"  (可选)        Cache       后台线程读全部 CLI 的清单
  }
```

**适配器是一次性的可执行文件，不是插件的常驻进程。** 常驻协议是「事件进、确认出」，
而 feed 是广播，**没有「问某一个插件、等它答」的通道**；这两个问题又是纯函数
（同样的文件进，同样的答案出，调用之间什么都不留）。所以 manifest 另外点名一个
文件，一个问题起一次。一个插件可以两样都有——Claude Code 那个就是：常驻进程管注册
Polter，适配器管角色。

两个问题，请求是**第二个参数**（一段 JSON），回答是 stdout 上的一个 JSON 对象；
答不了就非零退出、原因写 stderr：

```text
adapter inventory '{"version":1,"cwd":null|"/abs","home":"/abs"}'
→ {"version":1,"installed":bool,"resume":true?,"notes":[…],
   "items":[{"kind":"skill"|"mcp","id":"skill:pdf","name":"pdf",
             "description":"…","detail":"http · host","source":"user|claude.ai|claude-code|project|local|plugin:<p>",
             "group":"<plugin>","group_description":"…","locked":bool}]}

adapter launch '{"version":1,"cwd":…,"home":…,"polter":…,"session":"<id>"|null,
                 "params":{"<参数名>":"<值>",…},
                 "role":{"key","name","instructions"},
                 "cli":{"skills":{"default":bool,"except":[ids]},"mcp":{…},"model":…,"args":[…]}}'
→ {"version":1,"argv":["claude",…],"env":{},"summary":"…","notes":[…]}
```

- **`params` 是插件自己那份设置里的参数值**（任务 #2235），和常驻那一半在握手里拿到的
  是**同一份**：`Plugin.settingsFor` 一处决定「用户那份 `<config>/polter/plugins/<key>.json`
  还是发行自带的 `settings.json` 生效」，`launch` 只是把这个答案原样送来（`agent_cli.launchParams`）。
  **适配器不去读那两个文件**：那条规则每多一种语言、多一个平台实现一遍，就多一个会漂开的答案。
  值一律是**字符串**（和 `hello` 行里的 `params` 同一个约定），布尔参数由适配器自己映射成
  CLI 要的类型。⚠️ **这个键每次都写**，一个参数都没有时是 `{}`；同时**适配器必须容忍它不在**——
  旧版 Polter 的 `+launch` 不会写它，那是「没有开关要设」，不是错误。
  ⚠️ **只有 manifest 里标了 `"to_session": true` 的参数会出现在这里**，别的参数一律不来。
  理由是这个请求走的是**适配器的 argv**（`agent_cli.ask` 把它拼在命令行上）：`ps` 能读到，
  崩溃报告里也会留着，而插件的常驻那一半是经握手和 socket 拿到参数的，没有这个问题。
  **值是字面量**：带 `env:` / `file:` / `keychain:` / `cmd:` 前缀的值**不被解析**，那一条被跳过
  并记一行日志（解析出来就是那个引用本来要避开的明文）。所以标记 `to_session` 的参数应当是
  「这个会话怎么跑」这一类（渲染方式、滚动方式），不是凭据。适配器对不认识的键不理会即可。
  用户文件里**缺**的 `to_session` 参数，会从发行那份 `settings.json` 补上（只补这一类，
  「用户文件整份生效」那条规则不动）。

- **接着某个会话**（任务 #1486）：适配器在 `inventory` 里答 `"resume": true`，就是在说「`launch`
  收到 `session` 时我接得上」。只认 JSON 的 `true`；没说的 CLI 核心**从不**给它发非空的 `session`，
  它永远是新会话，总控台的快照里说得出是这一家接不上（`cli_cannot_resume`）。`session` 这个键
  **每次都写**，新会话是一个发过去的 `null`，不是一个可能有可能没有的键。会话号是 CLI 自己经 hook
  报上来的那个字符串，核心不懂它，只把它限在 `[A-Za-z0-9._-]`、96 字节以内
  （`agent_cli.isSessionToken`）：它要被打进 shell 的启动行、最后成为 CLI 的一个参数，不合这个形状的
  就不接、起新会话，而不是为每一种 shell 各写一条引号规则。
  **会话已经不在了怎么办，归适配器先判**：找不到就退回新会话，并在 `notes` 里说一句——`+launch`
  在 CLI 接管屏幕之前把它打出来。选这条而不是「起不来时走 `launch_failed`、由核心换新会话再来一次」，
  是量出来的：`claude --resume <不存在的会话>` 打印 `No conversation found…` 后**自己退出 1**
  （2.1.296），而 POSIX 上 `+launch` 此时已经把自己换成了 `claude`，没有人能替它说「没起来」；
  核心只能等满一分钟才知道，而且知道的只是「没有 agent 连上」。适配器看不出来的那一种（会话文件在、
  CLI 却读不进去）仍然落到那一分钟上；那次启动若是接着会话的，下一次默认就不再接
  （快照 `resume.why: last_try_failed`）。Claude Code 这边的实测与判法写在
  `plugins/claude-code/adapter.py` 文件头。
- `id` 是适配器的，核心只存不懂。`locked` 的项（Claude Code 的是 `polter` 这个
  MCP）角色关不掉——关掉等于一个交不了活的终端，和第五节「`polter` 永远隐式在内」
  是同一条。
- `source` 为 `project` / `local` 的项（`<cwd>/.claude/skills`、`<cwd>/.mcp.json`、
  `~/.claude.json` 的 `projects[<cwd>].mcpServers`）角色**也关不掉**：`launch` 一律
  保留。角色是在设置窗口里写的，那里没有工作目录，这些项永远进不了 `except`；
  `default:false` 的角色（比如总管）于是会在它启动的每个项目里把它们全关掉，而且
  没有人能说「别关」。项目里的东西只在那个目录里看得见，角色管不到。同名时（项目
  skill 和用户 skill 同名）那一行算项目的，也就保留。
- 描述里**不许有秘密**：MCP 只给传输方式和主机名 / 命令的文件名，不给参数（令牌常
  以参数传），不给 `env`，URL 里的 `user:pw@` 剥掉。这两条有测试钉着。
- 关掉的插件不列：它已经在每个会话之外了，角色对它无事可做。

### 11.3.1 第三个问题 `identify`：手动起的 CLI 是谁（任务 #1635）

不经 Polter、手动敲 `claude` 起来的 agent 没有 hook，也没有角色启动记录：Bus 只知道「这里连着一个
agent」（它的 MCP 边车连上了），别的一概不知，总控台原来对它什么都不说。认它是谁，**归适配器**：

```text
plugin.json  "agent_cli": { …, "identify_env": ["CLAUDECODE","AI_AGENT","CLAUDE_CODE_SESSION_ID"] }

adapter identify '{"version":1,"cwd":…|null,"home":…,"pid":N|null,"sidecar_pid":N|null,
                   "env":{<只有本适配器在 identify_env 里声明的那几个>}}'
→ {"version":1,"me":true|false,"session":"<id>"|null,"session_written_ms":N|null,
   "quit":{"text":"/exit","ready":{"line":["❯"],"none_of":["esc to interrupt",…]}}|null,"notes":[…]}
```

- **变量从哪来**：边车 `polter +mcp` 握手时，按**所有已装适配器声明过的名字**读自己的环境，只带这些名字
  （值限短的可打印 ASCII），外加父进程 pid（Windows 暂为 null）。环境里的 key、token 一个字节都出不去；
  核心再按名字分发，每个适配器只看得到自己声明的那几个。日志里不打值。
- **谁被问**：声明了、而且手上至少有一个它声明的变量的适配器，按 key 顺序问，第一个答 `me: true` 的算数。
  一个都没有、都答 no、都失败，结论是 `unknown`——**这不是「没问题」**，总控台说「不认得的 CLI，状态未知」。
- `session` 是适配器找到、`launch` 接得上的会话；`session_written_ms` 是它的记录最后写入的时刻，
  「是不是还在这个会话里」由用的人判（Claude Code 边车的环境活过 `/clear`，id 会停在旧的那个）。
- `quit` 是让 CLI 退出要打的字，和**屏幕什么样时打才安全**：倒数几行里有一行去掉空格后**正好是**
  `line` 之一，而且没有哪一行含 `none_of` 的任何一个。没有屏幕规则就没有 `quit`，核心不打字。
- 在核心的 `Identities.zig` 里、独立线程上问；快照里落在总管的 `supervisor.hookless`。

### 11.3.2 第二个适配器：Codex（任务 #1667）

`plugins/codex/adapter.py`（Windows 上是 `adapter.ps1`，逐项移植，两份由
`test/codex-adapter/compare.py` 逐字比对）。下面每条都在 codex-cli 0.163.0 上量过：用临时的
`HOME` 和 `CODEX_HOME`、一把不是 key 的 key（模型调用全是 401，没花额度），再加一个把自己的环境和
父进程记下来的探针 MCP。怎么量的写在 adapter.py 文件头。

**角色落到 `-c` 上，不写任何文件。** codex 每次启动都会把 `-c key=value`（值按 TOML 解析）叠在
`config.toml` 上面。下面每一项都有对照，判据是那次会话的 rollout 里模型实际收到了什么：

| 角色要做的事 | 写法 | 量到的效果 |
| --- | --- | --- |
| 关一个 skill | `-c 'skills.config=[{path="<…/SKILL.md>",enabled=false}]'` | 模型的 skill 清单里没有它了，别的都在。`name=` 也有效；**用 `path=`**，因为个人 skill 和项目 skill 可能重名，只有个人的那个归角色管 |
| 关一个 MCP | `-c mcp_servers.<名>.enabled=false` | 那个服务器根本不起 |
| 角色说明 | `-c 'developer_instructions="…"'` | 换行和引号都原样到达模型。⚠️ 这一次会话里，它会**顶替**用户在 `config.toml` 里写的同名项，launch 会在 note 里说一句；`AGENTS.md` 不受影响 |
| 模型 | `-m <model>` | — |

- **skill 在哪**：`$CODEX_HOME/skills`、`~/.agents/skills`，以及工作目录下的 `.agents/skills`
  和 `.codex/skills`，四处都量过。codex 自带的在 `$CODEX_HOME/skills/.system`，source 记为 `codex`。
- **项目的东西角色不碰**，跟 Claude Code 那条规则一样：`<cwd>` 下的 skill 和 `<cwd>/.codex/config.toml`
  里的 MCP 都是项目的。
- **接着会话**：会话 id 就是 rollout 文件名尾部那段 UUID。rollout 在
  `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-<本地时间>-<uuid>.jsonl`，这个 id 也是它首行的
  `session_meta.session_id`，也是 codex 退出时打印的 `codex resume <id>`。`codex resume` 接受和
  裸 `codex` 完全一样的选项，所以续会话的命令是 `codex resume <id> <同样的选项>`。
- **永远带 `--no-daemon`**：codex 不进共用的 app-server 守护进程，会话在它自己的进程里跑。否则 hook 带的是守护进程的
  环境（多个终端会互相认错，#1668 读出来的）、MCP 子进程会比 TUI 活得久、会话记录也不归 TUI 管。0.163 碰巧只要
  命令行上有 `-c` 就不进守护进程（`config_exclusion`）；显式写出来，以后哪一版改了这条规则也不会悄悄变。
  `codex` 和 `codex resume` 都接受它，拿一个不存在的选项做过对照。只有 id 是 UUID 形状
  （不是 UUID 的，codex 会当成会话名去搜），而且 rollout 真在这台机器上，才会续；否则起新会话，
  并在 note 里说明原因。理由同 11.3。

**identify 不能照搬 Claude Code 的办法。** codex 给 stdio MCP 子进程的环境只有一张固定的短名单
（HOME LANG LOGNAME PATH SHELL TERM TMPDIR USER __CF_USER_TEXT_ENCODING），再加上那一项自己的
`env` 和 `env_vars` 放行的变量。里面**没有任何一样说「我是 codex」，也没有会话号**：二进制里有
`CODEX_THREAD_ID`，但不交给 MCP。所以：

- **me**：两种情况算是。
  - provision 写进 polter 那一项 `env` 里的标记 `POLTER_AGENT_CLI=codex`（`identify_env` 声明的就是它
    和 `POLTER_REGISTERED`）。
  - 边车的父进程叫 `codex`。量过：父进程就是原生 codex，exec 和 TUI 下都是，不是 app-server 守护进程，
    也不是 npm 的 node 包装。标记出现之前写的注册项，在 POSIX 上靠这条也认得出来。
- **session**：先看那个进程开着的 rollout（`lsof`，或者 `/proc`）。
  - 量过：codex 在自己进程里跑会话时，会一直开着自己的 rollout；TUI 还没跑第一轮时还没有 rollout。真 codex 上
    只给 pid、不给任何变量，大约 4 秒后（rollout 出现时）答出了那份 rollout 的 id。
  - **用 ChatGPT 账号登录时，TUI 把会话放在共用的 app-server 守护进程里跑**（任务 #1667，测试账号里量到）：退出
    时打印「Disconnected from this task. Any running work continues.」，Polter 的 MCP 子进程的父进程是守护进程，
    `lsof` 在那里找不到 rollout。用 API key 登录时我这边造不出这个模式：自己起了守护进程，TUI 也没去连它。
  - **父进程是守护进程时，不采用它开着的东西**（`is_daemon`：命令行里有 `app-server`）。守护进程开着的是所有连着它的
    会话。测试账号里量到过一次：接管就这样续上了另一个终端的对话（第二版的问题）。
  - 进程那边给不出时，**改按目录读记录，再按开始时刻认**（`by_directory`）：
    - 在近一天写过的 rollout 里，找首行 `session_meta.cwd` 等于这个终端当前目录的。核心调 identify 时把终端的 pwd
      一起传过去（`App.terminalCwd`；原来传的是 null）。
    - 再按开始时刻认：codex 的会话开始时就把 Polter 的 MCP 边车起起来，所以会话的 `session_meta.timestamp`（没有就用
      UUIDv7 里带的毫秒）和边车的启动时刻应当在 30 秒之内。边车现在会在握手里报上自己的 pid（`identity.self`，经
      `Sighting.sidecar` 到请求里的 `sidecar_pid`），adapter 用 `ps -o etime=` 算出它的启动时刻。
    - **恰好一份才答，否则答 null**：0 份（比如手动 `codex resume` 了一个旧会话）或多份（同一时刻在同一目录起了两个），
      都答 null；接管的问句会说「会开一个新会话」。宁可不续，不能续错。
    - 没有边车时刻时（Windows 现在就是），只有目录里恰好一份记录才答。
  - 返回的 `session_written_ms` 还要再过 `TakeOver.sure`：记录停写之后 agent 还在调工具，就不算数。
  - 没验证的推论：守护进程模式下，MCP 边车是在会话开始时起的。这一点要 C 在测试账号上核：会话开始时刻和边车启动时刻
    是否在 30 秒内。在我这边的进程内模式里核过：TUI 一启动就建会话、起 MCP 子进程，rollout 文件名的时刻和 TUI 启动
    时刻相同。
  - Windows 没有 pid，也没有边车时刻，只能走「目录里恰好一份」这一条。
- **quit**：`/exit`（#1640 量过，几秒内就退出）。屏幕规则只用真 codex 屏幕上读到过的字样：
  - 空闲时输入行是 `› Ask Codex to do anything`，另一句占位 `› Ask a follow-up question` 在二进制里
    紧挨着它；
  - 回合中多出一行 `• Working (7s • esc to interrupt)`；
  - MCP 批准框是 `Allow the polter MCP server to run tool …`，下面跟着 `› 1. Allow` 菜单，以及一行
    `enter to submit | esc to cancel`。

**官方角色配了两个 CLI 以后，「没说用哪个」怎么办。** 两个官方角色都加了 `codex` 段。原来的规则是
「配了多个 CLI、没指定就回 `ChooseCli`」。照这个规则，点菜单或调 `role_launch {role}` 都会从
「起 claude」变成被拒，而 codex 插件默认是关的，用户其实没得选。现在 `Persona.defaultCli`（由
`App.resolveLaunch` 调用）只在本机 `agent_cli.discover` 找得到适配器的那几个里挑：只剩一个就用它；
都在，或一个都没有，才回 `ChooseCli`。`discover` 只读插件目录和 manifest，不起任何进程。宿主菜单里
CLI 子菜单的过滤是 #1670。

**接管、孤儿边车、启动失败（任务 #1667，测试账号 c1669-05/08 读出来的三处）**

- **接管等它退出，看的是 shell 是否回到提示符**（`TakeOver.quitDone`），不再同时要求 agent 断开。原因同上：
  在守护进程里跑的会话，`/exit` 只退出了 TUI，会话和它的 MCP 连接都还在守护进程里。接着用
  `codex resume <id>` 重启，会连回同一个会话。
- **`polter +mcp` 跟着父进程走**（`cli/mcp.zig` 的 `watchParent`）：每秒看一次父进程，变了（被 launchd 或 init
  收养）就退出。原来只认 stdin 的 EOF；而 codex 留下的子进程继承了那个管道的写端，EOF 永远不来。实测：用角色
  起的 codex `/exit` 之后，边车以 launchd 为父进程留了下来，Polter 一直以为那个终端里还有 agent。
  - 端到端核过，用构建出来的 polter 起 `+mcp`，让它停在握手里、stdin 一直有人开着：
    - 启动它的 shell 退出后，新构建 1 秒内跟着退出；
    - 旧包 app-1669-abx 在同样条件下仍在运行（被 launchd 收养）；
    - 父进程活着时，新构建一直在。
  - 只做了 POSIX。Windows 上的进程不会被重新收养，要等父进程的句柄，没做。
- **`+launch` 起不来，会告诉起它的那位总管**（`Bus.tellLaunchFailed`，`PersonaStore.launcherOf`），不管 watch 有没有
  生效。第二版只报给「看着它的人」，可角色的 watch 要等 agent 第一次连上才生效（`role_launch` 回 `watch: later`）；
  CLI 根本没起来时谁都没在看，测试账号里实测就没报。现在：经 `role_launch` 由某位总管起的终端，启动失败只送给那位
  总管，别的总管收不到；人自己点的启动不算。
- **目录进不去，就不开**（`workdir.check`，用于 `terminal_open` 和 `role_launch`）：有这个目录、它也是目录，但没有
  进入的权限时（实测 `rw-r--r--`），原来照样开，shell 退到 `/`，codex 在那里起来，一句话都没有。现在回
  `CannotEnterDirectory` 并说明原因，什么都不开。判断方法是在打开的目录里再打开一次 `.`：没有搜索权限时它和 `chdir`
  一样会被拒（macOS 上实测）。总控台的「启动总管」还没用上这个检查：那里的拒绝码要两个宿主都翻译，留作后续。
- **`+launch` 起不来，会告诉看着这个终端的人**（`Bus` 的 `AgentNotice.launch_failed`）：
  - 原来 `launch_failed` 只用来撤掉「hooks 要来」，通报框里什么都没有。现在会进一行
    `launch failed Ns ago (<原因>)`，只报一次；
  - 没人看着的终端、已经开口说过话的 agent，都不报。

**守护进程下的边车不认领任何终端（任务 #1674）**

- **问题**：用 ChatGPT 账号登录时，手动起的 codex 把会话放在共用的 app-server 守护进程里，守护进程为它跑的
  每个会话起 MCP 边车，带的是守护进程自己的环境，也就是最先起守护进程的那个终端的 socket、token 和 id。测试账号里
  量到：第二个终端里手动起的 codex，`me` 答的是第一个终端，`group_create`、`group_post` 都记在第一个终端名下，
  `become_supervisor` 回 already。
- **安全层**（`cli/mcp.zig` 的 `parentIsCodexDaemon`、`serveUnclaimed`）：边车发现父进程是 codex 的 app-server
  守护进程（程序名是 codex，命令行里有 `app-server` 这个词；先读 `/proc`，没有就问 `ps`），就**不用**继承来的
  身份连 Polter。它自己当一个最小的 MCP 服务：工具清单里只有 `me`，任何调用都回一句话，说明为什么这里没有
  Polter、该怎么办（`codex --no-daemon`，或从角色启动）。读不出父进程时照常连，绝不凭猜拒绝。Claude Code 不受影响：
  它的边车的父进程是 `claude`。
  - 端到端（`test/codex-adapter/daemon-sidecars.py`，用构建出来的 polter 跑）：一个名叫 codex、命令行带
    `app-server` 的替身，用同一份继承来的身份起两个边车 → 本单的构建 0 个连接，两个边车都回答了 initialize，
    调 `me` 都回了带原因的错误；对照组的父进程是不带 `app-server` 的 codex → 两个边车都照常连上。旧包
    app-1669-c 在同样条件下两个边车都用继承来的身份连上了，复现了问题。
- **体验层**：codex 插件新参数「让手动启动的 Codex 也能被 Polter 认出」（`manual_out_of_daemon`，**默认关**，等
  用户定）。开时，provision 在 `~/.codex/config.toml` 的 `[features]` 里写一行 `daemon_auto_start = false`（0.163
  的稳定功能开关），关时撤回，只动这一行：
  - 写入的那一行带标记注释；如果 `[features]` 表是我们建的，表头也带标记；撤回时只删带标记的行，表里没别的
    键了才连表头一起删；
  - 用户自己写过 `daemon_auto_start` 的，原样不动，日志里说一句；
  - **不去停用户的守护进程**：已经在运行的会继续承载它上面的会话，这一行要等它退出（或者重新登录、重启）之后才
    生效。参数说明（中英文）和 provision 日志都写明了这一点；
  - 撤回逐字节还原：写入时在我们新建的 `[features]` 表头前加的那一个空行，撤回时连带删掉。由
    `test/codex-adapter/provision-settings.py` 守住：sh 和 ps1 各跑一遍，起始文件分为没有表、以空行结尾、已有表、
    空文件四种，判据是「关掉后逐字节等于原样」。
  - 实测（sh 和 ps1 各一遍，真 codex 0.163）：开后 `codex features list` 读到 false；再跑是 unchanged；关后读回
    true，文件其余部分逐字节不变；用户已有 `[features]` 表时，那张表和里面的键都在；用户自己设过的不动。
  - 为此 SDK 加了一个可选的扩展点 `host_settings_apply`（ps1 是 `Set-HostSettings`），在规则块之后调用；别的
    插件不定义它，就什么都不发生。
  - **没验证**：`daemon_auto_start = false` 是否真的让 ChatGPT 登录下手动起的 TUI 不去连已经在跑的守护进程。
    帮助文字说的是「自动启动」；要 C 在测试账号上核。

**hook 归 #1668。** launch 会调同目录 `hooks.py` 里的 `hook_args(polter)`（ps1 那边是 `hooks.ps1`
里的 `Get-CodexHookArgs`），把它返回的 `-c` 参数原样加进命令行，并回 `"hooks": true,
"hooks_heard": "first_turn"`。文件不在、抛了异常、返回的不是字符串列表，都按「没有 hook」处理，
不存在只装一部分的情况。

## 11.4 角色文件 v2

```jsonc
{ "version": 2, "personas": [ {
    "key": "reviewer", "name": "代码审查员",
    "description": "只读审查",            // 给挑角色的人看
    "instructions": "…",                  // 启动时附加到系统提示词
    "clis": { "claude-code": {
        "skills": { "default": false, "except": ["skill:pdf"] },
        "mcp":    { "default": true,  "except": ["mcp:plugin_kanban_kanban"] },
        "model": "sonnet", "args": ["--permission-mode", "auto"] } },
    // 以下是第一至十节那一半的字段，原样保留
    "prompt": …, "skills": […], "mcp": […], "tools": {…}, "hint": {…} } ] }
```

- **默认 + 例外，不是「开着的清单」。** 开着的清单分不清「用户取消了勾」和「写角色
  时它还不存在」，而这两件事天天发生：项目自己的 skill 只在那个项目里存在，用户随时
  装新东西。所以每类由人定一次「以后新来的给什么」（`default`），`except` 是勾成反
  方向的那些。界面上翻 `default` 时**把当前看得见的每一项的状态都保住**。
- v1 文件照读（读成没有 `clis` 的 v2），写回一律 v2。
- 窗口不编辑的字段**原样带回去**：一个手写角色的 `tools` 不能因为有人在窗口里改了
  说明就没了。

## 11.5 一个写者

`PersonaStore.put / remove` 是 Polter 里唯一写 `personas.json` 的代码：拼出新集合 →
整份写到旁边的临时文件 → `rename` 替换 → **用读手写文件的同一个 `load` 读回来**。

- **文件当前解析失败时拒绝写**（`FileUnreadable`）：那多半是用户手写到一半，写进去
  就是拿我们手里上一份好的把它盖掉。
- ⚠️ **换 arena 之前先重绑每个终端的状态。** `State.key` 和生效集借的是旧 arena 的
  切片，文件一辈子只读一次的时候这个悬垂不会发生，现在每次编辑都会。重绑规则：
  角色还在就重新穿上（roster 变，等着的 agent 会听到），被删了就脱掉。这条有地板
  （去掉重绑，测试红在「编辑后生效集」那一行）。
- 编辑之后唤醒**所有**穿着角色的终端，不只是发起编辑的那个。

## 11.6 「用角色启动」为什么是 `polter +launch`

启动参数由适配器（一个脚本）算，**不能在 app 线程上算**——那是所有终端的线程。
于是核心和界面都只做三件事：开一个标签页、给它这个角色、往里敲一行
`'<本程序>' +launch <角色> <cli>` 并回车。`+launch` 在**那个新终端里**：读角色库 →
找适配插件 → 问 `launch` → 打一行「Polter · 角色 · CLI — 关掉了几个」→
`execve` 成 `claude …`。

- 真正的命令行（JSON 设置、带引号和换行的系统提示词）**从不经过 shell**，没有人会把
  引号写错；敲进去的那一行只有两个 `[a-z0-9-]` 的 key 和一个加了单引号的路径。
- 出错的原因打在出错的那个标签页里，就是人正看着的地方。
- `exec` 之后 CLI 是 shell 的子进程，和手敲的一样，继承这个终端的
  `GHOSTTY_POLTER_*`——它的 `+mcp` 就是靠这个知道自己在哪个终端。
- 所有能拒绝的都在**开标签页之前**拒绝（角色不存在、没配这个 CLI、配了多个没说哪个），
  不留一个空标签页当回答。标签页开了却没及时出现时，`role_launch` 答 `OpenedEmpty`
  而不是一个 `id` 为空的成功——那个标签页里什么都没敲，是个普通 shell。

## 11.7 一个菜单，程序判断意图

标签页右键、终端右键、Agents 菜单里**只有一个「角色 ▸」**：

```
角色 A
角色 B        ▸ Claude Code / Codex   （配了多个 CLI 时才有这一层）
─────
不设角色
─────
角色库…
```

原先并排的「角色 ▸」（给正在跑的终端换装）和「用角色启动 ▸」（起新 agent）
被用户合并了：**让用户按操作挑菜单，等于把判断推给了用户**。现在点一个角色，
由 `App.choosePersona` 看这个终端里是什么：

| 终端里 | 点角色做什么 |
| --- | --- |
| 有 agent 连着 Polter，或者这个角色没配 CLI | **热切换**（第五节那条路）。CLI 自己的 skill / MCP 要下次启动才变，菜单顶上那行「可能要重启」照旧说 |
| 停在 shell 提示符上 | **就在这个终端里启动**，不开新 tab |
| 前台有别的程序在跑 | **开新 tab 启动**——往一个不是 shell 的程序里敲命令，是在别人的活上打字 |

「有没有 agent」用的是 `Server.agentPresent`，**不是一张 CLI 名单**：任何走
Polter MCP 的 CLI 都算，所以这里不认识 Claude Code。「在不在提示符」用的是
shell 集成的答案（关 tab 时要不要确认也是问它）；没有 shell 集成时答「不在」，
那是安全的方向——结果是开新 tab，而不是往里敲。

旧的「角色编辑器」窗口删了：它能做的（选角色、看生效集）菜单和角色库都覆盖了。

同一条动作 `poltergeist_persona_set:<key>[,<cli>]` 在核心里判断，所以 Windows
菜单点角色也走这套逻辑。Windows 的角色库窗口见 `windows/host/src/roles_ui.rs`（2026-09-23 起）。

总管工具：`role_list`（全部角色，形状就是 `role_put` 收的）、`role_put`、`role_delete`、
`role_clis`（各 CLI 装了什么，读缓存；`stale` / `refreshing` 分开说）、`role_launch`
（总是开新 tab）。五个都只给总管，插件不可调。

## 11.8 Windows：真机上测出来的三件事

Windows 测试机上，隔离配置目录 + 一个 PowerShell 写的假 CLI 插件：

1. **Windows 开 tab 是异步的**，核心同步找不到新终端，`role_launch` 曾一律答
   `OpenedEmpty`、留一个空 shell。改成「待启动」：tab 没及时出现就记下，**下一个
   完成 `init` 的终端来认领**（`App.claimPendingLaunch`，10 秒过期）。
2. **敲进去的那一行在 Windows 上是另一句话**：`& '<polter-cli.exe>' +launch …`——
   PowerShell 跑带引号的路径要 `&`；用控制台版 `polter-cli.exe`，因为 GUI 版给不了
   子进程控制台；**Windows 没有 exec**，`+launch` 改为起子进程、等它、把退出码带回。
3. **Windows 没有 `HOME`**，请求里的 home 回落到 `USERPROFILE`。

修完之后的读数：`role_put` 两次（第二次改名覆盖已有文件）、`role_list`、坏 key 被拒、
`role_clis` 经 PowerShell 适配器读到清单、`role_launch` 答 `ok` 且随后新 tab 里
`polter-cli +launch` 调到适配器（带转义引号的指令原样到达）并起出子进程——子进程
写出的标记同时带着适配器给的环境变量和这个终端的 Polter 管道地址。

## 11.9 没做的，和没验证的

- ~~**Windows 没有角色库窗口**，菜单也还是 Windows 自己那一份（有旧的编辑器入口）；
  核心那一半（点角色的判断、`+launch`、`role_*`）已在 Windows 真机上走通。~~
  **两句都已不成立。** 窗口有了（`roles_ui.rs`，旧的 `personas_ui.rs` 已下线，与 mac
  63ab92741 一致）。而「已在真机上走通」**当时就不对**：11.8 在真机上用的是一个
  PowerShell 写的假插件，随包发的 claude-code adapter 是 `.py`，Windows 起不了——
  2026-09-23 真机上第一次用它，角色启动开箱即失败。
- **两个适配器：Claude Code，以及 Codex（11.3.2，#1667）。** 别的 CLI 照 11.3 各写一个插件。
  Claude Code 的那个在 Windows 上是
  `adapter.ps1`（manifest 的 `adapter_windows`），是 `adapter.py` 的逐项移植：Windows 上
  `.py` 起不来，Polter 在 Windows 上也不带 Python。两份的输出由
  `test/claude-code-adapter/compare.py` 按同一组夹具逐字比对（允许不同的三处及理由写在
  脚本开头）；mac 上用 pwsh 跑过，**Windows PowerShell 5.1 上没验证**，`argv[0]` 从
  `claude.cmd` 找到真正的 `claude.exe`（或 `node.exe` + `cli.js`）那一段也只在 Windows 上
  走得到。
- **菜单是人点的，没有人点过合并后的菜单。** Mac 上 `role_*` 与 `+launch` 用 `+mcp`
  在一个新实例里真跑过（claude 的 argv 与角色逐项对得上；关掉的 skill 调不到、MCP 不在
  清单里；指令经对照实验确认送到）；点菜单这一步（`ghostty_surface_binding_action`）
  没有 agent 能替人做。
- Swift 测试编过、没跑（以 app 为宿主会起第二个 Polter）。窗口是离线渲染真源码核的图。

# 十二、角色的 Polter 一半，和内置的「Polter 总管」

## 12.1 为什么要有这一半

第十一节的角色只说 **CLI 带什么**：skills、MCP、模型、指令。可用户选「总管」
角色，要的是**这个终端当总管**——那是 Polter 里的身份，不是 CLI 的配置。以前
得启动完再去菜单点一次「设为总管」；worker 起来后还得总管再 `set_watch` 一次，
这一步常被漏掉。

于是角色多了一个 `polter` 对象（`persona.Polter`）：

| 字段 | 意思 | 谁能设 |
| --- | --- | --- |
| `supervisor` | 启动后设为总管 | **只有用户** |
| `may_authorise` | 允许总管替它回答权限问题。只加不减：不勾 = 跟默认值走（默认开，2026-10-12 起），不是拒绝 | **只有用户** |
| `shielded` | 护盾，任何工具都碰不到 | **只有用户** |
| `watch` | 交给启动它的总管（用户启动时：唯一的那个总管）监管 | 总管也可以 |
| `open` | `auto`（在提示符处就地，否则新 tab）/ `tab`（始终新 tab） | 总管也可以 |
| `quiet_ms` | 静止多久算卡住，≥ 1000 | 总管也可以 |

不放进来的：**无人值守**是 CLI 自己的参数，已经可以写在 `args` 里；**按住（held）**
是用户此刻的临场决定，写进角色就成了永久的。

## 12.2 两条规则

**一、授予类三项只有用户能改。** 这就是 §7.1 被划掉时留下的那个理由：总管能
`role_put` 写角色，也能 `role_launch` 启动。若它能勾上「代答权限」，就能写一个
角色、再启动，**给自己授权**。所以 `PersonaStore.put(…, who)`：`who = .supervisor`
时，这三项必须与现有角色一致（新角色即全关），否则整个请求以 `NotPermitted`
拒绝——拒绝而不是悄悄保留，这样总管读回来的就是它发出去的。角色库窗口走
`.user`，什么都能设。

~~**二、只在启动那一刻生效一次**（`App.startRoleIn` → `applyRoleStanding`）。~~
**二、在启动出来的 agent 连上 Polter 时生效一次**（`App.startRoleIn` →
`PersonaStore.holdStanding` 挂起；该终端第一个请求到达时 `rpc.arrived` →
`PersonaStore.claimStanding` 应用）。

> 2026-09-23 改的，W3 在 Windows 真机上测出来的：原来在敲 `+launch` 那一行**之前**
> 就应用，而 `+launch` 失败（adapter 起不来）时 host 日志照样打「started in a
> supervisor role」——终端成了总管，里面却没有 agent。身份是给 agent 的，所以等
> agent：
>
> - **生效点**是该终端的第一个请求到 app 线程、被回答**之前**（在 `authorize`
>   之前），所以 agent 的第一个 `me` 读到的已经是新身份。`persona_wait` 会被
>   app 挂起而不走 `dispatch`，所以挂起前也调一次；领取只有一次，重复调用无害。
> - **`+launch` 失败 → 永远没有请求 → 身份不生效。**
> - **会过期**：`PersonaStore.standing_wait_ms`（60 秒，awake 时钟）内没连上就作废，
>   以免很久以后在这个终端里手敲的 `claude` 捡到它；到期的在领取时丢掉，不留。
>   同一终端再启动一次会替换它，新角色没有身份可给时直接清掉。
> - 看得见：`terminal_capabilities` 的 `pending_standing`（还剩多少毫秒）；
>   `role_launch` 的 `watching` 在「role 有 watch、agent 还没连上」时**省略**，
>   不答 `false`。
> - ⚠️ 窗口：`agentPresent` 在握手时就为真，身份要等第一个请求。这之间总管看到
>   「有 agent、还不是被监管」是真实状态，不是错。
> - ⚠️ 判据是「这个终端来了请求」，不是「来的是那个 CLI」：一分钟内在这个终端里
>   别的程序用这个终端的 token 连上来，也会领走它。

之后就是这个终端自己的状态：用户撤掉总管，角色不会把它「纠正」回来；给一个**已经在
跑**的终端换角色，只换工具，不动身份（热换不经过 `startRoleIn`，什么都不挂）。否则把
一个 worker 换成「总管」角色，它会突然开始监管别人——这是唯一一种在发生处看不见的
变化。

`open = tab` 连「有 agent 在就热换」那一支也跳过（`App.choosePersona`）。

~~内置总管角色用的是 `open = tab`，理由是在 worker 的菜单里点它应该得到新总管 tab，
而不是 worker 穿上总管角色。~~ **改成了 `auto`**（2026-09-22，用户实测报的 bug）：
想把一个正在跑的 agent 切成总管、或在停在提示符的终端里就地起总管，结果都被送去了
新 tab。点角色的人要的是「这个终端」，不是「另开一个」；想另开就用启动菜单或
`role_launch`。

## 12.3 总管身份怎么让 agent 知道

菜单里「设为总管」会推一条 `[Polter] You are now the supervisor…`
（`Surface.zig`）。启动时不能这么做：那一刻 agent 还没起来，`tellSurface` 会把它
**打印到 shell 上**。所以这句话随启动走：`persona.launchInstructions` 在
`supervisor` 为真时把 `supervisor_launch_note` 放在角色自己的指令前面，由
`polter +launch` 交给 adapter。用户自己写的总管角色，指令留空也不会起一个「是总管
却不知道」的 agent。

## 12.4 官方角色（原「内置角色」）

**2026-10-14 重写**（任务 #1504，用户定的：官方角色和 skill「不能代码写死，方便以后更新或者
用户可以自己调整」，「留一个还原功能」）。旧的写法和它的理由留在本节末尾，划掉并写了为什么改。

### 官方版本是数据，随二进制走

- 一个官方角色是 `src/poltergeist/roles/` 下的两个文件：`<key>.json`（就是 `personas.json`
  里一个角色对象的形状，同一个 `persona.personaOf` 解析）和 `<key>.md`（提示词；JSON 里
  不许再写 `instructions`，两份文本就没有人说得清用的是哪份）。现在两个：
  `polter-supervisor`、`polter-tester`。
- **构建时整份解析，坏了红构建**（`src/build/PolterOfficial.zig`）：它枚举这个目录、用程序自己
  的解析器读每个文件、生成嵌入清单 `polter_official`。放在构建脚本而不是测试里，是因为带
  `-Dtest-filter` 的构建不编译没点名的测试——测试守不住的那种构建，正是日常跑得最多的那种。
  地板四格（JSON 写坏 / JSON 里带 instructions / key 不等于文件名 / skill 的 name 不等于文件名）
  都红在 `zig build` 的第一行，点名文件。
- **「官方版本」= 这个二进制带的那一份**（`@embedFile`）。不在运行时从资源目录读：app 和
  `polter +launch` 是两个进程（Windows 上是两个 exe），运行时读就多一种「打包清单漏了一个文件
  → 总管角色消失、总控台起不了总管」的失败；而升级官方角色本来就是换安装包。
- 名字、说明、提示词一律英文，随包只有这一份。**宿主直接显示英文名**，不再按 key 换成本地化
  文字（原先 `Role.displayName` 等四处）。界面自己的字（「官方」「恢复出厂设置」）照常本地化。

### 用户的改动是一份覆盖

存在 `personas.json` **旁边**的 `official-overrides.json`（同一条路径规则，所以测试实例隔离了
角色库也就隔离了它），按字段存，每个字段带「改的时候官方是什么」：

```json
{"version":1,
 "roles":{"polter-supervisor":{
   "instructions":{"value":"…","base":"…"},
   "clis.claude-code.model":{"value":"opus","base":null}}},
 "skills":{"supervising":{"base":"<保存时随包那份的 sha256>"}}}
```

- 生效的角色 = 官方逐字段，被覆盖的字段取 `value`（`official.effective`）。**没改过的字段升级后
  自动跟新版，改过的保持用户的。**
- 字段单位：`instructions`｜`polter.watch` / `polter.open` / `polter.quiet_ms`｜`clis.<cli>`
  （这个 CLI 在不在）｜`clis.<cli>.skills` / `.mcp` / `.model` / `.args`。
- 保存时与当前官方相同的字段不写，所以「改回去」= 这一项覆盖自己消失。已有的覆盖若值没变，
  **保留它原来的 `base`**：把同一句话再说一遍不会让它变新，「官方版本有更新」的提示也不该因为
  用户存了别的东西就消失。要消掉它，用户说一声「知道了，仍用我的」（`acknowledge`，见 12.5）。
- **不放进 `personas.json`**：旧版 Polter 读到官方 key 会整份拒读，降级一次用户的整个角色库
  就空了。

### 四种状态，「不知道」和「没有」分开

`role_list` 与角色库目录里，官方角色带 `builtin: true` 和

```json
"official": {"state": "pristine|modified|modified_stale|unknown",
             "overridden": ["字段…"], "stale": ["字段…"], "reason": null}
```

| state | 意思 |
| --- | --- |
| `pristine` | 没改过 |
| `modified` | 改过；被改字段底下的官方值和改的时候一样 |
| `modified_stale` | 改过，而且至少一个被改的字段官方后来也变了（`stale` 点名）——界面提示「官方版本有更新」 |
| `unknown` | 有东西写着但读不出来：整份文件读不了、不是 JSON、版本不认识、这个角色那一项里有不认识的字段或某字段缺 `base`。**此时生效的是纯官方角色**（半份覆盖和整份长得一样，所以一点都不套），`reason` 说原因 |

`persona.Official` 的字段都**没有默认值**，没改过的那个有具名常量 `.pristine`——「没改」和「读不出
改了什么」看上去都是一个出厂角色，漏写一行就会把一个写成另一个（仓库规矩第 5、6 条）。
整份文件用不了的原因另在目录顶层 `overrides_error`；只有某一项坏不算文件坏。

### 谁能改什么

开放（界面里改，存成覆盖，可还原）：上面那几个字段。锁住，**谁都不能改**：`key`、官方属性、
名字、说明、三项授权类开关（总管的 `supervisor = true` 在内）、v1 遗留的
`tools` / `skills` / `mcp` / `prompt` / `hint`。改了锁住的东西整个请求被拒，四个错误名分别点名
（`LockedName` / `LockedDescription` / `LockedStanding` / `LockedField`）——拒绝而不是悄悄保留，
理由和 12.2 第一条一样：读回来的应当就是发出去的。

**AI 不能改官方的东西。** 官方角色的提示词就是它的 agent 的边界——总管的那份写着总管自己能
决定什么——让 agent 能改它等于让它自己给自己松绑。实现挂在现成的那条线上：`PersonaStore.put`
的 `who`，界面（`ghostty_app_persona_put`）是 `.user`，agent 能碰到的一切写入（`role_put`）是
`.supervisor`，对官方 key 一律 `BuiltinRole`，连「什么都没改」的写入也拒。`role_delete` 对官方
key 对谁都拒。还原、认领、skill 的保存与还原**只有 C 接口**，`rpc.Method` 里没有对应项。

### 恢复出厂设置

`PersonaStore.restore(key, everything)`：把这一个角色的那一项从覆盖文件里拿掉，别的项原样
留着（在 JSON 值上改，所以连本版读不懂的项也带得过去）。

**整份文件解析不过时**，没法只拿掉一项——不知道它在哪。此时 `everything = false` 被拒
（`OverridesUnreadable`），文件一个字节不动；宿主要先用这句话问用户：「改动文件读不了；恢复会把
**全部**官方角色与 skill 设回出厂，读不了的文件留作 `official-overrides.json.unreadable-<随机>`」，
得到同意再以 `everything = true` 调用，文件被**改名留存**而不是删除。同一个状态下保存新的改动
也被拒，不会把读不了的文件盖掉。

### 旧数据：文件里已经有一个官方 key

`polter-tester` 在成为官方 key 之前是谁都能用的名字，所以这不再只是「有人手写了
`polter-supervisor`」的问题。**不再整份拒读。** 那一项不进生效集（官方的赢），原样留在
`Set.shadowed` 里，`writeSet` 每次都把它写回文件——之后任何一次保存（用户的、总管的、删除）都
冲不掉它。目录里 `shadowed: [{key, name}]` 让界面说出来；`PersonaStore.adopt` 在**用户点了
之后**把它改成 `<key>-mine`（撞了加数字）变成用户自己的角色。读文件时不改用户的文件，也不把它
当成覆盖（名字、授权位的语义对不上）。

### 两个官方角色的内容

- `polter-supervisor`：与原来写死的那份逐字相同。
- `polter-tester`（新）：通用的测试 worker——只测不改、先说清测的是哪个产物、结论带证据、要人
  授权就停、只清自己起的、做完或卡住先 `task_progress` 再 `group_post`。不是总管，`watch` 开，
  skill 只留 `polter-operating-a-terminal`，MCP 全关。不写本仓、某台测试机或某个工具的事。
  用户自己库里原有的测试角色不受影响。

### 官方 skill 走同一套

- **清单不写死**：运行时列资源目录 `poltergeist/*.md`（`skill_store.shipped`），构建时列源码目录。
- **哪一份在用，只有一个函数说了算**（`skill_store.resolve`）。原先有两个答案：`skill_read`
  读 `<配置>/polter/polter/skills/`（目录拼了两次），交给各 CLI 的那份读
  `<配置>/polter/skills/`。用户按文档放一份，CLI 拿到改过的、`skill_read` 还答出厂的，没有任何
  地方说。现在以 `<配置>/polter/skills/` 为准；多拼一层的旧位置仍读（排在后面，用到时打一行
  日志），免得谁放过的文件静默失效。解析不过、或 `name` 不是这个 skill 的副本不用。
- 用户的副本仍是整份文件，保持纯净（它会原样进各 CLI 的 `SKILL.md`）；「它是照哪一版改的」记在
  `official-overrides.json` 的 `skills.<name>.base`。四种状态同上：有副本而没有记录 = 用户手放
  的文件 → `unknown`（分不出官方变没变），不是「没更新」。
- 保存或还原之后核心**重发一次 provision 事件**，各 CLI 的插件按内容比较重写它那份
  `polter-<name>/SKILL.md`。`skill_read` 每次读文件，立刻生效。
- ⚠️ 插件会删掉不再随包的 `polter-*` skill，而清单现在来自列目录。**「资源目录读不到」绝不能
  到了那边变成「什么都不随包了」**：`skill_store.provisioned` 此时给 null，核心交出空清单，两份
  插件 SDK 都把空清单当作「没说 skill 的事」、不删任何东西（`provision.sh` / `provision.ps1`
  「only when the line actually parsed into a list」）。中途少了一个也算读不到，不交半份清单。

### 被推翻的旧写法

> ~~`persona.builtins` 目前一个：`polter-supervisor`。~~
>
> ~~- **不写进 `personas.json`**，由读者补上：`parseLeaky` 把它放在最前面，没有文件
>   时 `builtinSet()`——应用和 `polter +launch`（另一个进程）都是这样。若写进文件，
>   用户删了它下次启动又回来，用户改了它升级时不知道该不该覆盖。~~
> ~~- 文件或 `role_put` 用了这个 key：`ReservedKey` / `BuiltinRole`，删它：`BuiltinRole`。
>   想改就在角色库里「复制」一份。~~
> ~~- 名字和说明在核心里是英文，mac 界面按 key 显示本地化文字（`Role.displayName`）。~~

为什么改，逐条：

- 「改了之后升级不知道该不该覆盖」是真问题，但答案不必是「所以不许改」。它问的其实是「这个字段
  是用户改的还是旧版留下的」，**按字段存覆盖并记下 `base`** 就能回答，而且比「整份覆盖/整份
  不覆盖」多回答一件事：官方后来动没动用户改过的那个字段。「删了又回来」则原样保留——官方
  角色仍然不能删，只能还原。
- 官方角色仍然**不写进 `personas.json`**，由读者补上，这一条没变；变的是「补上的是什么」：
  数据文件加覆盖，而不是一个 Zig 常量。
- `ReservedKey` 整份拒读在只有一个、谁也不会碰巧用到的官方 key 时是对的；第二个官方 key 一出现，
  它就会把已经有同名角色的用户的整个库清空。
- 按 key 本地化官方名：用户定了官方角色与 skill 全文英文，带「官方」标志的名字就该是出厂的
  那个名字。

## 12.5 没做的，和没验证的

- ~~**Windows 没有角色库窗口**，所以那边改不了 Polter 一半；内置角色与启动时的身份
  走核心，理应生效，**未在 Windows 真机上测**。~~ 窗口已有；真机读数见 status 与
  roles-win 群 #699（第一阶段：内置角色在、启动成总管、watch 归启动者、保留 key 整份
  拒读——并由此测出 12.2 第二条改成「agent 连上时生效」）。
- `watch` 在「用户启动、有多个总管」时不交给任何人，只写一行日志，界面上看不出来。
- ~~「官方版本有更新」的提示目前只有还原或重改那个字段才会消失。~~ 已补
  `PersonaStore.acknowledge`（`ghostty_app_persona_acknowledge`，只有界面能调）：「知道了，仍用
  我的」把这个角色每个覆盖的 `base` 提到当前官方值，状态回到 `modified`，用户的值不动；官方
  再变一次会再提示。官方 skill 同样有（`skill_store.acknowledge`，
  `ghostty_app_official_skill_acknowledge`）：把记录的哈希提到当前随包那份；用户手放、没有记录的
  副本也借此得到记录，从 `unknown` 变成 `modified`。
- 官方 skill 改完后，**已经在跑的 agent 什么时候读到新的 `SKILL.md` 是各 CLI 自己的事**
  （附录 A.3）；核心只保证文件被重写、`skill_read` 立刻是新的。重发 provision 之后插件确实
  重写了文件——这一步是读脚本推的，没在真机上跑过。
- `personas.json` 自己解析不过时，官方角色的保存与还原也被拒（`FileUnreadable`）：重读会留住
  上一份好的集合，写进去的东西看不见。

---

# 十三、总管查任意终端能力：`terminal_capabilities`

## 13.1 为什么要有

总管派活之前要知道对方手上有什么：穿的什么角色、CLI 是不是按角色起的、关掉了
哪些 skill 和 MCP、能看到哪些 Polter 工具、谁在管它。以前只有 `persona_face`，
而它**故意只问自己**（personas-contract.md ⑤ 第 1 条下面那段划线）。用户
2026-09-22 定的新规则：

- **worker 之间互相看不到，仍然对。** worker 查别人是低权限方摸边界，这正是当初
  「踩点面」担心的事，继续关着。
- **总管必须能查任意终端**——worker，也包括别的总管（为以后多总管铺路）。总管
  本来就能 `terminal_read` / `terminal_send` 任何未护盾终端，读屏幕或直接问那个
  agent 就能知道这些；结构化查询**不新增可及范围**，只是把猜变成读。

所以是**一个新方法**，而不是给 `persona_face` 加回 `id`：`persona_face` 对所有人
都只问自己，新方法对总管以外的所有人都关着。两条规则各自没有例外。

## 13.2 规则

| 调用者 | 结果 |
| --- | --- |
| 总管，问任何未护盾终端（含别的总管、含自己） | 回答 |
| 总管，问护盾终端 | `Shielded`，与其它工具一致 |
| 总管，问不存在的 id | `UnknownTerminal` |
| 非总管，问任何人（**包括自己的 id**） | `NotPermitted`；查自己用 `persona_face` / `me` |
| 插件 | `NotPermitted`（插件从来不是总管） |

`rpc.requiresSupervisor` 给出 `true`，`selfPermitted` 给出 `true`，护盾走
`authorize` 里那条对所有人都一样的检查。

## 13.3 回答

一次给全，四段；每个「没有」都是可见的 `null`，不是缺字段或空串：

- **`role`**：`key` / `name` / `deviated` / `builtin`；不穿角色时 `null`。
- **`started`** + **`cli`**：`launched`（按角色**启动**，CLI 那一半生效了，`cli`
  有值）、`worn_hot`（运行中**热换**上的角色：CLI 还是它启动时那样，所以 `cli`
  是 `null`，而这个 `null` 是答案不是缺口）、`none`。`cli` 里是 CLI 的 key、启动
  时用的角色 key（热换过之后可以和 `role.key` 不同）、`model`、`args`，以及这个
  CLI 的 skills / MCP 各 `kept` / `off` 哪些。
- **`polter`**：它此刻能看到的 Polter 工具（和它自己问 `persona_face` 得到的是
  同一个函数，`App.visibleTools`）、角色列的 Polter skills、上游 slots；
  `unfiltered: true` 表示没穿角色、什么都不扣。
- **`standing`**：`supervisor` / `watched_by` / `may_authorise` / `shielded` /
  `held`，取自 Bus。`shielded` 在成功的回答里恒为 `false`（护盾终端在查之前就被
  拒了），留着是为了形状自己说明这一点。
- **`agent_present`**：此刻有没有 agent 从那个终端连着 Polter。启动记录会比它描述
  的 CLI 活得久（agent 退出、剩下 shell），靠这一位区分。

## 13.4 「用哪个 CLI 启动的」记在哪

以前没有地方记：`App.startRoleIn` 只拿到角色 key 和一行命令。现在它拿到
`(key, cli)`，在敲那行命令时调用 `PersonaStore.noteLaunch`，把角色对这个 CLI 的
`CliChoice`（Selection、model、args）**拷贝**一份存在 `PersonaStore.launches`
里，每条一个自己的 arena。

- **和 `states` 分开存**：热换改 `states` 不改这里，重新启动改这里。只热换过的
  终端没有这条记录，`started` 就是 `worn_hot`。
- **启动时拷贝，不是事后查**：之后改角色不会改到已经在跑的 CLI。
- 异步开 tab 的那条路（`PendingLaunch`）也带上了 `cli`。
- 终端关闭时 `PersonaStore.forget` 一并释放。

`kept` / `off` 是**现在**的清单（`agent_cli.Cache` 的副本，不在 app 线程上跑
adapter）配**启动时**的 Selection 算的，规则和 adapter 拼命令行时一样：
`locked`（Polter 自己的服务器）永远保留，其余按 `Selection.enabled`。清单还没
读过：`inventory: "stale"`，`skills` / `mcp` 为 `null`——**不给空列表**，否则
「不知道」会读成「什么都没关」。CLI 在这台机器上已不在列：`absent`；adapter
答不上来：`failed` + `error`。

## 13.5 没做的，和没验证的

- **启动记录是「敲下那行命令时」的**，不是 CLI 真正起来之后的：`+launch` 在新
  进程里自己再解析一次角色并问 adapter，两次之间角色被改、或 `+launch` 失败，
  这里都看不出来。`agent_present` 能说明 agent 在不在，说明不了它是不是按这条
  记录起的。
- 启动之后装上的 skill / MCP 按 Selection 的 `default` 归到 kept 或 off——这和
  那个正在跑的 CLI 实际有没有它**未必一致**（它启动时还没有这一项）。
- **未在真机上核**：测试里构造了回答（`rpc.zig` 的 `terminal_capabilities:` 那
  五条），真机上由总管核。

---

# 附录 A：探针

**这三段是本章所有 🔬 结论的来源，也是以后重测的唯一办法。**
宿主行为会随版本静默变化，而「读到一条说支持的源码」和「今天真的支持」
长得一样。建议连同本章一起进仓，当回归用例。

## A.1 会中途换工具列表的 MCP 服务器

`probe2.py`：暴露 `probe_alpha`；它被调用后换成 `probe_beta`，并发一条
`notifications/tools/list_changed`。所有收发写进 `$PROBE_LOG`。

**判据在服务器日志上，不在 agent 的回答上**：

- `tools/call(probe_alpha)` 出现 → 这次实验有效（否则是审批拦了，阴性不算数）
- `FLIP` + `OUT … list_changed` 出现 → 通知真发出去了
- 之后**有没有第二条 `tools/list`** → 这就是答案

## A.2 各宿主怎么喂给它

```sh
# claude-code（🔬 通过）
claude -p "<提示词>" --model haiku --strict-mcp-config \
  --permission-mode bypassPermissions \
  --mcp-config '{"mcpServers":{"probe":{"command":"python3","args":["…/probe2.py"],"env":{"PROBE_LOG":"…"}}}}'

# codex（🔬 不通过；没有最后那个 -c 的话审批会拦掉，阴性无效）
CODEX_HOME=<独立目录，内含 auth.json 与 config.toml> \
codex exec --skip-git-repo-check -s workspace-write \
  -c approval_policy='"never"' \
  -c 'mcp_servers.probe.default_tools_approval_mode="approve"' "<提示词>"

# gemini / qwen：在一个 scratch 目录里放 .gemini/settings.json 或
# .qwen/settings.json（项目作用域，不碰用户配置），再 -p 跑。
# 本机两家都因账号问题跑不起来。
```

提示词：

> Call the tool named probe_alpha. Then check your tool list again: if you
> now have a tool named probe_beta, call it too. Report exactly which probe_
> tools you called and what each returned.

## A.3 skill 热改

两轮对话（`--input-format stream-json`），中间往 `<cwd>/.claude/skills/`
写入或删除一个 skill 目录。

**第二轮的问法必须是「去调用它」，不能是「你有没有它」**——后者会读到第一轮
留在上下文里的旧清单，于是「没撤掉」和「撤掉了但它还记得」长得一样。
判据是 `Unknown skill: <name>`。
