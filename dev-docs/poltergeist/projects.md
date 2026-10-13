# 群与项目：一一绑定，以及两端怎么说话

> 状态：**核心与契约做完并有测试（任务 #1490）；两个宿主都还没接。** 宿主不发 `projects` 之前，核心对
> 项目是「不知道」，什么都不自动做——所以今天的 mac 与 Windows 行为与接这件事之前相同。
> 设计依据：`control-room-design/v20/DESIGN.md` 第 10–19 条。代码：`src/poltergeist/Projects.zig`（判定，
> 纯函数）、`Chat.ProjectTie`（群这一半）、`ControlAct.zig`（宿主的四句话）、`ControlRoom.zig`（快照里的
> `project` 与 `project_orders`）、`App.zig` 的 `projectsWork`（把两者接起来，**没有单测**）。

## 1. 现状：核心原来知道多少

什么都不知道。`src/Project.zig` 是项目文件的格式库，运行时没有调用者；项目文件由宿主读写，「哪个标签页
属于哪个项目」在 mac 是窗口恢复状态里的 `boundProject`，没有任何一条 C API 或 apprt 动作把它告诉核心。
所以这件事的第一步不是绑定的规则，而是**让两端有话可说**。

## 2. 谁为准

**群的 `group.json` 为准，项目文件里的 `group` 是镜像。** 一个群一个项目：

| `group.json` 的 `project` | 意思 | 启动这个群 |
| --- | --- | --- |
| 没有这个键（`undecided`） | 没人说过——这一版之前的每一个群 | 选目录（#1486） |
| `{"name":"<项目名>"}`（`bound`） | 绑着这个项目；名字是宿主最后确认过的那个 | 打开项目 |
| `{"declined":true}` | 它的总管说它没有项目 | 选目录；不再自动提议 |

「没人说过」与「说了没有」是两个答案，分开存。绑上以后项目名要等于群名（设计第 10 条）；在宿主改完名
之前，`name` 里是宿主手里的那个名字，所以改名改到一半断电也接得上。

两边不一致时（`Projects.reconcile`，每一种都有测试）：

| 情形 | 怎么办 |
| --- | --- |
| 群说绑着 P，宿主的清单里没有 P | 群**解绑**（文件没了），回到选目录；不当场再提议一个——删项目的人没要新的 |
| 群说绑着 P，P 的文件写的是别的群或没写 | 待办 `set_group`：把文件改对 |
| 另一个文件也自称是这个群的（复制了项目文件） | 待办 `set_group`→`null`：清掉那一个 |
| 文件自称属于一个不存在的群，或一个说过「没有」的群 | 待办 `set_group`→`null` |
| **群没有绑定，而恰好只有一个文件自称是它的** | **群采纳它**——镜像唯一赢的一次：旧版本重写 `group.json` 会把这个键丢掉，那时项目文件是仅存的记录 |
| 两个以上文件自称是同一个没绑定的群的 | 不动，原因 `several_projects` |
| 绑着的项目名 ≠ 群名 | 待办 `rename`；那个名字已被别的项目占了 → 不改，原因 `project_name_taken`（仍然绑着） |

## 3. 宿主 → 核心：一句整份陈述

走现有的 `ghostty_app_control_act`（JSON），不加新的 C API。

```json
{"act":"projects","list":[
  {"name":"web-app","group":"web-app","pages":3,
   "open":[["0x…a1","0x…b1"],["0x…b2"]],
   "supervisor":"0x…a1"},
  {"name":"notes","group":null,"pages":1,"open":null,"supervisor":null}
]}
```

- **每次都是全部**：每个项目、它文件里写的群（没有写 `null`）、它一共几页、**开着的话**每一页上有哪些
  终端（`ghostty_surface_poltergeist_id` 的那个号，`0x` 加 16 位十六进制）、文件标成总管的那一格里现在是
  哪个终端。没开就是 `"open":null`、`"supervisor":null`。**五个键每一项都要写**，漏写不是「没有」，整句被拒。
- **它替换上一句**，不是增量。丢一句不要紧，下一句会把全部再说一遍。
- 什么时候说：启动时读完项目目录说一次；此后项目被新建、打开、关闭、改名、删除，或者多了少了一页、
  一格，都重说。说多了没有代价。
- 整句读不通（缺键、两个项目同名、一个终端出现在两个项目的页上、总管那格不在任何一页上）→ `BadRequest`，
  上一句继续算数。**不收半句**：半句会让另一半里的项目看起来被删了，它们的群会被解绑。
- **没说过 = 不知道**，不是「没有项目」。核心在不知道的时候不绑、不解绑，唯一会出的待办是 `open`。

另外三句：

