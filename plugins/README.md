# 插件

Polter 的出口。设计见 [docs/poltergeist/plugins.md](../docs/poltergeist/plugins.md)
（宿主那一层）和 [docs/poltergeist/storage.md](../docs/poltergeist/storage.md)
（常驻的存档插件多出来的东西）。

一个插件是一个目录：

```text
plugins/
  webhook/
    plugin.json     元数据：key、kind、参数 schema、要哪些权限
    send.sh         可执行；Polter 把事件作为一行 JSON 写进它的 stdin
  chat-archive/
    plugin.json
    archive.py      可执行；常驻，stdin 是一条行分隔的 JSON 流
    README.md       .md 不进安装，只留在仓库里
  claude-code/
    plugin.json
    provision.sh    可执行；启动时跑一次
    settings.json   随目录一起装的缺省设置；用户配置目录里那份压过它
```

**清单是 `plugin.json`，不是 YAML。** Zig 标准库里没有 YAML，而手写一个 YAML 子集
解析器要处理缩进、多行字符串、隐式类型转换 —— 每一样都是能悄悄解析错的地方，而清单
解析错的后果是插件的行为与它声称的不一致。

## 两处查找，近的赢

1. 用户自己的：`$XDG_CONFIG_HOME/polter/plugins/`
2. 随 Polter 安装的：`<resources>/ghostty/polter/plugins/`

按目录名去重，**先看到的赢**，所以用户可以放一个同名目录来替换我们发的插件，
不用动 app bundle。（`docs/poltergeist/plugins.md` 还提到第三处"配置里显式指定的
目录"，那一处目前没有实现。）

仓库里的 `plugins/` 会被整个装进 `<resources>/ghostty/polter/plugins/`，
**只排除 `.md`**（`src/build/GhosttyResources.zig`）。所以：README 随便写，别往
插件目录里放任何你不希望发给用户的可执行文件。

## 三种 `kind`

| | 生命周期 | stdin | 宿主怎么判成败 |
| --- | --- | --- | --- |
| `notify` | 一次一进程 | **一行** JSON，写完即关 | 退出码 0 = 送达。stdout 被忽略 |
| `archive` | **常驻**，随 Polter 结束 | 行分隔 JSON **流**，一行一批 | 每行回一行确认；**stdout 是协议通道** |
| `provision` | **启动时一次**，第一个终端开的时候 | **一行** JSON，写完即关 | 退出码 0 = 这个 AI CLI 现在知道 Polter 了。stdout 被忽略 |

`notify` 与 `archive` 的分界线是事件的疏密。通知一小时几条，每次 fork/exec 的开销
在这个尺度上不存在；存档是连续的，每条消息重建一次数据库连接显然不行。

`provision` 与 `notify` 的分界线是**喂的是什么**：通知拿到的是一次事件，provision
拿到的是对 Polter 本身的描述（哪个二进制、哪个构建、有哪些 skill、文件在哪），
把它翻译成某个 AI CLI 认识的形状。**它的失败会被打到用户的终端屏幕上**，因为这一步
失败的后果就是 agent 没有工具面 —— agent 正是那个收不到消息的人。见
[docs/poltergeist/boundary.md](../docs/poltergeist/boundary.md) 第三节。

**`archive` 的 stdout 只能出现确认行。**写进去的任何别的东西都会被判成失当并杀掉
进程 —— 所以插件起的子进程（比如 `psql`）必须自己接管道读，绝不能 inherit。
stderr 是 inherit 的，进 Polter 日志，那才是插件说话的地方。

确认行是 `{"ok":true}` / `{"ok":true,"cursor":N}` / `{"ok":false}`，一行、64KB 以内。
批次确认里的 `cursor` **绝不许超过这一批的 `through`** —— 超过是"我存了你没给我的
东西"，宿主认下它就意味着中间那些消息被从队列里丢掉而没有任何人存过，且没有任何
迹象。**插件订阅的是实时事件，不是核心的日志文件**；完整规则在
[storage.md](../docs/poltergeist/storage.md)。

## `plugin.json` 的字段

| 字段 | 说明 |
| --- | --- |
| `key` | 必填，且只能是一个平实的名字。**写成和目录名一样** —— 宿主不校验这一条，但查重按目录名，而下游全按 `key`（设置是 `<key>.json`，宿主查重也按它），不一致就得到一个设置文件叫着另一个名字的插件。两个目录声称同一个 `key` 时后一个被跳过并警告：两份拷贝会共用设置，而且会把每条消息各存一遍 |
| `name` | 给人看的名字，缺省等于 `key` |
| `kind` | `notify`（缺省）、`archive` 或 `provision`。不认识的 kind → 跳过这个插件，不是致命错 |
| `version` / `description` | 给读这个目录的人看的；宿主今天不解析它们 |
| `exec` | 必填。相对目录名，被拼成绝对路径后**直接当 argv[0]**（没有 shell 兜底，shebang 必须自己成立，文件必须有执行位） |
| `timeout_ms` | 正整数，缺省 10000。**它只界定一次交换**（写一行 + 读一行），不是整个会话的寿命 —— 交换之间宿主会把 deadline 撤掉 |
| `wants` | 权限声明，见下 |
| `params` | JSON Schema，见下 |

`wants` / `params` 里的一个笔误只让那一部分降级为空，**不会让整个插件消失** ——
后者对插件作者来说更难发现。

### `wants`

