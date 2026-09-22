# 契约：角色（persona）体系的地基

> 任务 568 的第一件产出。570 / 571 / 569 照这份写，**不要各自定数据形状**。
> 对应的设计文档是 [roles.md](roles.md)；本文件只写「写死的那部分」，
> 凡是 roles.md 已经论证过的理由不重复。
> 基线 commit：`6899e05aa`。核对：`git log -1 --format='%H %h'`

每一条都标了来源：🔬 我在这棵树上核过的行 / 📖 读源码推的 / ❓ 没验过。
**❓ 那几条不许当读数用**，它们是留白，不是结论。

---

## 0. 名字：代码里叫 `persona`，中文继续叫「角色」

🔬 `include/ghostty.h:761` 已经有 `ghostty_action_poltergeist_role_e`
（`NONE` / `SUPERVISOR` / `WATCHED`），`ghostty_action_poltergeist_mark_s`
里已经有一个字段就叫 `role`；MCP 的 `me` 和 `terminal_list` 回的 `role`
也是这三个值。

所以 W3 提的 `role_key` / `role_name` / `role_deviated` **我不认**，改成
`persona_key` / `persona_name` / `persona_deviated`。理由是同一个 struct 里
`role` 是「被监督状态」而 `role_key` 是「射手」，两个字段名只差一个后缀、
意思毫不相干 —— 这种误读发生时不报错，只是看起来对。

**这是我唯一一处推翻 W3 的假设，改名现在最便宜。** 主管若认为该保持
`role_*`，这一轮说，我照改；开写之后再改就要动三个仓两门语言。
中文一律仍叫「角色」，`persona` 只是标识符。

---

## 0.5 走 (a)：真往 `Action` union 加成员。动作字符串的确切拼法

**这一条排在最前面，因为它决定两端的代码形状，选错是两个人各返工一遍。**

W4 查到的那条闸是真的，我核过：
🔬 `windows/host/src/menu.rs:622` `is_resolvable()` 取 `:` 前面那一段，
拿去比 `core_actions()`；🔬 `menu.rs:561` 的 `core_actions()` 是
**直接把 `src/input/Binding.zig` 当文本扫**出 `pub const Action = union(enum)`
的成员名（`parse_action_names`，花括号计数，不是正则）。
所以不进 union 的名字 = 菜单行静默失效，而「点了没反应」和「还没接线」
长得一模一样。

**定：走 (a)。** `src/input/Binding.zig` 的 `Action` union 里真加四个成员，
由 568 加（核心侧归我，570/571 不要自己加）。**不走 (b)**：新导出一条
FFI 会绕开 `assert_actions_exist`，等于把这道已经存在的闸关掉，
而它正是为这类错设的。

**动作字符串，只有这四条是对的**，群里那两个猜法（`poltergeist_set_role:<key>`
和 `poltergeist_role:archer`）**都作废**：

```
poltergeist_persona_set:<key>      // <key> 是 personas.json 里的 key，如 archer
poltergeist_persona_clear          // 无参数
poltergeist_persona_skill:on,<id>     // 或 :off,<id>   ← id 不是名字，见下
poltergeist_persona_mcp:on,<id>       // 或 :off,<id>
```

union 成员名（`:` 前那一段，闸比的就是它）：
`poltergeist_persona_set`、`poltergeist_persona_clear`、
`poltergeist_persona_skill`、`poltergeist_persona_mcp`。

⚠️ **顺带钉死 key 的字符集，它不是随便定的。**
🔬 `menu.rs:1515` 的 `action_strings_have_a_binding_shape` 要求整条动作字符串
只含 `[a-z0-9_:,-]`。角色 key 进了动作字符串，所以 ① 里那条
`[a-z0-9-]{1,32}` 是**这道闸逼出来的**，不是审美：一个叫 `Archer` 或
`我的角色` 的 key 拼出来的是一条这道闸会红的字符串。
**加载 personas.json 时就要按这个字符集拒，并说清为什么**，
别让它一路走到菜单才炸。

（另：角色子菜单的行是按用户文件动态生成的，`assert_actions_exist` 只看
静态行，看不见它们 —— 所以上面那条「加载时就拒」是这批动态行**唯一**的
闸。571 若给动态行补一条同形状的断言，那是净赚。）

⚠️ **v2：`+` 不在那个字符集里，所以 `+`/`-` 作废，换成 `on,` / `off,`。**
W3 和 W4 各自独立核到同一行，谓词原文是
`a.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || "_:,-".contains(c))`
—— **`-` 在里面，`+` 不在**。所以原来那两条里 `:-name` 过闸、`:+name` 不过闸，
**半绿正是最像「已经接好了」的状态**。`,` 已经在集合里，语义和
「一个开关两个名字」的好处原样保住。
不选「把 `+` 加进闸」：那道闸存在的理由就是「不许发明标点」。
不选「给这一族一条具名例外」：例外会让闸对这一族永久失明，
**而这一族恰恰是能给终端扩权的那一族。**

⚠️ **v3：名字的字符集**不**钉死——那条被主管撤回了，而且撤得对。**
上一版写「skill 名和槽位名一并收成 `[a-z0-9-]`、加载时就拒」。
**这条是错的**：名字不是我们发明的标识符，是别人的。这台机器上此刻就有
`claude_ai_Claude_Docs`（大写 + 下划线）和 `kanban:task-review`（名字自带
`:`）——按那条做等于把合法的上游全拒在门外。
**key 可以约束，因为 key 是我们发明的；名字不能，因为名字是别人的。**

**v3 定案：动作字符串里放核心铸的 id，不放名字。**

```
poltergeist_persona_set:<key>        // key 照旧，字符集照旧 [a-z0-9-]{1,32}
poltergeist_persona_clear
poltergeist_persona_skill:on,<id>    // 或 :off,<id>
poltergeist_persona_mcp:on,<id>      // 或 :off,<id>
```

id 按构造就落在 `[0-9-]` ⊂ `[a-z0-9_:,-]` 里，**那道闸一个字符都不用放宽**，
名字一次都不进动作字符串。

### id 的形状：`<roster>-<index>`

```
8-3     // 第 8 版名册里，那一类（skill 或 mcp）数组的第 3 行
```

`index` 是 `ghostty_surface_persona_face` 回的 `skills[]` / `mcp[]` 数组下标；
哪一类由动作名自己说（`_skill` / `_mcp`），所以下标各数各的。

**为什么带一个版本号，而不是一个稳定的行 id。**
菜单是此刻构建的，点击是稍后发生的。裸下标做身份**会静默别名**——摘掉一项
再加回来，编号会复用，点击就落到别的东西上。带上版本号就不用维护一张
「不复用的行 id」表，而拿到的保证更强。

### ⚠️ v5：`roster` 不是 `epoch`，这是两个数

