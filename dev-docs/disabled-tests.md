# 被禁用的测试：它们为什么停着，以及怎么知道该重新打开

> 最后更新对应的 git commit：`515276fa1`（`515276fa13bf1ef86ea5aa9e3848426238485d61`，2026-09-10）
> 校验方式：`git log -1 --format='%H %h %ad %s'`

## 本文覆盖什么

- 全仓**无条件禁用**的测试各是哪几条、为什么停着、有没有重新打开的条件。
- 一条禁用测试可以有几种「看不见」，以及为什么只数 `skipped` 找不全它们。
- 给下一个想加 `SkipZigTest` 的人的约定。

## 本文不覆盖什么

- **条件性跳过**（换个平台、后端或构建选项就会跑的那些）。它们不是这篇的主题：一条在 Linux 上跳过、在 Windows 上会跑的测试没有停着，只是不在这里跑。
- 怎么跑测试。见 [preview-manual.md](preview-manual.md)。

## 这一页为什么存在

`SkipZigTest` 在本仓出现 219 处，而一次 macOS 默认构建只报 23 条 skipped。**那个差不是问题，是答案**：绝大多数跳过挂在平台或构建选项上，换个环境就会跑。

剩下的少数是**无条件**的——它们在任何环境下都不跑。这些才值得单独记一页，因为它们和条件性跳过在 `skipped` 计数里长得一模一样，**而计数是大多数人唯一会看的东西**。

## 无条件禁用的测试：6 条，**有重新打开条件的 0 条**

| 位置 | 测试 | 为什么停着 | 重新打开的条件 |
|---|---|---|---|
| `src/font/discovery.zig:1321` | `coretext sorting` | CI 上没有 SF Pro，而它依赖系统字体 | ❌ 无。注释写了技术方向（改用打包进来的字体直接测 `sortMatchingDescriptors`），那是一件待做的重构，不是一个可查的条件 |
| `src/terminal/osc/parsers/iterm2.zig:359` | `OSC: 1337: Copy with invalid base64` | 出于性能考虑，解析器现在不校验 base64 | ❌ 无 |
| `src/Command.zig:1577` | `Command: ConPTY B, an interactive shell echoes back` | 交互式 shell 起得来、横幅回得来，但它从不读写进 pty 输入端的东西。注释记了七轮单变量试验 | ❌ 无。注释说了**怎么**取消（删那一行），没说**什么条件下** |
| `src/font/shaper/harfbuzz.zig:1136` | `shape Tai Tham vowels` | 装了 `Noto Sans Tai Tham` 的 Linux 上会失败 | ❌ 无。「禁用到能修好为止」没说什么算修好 |
| `src/font/shaper/harfbuzz.zig:1257` | `shape Tai Tham letters` | 同上 | ❌ 无 |
| `src/font/shaper/harfbuzz.zig:1321` | `shape Javanese ligatures` | 装了 `Noto Sans Javanese` 的 Linux 上会失败 | ❌ 无 |

⚠️ **「怎么取消」不是「什么时候取消」。** `Command.zig` 那条写着「删掉下面那行即可重新启用，不需要别的改动」——**一句可执行的指示读起来很像一个条件，而它答的是 how，不是 when**。真正的触发条件是「有人找到让那个 shell 读键盘的办法」，没有任何东西能告诉你它到来了。

⚠️ **harfbuzz 那三条比另外三条更难恢复**：它们的测试体是**整段注释掉的代码**，删掉 skip 那一行也跑不起来，得先把测试体挖出来，而那期间没人知道它还编不编得过。

## 一条禁用的测试有三种看不见

这是这一页里唯一没法从代码重新推出来的部分。它是「219 处静态匹配」和「23 条运行时名单」对不上才逼出来的——**只看 `skipped` 计数做普查，第三档永远发现不了**。

| 档 | 它出现在哪 | 例子 |
|---|---|---|
| 1 | **本平台的 `skipped` 里** | `coretext sorting`、`iterm2` |
| 2 | **只在别的平台的 `skipped` 里** | `Command: ConPTY B` —— 它前面还有一行 `if (comptime builtin.os.tag != .windows)`，所以在 macOS 上跳过它的是平台条件，那句无条件的 `if (true)` 只在 Windows 上生效 |
| 3 | **任何计数里都没有** | harfbuzz 那三条 —— `src/font/shape.zig` 的 `test {}` 块只引用被选中的那个 shaper，所以在 coretext 构建里 `shaper/harfbuzz.zig` 的测试根本不编译。它们既不在 `passed` 也不在 `skipped`，**不存在** |

⚠️ 第三档换个后端**也不会跑**：那三条第一行是无条件的 `return error.SkipZigTest;`。换到 harfbuzz 后端，它们只会从「不可见」变成「在 `skipped` 里可见」。（未核实：这是从源码判的——无条件 skip 加上被注释掉的测试体——没有真的换后端编译一次验证。）

## 给下一个要加 `SkipZigTest` 的人

`c1313294c`（`add comments about why tests are disabled`）已经做对了一半：它给 harfbuzz 那三条补上了理由。**缺的是另外两半。**

1. **写下重新打开的条件，而且要能被机器检查。** 不是「等某某修好」，是某个数、某个文件、某个构建选项——某个东西能替你说出「现在可以打开了」。
   - 正例：`src/apprt/surface.zig` 里那两条 443 判据，条件是「取消这两条跳过之后，`skipped` 减 2、`passed` 加 2」，任何人跑一次测试就能核。
   - 反例：本页表里那 6 条，理由都写得很好，**没有一条能让机器说出「可以了」**。
2. **让它在某处可见。** 一条连计数都不进的禁用测试，理由写得再好也没人会读到它。

⚠️ **理由写得越好，越像已经处理过了。** 上表里几条的注释相当详尽——七轮单变量试验的记录、明确的技术方向——而正是那种详尽让人以为这件事有人在管。

## 边界

- 本页记的是**这些测试被禁用时写下的理由**，不是**它们今天的状态**。验证需要 Windows 真机（`Command.zig`）、CI 环境（`discovery.zig`）、装了特定字体的 Linux 加 harfbuzz 后端（那三条）——这三样在写作时都没有。（未核实：全部结论来自静态阅读源码与注释。）
- 条数与分类核对过三次，三个来源一致：`grep -c SKIP` 数测试二进制输出、测试二进制自己的汇总行、`zig build test --summary all`，都是 23 条 skipped。
