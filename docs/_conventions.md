# Ghostty 文档写作规范

> 最后更新对应的 git commit：`f81dcadc8`（`f81dcadc82ea2afdcf2dc92929037701122f05b5`，2026-08-14）
> 校验方式：`git log -1 --format='%H %h %ad %s'`

## 本文覆盖什么

- `docs/` 下全部 Markdown 文档的写作、引用、排版规范。
- 根 `AGENTS.md`（`CLAUDE.md` 是它的符号链接）新增章节的风格约束。
- 反幻觉铁律：什么算"有出处"，什么必须标 `（未核实）`。
- 五篇主文档的边界划分与去重规则。
- 交付前的自检清单。

## 本文不覆盖什么

- 具体技术内容。架构见 [architecture.md](architecture.md)，终端核心见 [terminal-core.md](terminal-core.md)，渲染与字体见 [rendering-and-font.md](rendering-and-font.md)，平台与配置见 [platform-and-config.md](platform-and-config.md)。
- 构建与运行命令。唯一权威是 [preview-manual.md](preview-manual.md)。
- 代码贡献流程、CLA、AI 使用政策。见 [CONTRIBUTING.md](../CONTRIBUTING.md) 与 [AI_POLICY.md](../AI_POLICY.md)。
- Zig / Swift 源码本身的编码风格。那不属于 `docs/`。

## 最高铁律：反幻觉

本仓库是真实开源项目，文档里的每个事实都必须来自你亲眼读过的文件。

1. **路径先验证再落笔。** 提到任何路径前先 `test -e` 或 Read 确认存在。
2. **符号先 grep 再引用。** 提到函数、类型、字段名前先找到定义位置，并给出 `路径:行号`。
3. **命令必须有出处。** 每条命令要能在 `build.zig`、`src/build/Config.zig`、[HACKING.md](../HACKING.md)、根 [AGENTS.md](../AGENTS.md) 或某个子目录 `AGENTS.md` 中找到依据，或你实际跑过。
4. **禁止用"典型终端模拟器一般怎么做"补写细节。** 不确定就去读代码；读不出来就标注，不要编。
5. **禁止编造运行结果。** 没跑过的命令不许写它的输出。

`（未核实）` 标注规则：

- 任何推测、未能从代码确认的行为、未在本机跑过的命令结果，必须在该句末尾加 `（未核实）`，并在同段说明原因和建议的核实方式。
- 不允许用"大概""应该""通常"来代替 `（未核实）`。
- 一篇文档里 `（未核实）` 超过 15%，说明调研不足，回去读代码而不是继续写。

正例：

```md
`zig build run` 在 macOS 上会启动 `macos/build/<configuration>/Ghostty.app` 内的可执行文件，
并强制 `GHOSTTY_LOG=stderr,macos`（出处：`src/build/GhosttyXcodebuild.zig:142-158`）。
本机 PATH 中没有 `zig`，未实际执行验证（未核实：仅静态阅读构建脚本得出）。
```

反例（无出处、凭空捏造结果）：

```md
`zig build run` 会输出 12 处泄漏警告，属于正常现象。
```

## 语言与用词

正文一律用简体中文。以下内容保持原文、不翻译：代码标识符（`PageList`、`SharedGrid`、`renderer_state`）、文件与目录路径、命令与参数、环境变量、构建选项、错误信息、第三方项目名（Zig、GTK4、HarfBuzz、CoreText、Metal、xcodebuild、Valgrind）。

语气说明性、祈使式。禁止营销腔（"极致""强大""业界领先"）。禁止使用 emoji。

### 统一术语表

全仓统一译法，不得自创。

| 原文                     | 统一译法               | 说明                                                                      |
| ------------------------ | ---------------------- | ------------------------------------------------------------------------- |
| surface                  | 表面 / surface         | 首次出现写「表面（surface）」，其后统一写 `surface`。不要译成"窗口""视图" |
| apprt / app runtime      | 应用运行时（apprt）    | 缩写 `apprt` 直接用                                                       |
| termio                   | 终端 IO（termio）      | 缩写直接用                                                                |
| renderer                 | 渲染器                 |                                                                           |
| renderer thread          | 渲染线程               | 线程名 `renderer`（`src/Surface.zig:729`）                                |
| IO thread                | IO 线程                | 线程名 `io`，指 `src/termio/Thread.zig` 的写线程                          |
| read thread              | 读线程                 | 线程名 `io-reader`（`src/termio/Exec.zig:145`）                           |
| app thread / main thread | 主线程                 |                                                                           |
| mailbox                  | 消息信箱（mailbox）    | 其后统一写 `mailbox`                                                      |
| scrollback               | 滚动回溯（scrollback） | 其后统一写 `scrollback`                                                   |
| page / PageList          | 页 / 页链表            | 类型名保持 `Page` / `PageList`                                            |
| glyph                    | 字形                   |                                                                           |
| shaper / shaping         | 整形器 / 文本整形      |                                                                           |
| atlas                    | 图集（atlas）          |                                                                           |
| keybind / binding        | 键绑定                 |                                                                           |
| pty                      | pty                    | 不译                                                                      |
| xcframework              | xcframework            | 不译，小写                                                                |
| build option             | 构建选项               | 形如 `-Demit-macos-app=false`                                             |