原来这里写的是 `<epoch>-<index>`，**那是错的**，而错法只在一个具体场景里
才看得出来：

- **id 挂 `epoch`** → 隔壁一个**不相干**的上游挂掉（`broken`）也会让 epoch +1，
  于是用户**此刻正在点的那个开关**被拒——**而且拒得完全正确**，理由却跟他
  做的事毫无关系。**一个既准确又无关的拒绝比一个错的更糟，因为用户没有任何
  可修的东西。**
- **健康变化不动 `epoch`** → 编辑器只在打开时读 face，**永远不知道**某个槽位
  断了；`persona_wait` 也不会醒。§4.3 要的那个区别就永远画不出来。

两条都不能选，所以是两个数：

| | 谁改它 | 干什么用 |
| --- | --- | --- |
| `epoch` | **任何**变化，含某个上游挂了 / 回来了 | `persona_wait` 醒、编辑器知道要重读 |
| `roster` | **只有这张表的构成变了**（某一行出现、消失、换位） | 铸 id，`resolveId` 拿它判 `Stale` |

**为什么「构成没变」时那个 id 仍然安全**：id 要回答的问题是「这个下标还指不
指得着那一行」，而那只取决于列表的构成。再加上**动作是绝对的不是切换的**
（`on,` / `off,` 说的是要落到哪个状态，不是「反一下」）——所以一条在
「内容变了但形状没变」的表上发出的点击，仍然落在用户指的那一行，并把它置成
用户要的那个状态。**当初选 `on,`/`off,` 是为了绕开闸的字符集，这个好处是顺带
买到的**；若做成 toggle，这里就只能把 id 挂到 epoch 上，然后吃上面第一条。

合成一个数也不是不行，但那要说清「`broken` 为什么不算构成变化」，而那句话
只有在上面那个定义下才成立——既然两个数的定义不同，就不该是同一个数。

### 过期的 id 必须**可见地**被拒

主管点名的那一条：**「id 过期了」和「点了没反应」是同形的**，所以拒绝
不能只是 `ghostty_surface_binding_action` 回一个 `false`——今天 false 在
两个 apprt 里都是「什么都不发生」。三件事一起做：

1. 核心**返回 false**（保持既有语义：这条 binding 没被处理）。
2. 核心把理由写进这个终端 face 的 `error` 字段，`error_kind` 取
   `"stale_id"`，`error` 是给用户看的一句话
   （大意「这份菜单是按第 8 版建的，现在是第 9 版，重开一次菜单」）。
3. 核心**照常发一次 mark action**，apprt 据此知道该重读 face。
   apprt 收到 false 时重读 face 并把 `error` 显示出来。

**判据只有一个判官**：核心。apprt 不许自己拿建菜单时的 epoch 和当前 epoch
比一遍再决定发不发——那就是第二个读者两套规则，和 §① 拒绝 apprt 自己读
`personas.json` 是同一条理由。

（`assert_actions_exist` 只看静态行，看不见动态行；**动态行的闸就是上面这三步**。
571 给动态行补的那条断言现在只需要检查 `:` 前的名字和 `on,`/`off,` 前缀，
不会撞上任何标点问题。）

---

## ① 角色清单从哪读、什么格式

**核心读文件，apprt 不读。** apprt 经查询函数拿（见 ③）。
570 不要照 `ProjectStore` 直接读磁盘那个套路 —— 闭集校验在核心侧
（roles.md §七），两个读者就有两套校验，而校验宽的那个说了算。

**路径**：`$XDG_CONFIG_HOME/polter/personas.json`
🔬 依据：`src/config/file_load.zig:19` 是 `.{ .subdir = "polter/config.polter" }`，
角色跟它同目录。**配置目录不是 state 目录**：state 是 Polter 写的，
config 是用户写的，而 roles.md §七 要求角色是用户定义的闭集
—— **Polter 侧一条写路径都不存在**，这就是那条硬闸的实现，不是提示词。

> ⚠️ **v2 起这一段的后半句不成立了，留着是因为它说明了当初为什么这样。**
> 用户决定总管对角色库和自己同权（roles.md §七 第 1 条的划线处），于是有了
> 一个写者：`PersonaStore.put / remove`，写完用同一个 `load` 读回。路径也不是
> 上面那个 XDG 路径：`PersonaStore.defaultPath` 在 macOS 上先用 Application
> Support，**以代码为准**。v2 新增的字段（`description` / `instructions` /
> `clis`）见 roles.md 第十一节。

**格式**：

```jsonc
{
  "version": 1,
  "personas": [
    {
      "key": "archer",                  // [a-z0-9-]{1,32}，文件内唯一
      "name": "射手（侦察 / 只读调研）",   // 显示名，任意文字
      "prompt": "archer.md",            // 可选，相对 polter/personas/
      "skills": ["reading-a-terminal"], // Polter 自己的 skill 名
      "mcp": ["argus"],                 // 槽位名，不含 polter: 前缀
      "tools": {                        // 【对 roles.md §5.1 的新增】
        "allow": ["terminal_*", "group_*", "task_*"],
        "deny":  ["notify_user"]
      },
      "hint": {                         // 只在冷宿主重启时兑现
        "disable_host_plugins": ["kanban@bestfunc-kanban-plugins"],
        "model": "sonnet"
      }
    }
  ]
}
```

对 roles.md §5.1 草案的三处改动，逐条给理由：

1. **加 `version`**。草案没有。这是用户手写的文件，将来加字段时
   `version` 是唯一能把「旧文件」和「写错了」分开的东西。
2. **`personas` 是数组不是 map**。保序：界面按文件顺序列菜单，用户能排序。
3. **新增 `tools`**。草案只声明 skill 和上游 MCP，**没有任何字段能表达
   「这个终端看不见 `task_*`」**。而 568 要实现的正是「工具面按 token 过滤
   `tools/list`」—— 没有这个字段，过滤没有输入，570/571 的编辑器也没有
   东西可编。语义写死：先 `allow`（省略 = 全部），再 `deny`（省略 = 空）。
   `*` 只许出现在结尾做前缀通配，不支持别的通配。

**五个工具永不可被 deny 掉**：`me`、`skill_read`、`group_post`、
`task_progress`、`task_list`。deny 到了就忽略，并在加载报告里说出来。
理由：一个 deny 掉 `task_progress` 的角色 = 一个交不了活的 worker，
而它长得跟「worker 死了」一模一样。
（roles.md §5.1 的「`polter` 永远隐式在内」落到实处就是这五条。）

**加载失败**：整份文件不生效，**保留上一份**，错误原文送到界面。
不做「跳过坏的那条」—— 部分加载的角色表和完整的角色表长得一样。

---

## ② 两个状态怎么存、偏离怎么表达

**都在核心进程内存里，按 `Bus.Id` 索引，随 surface 生死，一个字节都不落盘。**

