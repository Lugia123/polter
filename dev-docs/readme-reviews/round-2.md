# 第二轮 · 2026-09-06

- **读的版本**：`fe23d2190`（README.md 525 行 / README_CN.md 441 行）
- **触发**：第一轮改完之后的验证。**换了两个全新的 agent** —— 第一轮那两位已经理解
  这个产品了，再问他们等于问一个已经知道答案的人。
- **产出的改动**：见文末
- **读者**：身份设定与第一轮逐字相同，为的就是「同一类人读新旧两版」可比。

## 第一轮的问题解决了吗

| 第一轮的发现 | 第二轮的状况 |
| --- | --- |
| 「一个 tab 管着其它 tab」被读成只读看板 | **解决。** 两人都没有误解，而且都主动写出了一段准确的产品复述 |
| 痛点埋在第 37 行 | **解决。** 两人都在前 20 行认出了自己的场景 |
| Polter 和总管混用 | **部分解决。** 两人都能分开了，但两人都说这一段写得别扭（见下） |
| 换终端的成本被当脚注 | **解决，而且成了留人的理由。** 中文读者的装机决定就是被它翻过来的 |
| 四十个工具的表格 | **解决。** 不再是弹出点 |
| 上手缺 MCP 工具的验证 | **解决。** 两人都把 `me` 那一步复述进了流程 |

英文读者对能力表的评价：「This is the clearest part of the doc.」他随后写下的复述
是准确的。中文读者也一样，并且加了一句：「能复述，说明这一段是有效的。」

## 两人共同的新问题

### 1. 通知缺口是「先钩后说」——这是上一轮改动引入的

第一轮的修法是把「不带通知插件」写进「决定之前」。第二轮两人都指出，那个位置太靠
后了。

- **英文读者的弹出点就在这一行**：「line 41 — thirty lines earlier — sold me the
  single best thing in the product: *"that one wakes **you**, at any hour."*
  Then the ship state is: it can't wake you. The whole pitch is "mind them while
  you're asleep", and the asleep case is the one that isn't wired.」
- 中文读者说得更直接：「第 8 行和第 63 行隔了 55 行，我是先被卖点勾住、再被告知卖
  点缺一段。**这不是"缺点写出来加分"，这是"缺点埋得有点晚"。**」并给出了修法：在
  第 8 行那句下面直接加半句。

**照做了**：一句话卖点下面就是那半句，中英两版。

### 2. 成本没有数字

两人都把它列为决定性未知，且都点名原句等于没说。

- 中文读者：「'给它配一个你愿意让它一直跑着的模型和预算'——**这话等于没说**。一个
  总管盯三个 worker 跑一整夜，大概几刀？全文一个数字都没有。这是我决定要不要真跑
  通宵的第一个门槛，比什么权限模型重要得多。」
- 英文读者：「This is the number that decides whether I run it, and it's the one
  number not in the doc.」

**没有编数字。** 改成明说「目前没有实测数字」，加上决定成本的三个旋钮（worker 数
量、`poltergeist-notice-interval`、每次读进多少屏幕）和一句「先拿一个 worker 跑一
小时」。谁测出来了就在 issue 里说，这一段就会有数字。

### 3. 格言式文风——两轮四人次都提到了

第一轮英文读者提过，我当时的判断是「入口要能扫读，深处可以有声音」，并在
[round-1.md](round-1.md) 里写明留待下一轮看是否仍被提起。**第二轮两人都把它选为
「最烦的一处」**，判断被推翻。

- 英文读者：「Individually each one is a decent line. Stacked forty deep, the doc
  starts to feel like it's admiring itself, and it doubles the length of the
  thing I have to read to answer "what does this do and will it cost me $40 a
  night."」
- 中文读者：「单看每一句都漂亮，连着读三十句就累。我要的是"这东西怎么用、多少钱、
  会不会坏"，不是每一段都请我品一下作者的分寸感。」

**只改了他们点名的几处**（"a guarantee you were told about once…"、"它是查阅材料，
读起来也像查阅材料"、中文对应的同一句）。**全篇没有重写，这是一笔明确的欠账**，见
文末。

## 各自独有的发现

### 中文读者

