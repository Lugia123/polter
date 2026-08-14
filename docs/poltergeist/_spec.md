# Poltergeist 设计文档写作规范

> 最后更新对应的 git commit：`f81dcadc8`（`f81dcadc82ea2afdcf2dc92929037701122f05b5`，2026-08-14）
> 校验方式：`git log -1 --format='%H %h %ad %s'`
> 状态：**设计草案，尚未实现**。描述 Ghostty 现状的句子均带 路径:行号；描述 Poltergeist 行为的句子是设计意图。

## 本章覆盖什么

- `docs/poltergeist/` 下所有文档共用的红线、骨架、引用格式、代码块规则。
- 本批文档的固定文件清单与各章归属，用于消除章节间重复。
- Poltergeist 统一术语表（产品与角色、状态与模式、感知层、通信与界面）。
- 提交前自检清单。

## 本章不覆盖什么

- 任何设计内容本身 —— 见 [README.md](README.md) 与它索引的五章。
- Ghostty 现状文档的通用规范 —— 见 [\_conventions.md](../_conventions.md)，本文继承它。
- 构建与调试命令 —— 见 [preview-manual.md](../preview-manual.md)，那是唯一权威。
- Ghostty 现有架构与数据结构 —— 见 [architecture.md](../architecture.md)、[terminal-core.md](../terminal-core.md)。

## 一句话概括

本文继承 `docs/_conventions.md`；本批是**设计文档**而非现状文档，两者冲突时以本文为准。

## 绝对红线

1. 只允许新建 / 修改 `docs/poltergeist/` 下的文件。严禁碰 `src/`、`macos/`、`build.zig`、`build.zig.zon`、根 `AGENTS.md`。
2. 禁止 `git add` / `git commit` / 建 issue / 建 PR。
3. 反幻觉：写任何路径前先 `test -e` 或 Read；写任何函数 / 类型 / 字段前先 grep 到定义并给出 `相对路径:行号`。禁止用「终端模拟器一般怎么做」补写。不确定就写 `（未核实：<结论>，核实方式是 <怎么核实>）`。
4. 单篇 `（未核实）` 占比超过 15% = 调研不足，回去读代码。
5. 本批文档描述的是**尚未实现的设计**。凡描述 Poltergeist 自身行为的句子用「应」「拟」「本设计选择」等设计语气；凡描述 Ghostty 现状的句子必须带 `路径:行号`。两者在同一段里必须一眼分清。

举例，下面这句是合规的混排：Ghostty 现在把每个 surface 的稳定标识注入子进程环境变量 `GHOSTTY_SURFACE_ID`（`src/Surface.zig:651-655`），Poltergeist 的 sidecar 应直接读它来认领身份，不再新增环境变量。

## 文件与骨架

目录 `docs/poltergeist/`，固定 6 个文件：

- `README.md` — 总览与索引，不展开任何一章细节。
- `sensing.md` — 感知层。
- `supervisor.md` — 总管与监工模式。
- `mcp.md` — MCP 工具面与 skill 体系。
- `chatui.md` — 群聊与私信界面。
- `tabs.md` — tab 合并与状态标记。

本文件 `_spec.md` 是规范附件，不计入这 6 个之内，命名沿用 `docs/_conventions.md` 的下划线前缀惯例。

**文件名是规范性的。** 禁止写成 `mcp-and-skills.md`、`chat-ui.md`、`tabs-and-status.md` 等变体 —— 各章之间的相对链接依赖这份清单，改名会直接产生死链。文件名一律小写连字符，UTF-8 / LF / 末尾一个换行。

每篇开头固定块，顺序不可变：

1. 第 1 行 `# <标题>`。
2. 引用块三行：`> 最后更新对应的 git commit：` + 短哈希 `f81dcadc8`（全哈希 `f81dcadc82ea2afdcf2dc92929037701122f05b5`，2026-08-14）；`> 校验方式：` + `git log -1 --format='%H %h %ad %s'`；`> 状态：**设计草案，尚未实现**。…`。
3. `## 本章覆盖什么`（3–8 条）。
4. `## 本章不覆盖什么`（3–8 条，每条指向真正覆盖它的章节，用相对链接如 [supervisor.md](supervisor.md)）。

之后建议结构：`## 一句话概括` → `## 设计目标与约束`（列出本章对应的 R 编号）→ 主体若干 `##` → `## 取舍记录` → `## 未决问题` → `## 延伸阅读`。

## 标题与篇幅

- `#` 全篇仅一次，位于第 1 行。主体 `##`，子节 `###`，最深 `####`。标题不加数字编号。
- 每章 150–400 行（含代码块与空行）。单个 `##` 不超过 80 行，超了拆 `###`。段落不超过 6 行。
- 表格列数 ≤ 5。超宽信息改写成 `- **字段** — 说明`。

## 代码位置引用

