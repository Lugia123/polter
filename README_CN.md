<h1 align="center">
  <img src="images/icons/icon_256.png" alt="Polter Logo" width="128">
  <br>Polter
</h1>

<p align="center">
  <b>面向多 Agent 时代的新一代 Vibe Studio。</b><br>
  <b>基于 Ghostty 构建的本地智能体工作台：挑一个终端会话当总管，统领全屏 AI 编程小队——读屏幕、派任务、代答确认，毫秒级感知每个屏幕的静止状态。</b><br>
  <sub>告别单兵写代码与在多个终端间人肉切换。通过原生 MCP 协议，总管能读取其他标签页屏幕、派发工单并调配分级模型；你离开电脑后，它替你盯住整套全栈工程的持续交付。</sub>
</p>

<p align="center">
  <a href="#下载安装">下载安装</a> ·
  <a href="#快速上手-3-分钟开工">快速上手</a> ·
  <a href="#为什么叫-vibe-studio核心能力">核心功能</a> ·
  <a href="#专为-ai-设计的结构化截图">AI 专属截图</a> ·
  <a href="#竞品全维度对比">竞品对比</a> ·
  <a href="#技术规格与安全护栏">技术规格</a> ·
  <a href="#常见问题-faq">FAQ</a> ·
  <a href="README.md">English</a>
</p>

<p align="center">
  <a href="https://lugia123.github.io/polter/?lang=zh"><img src="docs/poster-zh.jpg" alt="Polter: 给你的 AI 找个总管。点击观看演示视频。" width="72%"></a><br>
  <sub><a href="https://lugia123.github.io/polter/?lang=zh">▶ 观看 73 秒演示视频</a></sub>
</p>

<p align="center">
  <img src="images/screenshots/group-chat.png" alt="带任务编号的工作群聊" width="46%">
  <img src="images/screenshots/group-total.png" alt="统计视图：任务状态与发呆时长" width="52%">
</p>

---

## 痛点与破局：从单兵 Vibe Coding 到 Agent 小队工作台

单兵使用 AI 编程（如在单个对话框或单个终端里跑 Claude Code / Codex）写个几十行 Demo 确实惊艳；但在真正的工程世界里，这种方式很快会陷入泥潭：
* **多窗口手忙脚乱**：前端开一个、后端开一个、测试开一个，你在 5 个终端 Tab 之间来回切换，人肉充当传话筒；
* **深夜长任务停摆**：满心期待 AI 通宵重构，第二天醒来发现它在凌晨 1 点半卡在一个 `(y/n)` 权限确认弹窗前，白白枯坐了 6 个小时；
* **单模型成本与失忆**：全上最贵的大模型很快会烧光 API 配额，而单个模型在庞大上下文里又容易产生幻觉、堆砌重复代码（屎山）。

**Polter 的解法：**  
Polter 基于现代极客终端 Ghostty 构建，内置了深度优化的本地 MCP（Model Context Protocol）服务器。你可以在终端里指定一个会话当**“总管 (Supervisor)”**。  
总管本身就是一个普通的 AI CLI 会话，但 Polter 赋予了它“上帝视角”：它负责与你过方案、拆解任务看板（Todo List）、调度全屏的 Worker 小队（业务码农、代码保洁员、自动化测试员），并在关键节点自动放行低危确认，实现**真正无人值守的通宵交付**。

---

## 下载安装

