# Ghostty 开发文档索引

> 最后更新对应的 git commit：`f81dcadc8`（`f81dcadc82ea2afdcf2dc92929037701122f05b5`，2026-08-14）
> 校验方式：`git log -1 --format='%H %h %ad %s'`

这些文档面向**在本仓库做开发的人**（也包括编码 agent），不是给终端用户看的使用手册。

**权威来源永远是代码本身。** 文档只是一张加速理解的地图：它会滞后于代码，也可能在重构后指错行号。任何文档描述与源码冲突时，以源码为准，并顺手更新文档顶部的 commit 标注。

用户向的文档在上游站点，不在这里；仓库内的贡献流程见 [CONTRIBUTING.md](../CONTRIBUTING.md)，环境搭建与 lint 细节见 [HACKING.md](../HACKING.md)。

## 文档列表

- [architecture.md](architecture.md) — 模块地图、进程启动到第一帧的调用链、每个表面（surface）的线程模型与 mailbox 消息通道。
- [terminal-core.md](terminal-core.md) — `src/terminal` 终端核心：VT 解析、`Screen`/`PageList`/`Page` 存储、OSC/DCS/APC 与 kitty 协议，以及 libghostty-vt 的 C API。
- [rendering-and-font.md](rendering-and-font.md) — `src/renderer` 的 Metal/OpenGL/WebGL 后端与着色器，`src/font` 的字体发现、face、整形器与图集（atlas）。
- [platform-and-config.md](platform-and-config.md) — `src/apprt` 应用运行时（apprt）抽象、`macos/` Swift 应用、`src/config` 配置系统、`src/input` 键绑定与按键编码。
- [preview-manual.md](preview-manual.md) — 怎么构建、怎么跑起来、怎么快速迭代、怎么看日志和调试。**构建与运行命令以本篇为唯一权威**，其他篇只做一行引用。
- [poltergeist/](poltergeist/README.md) — Poltergeist 能力层：让一个「总管」终端照看多个 AI 终端。**代码已落地**（`src/poltergeist/`），但整条链路尚未在真机上跑过 —— 验证情况与如何自己试见 [poltergeist/README.md](poltergeist/README.md)。本批文档的写作规范见 [poltergeist/\_spec.md](poltergeist/_spec.md)。

## 先读哪一篇

- 第一次上手、想把东西跑起来 → [preview-manual.md](preview-manual.md)
- 想搞清楚"一个按键怎么变成屏幕上的字" → [architecture.md](architecture.md)
- 改转义序列解析、屏幕数据结构、libghostty-vt → [terminal-core.md](terminal-core.md)
- 改绘制、着色器、字体或字形（glyph）问题 → [rendering-and-font.md](rendering-and-font.md)
- 改 macOS/GTK 侧、配置项、键绑定 → [platform-and-config.md](platform-and-config.md)
- 做 Poltergeist（多 AI 终端监督）相关设计 → [poltergeist/README.md](poltergeist/README.md)

## 写作规范

新增或修改 `docs/` 下任何文件前，先读 [\_conventions.md](_conventions.md)。它规定了引用格式（`路径:行号`）、代码块语言标注、术语统一译法、以及未核实内容的标注方式。

## 与仓库内其他文档的关系

- 根 [AGENTS.md](../AGENTS.md)（`CLAUDE.md` 是指向它的符号链接）是给 agent 的入口索引，只放最短路径，细节一律指向本目录。
- 各子目录还有自己的 `AGENTS.md`，规则对该子树生效，改到哪个目录就先读哪个：[macos/AGENTS.md](../macos/AGENTS.md)、[example/AGENTS.md](../example/AGENTS.md)、[src/benchmark/AGENTS.md](../src/benchmark/AGENTS.md)、[src/inspector/AGENTS.md](../src/inspector/AGENTS.md)、[src/terminal/c/AGENTS.md](../src/terminal/c/AGENTS.md)、[src/terminal/snapshot/AGENTS.md](../src/terminal/snapshot/AGENTS.md)、[src/terminal/compress/AGENTS.md](../src/terminal/compress/AGENTS.md)、[src/terminal/apc/glyph/AGENTS.md](../src/terminal/apc/glyph/AGENTS.md)、[test/fuzz-libghostty/AGENTS.md](../test/fuzz-libghostty/AGENTS.md)。