🔬 `Bus.Id` 是每个 surface 现抽的随机 u64（`src/Surface.zig:645-662`，
排掉 0 和 `not_a_terminal`），**不复用**，所以按它索引不会串到别的终端上。
不落盘的理由：重启后 surface 全是新 id，落盘那份只能靠猜重挂
—— 和 `session_recall` 拒绝替用户认领终端是同一条规矩。

```zig
/// 挂在 surface 上，随它生随它灭。
pub const PersonaState = struct {
    key: ?[]const u8 = null,   // 用户选的预设；null = 从没选过
    effective: Face,           // 此刻真正暴露的东西
    epoch: u64 = 0,            // 每次 effective 变就 +1（③④ 都用它）
};

pub const Face = struct {      // 「生效集」
    tools: std.StaticBitSet(tool_count),  // 位集，按 cli/mcp.zig 那张静态表的下标
    skills: []const []const u8,
    slots: []const []const u8, // 槽位名
    prompt: ?[]const u8,
};
```

**偏离（`deviated`）是算出来的，不是记出来的**：每次读它的时候拿
`effective` 和 `key` 声明的那份 `Face` 比一次。理由：单独记一个 bool 会和
`effective` 漂移，而「射手（已改）」被误显示成「射手」正是 roles.md §5.2
要防的那件事。`key == null` 时 `deviated` 恒 false。

三个动作的语义写死：

| 动作 | 对 `key` | 对 `effective` |
| --- | --- | --- |
| 设成某角色 | := 该 key | := 该角色的声明（重置） |
| 单独开关一项 | 不变 | 只动那一项 |
| 清掉角色 | := null | := 默认全集（= 今天的行为） |

**显示规则**（roles.md §5.3）：只有 `Server.agentPresent(id)` 为真时，
tab / 菜单才显示角色标记；为假时 `key` 和 `effective` 都还在，只是不显示。
🔬 `agentPresent` 在 `src/poltergeist/Server.zig:659`，它自己的注释说了
有个窗口期：握手没完成的 agent 答 false，和裸 shell 长得一样。

---

## ③ 核心给 apprt 暴露什么（570 / 571 照这个接）

照任务 535 那次的做法：**C ABI 和 core 我一次给齐**，两端各接各的。
动作分两个方向，方向不同走的路也不同。

### 3.1 核心 → apprt：显示。扩 `ghostty_action_poltergeist_mark_s`

**认 W3 的假设**（除了改名）。不新开 action，理由：标记的生命周期、
刷新时机、按 tab 汇总的逻辑已经全在 mark 这条路上，新开一条就是第二份
「什么时候刷新」的规则去漂移。

⚠️ **v2：走指针版，不走平铺版。** W4 在目标三元组上用静态断言量过
（带负对照：把一条改成 `== 41` 会 `static assertion failed`）：平铺追加四个
字段会让 `mark` 从 16 涨到 40，**联合体从 24 涨到 40、`ghostty_action_s` 从
32 涨到 48，每一条 action 的 payload 起点都挪**。编译期断言
（`windows/host/src/ffi.rs:770`）只保护「重编一次」，保护不了**旧
`polter-host.exe` 配新 `ghostty-internal.dll`**——那两个是分开的产物、靠
`GetProcAddress` 拼起来、没有版本握手，而这个组合在真机验证里是日常。
指针版的 `mark` 正好 24，**等于联合体今天的大小，什么都不动**。

```c
typedef struct {
  const char* key;    // NULL = 用户从没选过角色
  const char* name;   // 显示名；key 为 NULL 时也是 NULL
  bool deviated;      // 选完又单独改过
  bool agent_present; // 这个终端里此刻有没有 agent 连着 Polter
  ghostty_action_poltergeist_host_class_e host_class;
} ghostty_poltergeist_persona_s;

// ghostty_action_poltergeist_mark_s 尾部只加这一个（mark 由 16 变 24）：
  const ghostty_poltergeist_persona_s* persona;
```

```c
typedef enum {
  GHOSTTY_POLTERGEIST_HOST_UNKNOWN = 0,  // 零值是「不知道」，不是「热」
  GHOSTTY_POLTERGEIST_HOST_HOT,
  GHOSTTY_POLTERGEIST_HOST_WARM,
  GHOSTTY_POLTERGEIST_HOST_COLD,
} ghostty_action_poltergeist_host_class_e;
```

**枚举的 C 底层宽度：和 `ghostty_action_poltergeist_role_e` 一样是 int 宽
（4 字节）**，因为它就是一个普通的 C `enum`，Zig 侧写 `enum(c_int)`。
W4 在 Rust 侧按固定偏移读 4 字节 `i32`（`ffi.rs:421` 的 `role` 就是这么读的），
这句是给他的依据，不是让他猜。
（名字带 `action_`，照 W3 的 F 条与既有的 `ghostty_action_poltergeist_role_e`
`..._mark_s` 对齐。）

## 3.1.1 只有一个 NULL，不是两个

主管点名要把这件事说死：指针版一出现就有两个 NULL 候选
（`persona == NULL` 和 `persona->key == NULL`），而**两个几乎同义的 NULL**
正是这一轮已经抓到三次的形状。

**定：`persona` 永不为 NULL。** 核心总有话说——最少也是「没选过、没有
agent 连着」。所以：

| 状态 | 怎么表达 | 界面显示（W3 措辞表） |
| --- | --- | --- |
| 用户从没选过角色 | `key == NULL` | 「不设角色」那一项打勾 |
| 选了角色，但此刻没有 agent 连着 | `key != NULL && !agent_present` | 第 5 条「这个终端里没有 agent 连着，角色存下了，但还没有人穿上」 |
| 选了角色，有 agent，没单独改过 | `key != NULL && agent_present && !deviated` | 「角色：射手」 |
| 选了角色，有 agent，改过 | `… && deviated` | 「射手（已改）」 |

`persona == NULL` **是核心的 bug，不是一种语义**。apprt 仍然判一次
（Swift 的 optional 指针天然落到 `guard let`），判到了就按「从没选过」画并
记一条日志；但没有任何核心路径会送出它。

### 为什么 `agent_present` 必须单独送（W3 的 A，成立）

原来那句「`persona_key` 为 NULL 表示没有角色**或**此刻没有 agent 连着」
把两个状态并成了一个，而 apprt 只能在「不设角色」上打勾
——**等于告诉用户他的选择没了，他会再选一次**。
roles.md §5.3 要的是「不显示成**是**射手」，那是一条显示规则，归 apprt 兑现；
核心用「不给数据」去兑现它，就把「未设」和「设了但没人连」做成了同形。

顺带这也是 `agentPresent` 那个窗口期（握手没完成的 agent 答 false，
和裸 shell 同形）**更要单独送这一位**的理由：窗口期里界面显示的是
「还没人穿上」而不是「你没选过」，**前者会自己好，后者会骗用户重选**。