## 文件与目录

固定产出五篇主文档，加一个索引页和本规范页：

- `docs/README.md` — 索引，只做目录跳转，不重复内容。
- `docs/architecture.md`
- `docs/terminal-core.md`
- `docs/rendering-and-font.md`
- `docs/platform-and-config.md`
- `docs/preview-manual.md`（重点篇）
- `docs/_conventions.md` — 本文。

文件名小写连字符、`.md` 结尾。编码 UTF-8、LF 换行、文件末尾留一个换行（与 `.editorconfig` 一致）。

`docs/` 会被 Prettier 检查（[HACKING.md](../HACKING.md) 的 Prettier 一节说明非 Zig 资源用 Prettier lint，CI 会因格式不合格失败），所以要遵守 Prettier 默认风格：无行尾空格、无序列表用 `-`、有序列表用 `1.`、表格不能破损。提交前跑：

```sh
prettier -w docs/
```

## 每篇文档的固定骨架

每篇文档必须以下面这个头部开始，顺序不可变：

```md
# <文档标题>

> 最后更新对应的 git commit：`f81dcadc8`（`f81dcadc82ea2afdcf2dc92929037701122f05b5`，2026-08-14）
> 校验方式：`git log -1 --format='%H %h %ad %s'`

## 本文覆盖什么

- ...

## 本文不覆盖什么

- ...（并指向真正覆盖它的文档）
```

短哈希与全哈希都要写，日期用 `YYYY-MM-DD`。「覆盖 / 不覆盖」两节各 3–8 条，一句话说清边界。

头部之后的建议结构（可按主题微调，但一级/二级层次不变）：

1. `## 一句话概括`
2. `## 关键文件地图`（表格：路径 | 行数量级 | 职责）
3. 主体若干 `##` 章节
4. `## 常见坑 / 注意事项`
5. `## 延伸阅读`（指向仓库内其他 `AGENTS.md`、[HACKING.md](../HACKING.md)、其他 docs 篇目）

## 标题层级

- `#` 只允许出现一次，即文档标题，位于第 1 行。
- 主体章节用 `##`，子节用 `###`，最深到 `####`。不允许 `#####` 及更深。
- 标题文字不加编号前缀（不要写 `## 1. 架构`），除非是明确的步骤序列。
- 路径类标题写成 `## src/termio：终端 IO`。

## 代码位置引用格式

一律使用「相对仓库根的路径 + 冒号 + 行号」，包在反引号里。

| 形式        | 示例                                | 是否允许 |
| ----------- | ----------------------------------- | -------- |
| 单行        | `src/renderer/Thread.zig:21`        | 允许     |
| 区间        | `src/apprt/runtime.zig:14-24`       | 允许     |
| 只指文件    | `src/terminal/PageList.zig`         | 允许     |
| 绝对路径    | `/Users/xxx/ghostty/src/App.zig:77` | 禁止     |
| 带 `./`     | `./src/App.zig:77`                  | 禁止     |
| 自然语言    | `App.zig 第 77 行`                  | 禁止     |
| GitHub 锚点 | `src/App.zig#L77`                   | 禁止     |

补充规则：

- 行号必须是你当前读到的真实行号。
- 引用容易移动的实现细节时，同时给出符号名，形如：`App.create()`（`src/App.zig:77`）。
- 不要给指向源码的引用加 Markdown 链接，一律纯反引号文本——文件移动后链接会烂掉，而 Prettier 无法校验。
- 引用仓库内其他 Markdown 文档时才用相对链接：`[HACKING.md](../HACKING.md)`、`[src/benchmark/AGENTS.md](../src/benchmark/AGENTS.md)`。

## 代码块

- 所有 shell 命令用围栏代码块，语言标注一律写 `sh`。不要用 `bash`、`shell`、`console`、`shell-session`，也不要裸缩进代码块。
- 命令块内不写 `$` 提示符，一行一条命令。需要展示输出时另起一个 `text` 块。
- Zig 片段标 `zig`，Swift 标 `swift`，C 标 `c`，Nushell 标 `nu`，JSON 标 `json`，Markdown 示例标 `md`。Metal/GLSL 着色器统一标 `c` 并在正文说明。
- 禁止无语言标注的代码块，唯一例外是纯文本输出与目录树，标 `text`。
- 代码片段必须从源文件原样复制，长度 ≤ 30 行，截断处用 `// ...` 或 `# ...` 标明。片段上方一行写出处，格式：`出处：src/App.zig:77-108`。
- 不要"改写"源码让它更好懂。要解释就在代码块下面用正文解释。

## 篇幅与密度

- 每篇 200–500 行 Markdown（含代码块与空行）。`docs/preview-manual.md` 取 350–500 行。
- 单个 `##` 章节不超过 80 行，超了就拆 `###`。
- 段落不超过 6 行。优先用表格和有序步骤代替长段落。
- 表格列数 ≤ 5。超宽信息改用 `- **字段** — 说明` 这种定义列表式写法。

