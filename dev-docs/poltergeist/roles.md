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
| `qwen-code` | ⚠️ 主客户端没接 | ✅ 另有运行时通道 | 📖 源码 |
| `codex` | ❌ **冷** | ？未测 | 🔬 真机实测（有效阴性） |
| `opencode` | ⚠️ 收到了没人消费 | — 无 skill 概念 | 📖 源码 |
| `kimi` | ？未知 | — 无 skill 概念 | 文档没写 |
| `deepseek` | ？未知 | — 无 skill 概念 | 未查 |

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
| **温** | qwen-code | 走它自己的运行时接口（`/skills`、`serve` 的扩展刷新） |
| **冷** | codex、opencode、kimi、deepseek | **只能重启** |

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
| qwen-code | `--system-prompt` / `--append-system-prompt` / `--mcp-config` / `--allowed-mcp-server-names` / `-e` | 📖 help |
| opencode / kimi / deepseek | 待核 | — |

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
| 插件的 skill（`argus:xxx`） | `--disallowedTools "Skill(argus:xxx)"`（bypassPermissions 下也挡） | `skillOverrides`，写 `argus:xxx` 或 `xxx` 都不行 | 🔬 报 `blocked by permission rules`；同插件别的 skill 照常 |
| MCP 服务器 | `--disallowedTools mcp__<server>` | — | 🔬 探针服务器日志 0 次 `tools/call`，agent 说不在清单里 |
| 插件的 MCP | `--disallowedTools mcp__plugin_<plugin>_<server>` | — | 📖 本机工具名 `mcp__plugin_argus_argus-files__…` |

⚠️ **两个 `--settings` 不合并，后一个整个盖掉前一个**（🔬：同一次实验里第一轮
带了两个，skillOverrides 就没生效）。所以角色的额外参数里如果用户自己写了
`--settings '<json>'`，适配插件把它**并进同一个对象**；写的是文件路径时并不了，
就原样留着并在 `notes` 里说出来。

三条都不读 `env` 块里的值，也不写任何文件。

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
→ {"version":1,"installed":bool,"notes":[…],
   "items":[{"kind":"skill"|"mcp","id":"skill:pdf","name":"pdf",
             "description":"…","detail":"http · host","source":"user|project|local|plugin:<p>",
             "group":"<plugin>","group_description":"…","locked":bool}]}

adapter launch '{"version":1,"cwd":…,"home":…,
                 "role":{"key","name","instructions"},
                 "cli":{"skills":{"default":bool,"except":[ids]},"mcp":{…},"model":…,"args":[…]}}'
→ {"version":1,"argv":["claude",…],"env":{},"summary":"…","notes":[…]}
```

- `id` 是适配器的，核心只存不懂。`locked` 的项（Claude Code 的是 `polter` 这个
  MCP）角色关不掉——关掉等于一个交不了活的终端，和第五节「`polter` 永远隐式在内」
  是同一条。
- 描述里**不许有秘密**：MCP 只给传输方式和主机名 / 命令的文件名，不给参数（令牌常
  以参数传），不给 `env`，URL 里的 `user:pw@` 剥掉。这两条有测试钉着。
- 关掉的插件不列：它已经在每个会话之外了，角色对它无事可做。

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
菜单点角色也走这套逻辑；Windows 还没有角色库窗口。

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

- **Windows 没有角色库窗口**，菜单也还是 Windows 自己那一份（有旧的编辑器入口）；
  核心那一半（点角色的判断、`+launch`、`role_*`）已在 Windows 真机上走通。
- **只有 Claude Code 一个适配器**，没有 `adapter_windows`。codex 等照 11.3 各写一个插件。
- **菜单是人点的，没有人点过合并后的菜单。** Mac 上 `role_*` 与 `+launch` 用 `+mcp`
  在一个新实例里真跑过（claude 的 argv 与角色逐项对得上；关掉的 skill 调不到、MCP 不在
  清单里；指令经对照实验确认送到）；点菜单这一步（`ghostty_surface_binding_action`）
  没有 agent 能替人做。
- Swift 测试编过、没跑（以 app 为宿主会起第二个 Polter）。窗口是离线渲染真源码核的图。

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