```json
{"act":"project_failed","name":"web-app","why":"not_found"}
{"act":"project_remove","terminal":"0x…b2"}
{"act":"project_rename","from":"web-app","to":"storefront"}
```

- `project_failed`：被要求打开的项目没打开（`not_found` / `unreadable`）。等它的那次启动当场失败；
  `not_found` 还会让群当场解绑。
- `project_remove`：把一页移出项目**之前**问。那一页上有这个群的总管、而且这个项目就是这个群的 →
  `SupervisorPage`，不许移（设计第 14 条）。只是问，核心什么都不改；允许了以后宿主自己移、再重说一遍。
  关一页不是移出（第 5 条），关不用问。
- `project_rename`：给项目改名**之前**问。项目是某个群的 → 核心走群改名那条路（可能被拒：`BadName`、
  `GroupExists`…，因为项目名就是群名，而群名只许 `a-z 0-9 -`、48 字以内），成功后待办单里出现 `rename`，
  宿主照做。项目不属于任何群 → 直接回成功，宿主照常改。

## 4. 核心 → 宿主：快照里的待办单

也不加新的动作。快照多了：

```json
"projects_known": true,
"project_orders": [
  {"order":"open",     "project":"web-app","group":"web-app","to":null,"terminal":null},
  {"order":"create",   "project":"nightly","group":"nightly","to":null,"terminal":"0x…a1"},
  {"order":"bind",     "project":"scratch","group":"old","to":"old","terminal":"0x…a1"},
  {"order":"set_group","project":"copy","group":null,"to":null,"terminal":null},
  {"order":"rename",   "project":"web-app","group":null,"to":"storefront","terminal":null},
  {"order":"add_tab",  "project":"web-app","group":null,"to":null,"terminal":"0x…b9"}
]
```

**待办是声明，不是事件。** 它每次都从「群怎么说」和「宿主上一句怎么说」重新算出来：宿主没做，它一直在；
宿主做了并重新陈述，它就没了。没有确认消息。**同一条做两遍不能出事**——宿主收到每一版快照都把单子过一遍，
已经是那个样子的就跳过。

| `order` | 宿主做什么 |
| --- | --- |
| `open` | 打开这个项目（已经开着就切过去，第 3 条），然后重新陈述。**启动行不经过宿主**：核心在陈述里看到 `supervisor` 那格的终端号以后，自己把启动行打进去 |
| `create` | 新建一个项目，名字是 `project`（= 群名），只有一页：`terminal` 所在的那个标签页。文件里写 `group`，把 `terminal` 那一格标成总管 |
| `bind` | 一个已有的、没有群的项目绑给 `group`：文件里写 `group`，把 `terminal` 那一格标成总管，改名为 `to` |
| `set_group` | 把文件里的 `group` 写成这个值（`null` 是去掉） |
| `rename` | 把项目文件（连同 `.scrollback/`、`.prev`）改名为 `to`。**文件改名由宿主做**，它拥有这些文件 |
| `add_tab` | 把 `terminal` 所在的标签页加进这个项目 |

`add_tab` 是「总管开出来的标签页自动进它那个群的项目」：核心记着哪个终端是哪个 agent 开的。一个终端只催到
它在某个项目的页上出现过一次为止；之后用户把它移出去，是用户的决定，不再催。

每个群的行上多了 `project`：

```json
"project": {"tie":"bound","name":"web-app","pages":3,"open":false,"start":"project","why":"none"}
```

- `start` 是点「启动」会发生什么：`project`（打开项目，所有页都回来，总管在它那格里启动）或 `directory`
  （今天的：在 `supervisor.cwd` 开一个标签页）。**按钮上写什么看它**；`pages` 是 05a 那句「N 页」要的数。
- `pages` / `open` 在宿主没说过时是 `null`：**不知道不是 0，也不是「关着」**。
- `why` 一个词说清现状：`none`（绑着，没事）、`projects_unknown`（宿主没说过）、`not_taken_up`（旧群，
  这一轮还没有总管接手）、`declined`、`pending`（待办已经发给宿主）、`no_supervisor`、`other_supervisor`、
  `supervisor_of_several`、`supervisor_has_project`、`project_has_group`、`project_name_taken`、`several_projects`。

## 5. 从群启动

`start_supervisor` 不变。群绑着项目时：核心记「正在启动，等项目」（30 秒），待办单出 `open`；宿主打开并
陈述；核心看到 `supervisor` 那格的终端号，把那次启动的启动行（#1486 的 `+launch … --group= --resume=`）
打进去，此后与今天一样等 agent 连上。`cwd` 不读（那一格有自己的目录），`role` 与 `session` 照读。