### 生命周期

`key` / `name` 两个指针**仅在这次 action 回调期间有效**——和今天的
`prefix` 一样（`Ghostty.App.setPoltergeistMark` 里当场 `String(cString:)`）。
写出来是因为 §3.3 给 `ghostty_app_personas` 写了所有权而这里一个字都没写，
**一个照着契约写的移植者把指针存进结构体不会有任何东西报错，到下一帧才是垃圾。**

⚠️ **这个改动落地的那个提交，两端必须在同一个提交里。** W3 确认 Swift 侧
接得住（头文件经 GhosttyKit 导入，对不上就编不过），**真正会踩的是构建顺序**：
拿旧的 `GhosttyKit.xcframework` 编新的 Swift，那时候两边都编得过，
读到的才是垃圾。W4 重建 worktree 的基线取这个提交。

`UNKNOWN` 排在 0 位是照 `PoltergeistLayout.Result` 里
`unsupported` 排 0 的那条理由：**零值必须是诚实的那个答案**。
界面上 `UNKNOWN` 的措辞要和 `COLD` 不同，也不许长得像 `HOT`
（roles.md §六：「已经换好了」和「等下次启动」必须长得不一样；
这里多一格「不知道」，它也得自己长一个样）。

**核心侧填在哪，以及一个已经踩过的坑。**
🔬 `src/Surface.zig:3698 updatePoltergeistTabMark()` 是唯一的发送点，它把
所有字段装进 `PoltergeistTabState` 整体比一次（`std.meta.eql`，
`Surface.zig:3784`），不等就发。那段注释自己写着为什么是整体比：
*「`held` 不在那三个 `and` 里，所以按住一个没人看的终端什么都没发出去」*
—— **从今往后加进这个 struct 的字段是因为它在那儿才被比到的**，这正是
persona 三个字段该加进去的地方。

⚠️ 但 `persona_key` 要以**定长数组存进 `PoltergeistTabState`**
（`[32]u8` + `len`，正好是 ① 里 key 的上限），不要存 slice：
`std.meta.eql` 比 slice 比的是指针，配置重载后同一个 key 换了地址就会被判成
「变了」（这个方向无害，只是多发一次），但把值拷进定长数组是**按内容比**，
没有这一类问题要想。

⚠️ **这是破坏性 ABI 改动**，Swift（`macos/Sources/Ghostty/Ghostty.App.swift`）
和 Rust（`windows/host/src/ffi.rs`）两侧都要同步；不同步的那侧读到的是垃圾
指针，不是空值。🔬 两处都已确认有 `ghostty_action_poltergeist_mark_s` 的
对应定义。

**`host_class` 从哪来：定了，用 MCP `initialize` 的 `clientInfo.name`。**
原先这是本契约唯一的留白，现在有实测。

🔬 **我自己跑的探针**（`scratchpad/probe_ci.py`，记下收到的每一行；
判据照 roles.md 附录 A：日志里要有 `tools/call` 才算这一轮有效，
否则是审批拦在外面的无效阴性）：

| 宿主 | `clientInfo.name` 原文 | 这一轮有效吗 |
| --- | --- | --- |
| claude-code 2.1.274 | `claude-code` | 🔬 有效（`tools/call` 到了服务器） |
| codex 0.142.5 | `codex-mcp-client` | 🔬 有效（同上，答 `probe_alpha returned: ok`） |
| gemini | `gemini-cli-mcp-client` | 🔬 主管的探针日志 |
| qwen-code | `qwen-cli-mcp-client-probe` | 🔬 主管的探针日志 |
| opencode / kimi / deepseek | ❓ 没量到 | — |

⚠️ **匹配一律写前缀匹配，不许写等值。** qwen 那条尾巴上的 `-probe`
**正是探针服务器在配置里的名字**，所以它很可能是「固定前缀 + 服务器名」。
我这两轮是这条假说的对照：我的服务器也叫 `probe`，而 claude-code 和 codex
回的字符串里**都没有** `probe` —— 所以「带服务器名」是 qwen 独有的，
不是通例，而前缀匹配对四家都成立。

⚠️ **没量到的三家一律 `UNKNOWN`，不许按名字猜。** 「opencode 大概会叫
opencode-mcp-client」这种猜法和读数长得一样，而它错了的时候界面会把一个
冷宿主画成热的。

落点：🔬 `src/cli/mcp.zig:907` 那段今天把 `initialize` 的 params 整个丢掉、
回一个静态字面量；改成把 `clientInfo.name` 读出来送给 host，核心侧查一张
前缀表。**agent 还没连上的那段窗口期永远是 `UNKNOWN`**，所以 570/571 的
`UNKNOWN` 分支本来就必须存在，不是为这几家临时加的。

### 3.2 apprt → 核心：用户点菜单。走 keybinding action，不走 action 联合体

理由：这是用户在自己那个 tab 上做的事，`src/input/Binding.zig` 里
`poltergeist_toggle_*` 一族已经铺好了这条路，apprt 只要
🔬 `ghostty_surface_binding_action()`（`include/ghostty.h:1430`）
喂一个字符串，不用碰那个被 comptime 断言钉死在三字的联合体。

四个动作名，全部 `.surface` scope（`Binding.zig:1542` 那张表里追加）：

| 动作名 | 干什么 |
| --- | --- |
| `poltergeist_persona_set:<key>` | 设成某角色（`key` 不存在 → 返回 false） |
| `poltergeist_persona_clear` | 清掉，回默认全集 |
| `poltergeist_persona_skill:on,<id>` / `:off,<id>` | 单开 / 单关一个 skill（id = `<epoch>-<index>`，见 0.5） |
| `poltergeist_persona_mcp:on,<id>` / `:off,<id>` | 单开 / 单关一个槽位（同上） |

后两个就是 W3 问的第 4 条 ——「产生『已改』的那条路」。
`+` / `-` 写在名字前面而不是做成两个动作名：一个开关两个名字，
将来加第三种状态时是两处要改。

⚠️ **这四个动作不许进命令面板，也不给默认键位。**
🔬 依据是 `Binding.zig:748` 上 `poltergeist_toggle_authorise` 自己的注释：
*「agent 能用 `terminal_key` 打开别的终端的命令面板并往里打字，所以一个
面板条目就是 agent 给自己授权的路子」*。换装能给终端扩权
（roles.md §七 1），跟它同类。

`shielded` 的终端拒绝一切换装，对总管也一样（roles.md §七 2）：
核心侧照 `rpc.zig` 现有那条拒；界面上那个 tab 的菜单项置灰。

### 3.3 列出角色给菜单用：查询函数，不走 action 队列

action 是单向的，菜单要同步拿到列表。

