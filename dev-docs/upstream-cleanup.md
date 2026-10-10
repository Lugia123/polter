# 上游说明文档清理记录

> 清理日期：2026-10-10
> 基于的提交：`29dd651df`
> fork 点：`f81dcadc82ea2afdcf2dc92929037701122f05b5`

本仓是 Ghostty 的 fork。这一篇记录一次性的清理：从仓库里删掉了哪些**上游 Ghostty 自己的**说明文档和示例目录、各自的内容去了哪里、哪些引用因此悬空，以及**以后合并上游时遇到这些文件该怎么办**。

**合并上游之前先读「合并上游时怎么办」一节。**

## 为什么清

仓库是公开的。读这个仓库的人和工具会先读到根目录的文档，而根目录原先有大量上游 Ghostty 的开发说明（Nix、GTK、Wayland、内存泄漏排查、打包规范、示例工程），它们把这个仓库描述成一个普通的终端模拟器。Polter 的定位是「监管其它终端里 AI agent 的终端」，终端模拟器是它继承来的地基，不是它要讲的事。

清理只动说明文档和示例，不动任何产品代码逻辑。

## 删掉了什么

「删前上游是否存在」看的是 fork 点那次提交里有没有这个路径。「本仓是否改过」看的是 fork 点到清理前，有没有**本仓自己的**提交改过它；随合并上游进来的改动不算本仓改的。

| 被删的路径     | 处理方式                                                                                   | 删前上游是否存在                   | 本仓是否改过                                                           |
| -------------- | ------------------------------------------------------------------------------------------ | ---------------------------------- | ---------------------------------------------------------------------- |
| `HACKING.md`   | 直接删。仍成立的内容本来就已写在 `dev-docs/` 里，见下面「内容去向」                        | 是                                 | 否，与 fork 点逐字节相同                                               |
| `PACKAGING.md` | 全文并入 [linux-packaging.md](linux-packaging.md)                                          | 是                                 | 否。相对 fork 点多出的 WebAssembly 一节是合并上游带进来的              |
| `CODEOWNERS`   | 直接删                                                                                     | 是                                 | 否。相对 fork 点多出的两行塞尔维亚语条目是合并上游带进来的             |
| `AI_POLICY.md` | 要点并入 `CONTRIBUTING.md` 的「AI assistance, and understanding your own code」一节        | 是                                 | **是**。本仓在文件开头加过一段说明（这份政策继承自上游、对本仓同样适用） |
| `example/`     | 整个目录直接删，133 个文件                                                                 | 是，fork 点时 129 个文件           | 否。相对 fork 点的差异（新增 `c-vt-search/`、另有 8 个文件被改）都是合并上游带进来的 |

`example/` 删前的内容，按目录列：

- 顶层 3 个文件：`.gitignore`、`AGENTS.md`、`README.md`。
- C 示例 28 个目录：`c-vt`、`c-vt-build-info`、`c-vt-cmake`、`c-vt-cmake-cross`、`c-vt-cmake-static`、`c-vt-color-scheme`、`c-vt-colors`、`c-vt-compression`、`c-vt-effects`、`c-vt-encode-focus`、`c-vt-encode-key`、`c-vt-encode-mouse`、`c-vt-formatter`、`c-vt-grid-ref-tracked`、`c-vt-grid-traverse`、`c-vt-kitty-graphics`、`c-vt-modes`、`c-vt-paste`、`c-vt-render`、`c-vt-search`、`c-vt-selection`、`c-vt-selection-gesture`、`c-vt-sgr`、`c-vt-size-report`、`c-vt-snapshot`、`c-vt-static`、`c-vt-stream`、`cpp-vt-stream`。
- Swift 示例 1 个目录：`swift-vt-xcframework`。
- WebAssembly 示例 3 个目录：`wasm-key-encode`、`wasm-sgr`、`wasm-vt`。
- Zig 示例 3 个目录：`zig-formatter`、`zig-vt`、`zig-vt-stream`。

合计 35 个目录加 3 个顶层文件。

### 随删除一起去掉的构建内容

`example/` 不被任何 `zig build` 的 step 依赖，但 Nix 检查和 C API 文档的构建用到它，一并处理了：

| 文件                                     | 改动                                                                                                    | 后果                                                                                 |
| ---------------------------------------- | ------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| `nix/libghostty-vt.nix`                  | 删掉 `passthru.tests` 里的 `build-example-c-vt-build-info` 这一个派生（35 行）。`nix/` 下别的内容没有动 | 少一条 Nix 检查：用 pkg-config 链接 libghostty-vt 编译那个示例                       |
| `src/build/docker/lib-c-docs/Dockerfile` | 去掉 `COPY example/ ./example/` 一行                                                                    | 不去掉的话，镜像构建会在复制一个不存在的目录时失败                                   |
| `Doxyfile`                               | `EXAMPLE_PATH` 由 `example` 改为空                                                                      | Doxygen 不再到示例目录里找源码                                                       |