- 一律 `` `相对路径:行号` ``，例：`` `src/Surface.zig:3308` ``；区间 `` `src/terminal/render.zig:554-558` ``。
- 禁止：绝对路径、`./` 前缀、`App.zig 第 77 行`、`#L77` 锚点、给源码引用加 Markdown 链接。
- 行号必须是你亲眼读到的真实行号。引用易移动的实现细节时同时给符号名：`RenderState.beginUpdate()`（`src/terminal/render.zig:356`）。
- 每个 `##` 章节至少含一处 `路径:行号`。没有出处的章节要么删，要么整章标 `（未核实）`。索引性质的章节（如 `## 延伸阅读`）例外。

## 代码块

- shell 命令一律 ```sh，块内不写 `$`，一行一条。禁止 `bash` / `shell` / `console`。
- Zig 标 `zig`，Swift 标 `swift`，C 标 `c`，JSON 标 `json`，Markdown 示例标 `md`，配置片段标 `ini`，纯文本 / 目录树 / 架构图标 `text`。禁止无语言标注的代码块。
- 引自源码的片段必须原样复制、≤ 30 行、截断处写 `// ...`，上方一行写 `出处：src/xxx.zig:12-30`。
- **设计示意的伪代码 / 配置样例不是源码引用**，必须在块上方明确写「以下为设计示意，仓库中尚不存在」。

## 内容质量

**设计文档要写取舍理由，不要只写结论。** 每一个「我们选 A」必须配套写清：候选方案有哪几个、各自成本（代码量 / 跨平台代价 / 与上游分叉代价 / 运行时开销）、为什么淘汰其余、这个选择在什么条件下会被推翻。

落地形式：每章末尾必须有 `## 取舍记录`，用表格 `方案 | 成本 | 为什么没选 / 为什么选` 逐条列。正文里做出选择的地方也要就地写一到两句理由，不能只在末尾集中堆。

其他要求：

- 描述调用链时用有序列表逐跳给出，每跳带出处。
- 描述平台差异必须写清「哪个平台 / 哪个 apprt / 哪个构建选项」。例如 IPC 目前是 Linux-only：`src/apprt/ipc.zig:176-179` 只有三个 action，而 embedded（macOS）的 `performIpc` 三个分支全部返回 false（`src/apprt/embedded.zig:349-360`）。
- 不写「未来会如何」的路线图，除非是本设计自己的分阶段计划（那属于设计内容，允许，但要标明是设计而非承诺）。
- 语气说明性、祈使式。禁止营销腔（「极致」「强大」「业界领先」）。禁止 emoji。

## 语言

正文一律简体中文。以下保持原文不译：代码标识符（`PageList`、`RenderState`、`renderer_state`）、文件与目录路径、命令与参数、环境变量、构建选项、第三方项目名（Zig、GTK4、libadwaita、SwiftUI、AppKit、Metal、libxev、imgui、z2d、MCP、D-Bus）。

Ghostty 侧沿用 `docs/_conventions.md` 的既有译法：表面（surface）、应用运行时（apprt）、终端 IO（termio）、渲染器、渲染线程、IO 线程、读线程、`mailbox`、`scrollback`、页 / 页链表、pty 不译。

## 术语表：产品与角色

| 中文        | 英文 / 标识        | 说明                                                                                                 |
| ----------- | ------------------ | ---------------------------------------------------------------------------------------------------- |
| Poltergeist | Poltergeist        | 能力层名，首次出现写「Poltergeist（能力层）」，其后直接写 Poltergeist。禁止再写 "Ghostty Agent Loop" |
| polter      | polter             | 命令名 / 短名，如 `ghostty +polter-mcp`。全小写                                                      |
| 宿主终端    | Ghostty            | Poltergeist 的宿主，fork 自 ghostty-org/ghostty                                                      |
| 总管        | Supervisor         | 被指定为监督者的那个终端里的 AI。禁止译成「管理员」「主控」                                          |
| 被监督终端  | supervised surface | 总管监督的终端。禁止写「从属终端」「worker」                                                         |
| 监督关系    | supervision link   | 总管 ↔ 被监督终端的配对关系                                                                          |

## 术语表：状态与模式

| 中文         | 英文 / 标识      | 说明                                                                     |
| ------------ | ---------------- | ------------------------------------------------------------------------ |
| 上班         | on-duty          | 被监督终端的默认状态。tab 上写「上班中」                                 |
| 静止待判     | quiescent        | 静止时长达到阈值、已通知总管、尚未收到总管结论。程序侧去重用             |
| 等确认       | pending-confirm  | 总管认为需要人确认、正按确认策略处理中                                   |
| 下班         | off-duty         | 总管判定该终端无需继续工作后打的标记。tab 上写「下班休息」               |
| 监工模式     | supervision mode | 每个被监督终端各自设定的模式，是「下班模式」与「无限工作模式」的上位概念 |
| 下班模式     | clock-out mode   | 允许打下班标记的监工模式                                                 |
| 无限工作模式 | endless mode     | 禁止打下班标记的监工模式                                                 |
| 定向无限     | endless-directed | 无限工作模式子型 (i)：在用户设定的大方向下持续工作                       |
| 接续无限     | endless-chained  | 无限工作模式子型 (ii)：做完一个任务切下一个                              |