[**点击此处直接下载最新发布版 (GitHub Releases)**](https://github.com/Lugia123/polter/releases/latest)

| 操作系统 | 安装包文件 | 说明 |
| :--- | :--- | :--- |
| **macOS 13+** | `Polter-*-macos-universal.zip` | 原生通用二进制，同时支持 Apple Silicon (M系列芯片) 与 Intel。 |
| **Windows 10+** | `Polter-*-windows-x64.zip` | x64 免安装绿色版。解压即用，不修改注册表，无多余权限申请。 |
| **Linux** | 源码编译 | 支持从源码构建（截图标注模块后续补齐）。 |

#### macOS 快速安装说明：
当前公测安装包暂未购买苹果商业公证，会被 Gatekeeper 安全机制拦截。解压后请打开系统自带终端执行以下命令解除隔离属性：
```sh
unzip Polter-*-macos-universal.zip
xattr -dr com.apple.quarantine Polter.app
mv Polter.app /Applications/
```
> **重要提示**：请务必从 **“访达 (Finder)”** 或 **“程序坞 (Dock)”** 中双击启动 Polter，不要通过其它子 shell 命令启动——否则它可能无法完整继承系统 `PATH` 中的 AI 工具环境。

#### Windows 快速安装说明：
解压压缩包后，直接双击运行目录内的 `polter-host.exe` 即可（请保留同目录下的 DLL 及 `share/` 文件夹）。如遇 Windows SmartScreen 提示，点击“更多信息 -> 仍要运行”。

#### 前置准备
请确保你的常用 AI CLI（如 Claude Code、Codex、OpenCode 等）已正确安装并处于系统 `PATH` 路径中。Polter 启动时会自动挂载检测。

---

## 快速上手（3 分钟开工）

1. **拉起终端：** 启动 Polter，进入你的项目代码目录，敲入命令启动你的主力 AI（如 `claude`）。
2. **任命总管：** 在顶部菜单栏点击：`Agent → 设当前终端为总管`（或直接对 AI 说：*“你来当总管，监管并调度其他终端”*）。
3. **连通性校验：** 对总管说：*“调用 `me` 工具，告诉我它说了什么。”* 当它成功返回当前终端 ID 与环境信息，即表示总控通道已就绪！*(若提示工具不存在，请见下方 [FAQ](#常见问题-faq))*。
4. **下发工程：** 像技术总监一样向总管下发宏观需求。总管会自动建立任务看板、拆分工单、横向纵向切分屏幕、拉起新的 Worker 终端开工。
5. **挂机与检阅：** 放心合上电脑或切换后台。随时可以在总控台的「群聊」页面（或终端敲 `polter +chat`）查阅进度，使用 `Tab` / `Shift+Tab` 自由在对话记录、任务看板与统计视图之间无缝切换。

---

## 为什么叫 Vibe Studio？核心能力总览

*   🎯 **智能总管全局调度**：总管能直接读取任意标签页的纯文本输出（真实终端输出，而非 OCR 识别），能向任意终端键入指令，也能自动切分窗口拉起新 Worker。
*   📋 **持久化看板与小队群聊**：内置 Task Board（任务面板）与 Group Chat。任务编号、执行状态与沟通日志完全落盘，终端重启依然完好如初。
*   ⏱️ **毫秒级静止感知**：时刻监测每个屏幕多久没有输出变化。是陷入死循环、思考中，还是等待输入，总管秒级洞察并主动处理。
*   🛡️ **无感代答防卡死**：Worker 遇到依赖安装等常见权限确认时，总管智能判断并代为放行（`terminal_answer_prompt`）；遇高危操作自动推送到人面前并附带系统通知，通宵狂奔不挂起。
*   📊 **全量系统与进程监控 (New · #2149)**：
    *   内置 `resource_overview` 监控引擎：极低开销常驻监控 Polter 自身、各群组 Worker、MCP 边车进程占用；
    *   控制室新增专属性能仪表盘：实时 CPU/内存指标、按天按周堆叠历史趋势、Swap 交换分区与磁盘余量全景透视。
*   📁 **群组工作目录与文件浏览器切片 (New · #2145)**：
    *   核心层支持按群组终端自动聚合真实工作目录（Workdirs），清晰识别各终端与代码工作树（Worktree）的从属关联；
    *   支持在群组工作目录范围内索引与读取代码文本文件，内置 `too_wide` 路径保护，防止终端停在根目录或家目录时误暴露无关敏感目录。
*   🎭 **角色 (Role) 与 CLI 智能关联 (New · #2156)**：
    *   将常用启动参数（模型、System Prompt、工具集）存为“角色”；
    *   支持为特定角色勾选专属 CLI，启动菜单自适应过滤裁剪，杜绝模型与脚本错配。
*   ⚡ **OpenCode 2.x 独立插件适配 (New · #2237)**：
    *   正式拆分并提供 `opencode-v2` 专属插件，与 1.x 独立共存并精准匹配版本。
*   🔍 **控制室任务按编号极速过滤 (New · #2248)**：
    *   任务看板支持直接输入编号（如 `2149` 或 `#2149`）毫秒级过滤定位。
*   📜 **终端视口保护与全屏沉浸 (New · #2233, #2235)**：
    *   向上翻看历史日志时，底层的持续输出不会将视口粗暴扯回底部；
    *   由 Polter 启动的 Claude Code 默认支持全屏绘制（fullscreen），告别多余闪烁。
*   🛡️ **高弹性 MCP 边车通道 (New · #2170, #2236, #2287)**：
    *   超长请求优雅容错不闪退，自动回收巨幅日志内存，严格守护 IPC 管道安全。
*   💾 **一键项目复原 (Projects)**：
    *   将当前整个工作区的所有分屏布局、目录、标签名与 Shell 历史一键存档，下次开机一秒还原。
*   🔒 **100% 本地与隐私无忧**：
    *   不建账号、不传云端、不碰私钥，所有会话日志与状态纯本地存储。

---

## 专为 AI 设计的结构化截图

Polter 内置的截图工具专为多模态 Agent 工作流设计：**标注本身即结构化数据**。  
保存截图的同时，会在同目录下伴生一份 `.json` 元数据文件，记录用户绘制的红框坐标、文本批注与步骤序号。当粘贴给 AI 时，标注文本直接以纯文本连同图像一并送出，**AI 彻底免除 OCR 肉眼识字的不确定性**。

*   **全局快捷键**：Mac `⌘⇧0`，Windows `Ctrl+Shift+0`。
*   **长截图拼合**：点击“长截图”，引擎自动控制视口平滑滚动拼合长代码或完整网页。
*   **不可逆马赛克**：涉及账号密码或密钥的区域涂抹后直接在内存销毁，绝不落盘、不进剪贴板。
*   **总管静默截图**：总管可通过 `screenshot_capture`、`screenshot_long` 等 MCP 工具在后台静默抓取指定窗口画面并分析。

---

## 竞品全维度对比矩阵

*(对比数据源自 2026 年各项目官方文档与实机基线)*

| 关键考量维度 | Polter (Vibe Studio) | tmux | Claude Code (内置子智能体) | [Claude Squad](https://github.com/smtg-ai/claude-squad) | [cmux](https://github.com/manaflow-ai/cmux) | [herdr](https://github.com/ogulcancelik/herdr) | [Warp](https://docs.warp.dev) |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **产品本质形态** | **基于 Ghostty 的多智能体工作台** | 经典字符终端复用器 | 单个会话内部的任务派生 | 基于 tmux + git 的 TUI 工具 | 基于 Ghostty 的单向增强终端 | Rust 编写的终端 Agent 复用器 | 带 AI 侧边栏的商业闭源终端 |
| **调度核心机制** | **AI 总管自主管理全屏小队** | 人类完全手动管理 | 父级会话阻塞等待子级 | 人类在单一窗口肉眼监视 | 人类靠通知铃声被动响应 | 人类查看状态指示条 | 人类与内嵌单智能体交互 |
| **静止与发呆感知** | **硬件级屏幕静止时钟 + Hooks 双轨** | 仅依赖传统 bell 响铃 | 无（仅靠会话内部超时） | 无独立静止感知 | 仅依赖 Agent 显式信号 | 标记状态为 idle/blocked | 无独立终端空闲检测 |
| **权限中断代答** | **总管基于策略代答放行 (Proxy Approval)** | 无（人肉敲 y） | 无（只能开启全量不安全模式） | 人肉介入确认 | 无 | 无 | 无 |
| **协作通信架构** | **星型拓扑：进程间群聊 + 任务看板** | 终端彼此无隔离通信管道 | 仅限内存父子上下文继承 | 依赖外部 git 分支通信 | 无原生跨会话管道 | 无结构化群聊面板 | 无 |
| **资源与负载度量** | **全景透视：自身与小队内存/Swap/磁盘监控** | 依靠外部 top/htop | 无度量 | 无度量 | 无度量 | 基础进程状态 | 仅自身客户端消耗 |
| **底层性能引擎** | **Ghostty 原生渲染引擎 (Zig/Metal/DirectX)** | 字符终端 | Node.js 宿主 | shell/tmux 包装器 | Ghostty (早期分支) | 终端虚拟层 | 闭源专有引擎 |
| **数据与隐私模型** | **100% 本地存储 ($XDG_STATE_HOME)** | 100% 本地 | 取决于 Anthropic 接口策略 | 本地 | 本地 | 本地 | 依赖云端账号与遥测 |

---

## 技术规格与架构实现 (Technical Specifications)

Polter 通过模块化分层解耦，在 Ghostty 高性能终端核心之上构筑了高内聚的 Agent 控制平面：

```
┌────────────────────────────────────────────────────────────────────────┐
│                        Polter Core Architecture                        │
├────────────────────────────────────────────────────────────────────────┤
│  [Human Layer]    设置管理 / 任务检阅 / 架构契约立法 / 体验终审        │
│          ▲                                                             │
│          │ (UI / TUI / Menu / Native Hotkeys)                          │
├──────────┼─────────────────────────────────────────────────────────────┤
│  [Supervisor]     总管 Agent 会话 (Claude Code / Codex / agy)          │
│          ▲                                                             │
│          │ (MCP Protocols: become_supervisor / task_* / terminal_*)   │
├──────────┼─────────────────────────────────────────────────────────────┤
│  [Bus & State]    IPC 管道 + 本地状态存储 ($XDG_STATE_HOME/polter)      │
│                   - chat.jsonl (结构化群聊轮转流，单代上限 8MB)         │
│                   - tasks/ (任务状态机持久化存盘)                       │
│                   - resource_overview (全量 CPU/内存/磁盘低开销采样)   │
├──────────┼─────────────────────────────────────────────────────────────┤
│  [Workers Array]  Worker 1 (码农)  │  Worker 2 (保洁)  │ Worker 3 (压测)│
│                   各终端独立进程、互不干扰、支持差异化模型路由          │
├────────────────────────────────────────────────────────────────────────┤
│  [Engine Base]    Ghostty Terminal Core (Zig, GPU Acceleration, PTY)   │
└────────────────────────────────────────────────────────────────────────┘
```

#### 1. MCP 工具集协议清单
*   `become_supervisor`：将当前终端升级为总管角色，获取全局读写与编排权限。
*   `terminal_list` / `terminal_read` / `terminal_send`：跨终端巡检、读取无污染屏幕数据、非阻塞模拟键入。
*   `terminal_answer_prompt`：针对停摆确认对话框的自动化代理决策通道。
*   `group_create` / `group_post` / `group_read` / `group_list`：跨智能体消息总线与持久化审计流。
*   `task_create` / `task_assign` / `task_progress` / `task_close` / `task_history`：结构化状态机看板。
*   `resource_overview`：毫秒级全域系统资源透视（进程树、内存分配、Swap 交换分区、剩余磁盘）。

#### 2. 本地存储布局与持久化规范
Polter 遵循 XDG 规范，所有持久化资产均保存在 `$XDG_STATE_HOME/polter/`（macOS 通常为 `~/.local/state/polter/`）：
*   `chat/`：智能体群组通信数据，主文件 `chat.jsonl` 自动执行单代 8MB 滚动备份（`chat.jsonl.1`）；
*   `tasks/`：各群组独立维护的任务状态机数据；
*   `projects/`：保存的多分屏布局、目录路径及环境定义；
*   `launchers.json` & `personas.json`：角色系统与 CLI 预设配置。

---

## 安全护栏（Polter 绝对不做的事）

1.  **绝不偷偷向云端上传代码**：没有商业遥测、没有中央服务器、没有云端中间商，完全断网亦可流畅运行。
2.  **绝不剥夺人类终极否决权**：
    *   你可以通过设置 `poltergeist-may-authorise = false` 全局关闭总管代答；
    *   可以通过“防护 (Shield)”功能将特定生产终端彻底设为只读隔绝，任何 AI 权限均无法逾越。
3.  **绝不在内存中保留敏感明文图像**：马赛克涂抹区域在渲染管线阶段直接像素级破坏，磁盘与剪贴板永不留存原始敏感数据。

---

## 常见问题 (FAQ)

**Q: Polter 和常规的 AI 编辑器（如 Cursor、Windsurf）有什么本质区别？**  
A: Cursor 等工具本质是“单人、单仓代码补全编辑器”。当你的工程演进到全栈阶段，需要同时运行前端构建、后端开发、数据库迁移和自动化压测时，单编辑器架构就会崩溃。Polter 是**多 Agent 协同的 Vibe Studio**，它在终端层调度多支独立小队并行运转。

**Q: 为什么总管能防止半夜停摆？**  
A: 绝大多数过夜长任务中断，都是因为终端卡在了低危确认提示符（如 `npm install`、`allow reading file?`）。Polter 的总管能在秒级识别此类状态并代为确认；遇到真正的高危操作则触发系统通知叫醒人类，兼顾效率与安全底线。

**Q: 除了 Claude Code，还能接入哪些 AI CLI？**  
A: Polter 完整内置支持 Claude Code、OpenCode (v1 及 v2)、Codex 以及 macOS 下的 Antigravity（`agy`），并提供统一的角色与钩子支持。任何基于终端的命令行工具均可在 Worker 标签页中顺畅运行。

**Q: 本地性能开销大吗？**  
A: 极小。底层基于现代高性能 Ghostty（采用 Zig 编写，GPU 硬件加速渲染），监控模块 `resource_overview` 采用静态内存预分配，全量全屏监控时 CPU 占用通常不足 1%。

---

## 联系与支持

*   **问题反馈与建议**：[GitHub Issues](https://github.com/Lugia123/polter/issues)
*   **商务与交流**：[xugf@bestfunc.com](mailto:xugf@bestfunc.com)
*   **关于 Ghostty**：Polter 的卓越终端基底源于 [Ghostty](https://github.com/ghostty-org/ghostty) 开源项目。我们遵循 MIT 开源协议，持续同步上游核心能力。

---
*感谢 [LINUX DO](https://linux.do) 社区在早期分享中给予的宝贵反馈。*