## 内容质量要求

- 每个 `##` 章节至少含一处 `路径:行号` 引用。没有出处的章节要么删掉，要么整章标 `（未核实）`。
- 描述数据流或调用链时，用有序列表逐跳给出，每跳带出处：

  ```md
  1. `main()` 初始化全局状态并解析 CLI action（`src/main_ghostty.zig:26-75`）
  2. 创建核心 `App`（`src/main_ghostty.zig:100`，实现见 `src/App.zig:77`）
  ```

- 描述平台差异时必须写清「哪个平台 / 哪个构建选项」。例如：macOS 默认 `app_runtime = .none`，Linux 与 FreeBSD 默认 `.gtk`（`src/apprt/runtime.zig:14-24`）。
- 不要复述 [CONTRIBUTING.md](../CONTRIBUTING.md) 的贡献流程和 [AI_POLICY.md](../AI_POLICY.md) 的政策，只做链接。
- 不要写"未来会如何"的路线图内容，除非 README 或代码注释里有明确出处。

## 交叉引用与去重

五篇文档之间零重复。同一事实只在归属篇里展开，其他篇用一句话加链接带过。

| 主题                                                     | 归属篇                   |
| -------------------------------------------------------- | ------------------------ |
| 线程模型、启动流程、mailbox                              | `architecture.md`        |
| VT 解析、Screen/PageList/Page、kitty、OSC、libghostty-vt | `terminal-core.md`       |
| 渲染后端、着色器、字体栈                                 | `rendering-and-font.md`  |
| apprt、macOS、config、input                              | `platform-and-config.md` |
| 一切"怎么跑起来 / 怎么调试"                              | `preview-manual.md`      |

构建命令的唯一权威是 `preview-manual.md`。其他篇需要提到命令时只写一行并链接过去。

## 正反例合集

正例（章节写法）：

```md
### 渲染线程

渲染线程由 `Surface.init` 通过 `std.Thread.spawn` 启动，入口是
`rendererpkg.Thread.threadMain`，线程名设为 `renderer`（`src/Surface.zig:723-729`）。
线程内部跑一个事件循环，`DRAW_INTERVAL` 为 8ms、约 120 FPS，
`CURSOR_BLINK_INTERVAL` 为 600ms（`src/renderer/Thread.zig:21-22`）。
```

反例（无出处、无行号、有营销腔，"通常""自动"属编造）：

```md
### 渲染线程

Ghostty 用了一个高性能渲染线程，通常运行在 60FPS，架构非常先进。它会自动和 GPU
同步，保证画面流畅。
```

正例（命令写法）：

````md
在 macOS 上只改了 Zig 核心、不需要 app bundle 时，跳过 Xcode 构建可以加速：

```sh
zig build -Demit-macos-app=false
```

出处：根 `AGENTS.md:7-10`、`macos/AGENTS.md:4-6`。
````

反例（无语言标注、带 `$`、参数在本仓库不存在，属编造）：

````md
运行：

```
$ zig build --release=fast --run
```
````

## 根 AGENTS.md 的特殊约束

根 `CLAUDE.md` 是指向 `AGENTS.md` 的符号链接（`ls -la CLAUDE.md` 可确认）。因此：

- 不要删除该符号链接、不要把它替换成普通文件。编辑 `AGENTS.md` 即可，`CLAUDE.md` 自动同步。
- 若编辑工具因符号链接失败，用 `AGENTS.md` 作为路径重试。
- 现有内容一字不改、位置不动，尤其是 `## Issue and PR Guidelines` 全段。
- 新增内容一律追加在文件末尾，用英文书写（与该文件既有语言一致），风格保持 `## ` 二级标题加 `- ` 短条目。
- 它是给 agent 读的索引，不是教程。细节一律指向 `docs/`。

## 提交前自检清单

- [ ] 文档第 1 行是唯一的 `#` 标题，紧跟 commit 标注块
- [ ] 有「本文覆盖什么 / 不覆盖什么」两节
- [ ] 所有代码位置引用都是 `相对路径:行号` 格式，无绝对路径、无 `./`、无 `#L`
- [ ] 逐条 `test -e` 过所有出现的路径
- [ ] 所有 shell 块的语言标注是 `sh`，所有代码块都有语言标注
- [ ] 所有推测都带 `（未核实）`
- [ ] 行数在 200–500 之间
- [ ] 术语译法与本文术语表一致
- [ ] 没有修改 `docs/` 与根 `AGENTS.md` 之外的任何文件
- [ ] 已跑 `prettier -w docs/`
- [ ] 没有执行 `git add` / `git commit`，没有创建 issue 或 PR

## 延伸阅读

- [README.md](README.md) — 文档索引
- [HACKING.md](../HACKING.md) — 依赖、日志、lint、Nix VM
- [AGENTS.md](../AGENTS.md) — agent 入口索引
- [CONTRIBUTING.md](../CONTRIBUTING.md) — 贡献流程
