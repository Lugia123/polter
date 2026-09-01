# 供给：让各家 agent CLI 知道 Polter 在这儿

## 本章覆盖什么

- 一个 agent 跑在 Polter 的终端里，怎么才能真的用上 Polter 的工具
- 为什么这件事是插件，不是核心功能
- 七个宿主各自要什么形状，以及它们之间差在哪
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
| **A. 有 `x mcp add` 子命令** | 调命令，不碰文件 | claude, codex, gemini, qwen, kimi |
| **B. 只能改 JSON 配置** | 读→合并→写 | opencode, deepseek |

> **B 族的判据是「能不能非交互地调用」，不是「有没有那个子命令」。**
> `opencode mcp add` **是存在的**（2026-09-01 实测 opencode 1.2.10），但它是一个
> **交互向导**，一个位置参数都不接——`opencode mcp add` 直接进「Enter MCP server name」
> 的提示符。**照着 `--help` 把 opencode 改成 A 族，会得到一个一直挂到宿主超时的插件，
> 而那从插件那侧看起来只是「闲着」。**
> 归族没错，早先写的理由（「没有 `mcp add`」）错了；**「没有这个命令」和「有但用不了」
> 在文档里是同一个结论，在代码里是不同的防线。**
| **C. IDE 专用** | **不做** | cursor, windsurf, kiro, cline, 通义灵码 IDE, 文心快码 |

**A 族优先，而且优先得有理由**：调一条命令是那家自己维护的接口，格式、锁、原子
性都是它的事；改用户的配置文件是我们替它维护它的格式，注释、并发写、schema 变
更全部变成我们的债。B 族要做，但它是**另一种东西**，不能和 A 族用同一份代码假装
一样。

## 四、七个宿主

已核实的部分来自各家官方文档（2026-08-30 查）。**没有一条是我实机跑过的**，
这一点在实现时必须重新验。

| key | 宿主 | 族 | MCP 落点 | 顶层键 | skill 目录 |
| --- | --- | --- | --- | --- | --- |
| `claude-code` | Claude Code | A | `~/.claude.json` | `mcpServers` | `~/.claude/skills/` |
| `codex` | OpenAI Codex CLI | A | `~/.codex/config.toml` | `mcp_servers` **(TOML，下划线)** | `~/.codex/skills/` |
| `gemini` | Google Gemini CLI | A | `~/.gemini/settings.json` | `mcpServers` | `~/.gemini/skills/` |
| `qwen-code` | 阿里 Qwen Code | A | `~/.qwen/settings.json` | `mcpServers` | 待核 |
| `kimi` | 月之暗面 Kimi CLI | A | TOML | 待核 | 待核 |
| `opencode` | opencode | B | `~/.config/opencode/opencode.json` | `mcp` **(嵌套，不是 mcpServers)** | 待核 |
| `deepseek` | DeepSeek-TUI | B | `~/.deepseek/mcp.json` | 待核 | 待核 |

三点要记住：

- **Codex 的键是 `mcp_servers`，别家是 `mcpServers`**，而且它是 TOML。照着别家
  抄一定错。Codex 另外要一个 `openai.yaml` 放 UI 元数据，别家会忽略它。
- **opencode 的键是 `mcp`，结构也不同**，不是换个文件名的 `mcpServers`。
- **Qwen Code 和 Gemini CLI 是一系**，形状一样。这不是巧合，是两家共用一份上
  游——**也意味着上游一变，两家一起变**。（iFlow CLI 原本是这一系的第三家；
  2026-04-17 停止服务，插件已删除。）

### DeepSeek 是个例外，要单独说

**DeepSeek 没有官方 CLI。** 2026 年 8 月发的 V4-Pro 是模型。终端 agent 全是第三
方的：`DeepSeek-TUI`（Hmbown，`deepseek` 命令，`~/.deepseek/mcp.json`）、
`DeepSeekCode`（Claude Code 的 fork）、`Deep Code CLI`。我们对着
DeepSeek-TUI 写。

**这一条的风险和别的不是一个量级**：第三方项目改配置形状不会通知任何人，坏了我
们才知道，而用户会以为是 Polter 坏了。所以它的失败必须比别家更响。