```c
typedef struct { const char* key; const char* name; } ghostty_persona_s;
// 返回真实总数。cap 不够就写满 cap 条并返回真实总数，调用方据此重试。
uintptr_t ghostty_app_personas(ghostty_app_t, ghostty_persona_s* buf, uintptr_t cap);
```

「写得下多少写多少并把真实数量说出来」是抄 `PoltergeistLayout.Out` 那条
（`src/apprt/action.zig:2333`：*an apprt that needs more writes what fits and
says so rather than truncating silently*）。字符串归核心所有，在下一次
`ghostty_app_personas` 或配置重载之前有效 —— apprt 要留就自己拷。

**两个调用约定（W4 要的补白，两个查询函数都适用）：**

- **`(app, NULL, 0)` 合法**，专门用来先问真实数量再分配：`cap == 0` 时不碰
  `buf`，只返回总数。`buf == NULL` 而 `cap > 0` 是调用方的错，核心当成
  `cap == 0` 处理（不写、只回数），不崩。
- **`ghostty_app_persona_hosts` / `ghostty_surface_persona_face` 返回的是
  JSON 的字节数，不含结尾 NUL**；写得下的时候缓冲区**额外补一个 NUL**
  （所以调用方给 `cap` 时要留出那一个字节：`written + 1 <= cap` 才补）。
  按长度解析和按 NUL 解析**两种都成立**，这是有意的：Rust 侧按长度切片，
  Swift 侧 `String(cString:)` 也能用。`cap` 不够时**不补 NUL**，返回值仍是
  真实字节数，调用方据此重试。

### 3.5 编辑器主体要读的「生效集」：surface 作用域的一条查询

W3 的 B 条成立且是挡路的：mark 只给 key / name / deviated / host_class，
`ghostty_app_personas` 只给 key + name，**没有一条能回答「这个终端此刻
交出去的是哪些 skill、哪些槽位、每个是开是关、是手动加的还是手动关的」**
——而那正是编辑器中间那块要画的东西。这和 §① 给 `tools` 字段的理由是
同一句话：没有它，570/571 能让用户点，但点完画不出结果。

**surface 作用域，不是 app 作用域**：生效集是按终端的，编辑器是为某个 tab 开的。

```c
uintptr_t ghostty_surface_persona_face(ghostty_surface_t, char* buf, uintptr_t cap);
```

```jsonc
{ "key": "archer", "name": "射手（侦察 / 只读调研）",
  "deviated": true, "epoch": 8, "agent_present": true,
  "host_class": "unknown",
  "prompt": "archer.md",
  "hint": { "disable_host_plugins": ["…"], "model": "sonnet" },
  "roster": 8,
  "skills": [ {"id":"8-0","name":"reading-a-terminal","enabled":true,"in_persona":true} ],
  "mcp":    [ {"id":"8-0","name":"argus","enabled":false,"in_persona":true,
               "slot":"broken"} ],
  "error": null, "error_kind": null }
```

- **`id` 就是动作字符串里那个 id**（`<epoch>-<index>`，0.5）。apprt 原样搬进
  动作字符串，不要自己拼——自己拼就是第二个地方知道这个格式。
- **`in_persona` 由核心算**，不让 apprt 拿 `ghostty_app_personas` 的清单在
  Swift/Rust 里再算一遍。理由同 §①：两个读者两套规则。
  `in_persona && !enabled` = 措辞表 17「手动关掉的」；
  `!in_persona && enabled` = 措辞表 16「手动加上的」。**两个方向不合并**，
  因为用户要撤销的动作不一样。
- **`tools` 这一维这一版不放进来**：主管定的范围是「选角色 + 单独开关某个
  skill / 某个 MCP」，编辑器不编 `tools`。核心内部当然有它（§② 的 `Face.tools`），
  只是不从这条缝里出去。
- ⚠️ **`slot` 是 v5 新增的，`enabled` 一个字段不够**（`transparent` /
  `granted` / `withheld` / `broken`，见 §4.3）。原来的 face 里
  「用户手动关掉了 argus」和「角色给了 argus 但那个服务器起不来」
  **逐字节相同**（都是 `enabled:false`），于是编辑器只能画成同一行——
  **正是 §4.3 说会把用户引去改角色的那个形状**，而该做的是去看那个服务器。
- **`epoch` 和 `roster` 两个都要给**：前者是「有没有变过」，后者是 id 的
  版本。apprt 原样搬 `id`，两个数都不用自己拼。
- **`error` / `error_kind` 是 §① 那句「加载失败把错误原文送到界面」的通道**
  （W3 的 E）。取值：`"parse"`（personas.json 没加载成功，整份没生效、用的是
  上一份）、`"stale_id"`（0.5 那条过期 id）、`null`（没有错）。
  不接这条的话，**「文件写错了」和「还没定义任何角色」在界面上完全同形**，
  而 W3 菜单里已经有「还没有定义任何角色」这一条，它会替一个语法错误背锅。

### 3.4 宿主只读清单经哪条路到界面（W3 第 5 条）

**数据由 569 在核心侧算**（已定），**经一个同样形状的查询函数到界面**：

```c
// 一段 JSON，写进调用方给的缓冲区；返回真实字节数，语义同上。
uintptr_t ghostty_app_persona_hosts(ghostty_app_t, char* buf, uintptr_t cap);
```

为什么是 JSON 字符串而不是 struct 数组：条目数量和形状都由宿主决定
（argus 一家就 16 个 skill），而 `PoltergeistLayout` 已经立过这条规矩
—— 🔬 `src/apprt/action.zig:2288`：*a string is a conduit; a struct would be
a claim*。这份清单是别人家的东西，核心只搬不懂。

形状（569 定细节，这里只钉外壳）：

```jsonc
{ "stale": false, "hosts": [ { "key": "claude-code",
    "plugins": [...], "skills": [...], "mcp": [...] } ] }
```

⚠️ **扫宿主目录是 I/O，不许在 UI 线程上同步做。** 核心持缓存，
这个调用是一次 memcpy；缓存还没建起来时回 `"stale": true` 和空列表，
界面照 roles.md §四 的措辞显示「还没读到」，**不要显示成「什么都没装」**。

---

## ④ 槽位进程 ↔ Polter 的线协议（569 用）

槽位进程连同一个 socket、同一条握手：
🔬 `{"method":"auth","params":{"token":"…"}}`（`Server.zig:766`），
token 从 `GHOSTTY_POLTER_TOKEN` 来，所以它天然知道自己在哪个终端。

**两个方法。**

```jsonc
// 问：这个终端的角色要不要我
→ {"method":"persona_slot","params":{"slot":"argus"}}
← {"ok":true,"wanted":true,"epoch":7}

// 等：变了叫我。长轮询。
→ {"method":"persona_wait","params":{"slot":"argus","epoch":7}}
← {"ok":true,"wanted":false,"epoch":8}          // 变了
← {"ok":true,"timeout":true,"epoch":7}          // 超时，什么都没变
```