- **第 253 行把读者指向「下面那个完整例子」，而例子在第 174 行。** 实打实的错误，
  是上一轮引入的。已修（中英两版都是「上面」）。
- **「总管能做什么」整节自相矛盾**：「你刚花了 20 行跟我讲四十个工具的权限划分…然
  后在结尾告诉我"你不需要它就能用"。**那我刚才为什么要读？**」他建议整节挪进 docs，
  README 只留五个家族那张表。**未做**，见欠账。
- **能力表和「Polter 从不判断」打架**：表里说「**它**看得见 worker 卡在哪个确认框
  上」，下面又说「**它**从不做任何判断」——两个「它」不是同一个东西。已改：明写
  「表里的每一个"它"都指总管」，并把 Polter 的角色从「不判断」改写成「不看内容，
  只递东西」。
- **「供给插件」是 provision 的硬译**，出现四次，「每次我都要重新想一下它是什么」。
  已全部改为「注册插件」。
- **中文不通**：「而发一个谁都没启动过的包不该悄悄地做」。已改写。
- 他**会装**，决定性理由是「它本身就是一个完整的 Ghostty」——正是上一轮加的那句
  缓解。但他补了一句实话：「**我会先当普通终端用**，监管功能大概率放两周不碰。」

### 英文读者

- **`terminal_open` 那处矛盾**：第 192 行说「You don't need to name terminal ids or
  tools」，而第 214 行的例子里明写着 `terminal_open` 和 `watch: true`。「Those two
  contradict each other and I don't know which one is true.」已修：例子前说明它是
  故意写细的版本，只说目标也行。
- **零截图**：「There's a chat TUI, a task panel, a stats page, tab marks with
  rings and padlocks — and not one image. For a terminal app that's a strange
  omission.」**未做**，见欠账。
- **总管自己的上下文满了会怎样**：「does the supervisor still know what it was doing
  at hour six?」文档里只有配置表的一行提到 hand-over。**未做**。
- 他**不装**，唯一的决定性理由是通知缺口：「Until that ships as a working plugin —
  even one crappy `osascript` one — I'd have to babysit the babysitter, which is
  the thing I already do.」他同时说换终端这一条已经不是障碍了：「The terminal
  replacement is a smaller obstacle than the doc seems to fear.」

## 这一轮做了什么

| 反馈 | 改动 |
| --- | --- |
| 通知缺口埋得晚（两人） | 一句话卖点底下就说，中英两版 |
| 成本没数字（两人） | 明说没有实测数字 + 三个决定成本的旋钮 + 先小规模试 |
| 「下面那个完整例子」指错方向 | 改成「上面」 |
| 「不用说工具名」与例子点名工具矛盾 | 例子前说明它是刻意写细的版本 |
| 两个「它」指代不同东西 | 重写 Polter / 总管的定义，明写表里的「它」都指总管 |
| 「供给插件」硬译 | 改为「注册插件」 |
| 「不该悄悄地做」中文不通 | 改写 |
| 格言式文风（四人次） | **只改点名的三处**，未全篇处理 |

## 欠账（确认存在，这一轮没做）

1. **全篇的格言密度。** 两轮四人次一致，证据是充分的。没做的原因是范围：涉及全篇
   几十处，且改写有把准确的话改松的风险。**下一轮之前应该做掉**，做法是把「事实」
   和「为什么」拆开——事实用短句，理由降级或删除。
2. **「总管能做什么」整节。** 中文读者说它自相矛盾，建议整节进 docs。这一节现在是
   README 里密度最高的地方，而两轮里没有一个读者说它有用。
3. **截图。** 一张都没有。作者手上有现成的（群聊、任务面板、菜单、多 tab 概览），
   在仓库外的另一个目录里。**需要作者确认哪些可以公开**——截图里可能有本机路径、
   项目名和真实对话内容。
4. **两轮读者共同关心、文档至今没有回答的几个问题**：总管读屏幕时读进去的到底是
   什么（整屏还是 scrollback，会不会把刚 `cat` 过的 `.env` 一起喂进去）、没有通知
   插件时「叫醒你」退化成什么、现有的 Ghostty 配置能不能直接搬过来、总管自己上下文
   满了怎么办。这四个都是真问题，都还没写。