## 五、设计：SDK 出实现，插件出答案

379 行 × 7 份是不能接受的，但「七个插件合成一个」也不行——一个失败会连坐其余六
个，而且 `wants.exec` 是按二进制声明的，合起来就得声明全部七个。

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

七个插件全开会让每台机器上有五六个在「静默地什么都没做」——那不是坏，但它会把
日志变成噪音，而噪音里藏不住真正的失败。

**所以默认只有 `claude-code` 是开的，其余六个装了但关着。**

代价必须说清楚：**默认关 = 在用户找到那个菜单之前，对任何非 Claude Code 用户都不
生效。** 一个装了 Codex 的人打开 Polter，什么也不会发生，而且没有任何东西告诉他
本可以发生什么。

所以配一条：**供给插件在启动时看一眼各家二进制在不在 PATH 上，发现了就通过通知
系统说一次**——「检测到 codex，插件 → Codex CLI 可以打开」。用的是已有的插件通知
通道（[plugins.md](plugins.md)），说一次，不重复。**探测是免费的，注册不是**：
前者只是看 PATH，后者会写用户的配置文件，两者的门槛不该一样。

## 七、「没装」不是「失败」，这两件事现在分不开

`claude-code` 现在在 `claude` 不在 PATH 上时**静默退出 0**，理由写在它自己的注释
里：这台机器上的 agent 可能压根是别的东西。一个插件时这是对的。七个插件之后就不
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
但**「静默退出 0」这个形状本身仍在**，七个插件会把它放大七倍。

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

## 九、一个插件在不同系统上执行什么 —— **待拍板，本节只是设计**

Windows 上出厂的 7 个供给插件各补了一份 `provision.ps1`（`docs/windows/development.md`
5.3）。**但宿主现在够不着它们**：`plugin.json` 里只有一个 `exec`，指向 `provision.sh`，
Windows 执行不了 `.sh`，报 `error.InvalidExe`。

**这不是 Windows 专属的缺口。** 今天是 Windows，明天是一个只在 Linux 上有意义的
插件，或者一个在 macOS 上要走 `.scpt`、别处走别的东西的插件。所以这一节在
provisioning 自己的文档里，不在 `docs/windows/`。

### 9.1 一个问题还是两个

**是两个，而且答案该落在不同的地方。**

| | 谁的知识 |
| --- | --- |
| **在这个系统上跑哪个文件** | **插件的**。只有插件知道它为哪些系统写过东西 |
| **这类文件在这个系统上怎么启动** | **宿主的**。「`.ps1` 要用 `powershell … -File` 起」是这台机器的事实，不是这个插件的 |

5.3 里那句「能不能在这个系统上跑是插件的属性，不是宿主的推断」裁的是**第一个**问题。
**它没有裁第二个**，而第二个必须有人回答：Windows 不会直接执行 `.ps1`，默认执行策略
还会拒绝脚本文件。这串咒语是

```
powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File <绝对路径>
```

三个开关各有理由，缺一个就是一种具体的坏法：

- **`-File` 不能换成 `-Command`。** 实测（`windows-5eca899157d2-bestf`，Windows
  PowerShell 5.1）`-Command "…"` 只回显不执行。
- **`-NoProfile` 不是装饰。** 用户 profile 只要印一个字，就落在插件的 stdout 上，
  而 stdout 上非「应答/报告」的东西按协议算 misconduct，插件会被杀。
- **`-ExecutionPolicy Bypass`**：默认策略直接拒绝脚本文件。

**让 7 个插件各自把这串咒语抄一遍，是把宿主的知识搬进插件**——正是 `_sdk` 这个结构
在避免的事。所以：**插件说「跑这个文件」，宿主说「这类文件这么起」。**

### 9.2 字段形状：推荐 `exec_<os>`，加缺省回落

```json
{
  "exec": "provision.sh",
  "exec_windows": "provision.ps1"
}
```

规则三条：

1. 先找 `exec_<当前系统>`；没有就回落 `exec`。
2. `<当前系统>` 用 `builtin.os.tag` 的名字：`windows` / `macos` / `linux` / `freebsd`。
3. **两个都没有 = 这个插件在这个系统上没有东西可跑**，见 9.4。