`epoch` 是这个终端 `effective` 的版本号，每次变 +1。传进来的 `epoch`
已经落后 → 立刻回，**不挂住** —— 这是「我睡着的时候已经变过了」的防漏。

**为什么是长轮询而不是服务端主动推。**
🔬 `Server.zig` 里每条连接的 `writer` 是**连接线程栈上的局部变量**
（`connectionMain` 内 `var writer = stream.writer(...)`，第 4 行往下），
别的线程根本拿不到它；要推就得把 writer 指针和一把锁塞进 `Slot`，
再和 shutdown 那段「关句柄必须在锁内」的既有约束对齐。
而「app 线程稍后再答」这套机器是**现成的**：`Pending` + `Pending.complete`
（`Server.zig:98-145`），`serveOne` 里就是 `pending.done.waitUncancelable`
挂着等。长轮询一行新代码都不用加在写路径上。

### 4.1 连接预算：先有式子再有数

一条长轮询占住一条连接。先把倍数写清楚，**不要先拍一个默认值**。

**一个终端要几条连接：**

| 谁 | 几条 | 为什么 |
| --- | --- | --- |
| `+mcp` 的 serve 连接 | 1 | 今天就有，`Host.call` 是锁步请求/应答 |
| `+mcp` 的 `persona_wait` 连接 | 1 | 长轮询挂住时 serve 那条还要能干活，**所以必须是第二条** |
| 每个槽位进程 | 1 | `persona_slot` 问一次，然后同一条上挂 `persona_wait`；它没有别的要问 |

⚠️ **不被要的槽位照样占一条。** 槽位进程是宿主配置里的 MCP 服务器条目，
agent CLI 一起就把它们全起了；「这个角色不要 argus」是槽位**连上来问完之后**
才知道的答案，不是它不连的理由。所以式子里的 M 是**注册了几个槽位**，
不是「这个角色用几个」。

```
最坏情况 = K × (2 + M)
  K = 同时开着 agent 的终端数
  M = 注册给 Polter 的上游槽位数（全局的，不是每角色的）
```

两个已知的数（🔬 都在代码里）：

- 默认 `default_max_connections = 64`（`Server.zig:55`），配置项
  `poltergeist-max-agents: u16 = 64`（`Config.zig:1320`）。
- **硬上限 `limit_max_connections = 256`（`Server.zig:57`）**，这条是天花板，
  不是默认值。所以真正的约束是 **K × (2 + M) ≤ 256**：M=4 时 K 最多 42 个终端，
  M=10 时 K 最多 21 个。

抬这个数的代价：槽位数组是预分配的（`alloc(Slot, slot_count)`），每条连接
一个线程。RSS 上不贵（线程栈是惰性提交的），虚拟地址空间上不是白拿。
**v2：默认值从 M 推出来，不拍常数。** 主管定的验收判据不是一个数，是一句
行为：**装上角色功能之后，同时连得上的终端数不得少于今天。** 今天一个终端
占 1 条，`64 / 1 = 64`；实际用得到的并发远小于此，取**今天保证的 32 个终端**
（留一半余量）做地板。于是：

```
poltergeist-max-agents 的默认值 = clamp(64, 32 × (2 + M), 256)
                                  在启动与配置重载时按当时的 M 重算
```

`M` 是注册了几个槽位，**这是 Polter 自己知道的事**（槽位是它注册的），
所以它属于「能算出来的就不要去猜一个」。配置项的**含义不变**——它今天数的
就是连接数，v2 只是把它的**默认值**从常数换成一个按 M 算的式子；用户写死一个
数仍然照用户的。

⚠️ **v4：M 可能是不完整的，而不完整的 M 只许把上限往大了推。**
M 来自扫宿主的 MCP 配置，而 W2 的 `inventory.zig` 是**四态**的：有 agent 的
配置是 `unknown_location` 或 `failed` 时，**我们数到的 M 是一个下界，不是
真值**。于是：

- `complete == false` 时，**只许用 M 把上限往大了推，绝不许用它把上限往小了定**。
  少算一个上游 → 少开的连接 → 用户撞 `AgentsFull`；而那个失败形状（477）
  是「此后每个新终端都连不上」，不是「角色少了一个」。
- **clamp 的下界 64 保留**，任何情况下不低于今天。
- 启动时那句话要把这件事带上：**「还有 agent 的配置没读到，这个数可能偏小」**。
  一个算出来的数**看起来和一个数全了的数一模一样**，所以不完整必须说出口。

⚠️ **两条规则在 M > 6 时会撞上，现在就说出来。** `32 × (2 + M) ≤ 256` 要求
`M ≤ 6`。M 到 7 就顶到天花板，届时要么抬 `limit_max_connections`（主管定了
**在量出每条连接的真实代价之前谁都不许动**——「RSS 不贵」是个形容词，
抬天花板要的是数），要么并发终端数降到 `256/(2+M)` 以下（**违反那条验收判据**）。
**这不是我今天能两边都满足的**，所以：M ≥ 7 时 Polter 要在启动时把这件事
说给用户听（「你交给 Polter 的上游有 7 个，同时能用的终端从 32 降到 28」），
而不是等 `AgentsFull` 打过来。

那个 `2` 里唯一能省掉的是第二条：把 `persona_wait` 折回 serve 连接，
代价是服务端要能主动往连接里写（就是上面那段 writer 在连接线程栈上的问题）。
**今天不做，但记下来**：如果 K×(2+M) 顶到天花板，这是第一个该动的地方。

⚠️ 🔬 `full_refusal_code = "AgentsFull"` 那句
*「every agent slot on this socket is in use」***必须改措辞**。
它现在会把用户引向「去关几个 agent」这个**错误动作** —— 顶满的很可能是槽位
进程，关 agent 才是对的操作时它也没说清是哪一类。措辞要同时说出
「几条是 agent、几条是槽位」和「这个数在哪个配置项里」。

### 4.2 ⚠️ 透传只在「从未拿到过答案」时发生（W2 的 B，安全方向，逐字收）

roles.md §3.3 原来那句「拿不到 socket 和 token 时必须原样透传」
**最自然的实现是「连不上就透传」，而那是一个漏洞**：一个明确写了不给 argus
的终端，只要 Polter 抖一下断线，槽位就把 argus 的全部工具交出去，
**而且没有任何东西会报错**。主管已按这条改了 roles.md §3.3，契约逐字收：

- **启动时从未拿到过答案** → **透传**。这时我们没有任何依据去拿走用户的工具。
- **已经拿到过答案之后连接断了** → **保持当前状态不变**，重连重试，
  **绝不升级成透传**。

这条属于「写反了也跑得通、只是把闭集漏了」那一类，所以它自己占一节，
不当某段里的一个从句。