**C API 文档本仓不发，示例片段会缺。** `include/ghostty/vt.h` 和 `include/ghostty/vt/` 下的头文件里有 46 处 `@snippet`（分布在 17 个头文件）、13 处 `@example` 和 12 处 `@ref`，都按路径引用示例源码。这些指令**一律没有动**：头文件是上游的，改注释只会让以后每次合并上游都多一批冲突。代价是在本仓跑 Doxygen 时这些片段找不到源文件。

## 内容去向

- **`HACKING.md`**：构建、依赖、日志、lint、Valgrind、Nix VM 这些内容，[preview-manual.md](preview-manual.md) 早就逐条写过（原先把它当出处引用）；输入栈的手工测试清单在 [platform-and-config.md](platform-and-config.md) 里有一份。所以没有新搬内容，只是把这两篇里指向它的出处改成了仓库里仍然存在的文件，或者直接陈述那条事实。**没有搬的**：自定义 Nix VM 的 `flake.nix` 模板、给上游贡献新 VM 定义的准入条件、上游的 agent 命令介绍。这三样要么只对上游的协作流程有意义，要么在本仓已经不成立。
- **`PACKAGING.md`**：全文在 [linux-packaging.md](linux-packaging.md)，只改了标题层级和一句自我指称，开头加了一段说明。
- **`AI_POLICY.md`**：并进 `CONTRIBUTING.md` 的是四条规则（披露、提交的人必须完全看懂代码、issue 和讨论也要有人把关、不收 AI 生成的媒体）和一句定位（本项目自己就是重度 AI 辅助写的，并明说）。**没有并的**：上游的公开点名名单（本仓从来没有维护过）、「维护者豁免」条款（本仓的立场相反，规则对自己的提交同样适用）。
- **`CODEOWNERS`**：内容是上游 GitHub 组织里的团队名，对本仓没有意义，没有保留。

## 被改掉引用的文件

因为指向被删的文件而改过的：

- 根 `AGENTS.md`：嵌套 `AGENTS.md` 的清单里去掉示例目录；开头加了一段定位（见下）。
- `CONTRIBUTING.md`：AI 一节改写，不再链接已删的政策文件。
- `dev-docs/README.md`：环境搭建的指向改为 `preview-manual.md`；嵌套 `AGENTS.md` 的清单里去掉示例目录；索引里加了 `linux-packaging.md` 和本篇两行。
- `dev-docs/_conventions.md`：7 处。
- `dev-docs/preview-manual.md`：21 段（其中「关键文件地图」里的一行、「常见问题」里讲上游文档过时的一条是整条删掉）。
- `dev-docs/platform-and-config.md`：7 处。
- `dev-docs/architecture.md`、`dev-docs/rendering-and-font.md`：各 1 处延伸阅读。
- `dev-docs/terminal-core.md`：讲示例目录的一节改写为「示例在上游，不在本仓」；延伸阅读去掉 1 条。
- `dev-docs/en/README.md`、`dev-docs/en/architecture.md`、`dev-docs/en/preview-manual.md`：与中文版对应的改动。
- `po/README_TRANSLATORS.md`：去掉「提 PR 前更新 code-owners 文件」那句，原来讲这个文件的小节改写为说明本仓没有它。
- `src/apprt/gtk/build/blueprint.zig`：找不到 `blueprint-compiler` 时的提示文字里，「详见」的指向改为 `dev-docs/preview-manual.md`。只改了这一行字符串。
- `.gitignore`、`.prettierignore`：去掉只对示例目录有意义的忽略规则。
- `nix/libghostty-vt.nix`、`src/build/docker/lib-c-docs/Dockerfile`、`Doxyfile`：见上一节的表。

同一次清理里顺带做的、不属于「改引用」的一处：根 `AGENTS.md` 开头加了一段话，说明这个仓库是 Polter、是 Ghostty 的 fork。

### 已知悬空引用

下面这些地方仍然提到示例目录，**刻意没有改**，因为它们是上游的文件，改了只增加合并冲突：