**考虑过并否决的四种：**

| 形状 | 为什么否决 |
| --- | --- |
| `"exec": {"default": "…", "windows": "…"}` | `exec` 要同时能是字符串和对象，`load()` 里多一处联合解析，而且**每一份第三方文档和示例从此都有两种写法**。收益只是少几个平铺的键 |
| `"exec": [{"os": "windows", "path": "…"}, …]` | 同上，外加顺序、重复项、缺省项都要定规则。用数组表达一张小映射表是把简单的事写复杂 |
| **约定优先：宿主自己去找 `exec` 同名的 `.ps1`** | **不用改 schema，但它把「这个插件支持 Windows」变成了一次文件存在性推断。** 一份忘了删的旧 `.ps1`、一份写了一半的 `.ps1`，都会被读成声明。5.3 拒绝的正是这种形状 |
| 每个系统一份 `plugin.windows.json` | 参数、`wants`、描述全部要么重复要么分叉。差异只有一行，不该用一整份清单去表达 |

**推荐平铺键的理由，一句话**：它是**纯增量**的——老写法一个字不用改，含义也一个字
没变；不认识新键的读者（人或程序）在 POSIX 上仍然完全正确。上面三种都要求所有人
重新学一遍 `exec` 是什么。

### 9.3 宿主侧要改哪里 —— 给 #73 的输入

**两处，一处读，一处拼。**

**（一）`src/poltergeist/Plugin.zig`，`load()` 里读 `exec` 的那一段**
（现在是 `const exec_rel = stringField(obj, "exec") orelse { … return error.BadManifest; }`）。
改成先试 `exec_<tag>` 再回落 `exec`。`Manifest.exec` 拼绝对路径的方式不变。

> ⚠️ **别和 `wants.exec` 搞混。** `wants.exec` 是「这个插件会去 PATH 上找哪些二进制」，
> 是 disclosure；这里的 `exec` 是「启动哪个文件」。两个名字已经在读者脑子里撞过一次，
> 新键落地时值得在注释里点一句。
>
> 顺带：`deepseek` / `opencode` 的 `wants.exec` 里有 `python3`，那是 `.sh` 版编辑 JSON
> 用的；PowerShell 版语言里就有 JSON，Windows 上不需要它。`wants` 是一份跨系统的
> 清单，不影响运行，但拍板时值得知道**它已经在携带某些系统上不成立的信息**。

**（二）`src/poltergeist/Resident.zig`，唯一拼 argv 的地方**
（`child = std.process.spawn(io, .{ .argv = &.{self.exec}, … })`）。
扩展名 → 启动方式的展开落在这里，或者落在它旁边一个小函数里，**这样别的调用方继续
只递一个路径**。

建议做成一张封闭的小表，而不是一个可扩展的钩子：

| 扩展名 | argv |
| --- | --- |
| `.ps1`（仅 Windows） | `powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File <path>` |
| `.cmd` / `.bat`（仅 Windows） | `cmd /c <path>` |
| 其他 | `<path>`，也就是今天的行为 |

**封闭是有意的**：宿主替一个文件选解释器，等于宿主决定用什么去执行用户机器上的一份
文件。表越短，这个决定越好审。

**还有两处同形状的地方**，不改也能跑，但改了才叫「测的是我们真发出去的东西」：
`Resident.zig` 里那两条端到端测试自己拼 argv（一条跑 `archive/archive.py`，一条跑
`claude-code/provision.sh`）。它们该走同一个展开函数，否则测试和产品路径会分叉。

`src/build/GhosttyResources.zig` **不用改**：它是整目录安装、只排除 `.md`，`.ps1`
已经随包走了。

### 9.4 向后兼容：只写了 `exec` 的旧插件，在 Windows 上应该怎样

**今天的行为是最坏的一种**：spawn 失败 → 宿主退避 → 重启 → 再失败，一个从插件那侧
看起来和「闲着」一模一样的重启循环。而且它发生在**运行时**，尽管所需的信息在
**加载时**就全在手里了。

三个选项：