**「四态」一词必须带限定语。** 本批文档里只有一个四态状态机：上班 / 静止待判 / 等确认 / 下班（归 [supervisor.md](supervisor.md)），它是程序侧的去重与超时簿记。被本次修订推翻的那个 working / thinking / idle / stalled 是**感知层的语义推断**，写它时必须写全四个英文值并注明「旧稿」，不得简称「四态」。

最接近「上班 / 下班」的既有 per-surface 状态先例是 `Surface.readonly`（`src/Surface.zig:168`），`toggle_readonly` 翻转它并发出 apprt action（`src/Surface.zig:5426-5432`）。

## 术语表：感知层

| 中文     | 英文 / 标识          | 说明                                                                       |
| -------- | -------------------- | -------------------------------------------------------------------------- |
| 静止     | quiescence           | 屏幕内容在一段时间内没有变化                                               |
| 静止时长 | quiescence duration  | 距离上一次屏幕变化过了多久                                                 |
| 静止阈值 | quiescence threshold | 达到就通知总管的时长配置                                                   |
| 传感器   | sensor               | 感知层的定位：只测量、不做语义判断                                         |
| 采样     | sampling             | 周期性读取屏幕并计算指纹                                                   |
| 屏幕指纹 | screen fingerprint   | 可见网格内容的哈希值。**不要叫「语义哈希」** —— 本次修订已删除语义剔除逻辑 |

逐行脏标 `Row.dirty`（`src/terminal/page.zig:2004`）由渲染路径消费即清零，注释自称唯一消费者（`src/terminal/render.zig:554-556`），感知层不能独立读+清它 —— 细节见 [sensing.md](sensing.md)。

## 术语表：通信与界面

| 中文       | 英文 / 标识         | 说明                                                                                               |
| ---------- | ------------------- | -------------------------------------------------------------------------------------------------- |
| 群聊       | group chat          | 多个 AI 共同可见的消息频道                                                                         |
| 私信       | direct message / DM | 两个 AI 之间的点对点消息。禁止写「单聊」「私聊」混用，正文统一「私信」，章节标题可写「群聊与私信」 |
| 通知时间段 | notification window | 允许打扰用户的时段，如 09:00–22:00                                                                 |
| 确认策略   | confirmation policy | 需要人确认时二选一：总管代理决策 / 通知用户                                                        |
| 停掉监控   | stop monitoring     | 唯一的停止动作。**禁止写「一键开关」「全局开关」「急停键」**                                       |
| Skill 体系 | skill system        | 监工模式的实现载体                                                                                 |
| 边界       | boundary            | 指 R8：Poltergeist 不管理任务                                                                      |

## 交叉引用与去重

五章之间零重复。同一事实只在归属章展开，其他章一句话加链接带过。

| 主题                                                              | 归属章                         |
| ----------------------------------------------------------------- | ------------------------------ |
| 屏幕静止怎么测、成本、阈值、为什么不做语义判断                    | [sensing.md](sensing.md)       |
| 监督关系、上班 / 下班、监工模式、确认策略、通知时间段、停掉监控   | [supervisor.md](supervisor.md) |
| MCP 工具清单、sidecar、身份识别、skill 集成与维护、不管任务的边界 | [mcp.md](mcp.md)               |
| 群聊 / 私信界面的承载方式选型                                     | [chatui.md](chatui.md)         |
| tab 合并、tab 状态标记、macOS/GTK 差异                            | [tabs.md](tabs.md)             |

`docs/poltergeist/README.md` 只做总览与索引，不展开任何一章的细节。

## 提交前自检清单

- [ ] 第 1 行是唯一 `#` 标题，紧跟三行引用块（短哈希 + 全哈希 + 校验命令 + 状态行）
- [ ] 有「本章覆盖什么 / 不覆盖什么」两节
- [ ] 有 `## 取舍记录`，且正文中每个选择都就地写了理由
- [ ] 所有代码位置是 `相对路径:行号`，无绝对路径 / 无 `./` / 无 `#L`
- [ ] 逐条 `test -e` 过所有出现的路径
- [ ] 所有 shell 块标 `sh`，所有代码块都有语言标注
- [ ] 设计示意的代码 / 配置块上方写明「仓库中尚不存在」
- [ ] 所有推测带 `（未核实）` 且写了核实方式
- [ ] 行数在 150–400 之间
- [ ] 术语与本文术语表一致，全文无 "Ghostty Agent Loop"、无「一键开关」、无「语义哈希」
- [ ] 没有修改 `docs/poltergeist/` 之外的任何文件
- [ ] 已跑 `prettier -w docs/`
- [ ] 没有 `git add` / `git commit`，没有建 issue / PR

## 延伸阅读

- [README.md](README.md) — Poltergeist 设计总览与五章索引。
- [\_conventions.md](../_conventions.md) — 本文继承的通用文档规范。
- [README.md](../README.md) — Ghostty 开发文档索引。