⚠️ **我要把「从未拿到过答案」这条线再画细一格，这是对主管原话的收紧，
不是改写，请裁决。** 「够不到 Polter」有两种：

| 情形 | 我的判断 | 理由 |
| --- | --- | --- |
| 环境里**根本没有** `GHOSTTY_POLTER_SOCKET`/`TOKEN` | **透传** | 用户在 Ghostty 之外跑的 `claude`，roles.md §3.3 的原意，必须透传 |
| 环境变量在，但连不上 / 握手失败 / 被 `AgentsFull` 拒 | **`broken`，不透传** | 我们**确实够到了 Polter 并被明确拒绝**。这是在 Polter 之内，透传就是绕过闭集 |

第二行按主管原话的字面读法会落到「从未拿到过答案 → 透传」，
而那恰恰是 W2 那条漏洞的一个变体（把 Polter 打满就能拿到全部上游）。
**若主管认为字面那条更重要，说一声，我改回去并把这段留作记录。**

### 4.3 四态，不是三态（W2 的 C，收下）

roles.md 第十节待定②「不要让『上游挂了』和『这个角色没有它』长得一样」
到此有答案：

| 状态 | 什么时候 | 客户端看到 |
| --- | --- | --- |
| `transparent` | 从没拿到过答案（见 4.2 第一行） | 上游全部工具，**逐字节** |
| `granted` | `wanted = true` | 上游的工具，**不改名** |
| `withheld` | `wanted = false` | `{"tools":[]}`，**上游进程根本不起** |
| `broken` | `wanted = true` 但上游起不来/中途死了 | **一个**工具 `polter_slot_unavailable` |

`polter_slot_unavailable` 的描述里必须写清**「这不是你的角色没有给你它——
角色里有它，是那个服务器本身没跑起来」**。进入 `broken` 有两个点：拉起失败，
和读到上游 stdout EOF（跑着跑着死了）；后者要**发一条 `list_changed`**。
@570/571：**这个区别编辑器里也要有**，否则用户看到「角色给了 argus，但 agent
说没有」会去改角色，而该做的是去看那个服务器。

### 4.4 `persona_wait` 醒来 ≠ 你的 wanted 变了（W2 的 E，逐字收）

**`persona_wait` 返回时 `wanted` 可能与传入时相同，调用方必须比较后再决定
要不要发 `notifications/tools/list_changed`。**

`epoch` 是**整个终端 effective 的版本号**（§②），用户只改了一个 skill，
epoch 就 +1，于是**这个终端上每个槽位的 wait 都会醒，而它们的 wanted 没变**。
读成「醒来 = 变了」而无条件发通知，用户在编辑器里点一下，所有 agent 的所有
槽位就集体重拉一次 `tools/list`。**「醒来就发」和「比较后发」在代码里长得
一样，在真机上差一个数量级。**

### 4.4.1 ⚠️ 实现状态（写在这里，因为「写了」和「做了」在契约里长得一样）

截至 `41ba1d068` 之后这一段：

| 这一条 | 状态 |
| --- | --- |
| `persona_slot` 问一次拿 `{wanted, epoch}` | ✅ 做了 |
| `persona_wait` 的线协议与回包形状 | ✅ 做了 |
| `persona_wait` **真的挂起**，等 epoch 变了再答 | ✅ 做了（`App.parkPersonaWait`） |
| 换装唤醒（选角色 → 挂起的 wait 当场被答） | ✅ 做了（`App.setSurfacePersona` 绑三件事） |
| `+mcp` 醒来发 `notifications/tools/list_changed` | ✅ 做了（第二条连接 + stdout 互斥 + **比对后才发**） |
| 30 秒超时由**一个真的定时器**驱动 | ❌ **没做，而且短期不打算做** |
| 断线重试的退避节奏（0.5s→…→15s、`AgentsFull` 60s） | ❌ **没做**，归槽位进程那侧 |
| `poltergeist_persona_skill` / `_mcp` 两个动作 | ❌ **没做**，见下 |

⚠️ **`_skill` / `_mcp` 为什么宁可不做**：它们要把 id 拿去对菜单构建时那份 face
解析，**其中包括 id 过期时那个必须可见的拒绝**（0.5 节那三步），而 `error_kind`
那条回话通道还没建。**做一半比不做更糟**：一个静默作用到错误行上的开关，
正是那个铸出来的 id 存在的全部意义。今天它们返回 `false`，含义唯一——没接线。

### 4.4.3 🔴 欠账：调用那一侧没有闸，`tools/list` 的过滤是唯一的门

**核过的事实**（`grep`，不是推断）：`toolVisible` 在全仓的非测试调用点**只有
一处**——`src/App.zig` 里 `poltergeistPersonaFace` 构造可见清单的那个循环。
`rpc.zig` 的 `authorize` 和 `dispatch` 里 `persona` / `toolVisible` 出现 **0 次**。

**所以：一个工具只要留在 `tools/list` 里，就调得到。** 角色对工具的约束今天
**只发生在列清单那一刻**，不发生在调用那一刻。

三条后果，逐条写下来：

1. **`+mcp` 里「失败打开」的那句理由曾经是错的。** 原注释写着「真正拦住调用的
   闸在 host 侧，所以失败关闭买不到安全」——**那道闸不存在**。方向今天仍然可以
   成立（一次没解析成功的回包不该把终端的工具拿走），但它是**在两种失败之间做
   选择**，不是「没有东西处在风险里」。注释已经改成实话。
   ⚠️ 这条的传播值得记：**一段声称有兜底而其实没有的注释，比没有注释更糟**——
   它让读的人停止去找，而且它被照抄进了一条提交信息里当论证用。
2. **roles.md §8「陈旧信念」那一节的机制今天不成立。** 那一节说的是：能力立刻被
   收走，但 agent 的记忆不会，所以它「会先去调一次，撞一次墙，才知道自己变了」
   ——**而今天它撞不到墙**。一个刚被撤掉某个工具的 agent 去调它，会**调用成功**。
   §8 给的补救（回话里挂一句「你的工具面刚被改成〈X〉」）是为了**省掉**那次撞墙；
   今天要做的事不一样：**先让那面墙存在**。
3. **这不是热换装本身的缺陷。** 热的宿主收到 `list_changed` 会重新拉清单，于是很
   快就不再持有那个工具名。缺口是那之前的窗口，以及任何**不重新拉清单**的宿主
   （冷的那几家），它们会一直拿着旧清单调得通。

**要做的是什么**：在 `rpc.dispatch` 里，按调用者自己的 face 判一次
`toolVisible(method)`，不通过就拒，拒绝的措辞要说清是角色不给而不是没这个工具
（`NotInPersona` 之类），否则它和 `UnknownMethod` 又是一对同形的东西。
**没做，本轮不做**——用户的要求是先把演示通路跑通。