| | 行为 | 评价 |
| --- | --- | --- |
| A | 保持现状 | 循环失败。**不选**，它把一个静态事实推迟成一个运行时症状 |
| B | 加载时拒绝，`error.BadManifest` | 比 A 好，但和「清单写坏了」用同一个错误。**一个只支持 POSIX 的插件不是一份坏清单** |
| **C** | **加载时进入第三态 `unsupported`，在 `plugin_list` 里可见，不启动、不算失败** | **推荐。** 和本文第七节那个 `absent` / `provisioned` / `failed` 三态是同一种思路：**「这里没事可做」和「这里出事了」必须长得不一样** |

C 的代价要说清楚：`load()` 的返回类型要能表达「读成功了但这台机器上跑不了」，不能
再是「Manifest 或 error」。

### 9.5 和「系统字段暂不加」那条裁决的互动 —— **这一条请拍板的人重看**

用户裁过：插件清单里**暂不加**「支持哪些系统」这个字段，理由是

> 现在加等于 8 个插件都填同一个值，字段不携带任何信息，却要从现在起一直维护。

**那条理由在当时是对的，而 `exec_windows` 会让它不再成立**，方向有两个，都要看到：

- **信息出现了。** 8 个插件填的 `exec_windows` 各不相同（7 份 `provision.ps1`，
  `archive` 一份都不需要）。**不同的值 = 携带信息**，这正是那条裁决用来否决 `os` 字段
  的判据，而它在这个字段上成立。
- **「有没有这个字段」本身开始说话了。** 一旦 `exec_<os>` 存在，
  「一个插件没有 `exec_windows`，`exec` 又是 `.sh`」就等于说了「我不支持 Windows」，
  **只是用一种间接的、要靠扩展名去推的方式说的**。而 9.4 的 C 方案要真正落地，宿主
  就得读懂这句话。

**所以这两件事不是并列的，是一个可能替代另一个**：

| | `exec_<os>` | `os` / `platforms` 字段 |
| --- | --- | --- |
| 回答 | 在这个系统上**跑哪个文件** | 在这个系统上**该不该被加载** |
| 现在有信息吗 | **有**（8 个值不同） | 没有（8 个都跨平台） |
| 能推出对方吗 | 能间接推出「不支持」，靠扩展名和缺省 | 推不出跑哪个文件 |

**我的建议：先加 `exec_<os>`，`os` 字段继续不加。** 理由不是「以后再说」，是
**`exec_<os>` 把那个字段今天唯一能表达的东西表达掉了**，而且是用一个此刻真的有信息的
形状。等出现第一个「有 Windows 可执行文件、但作者仍然不想它在 Windows 上加载」的
插件时——那才是 `os` 字段唯一不能被替代的场景——需求会是具体的。

### 9.6 这是给所有插件的机制，不只是给出厂那 8 个

**按出厂插件设计会漏掉三件事：**

1. **第三方插件更可能是单系统的。** 出厂这 8 个恰好都跨平台，所以 9.4 那个
   `unsupported` 态对它们一次都不会触发——**而对第三方插件那会是常态**。拿出厂插件
   验收这个机制，等于永远不测那条分支。
2. **`-ExecutionPolicy Bypass` 是替别人的文件绕过这台机器的策略。** 对我们自己发的
   插件这只是必要条件；对一份用户从别处装进 `<config>/polter/plugins/` 的 `.ps1`，
   这是宿主主动跳过了一道用户或管理员设的闸。**这是一个安全形状的决定，不是机械的**，
   拍板时该被看见——哪怕结论仍然是「就这么做」，也该是被看过之后的「就这么做」。
3. **扩展名表必须是封闭的。** 一旦它变成「按扩展名找解释器」的通用机制，
   `<config>/polter/plugins/` 里放一个 `.py` 或 `.jar` 就成了「宿主替我找运行时」。
   9.3 那张三行的表是有意短的。

### 9.7 不在这一节里的

- **实现。** 本节只到设计，没有一行代码，`plugin.json` 一个字没改。
- **`exec_windows` 之外的 Windows 移植事项**，见 `docs/windows/development.md`。
- 那 7 份 `.ps1` 本身怎么写、PowerShell 相对 `sh` 哪里简单哪里麻烦，见
  `plugins/_sdk/provision.ps1` 的头注释和 `test/plugins/README.md`。

## 取舍记录