- `CMakeLists.txt:65-66`、`dist/cmake/README.md:102`、`dist/cmake/GhosttyZigCompiler.cmake:34`：注释和说明里让读者去看 CMake 示例。
- `include/ghostty/vt/key.h:30`、`include/ghostty/vt/mouse.h:27`、`include/ghostty/vt/snapshot.h:38`：注释里的散文。
- `include/ghostty/vt.h` 与 `include/ghostty/vt/` 下头文件里的 Doxygen 指令，见上文。
- `src/build/GhosttyDist.zig:195`：打 lib-vt 源码包时的排除清单里有 `"example"`。排除一个不存在的路径没有后果。

## 合并上游时怎么办

本仓删掉的这些路径，上游还在继续改。合并时会遇到两种情况。

**一、上游改了被删的文件。** git 报 modify/delete 冲突（`CONFLICT (modify/delete): ... deleted in HEAD and modified in ...`）。**默认解法是保持删除**：

```sh
git rm -r --ignore-unmatch HACKING.md PACKAGING.md CODEOWNERS AI_POLICY.md example
```

**二、上游在 `example/` 下新增了文件。** 这不是冲突，新文件会安静地跟着合并进来，没有任何提示。所以**上面那条命令每次合并上游都要跑一遍，不管有没有报冲突**；`--ignore-unmatch` 保证路径不存在时它也不报错。跑完用下面这条确认，输出应为空：

```sh
git ls-files HACKING.md PACKAGING.md CODEOWNERS AI_POLICY.md example
```

**三、上游改了本仓改过的那几行。** 这是普通的内容冲突，解法都是保留本仓的版本：

- `nix/libghostty-vt.nix`：上游动了 `build-example-c-vt-build-info` 那个派生，或在 `passthru.tests` 里加了新的、引用示例目录的派生。继续删。
- `src/build/docker/lib-c-docs/Dockerfile` 的 `COPY example/` 一行、`Doxyfile` 的 `EXAMPLE_PATH`：保持去掉、保持为空。
- `.gitignore`、`.prettierignore` 里示例目录的规则：保持去掉。
- `po/README_TRANSLATORS.md`：上游改了讲 code-owners 的小节时，保留本仓的写法。
- `src/apprt/gtk/build/blueprint.zig` 的那一行提示文字：保留本仓的指向。

### 要停下来看的情况

下面几种不能照默认解法直接过：

1. **`PACKAGING.md` 上游有实质更新。** 合并前先看上游改了什么（把 `<上游分支>` 换成实际的远端分支名）：

   ```sh
   git diff "$(git merge-base HEAD <上游分支>)" <上游分支> -- PACKAGING.md
   ```

   有实质内容（新的构建选项、新的打包要求）就把它同步进 [linux-packaging.md](linux-packaging.md)，然后再删。只删不同步的话，那份文档会悄悄过期。
2. **上游在 `example/` 之外新增了对示例目录的构建依赖。** 清理时查过的范围是 `build.zig`、`src/build/`、`.github/`、`nix/`、`flake.nix`、`CMakeLists.txt`、`dist/`、`Doxyfile`；当时 `.github/` 和 `build.zig` 里没有任何引用。合并后再查一遍：

   ```sh
   git grep -n 'example/' -- build.zig src/build .github nix flake.nix
   ```

   清理完成时这条命令的输出为空。合并后多出来的每一行，都是一处会因为目录不存在而失败的构建，要逐条处理，不能留着。
3. **`AI_POLICY.md` 上游改了规则本身。** `CONTRIBUTING.md` 里那一节是要点的转述，上游加了新规则或改了旧规则时，要判断本仓是否跟进。
4. **`HACKING.md` 上游改了输入栈测试清单或依赖版本。** [platform-and-config.md](platform-and-config.md) 和 [preview-manual.md](preview-manual.md) 里各有一份对应内容，要跟着改。

## 刻意保留的东西

| 路径                                             | 为什么留                                                                                                   |
| ------------------------------------------------ | ---------------------------------------------------------------------------------------------------------- |
| `LICENSE`                                        | MIT 许可证要求保留上游的版权声明。不能删，也不能改掉里面的版权行                                           |
| `nix/`、`flake.nix`、`flake.lock`、`snap/`、`flatpak/`、`dist/` | Linux 打包与分发用的目录。本仓目前不发 Linux 包，但这些是能用的构建定义，不是说明文档，留着日后发包时用    |
| `build.zig.zon.txt`                              | 依赖清单的纯文本形式，由打包流程读取，属于构建输入                                                         |
| `CMakeLists.txt`                                 | 让 CMake 工程能直接依赖 libghostty-vt 的入口，属于构建定义                                                 |

README、官网目录 `docs/`、路线图和安全说明不在这次清理的范围内，没有动。