```json
"wants": { "groups": ["*"], "network": true, "exec": ["psql"] }
```

**只有 `groups` 是真的被强制的**，而且强制得彻底：喂给插件的批次就是按这份清单筛
出来的，它没有第二条通道能碰到日志。`network` 与 `exec` 是**声明与告知** —— 给装
之前的人读、给审计当依据，**不是沙箱**。`"network": false` 绝不能被读成"它上不了网"。

**没有 `wants` 的清单等于什么都不要**，而且不是悄悄不干活：存档插件因此根本不启动，
并且被点名警告，连该补的那一行都抄给用户。缺省当成 `["*"]` 会让一份什么都没声明的
清单拿到全部群，权限声明存在的意义当场归零。

`wants` 是**插件级**而不是后端级的，所以写并集。`chat-archive` 选 `file` 后端时既
不联网也不起 psql，声明仍然照最大能力写 —— 缩水的声明会让审计失效。

### `params`

JSON Schema。`properties` 下每个字段读 `title`、`description`、`required`，外加
本轮新增的两个注解：

- **`"secret": true`** —— 插件作者在说"这个参数是凭据"。工具面据此**拒绝写入明文**。
  必须是真正的 JSON 布尔值：`"true"`、`1` 都被读作**缺省的 false**，而 false 正是
  让那条拒绝规则失效的东西。名字猜不出来（`webhook` 的 `url` 长得完全不像密码，但
  拿到它就能以用户的名义发东西），只有作者知道。
- **`"enum": [...]`** —— 取值是封闭集合。必须是字符串数组，非字符串项会被跳过。
  这是**唯一一种敢把已配置的值回显给 agent 的参数**：封闭集合装不下密码。
  注意它只对**字面量**生效 —— `env:BACKEND` 会被放行，然后带着环境里的任何东西
  到达插件，所以**插件自己也要再校验一遍**。

## 凭据：存引用，不存值

参数值支持四种前缀，Polter 在**调用插件的那一刻**才解析，值只进插件的 stdin：

| 写法 | 从哪取 |
| --- | --- |
| `env:NAME` | 环境变量 |
| `file:~/.config/polter/x.key` | 文件首行，去空白（`~/` 会展开） |
| `keychain:service/account` | 系统钥匙串（macOS `security`，Linux `secret-tool`） |
| `cmd:op read op://Private/x` | 执行命令取 stdout —— 一条覆盖全部密码管理器 |

没有前缀就是字面值。三条规矩：

1. **只在调用时解析，不缓存。**密码管理器可能会锁上，锁上之后就该失败 —— 缓存会让
   "已锁定"这件事对 Polter 不可见。
2. **解析失败 = 这次调用失败**，写日志，不回退到别的值。
3. **绝不把引用本身当成值发出去。**把 `cmd:op read …` 当成密码发给飞书，比发不出去
   糟得多。

## 设置只有一处，而且没有游标文件

```text
$XDG_CONFIG_HOME/polter/plugins/<key>.json      {"enabled": bool, "params": {…}}
```

**`<key>.cursor` 不存在了。** 它从前记的是「跟读核心那个日志文件到第几行」，
而插件已经不跟读任何文件：它订阅实时事件，队列在内存里，跨重启的进度只存在于
插件自己的库里（按 `seq` 幂等）。一个不存在的文件不会被 dotfiles 同步到另一台
机器上去撒谎。

**没有 `<key>.json` 就是没开** —— 除非插件目录里自带一份 `settings.json`：那是发行
带的缺省，只在用户没有自己那份文件时才生效。**用户那份存在就赢，包括它写的是「关」**
（两者不合并：合并分不清「关掉了」和「从没配过」，升级就会把用户关掉的东西打开）。
运行时永不写发行那份。`plugins/claude-code/settings.json` 就是靠这个预装即开。

## 什么能被工具面改，什么不能

见 [docs/poltergeist/mcp.md](../docs/poltergeist/mcp.md)。

**能**：把插件打开；设它清单里声明过的参数。

**不能**，每条都有理由：

- **写 `cmd:`** —— `cmd:` 是 Polter **稍后自己执行**的一条命令，那时候授权这次工具
  调用的东西早就结束了。搬运数据和引入新代码不是一回事。
- **往标了 `secret` 的参数里写明文** —— 回显是不可逆的，而写进去的是一份长期凭据。
- **让 `file:` 指到 polter 的 config/state 目录之外** —— 否则"把用户放在别处、为
  别的用途的文件变成插件会外发的东西"这条路就通了。
- **设清单没声明过的参数名** —— 一个不在 schema 里的名字**无法被判定是不是 secret**，
  放行它等于给出一条绕过明文规则的路。同理，清单完全没声明 `params` 的插件，一个
  参数都不能设。
- **把插件关掉** —— 通知是用户在挂机场景里唯一的知情通道，让 agent 能掐掉它，等于让
  它能给自己关灯。要关就说清楚想关什么、为什么，留给人自己关。

读那一侧另有一条兜底：**明文值一律不回显**，不看 `secret` 标没标（枚举参数除外，
而枚举装不下密码）。也就是说 `secret` 只用来**收紧写入**，从不用来**放宽读出** ——
一个作者漏标的参数，最坏是能被 agent 写进明文，而不是能被 agent 读出来。

**手写这些文件时明文完全合法，只有工具面不许。**这个不对称是故意的：写文件的是
用户，调工具的是 agent。