| 方案 | 为什么没选 / 为什么选 |
| --- | --- |
| 每家一份完整脚本 | 379 × 7。而且共同的那部分（幂等、版本戳、清理过期 skill、日志）会分叉成七个版本 |
| 一个插件带一张宿主表 | 一个失败连坐六个；`wants.exec` 得声明全部七个二进制，等于每台机器都在声明它用不到的东西 |
| **SDK 出实现 + 每家一份声明** | **选这个。** 共用实现，独立身份、独立开关、独立日志 |
| 七个全默认开 | 噪音淹掉真正的失败 |
| **只开 Claude Code + 探测到就提示一次** | **选这个。** 探测只读 PATH，注册要写用户的文件，门槛不该一样 |
| 先加七家再重构 | 拿七个没验过的去压一个正在工作的 |

## 未决问题

1. ~~**七家一家都没有真机验过。**~~ **2026-09-01：五家验过了**，判据是**那家 CLI
   自己报出 polter**，不是「配置文件写进去了」——后者只证明我们会写文件。

   | 宿主 | 状态 |
   | --- | --- |
   | `claude-code` | **最完整**：`claude mcp get` 逐格回显 scope / type / command / args / **env** |
   | `qwen-code` | Windows 真机，`qwen mcp list` 报出 polter；**env 不回显，那格是推断** |
   | `gemini` | 写入内容读回核对 + 四遍幂等契约；env 由文件读回，非 CLI 回显 |
   | `opencode` | `opencode mcp list` 认出条目并尝试 spawn（`ENOENT` 是假路径，不是拒绝）；`environment` / `enabled` 仍是推断 |
   | `codex` | **部分**：`mcp add` 成功且 env 写对，**没让 codex 自己报出来**。本机装着，这条能补 |
   | `deepseek` / `kimi` | **完全未验**，两台机器都没装 |

   **`env` 那一格此前没有任何一家确认过**——`qwen`/`gemini` 的 `mcp list` 根本不打 env
   （那正是 staleness 那个 bug 的成因），`opencode` 也没回显。`claude mcp get` 是第一个。

   **剩下的三行卡在「没有那台机器」上，不卡在实现上。**

   **验证方式记在这里，因为它可复用**：先确认那家 CLI **遵循 `$HOME`**（五家都遵循，
   但每家单独验过，**没有一家是假设的**），在假 HOME 里跑出厂脚本，再用那家自己的
   只读子命令去问。真配置全程 sha 前后对照，而**判据不是「文件变没变」——是
   「我写的那个特征串在不在里面」**：跑 `claude-code` 那次真配置的 sha 确实变了，
   而定案靠的是「本次的版本戳和假 exe 路径一个都不在里面」，变化来自另外两个
   活着的 `claude` 会话进程。**「变了吗」分辨不了方向，「我写的东西在里面吗」才可以。**
2. **四家的 skill 目录仍然是空的**（`qwen-code` `kimi` `opencode`
   `deepseek`）。`host_skills_dir` 返回空串，那一步整个跳过。这是可接受的降级，
   补法是核实一家填一家，**不要猜**：写进猜出来的目录是留在别人机器上的垃圾。
3. **第六节那条「探测到就提示一次」还没做。** 没有它，默认关就意味着装了 Codex
   的人永远不知道这里有东西。这是目前最大的一个缺口，而且它和插件本身无关——它
   属于宿主那一侧。
4. `deepseek` 对着的是第三方的 DeepSeek-TUI。它改配置形状不会通知任何人，届时用
   户会以为是 Polter 坏了。没有别的办法，只有让它失败得响一点。
5. **`exec_<os>` 没拍板，所以 Windows 上那 7 份 `provision.ps1` 宿主够不着。**
   设计在第九节，包括它和「系统字段暂不加」那条裁决的互动——**那条裁决的理由
   （「8 个插件都填同一个值」）在这个字段上不成立**，值得拍板的人一起看。

## 延伸阅读

- [plugins.md](plugins.md) —— 插件协议、日志、通知
- [mcp.md](mcp.md) —— 工具清单、可达性、自指
- [tasks.md](tasks.md) 第九节 —— `instructions` 为什么是跨宿主的那一层
