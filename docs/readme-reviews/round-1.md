# 第一轮 · 2026-09-06

- **读的版本**：`af2cccc21`（README.md 589 行 / README_CN.md 508 行）
- **触发**：一位真人读者（项目作者的朋友）读了 README 之后表示不理解这个产品是干
  什么的，没有继续往下看。他卡在的表述是「某一个 tab 去照看其它 tab」。
- **产出的改动**：`fe23d2190`
- **读者**：两个全新的 agent，中英各一，互相不知情。身份设定为「有 7–8 年经验、
  近半年重度使用 AI 编程工具、习惯同时开好几个终端跑 agent」的开发者，场景设定为
  「有人在群里甩了个链接说你可能用得上」。只给一份改名为 `doc-cn.md` /
  `doc-en.md` 的文件，禁止读其他文件、禁止搜索代码库、要求丢弃任何关于 Polter 的
  先验知识。

## 两人独立得出的相同结论

这四条是两份反馈里重合的部分。因为两个读者之间没有任何通道，重合本身就是证据。

### 1. 「一个 tab 管着其它 tab」被理解成了只读看板

- 中文读者：「脑子里的画面是一个像 tmux 或者 htop 那样的监控面板 tab，列着其它
  tab 的状态。就是一个只读的视图。这个理解是错的，而且错得挺离谱。」
- 英文读者：「My guess: some kind of idle/completion detector … basically "tmux
  with a babysitter." That guess is *wrong* in the most important way.」

英文读者补充了一个我们想不到的角度：**在基础设施语境里 "supervise" 是进程守护**
（systemd / supervisord），所以他的第二猜是「它会重启死掉的 agent」——同样是错的。

中文读者指出了这个短语的结构性问题：「"tab 管 tab"这个说法把主语藏起来了——**tab
不会管任何东西，tab 里的那个 agent 才会**。」

两人都指出，真正的意思（另一个 Claude Code 会话，拿着能读屏幕、能打字的工具）在
第 41 行才出现。英文读者：「That's a fundamentally different product and it's the
actual selling point. Line 9 hides it.」

### 2. 全文最好的一段排在第 37 行

两人各自把同一段选为「第一次明白它解决什么问题」的地方——四个 agent、一个卡在没
人回答的提问上、一个二十分钟前干完了、一个在等编译。

- 中文读者：「这是全文唯一一处让我"哎这就是我"的地方……**它却排在第 37 行，而且
  前面还压着一句会让人产生抵触的"这是 Ghostty 的分支"**。」
- 英文读者：「That is exactly my Tuesday. That paragraph is the best thing in the
  document and it's the reason I kept reading past the vague pitch above it.」

### 3. 四十个工具的完整表格不该在 README 里

- 英文读者的**关闭点**就在这里（第 286 行）：「lines 286-362 are seven consecutive
  reference tables of forty MCP tools, each cell a paragraph … That's API
  documentation. It does not belong in a README.」
- 中文读者独立给出同样建议：「**四十个工具的完整表格（第 216-330 行，115 行）不该
  在 README 里。** 那是参考手册，扔进 `docs/`。它把 README 从"读物"变成了"文档"，
  而这两种东西的读者不是同一批人。」

### 4. 上手部分有一个洞：MCP 工具是怎么来的

两人都发现第 2 步（设成总管）和第 3 步（说活是什么）之间缺一环，而失败时的答案在
三百行之外。

- 中文读者：「**如果它没生效，我在第 5 步会一脸懵地看着 Claude 说"我没有这些工具"，
  而我不会知道去哪找答案。**」
- 英文读者：「It deserves a "verify it worked: ask your agent to run `me`" line
  right there in the Quick start, not a troubleshooting section 300 lines later.」

## 各自独有的发现

### 中文读者

- **「Polter」和「总管」两个概念全文混用，从来没有正面定义过一次。** 他读了三遍才
  分清：「Polter = 那个终端程序，总管 = 跑在里面的 Claude。」
- **前 30 行里 18 行是导航链接**：「一个 GitHub README 的前 30 行里，60% 是目录，
  这是纯粹的浪费——GitHub 右侧本来就有大纲。」
- **第 45–64 行整整 20 行没有一句在讲能做什么**，全在讲不做什么、不碰什么、还没做
  到什么：「一个正在评估"要不要花时间"的人，读到这里的感受是：作者在跟自己的良心
  对话，不是在跟我说话。」