### 4.4.2 ⚠️ 客户端那条 250ms 地板是永久的，不随服务端挂起完成而移除

W2 指出并实现，两侧都照办（槽位进程和 `+mcp` 的唤醒线程）。

`dispatch` 里那条「没人挂住我」的分支会**立刻**返回，注释原来写的是调用方
「退化成轮询」——**但没有间隔的轮询不是轮询，是满速忙等**，而这种进程是
**每终端 × 每槽位**一个，代价被用户开着的东西数乘一遍。

所以调用方一侧钉一条下限：**一次 `persona_wait` 往返若在 250ms 内以 `timeout`
形式返回，补睡到 250ms 再发下一次。**

**它不是「等服务端挂起做完就该删」的临时措施。** 它防的是**「服务端没挂住」
这件事本身**，而那不是一个会被修好的状态——测试宿主、嵌入方、任何没接这条
的实现都会触发它。真正的变更不走这条路（它唤醒的是挂起的那个请求），
**所以换装延迟的代价是零**。

两条要说清楚的：

1. **没被挂起的 `persona_wait` 会立刻回答。** `dispatch` 里那条分支是这么写的，
   并且注释说明了它是什么：一个没有被拦下的 wait **退化成轮询**——答案仍然正确，
   只是不阻塞。调用方不会坏，只会变吵。这是有意选的降级方向：一个立刻返回正确
   答案的 wait，和一个挂住不返回的 wait，前者的失败模式是浪费，后者是死锁。
2. **超时是「有请求进来时顺带扫一遍到期的」，不是定时器。** 所以在一台完全空闲
   的机器上，一个挂起的 wait 可能超过 30 秒还没被答。对演示通路没有影响——
   **唤醒它的是变更本身，不是超时**——但它不是本节写的那个超时，
   **不许当它做了**。

### 4.5 `persona_wait` 的超时与重试节奏（W2 的 A，我补）

**超时 30 秒**，服务端答 `{"ok":true,"timeout":true,"epoch":<当前>}`，
客户端**立刻重发**。

⚠️ **超时到点是回一行，不是关连接**（W2 要的确认，确认）。
关连接会让槽位走进 4.5 的重试退避（0.5s→…→15s），而那条退避是为**故障**
写的；把一次正常的超时喂进去，就是把「一切正常」和「Polter 出事了」做成
同一条路径。而且 `transparent` 的判定挂在「从未拿到过答案」上（4.2），
一条被服务端主动关掉的连接**在客户端看来和握手失败是同形的**。
所以：到点写一行，连接留着，客户端立刻重发。选 30 的理由，两头夹：

- 上限：这条连接没有心跳，**半开连接**（机器睡过去、Polter 被杀、网络栈回收）
  只能靠一次往返发现。30 秒是「换装延迟最坏 30 秒」和「发现死连接最坏 30 秒」
  的同一个数。合盖那条已经吃过一次亏（面板 565：`Sampler` 认不出「中间机器
  睡过去了」），所以这里不依赖墙钟差值，只依赖「一次往返回来了没有」。
- 下限：满配时 `K×(2+M)` 条连接每 30 秒各重发一次；K=32、M=4 时是
  192 条 / 30s ≈ **6.4 次请求/秒**，每次是一行 JSON。再短就是拿服务端
  的空转换一点点延迟。

**断线之后的重试节奏**（4.2 管方向，这里管节奏）：

```
0.5s → 1s → 2s → 4s → 8s → 15s → 15s → …   （上限 15s，永不放弃）
```

- **状态在整个重试期间保持不变**，一次都不升级成透传（4.2）。
- **`AgentsFull` 单独一条**：上限抬到 **60s**。快速重试会让「槽位耗尽」
  这件事本身更严重——477 记的失败形状正是「此后每个新终端都连不上」，
  而一堆 0.5 秒重连的槽位进程就是那个「此后」。
- 重连成功后**先发一次 `persona_slot` 拿当前 `wanted` 和 `epoch`**，
  再按 4.4 比较，**变了才发 `list_changed`**。不许用断线前那个 epoch 直接挂
  `persona_wait`：中间可能变过不止一次。

**Polter 之外**（roles.md §3.3）：拿不到 socket/token 的槽位进程
**原样透传上游全部工具**，不许静默变空。这条是必须的，不是可选的。

### 4.6 ⚠️ `cli/args.zig` 会静默吞掉以 `+` 开头的参数（W2 撞到的，我也用得上）

🔬 `ArgsIterator.next()` 靠跳过 `+action` 来认子命令，**任何以 `+` 开头的
参数都会被它静默吃掉**。槽位进程承诺原样搬运上游的 argv，用它解析就会让上游
**少一个参数启动**——**而那长得像「上游自己坏了」**。W2 改用
`std.process.Args.Iterator` 自己扫。`+mcp` 这边今天只有 `--socket` / `--token`
两个具名参数，暂时碰不到，但同一条路上的任何「搬运别人的 argv」都要绕开它。

---

## ⑤ `+mcp` 这一侧（568 自己写，贴出来是因为 ④ 和它同一个协议）

1. `tools/list` 不再纯本地。先问 host 一次
   `{"method":"persona_face"}` → `{"ok":true,"tools":["me","terminal_list",…],"epoch":N}`，
   拿名字去过滤本地那张静态表。**表留在本地**：描述文字和 schema 是几十 KB，
   不该每次过 socket；host 只给名字。
2. 🔬 `src/cli/mcp.zig:106` 那行 `"capabilities":{"tools":{}}`
   改成 `{"tools":{"listChanged":true}}`。不改的话守规矩的客户端根本不订阅
   这条通知 —— 而「客户端没听」和「我们没发」在服务端日志上长得一样。
3. 起一条线程跑 `persona_wait`（同 token 的第二条连接），醒来往 stdout 写
   `{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}`。
   ⚠️ **stdout 要加锁**：🔬 `src/cli/mcp.zig:864` 那个 writer 现在是
   serve 循环单线程独占的。
4. roles.md §八 的陈旧信念：换装之后这个终端第一次调 Polter 任何工具，
   回话里挂一句「你的工具面刚被改成〈X〉，此前清单作废」，挂在 `report.zig`
   那条现成的应答通道上。

---

## ⑥ 判据：先证明它会红

写测试之前先让它红，红在哪一条都记下来贴群：

| 故意打坏 | 必须红的那条 |
| --- | --- |
| 过滤函数改成恒真（谁都可见） | 「deny 掉的工具不在 `tools/list` 里」 |
| `epoch` 不递增 | `persona_wait` 的唤醒测试 |
| capabilities 改回 `{"tools":{}}` | initialize 那条字面量断言 |
| 五个保底工具的例外拿掉 | 「deny `task_progress` 无效」 |

**地板**：上面四格里任何一格不红，说明那条测试从来没测到东西。