三种等不到：宿主说 `project_failed`（当场）；30 秒里宿主没给出总管那格的终端号（文件里没有一格标着总管，
或者宿主根本没接这件事）；给了终端号但没有 agent 连上（60 秒）。**前两种现在都报成
`terminal_never_opened`**——宿主的 `failed` 枚举是严格的，加一个新取值要两个宿主同时认得、各配一句话，
留给接宿主的那一单；要加的话核心这边改 `App.controlActProjectFailed` 与 `Chat.startOf` 两处。

没有项目的群：与 #1486 完全一样，选目录。

## 6. 补全：旧群用起来就绑上，有歧义就不动

「用起来」是三件事之一：总管建了这个群、总管进了这个群（重启后 `group_add` 自己回去也算）、总控台为它
启动的总管连上了。那一刻核心在这个群上记一笔「被这个总管接手了」（只在本轮内存里），之后每次对账：

- 它所在的标签页已经是一个**没有群的项目**的一页 → 待办 `bind`。
- 它所在的标签页不属于任何项目 → 待办 `create`，以群名新建。
- 宿主做完、陈述里出现「这个文件自称是这个群的」→ 群采纳，写进 `group.json`。**在那之前什么都不落盘**：
  宿主没做成的事，核心不先记成做了。

有下面任何一条就**什么都不做**，原因写在快照与 `me` 里：

| `why` | 情形 |
| --- | --- |
| `other_supervisor` | 群里不止一个总管——用谁的那一页，不归核心挑 |
| `supervisor_of_several` | 这个总管同时是好几个没项目的群的总管，一页不能是它们各自的项目 |
| `supervisor_has_project` | 它已经是另一个有项目的群的总管 |
| `project_has_group` | 它那一页所在的项目已经是别的群的 |
| `project_name_taken` | 已经有一个项目叫这个群的名字，而不是它那一页所在的那个 |
| `no_supervisor` | 接手的那个总管已经不是这个群的总管了 |

**名字撞了算歧义**，不改名、不加后缀：项目名就是群名，自动造一个「群名-2」会让「打开群的项目」找不到它。
人把占着名字的那个项目改名或删掉即可。

总管可以自己说：MCP 工具 `group_project{group, action}`。`use` =「这个群用我所在的这个项目」（不在任何项目里
就以群名新建）——它替核心回答了前两种歧义（哪个总管、它的哪个群），所以那两种不再拦；**一对一不归它豁免**：
群已有别的项目、它那页的项目是别的群的、名字被占，照样拒绝并说出原因（`ProjectHasGroup` /
`ProjectNameTaken`），宿主没说过项目时是 `ProjectsUnknown`。`drop` = 这个群没有项目：解绑，并且不再自动提议，
直到它再说 `use`。只有这个群的总管能说。`me` 在每个它管的群上给出 `tie` / `project` / `why`。

## 7. 改名

群改名（`group_rename`、总控台）→ 群的绑定里仍是旧项目名 → 对账出 `set_group`（文件里的群名）与 `rename`
（文件名）两条待办 → 宿主做完重说 → 一致。从项目这头改名见第 3 节的 `project_rename`。新名字已经是另一个
项目的 → 群照样改了名、仍绑着原来那个项目，`why: project_name_taken`，`rename` 待办不出；项目名与群名在
那之前不一样，这是唯一允许不一样的时候。

## 8. 给接宿主的人：最少要做的

1. 启动时与每次项目有变化时发 `projects`（第 3 节）。只做这一步，快照里的 `project.pages` / `open` 就有数了。
2. 每收到一版快照，把 `project_orders` 过一遍（第 4 节的表），做完重发 `projects`。
3. 移出一页之前问 `project_remove`，给项目改名之前问 `project_rename`，被拒就把拒绝名对应的话告诉人。
4. 「启动」按钮的字看 `groups[].project.start`；`start_supervisor` 的请求不用改。
5. 打开项目时，标成总管的那一格**只起 shell**，不要自己启动 agent——启动行是核心打的。其它格按设计第 13 条
   只还原终端。

## 9. 没验的

- `App.zig` 的接线（`projectsWork` 的提交循环、`deliverProjectLaunch`、`takeUpGroups`、三条 `controlAct*`、
  `poltergeistGroupProject`、`me` 的 `projects`）编得过，调用的判定函数都有测试，**但没有在真程序里走过**，
  也没有宿主能驱动它。
- 两个宿主都没接，所以「打开项目并在总管那格启动」的全流程没有任何读数。
- 一个项目跨窗口、一页被拖到别的窗口后的陈述：按设计「仍属于这个项目」，核心只看终端号，不看窗口，
  推断不受影响，没验。