- **成本**：「我**完全不知道**"总管"这个 Claude 会话是不是会一直烧 token……这份文档
  从头到尾**一个字没提成本**。这对我来说是个真问题。」
- **未被利用的分发优势**：「它是个终端，装了不用也不亏（我可以先当 Ghostty 用）。
  这个"沉没成本很低"的性质其实是它最大的分发优势，**而文档完全没有利用这一点**。」
- 黑话清单：「不许下班」「认领」「计时」「一页算术」在首次出现处都没有解释。
- 他的结论是**会装**，理由是那段痛点描述「准确得让我不舒服」。

### 英文读者

- **没有承认自己在要求用户换掉整个终端**：「Line 35 mentions "a fork of Ghostty"
  almost in passing, as parenthetical lineage. Nobody flags that the ask is
  "replace your terminal app." **That's the biggest cost in the entire proposal
  and it's stated as a footnote.**」这是他**不装**的首要理由。
- **通知插件不随包发行**，而这正是标题承诺（"while you sleep"）的兑现路径：
  「That fact is scattered across line 66, line 235-236, and line 536, and never
  stated once as "you will need to write a ~20 line shell script to get woken
  up." **Burying that reads as evasive**, and it's the one thing that soured me
  on an otherwise unusually honest document.」
- **`tool surface` 在第 93 行使用，第 256 行才定义**，中间隔了 160 行。
- **「a task past the line you set」——什么 line？** 在此之前没有任何地方定义过任何
  阈值。
- **文风**：「it's aphoristic all the way down … For twenty lines that's charming.
  For 590 it reads like the author enjoying their own voice, and it makes
  scanning impossible, because every heading is a metaphor instead of a label.
  I cannot skim this document. That's a defect.」
- **一个具体缺陷**：开头的 HTML 标签嵌套是坏的——`<h1>` 里开的 `<p>` 从未闭合。
  （核实属实，是从上游 Ghostty 继承来的。）
- 他的结论是**不装**。

## 据此做了什么（`fe23d2190`）

| 反馈 | 改动 |
| --- | --- |
| 「一个 tab 管着其它 tab」 | 中英两版删除。换成一张具体动词的表：读屏幕 / 打字 / 开 tab 起 agent / 知道静止多久 / 群聊与任务面板 |
| 痛点排在第 37 行 | 提到标题之后第一件事，标题就叫「问题」/`The problem` |
| 18 行导航 | 砍到 5 个链接 |
| Polter vs 总管没定义 | 开头用四行正面定义两者的分工 |
| 换终端的成本被当脚注 | 新增「决定之前」一节，第一条就是它，并补上从未说过的缓解办法：它本身是个完整终端，可以先当普通终端用一周 |
| 通知插件不随包发 | 同一节第二条，明写「发行包里不带任何通知插件」 |
| token 成本无人提 | 同一节末尾一段 |
| 四十个工具的表格 | 搬到 `docs/tools.md` 和 `docs/tools_CN.md`，README 里留五个家族加一个链接。两版各瘦 64 / 67 行 |
| 上手的洞 | 第 2 步和第 3 步之间加验证步骤：问它 `me` 返回什么，答不出就停下，并就地解释 MCP 工具从哪来 |
| 黑话 | `tool surface`、「超过你设的线」、「不许下班」在首次出现处解释或改写 |
| HTML 坏了 | 修 |

### 自己发现的一处矛盾

写新表格时引入的：那一行原本写「它能替你回答那个框」，而两百行之后的「它永远不会
做的事」第一条就是 **Never answer a permission prompt for an agent. No
allow-list, no flag.** 两个读者都没看到（他们读的是旧版）。改成「它不能替 agent
点"允许"——那种情况只会来叫醒你」，一个矛盾变成了一条值得信任的理由。

## 没有采纳的

- **英文读者建议把整个「What it gives you」压到四条。** 压到了五条而不是四条。第五
  条（统计页）是这一版才做出来的功能，从未在任何面向用户的文档里出现过，压掉它等于
  它不存在。
- **英文读者建议整体改掉格言式的文风。** 只改了标题（现在是标签不是隐喻）和前 100
  行。正文没有大改：他自己也说这些句子「genuinely better than most READMEs」，而
  「它永远不会做的事」那一节两人都评价为全文最有说服力的部分，那一节正是格言式的。
  **判断是：入口要能扫读，深处可以有声音。** 这一条留待下一轮再看是否仍被提起。
