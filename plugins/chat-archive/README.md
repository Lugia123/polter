# chat-archive

把群聊记录复制到一个比这台机器活得久的地方。

## 一句话模型

**本地那份 `chat.jsonl` 是唯一的事实来源，这个插件只是它的跟读者。**
**而「本地留一份能读的」是核心的事，不是这个插件的事。**

Polter 自己一直在写两份：`$XDG_STATE_HOME/polter/chat/chat.jsonl`（流，给机器
跟读的）和 `$XDG_STATE_HOME/polter/chat/<群>/<日期>.jsonl`（记录，给人和 AI 读
的）。两份都不依赖任何插件。所以这个插件的价值只在**送到别处去** —— 数据库、
共享盘、公司内网 —— 它不再、也不该在本地重写一份同样形状的东西。

消息先同步写进 `$XDG_STATE_HOME/polter/chat/chat.jsonl`，写完才算数；这个插件
从那个文件往后读，读到哪由游标记着。于是**插件停了不丢任何东西**：它挂一小时，
游标就一小时不动，起来之后自己补齐。数据库连不上、凭证过期、psql 被卸了，都
只是游标不前进而已。

反过来的做法（消息来了直接写库）会让耐久性依赖插件，而你不会立刻发现它坏了。
详见 [docs/poltergeist/storage.md](../../docs/poltergeist/storage.md)。

## 需要什么

- `python3` —— 只用标准库，按 **3.8** 写。不需要 pip、venv、psycopg2。
- 用 postgres 后端时还需要 `psql`。

> **从 Dock 启动的 Polter 只有 launchd 的 PATH**（`/usr/bin:/bin:/usr/sbin:/sbin`），
> 你 shell 里好好的 `psql` 它是看不见的。所以这个插件在 PATH 之外还会去几个固定
> 目录找：`/opt/homebrew/bin`、`/usr/local/bin`、`/opt/local/bin`、
> `/Library/PostgreSQL/*/bin`、`/usr/pgsql-*/bin`。这几个目录是写死在
> `archive.py` 里的常量，不是配置项 —— 它不打算给出一条"挑一个可执行文件"的通道。
> 都找不到就 stderr 一句话然后 exit 2。**从终端里启动 Polter 是更省事的解法。**

## 参数

写在 `$XDG_CONFIG_HOME/polter/plugins/chat-archive.json` 的 `params` 里。

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `backend` | **无** | `postgres` 或 `file`。**必填**，没有默认值 → 缺了或写错都是 exit 2 |
| `dsn` | 无 | postgres 连接串。**凭据，见下** |
| `schema` | `public` | postgres schema。必须匹配 `[a-z_][a-z0-9_]{0,62}` |
| `stream` | `default` | 这份日志叫什么。主键的一半，**多机时务必各起一个名** |
| `path` | **无** | file 后端导出到哪个文件。**绝对路径、`.jsonl` 结尾、父目录必须已存在** |

```json
{
  "enabled": true,
  "params": {
    "backend": "postgres",
    "dsn": "cmd:op read op://Private/polter-pg",
    "stream": "laptop"
  }
}
```

**清单里的 `default` 宿主不会替你填** —— `App.ensureArchive` 把 `settings.params`
原样递过来，没有设置文件的插件收到的就是 `{}`。默认值是 `archive.py` 自己兜的，
两边由自检的第 13 条比对着，不会漂。

### `dsn` 为什么要写成引用

`dsn` 在清单里标了 `"secret": true`。值到达这个插件时**已经是解析好的明文**，
所以盘上那份文件里应该只有秘密的**地址**，而不是秘密本身：

| 写法 | 从哪取 |
| --- | --- |
| `env:POLTER_PG` | 环境变量 |
| `file:~/.config/polter/pg.dsn` | 文件首行 |
| `keychain:polter/pg` | 系统钥匙串 |
| `cmd:op read op://Private/polter-pg` | 执行命令取 stdout —— 一条覆盖全部密码管理器 |

这样 `chat-archive.json` 就可以进 dotfiles 仓、可以贴进 issue。解析发生在
**每次子进程重起的那一刻**，不缓存 —— 密码管理器锁上了就该失败，缓存会让"已锁定"
这件事对 Polter 不可见。

这个插件拿到明文之后，**绝不让它靠近 stderr**：插件自己组的每一句话都走
`_note()` 这一个出口，DSN 的解析异常被单独兜住（`urllib` 和 `shlex` 的报错会把它
没解析成功的那个字符串原样引在消息里，而那个字符串就是密码）。另一个写 stderr 的
地方只有兜底的 `traceback.print_exc`，那是故意的：traceback 打的是调用栈不是局部
变量，没有值可漏。DSN 也**绝不进 argv** —— Linux
上 `/proc/PID/cmdline` 全局可读，`ps` 一眼就看得见；它被拆成 `PGHOST` / `PGUSER` /
`PGPASSWORD` 一类的环境变量交给 psql。

## 两个后端

### `file`（零依赖）—— 导出到你指定的一个文件

追加写 `path` 指的那个文件，一行一条：

```json
{"stream":"default","seq":1043,"at_ms":1786819271275,"group":"build","author":"worker-core","summary":false,"text":"…"}
```

**没有默认落点，这是这个后端唯一真正改过的地方。** 它以前只要被打开就在
`$XDG_STATE_HOME/polter/archive/` 下写一份 —— 和核心自己在写的记录同一种形状，
差一个目录。核心已经在本地留一份能读的了，插件再默默写第二份不增加任何东西，
反而让人以为「有没有记录」取决于这个插件开没开。所以现在必须点名写到哪。

`path` 的三条限制，理由都是同一条：**`path` 是工具面能写的参数，而被写进去的是
聊天正文。**

- **绝对路径** —— 相对路径会按 Polter 的启动目录解析，那不是任何人选的地方
- **`.jsonl` 结尾** —— 这一条挡住的是 `~/.zshrc`、`~/.ssh/authorized_keys` 这类
  文件。对真正要导出的人零成本（他本来产出的就是 jsonl），但它把所有要紧的文件
  一次性移出射程
- **父目录必须已存在** —— 在别人选的路径上造目录，比写一个被点名的文件是更大的
  能力，不顺手做

打开时读文件尾恢复 `written_through`，跳过 `seq <= written_through` 的消息，所以
重放是幂等的。上次崩溃留下的半行会被截回到最后一个换行处 —— 不截的话它会和下一条
粘在一起，一次坏掉两条记录。

### `postgres`

**一条常驻的 psql 连接**，SQL 从它的 stdin 流进去，用 `\echo` 哨兵在 stdout 上划
工作单元。稳态下宿主每 500ms 看一次日志，一批往往就是一条消息 —— 按批起 psql 等于
按消息起 psql，正是常驻设计要避免的。

`ON_ERROR_STOP=1`：任何 SQL 错误直接结束 psql，我们读到管道关闭就知道这次没成，
下一批重连。**状态机只有两态：psql 活着或不活着。**

一批按 100 条切块、每块一个事务。前 k 块成功、第 k+1 块失败时回
`{"ok":true,"cursor":<第 k 块最后一条的 seq>}`，剩下的下一轮自然重发。

## 手工建表

角色没有 DDL 权限时，让 DBA 照这个建（`archive.py --print-schema` 打的就是它）：

```sql
CREATE SCHEMA IF NOT EXISTS "public";

CREATE TABLE IF NOT EXISTS "public".polter_chat (
  stream     text        NOT NULL,
  seq        bigint      NOT NULL,
  at_ms      bigint      NOT NULL,
  "group"    text        NOT NULL,
  author     text        NOT NULL,
  summary    boolean     NOT NULL DEFAULT false,
  text       text        NOT NULL,
  stored_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (stream, seq)
);

CREATE INDEX IF NOT EXISTS polter_chat_group_seq
  ON "public".polter_chat ("group", seq);
```

**主键是 `(stream, seq)`，这是整张表最重要的一行。**

- `seq` 是消息在这个系统里唯一的身份：全局、单调、跨群共用、跨重启恢复。把它做成
  主键，**幂等就不是一段代码，而是一条数据库约束** —— 重发写不进第二行，不依赖
  插件记得去查。写法只有一种：`INSERT … ON CONFLICT (stream, seq) DO NOTHING`。
- `stream` 让 `seq` 在多机/重来的情况下仍然唯一，见下一节。
- **`DO NOTHING` 而不是 `DO UPDATE`**：`group_compact` 会把某个 seq 的正文改写成
  摘要并继承那条的 seq。握手回拨会让插件重新看到已存过的 seq（那是正常路径），
  `DO UPDATE` 会用摘要覆盖掉原文 —— **存档因此丢掉它存在的理由**。`DO NOTHING`
  保留先到的那份，也就是更完整的那份。
- `stored_at` 和 `at_ms` 是两件事：前者是落库时刻（排障用：插件停了多久），后者是
  消息发生的时刻。

表名 `polter_chat` 是写死的常量。标识符没有参数绑定、只能拼进 SQL 文本，把它开给
配置就是开一条注入通道，而对面没有任何收益。`schema` 是唯一的例外，且被强校验后
用双引号包起来。

## ⚠️ 清了 state，或者把 dotfiles 同步到第二台机器，请换一个 `stream`

这是这个插件唯一一种**看起来健康、其实什么都没存**的失败方式：

1. 你清了 `$XDG_STATE_HOME`，或者把同一份 `chat-archive.json` 同步到了第二台机器。
2. 本地日志从 `seq=1` 重新数，而库里还留着上一轮/另一台机器的 1、2、3…
3. `ON CONFLICT DO NOTHING` 于是**静默丢掉每一条新消息** —— 没有报错，没有日志，
   游标照常前进，一切看起来都对。

`stream` 就是为这个存在的：给每台机器、每一轮重来各起一个名字，主键就不会撞。

握手时插件发现"库里已经比本机日志走得更远"会往 Polter 日志里喊一句，但**它没法在
那句话里告诉你 stream 现在是什么** —— 它一个参数值都不打印。所以这一节是你唯一
会看到的完整说明。

## 不装数据库怎么验证

```sh
./archive.py --self-test                      # 17 条，走 file 后端写临时目录
./archive.py --self-test --backend postgres   # 再加 7 条，用它自己写的假 psql
./archive.py --print-schema                   # 上面那段 DDL
```

`--self-test` 第一件事就是把 `XDG_STATE_HOME` 指到 `mkdtemp()`，绝不碰你真的存档。

其中一条专门盯着上面那几个正则**有没有真的被接上**：坏 `backend` / 缺 `dsn` /
坏 `schema` / 坏 `stream` / 带 `..` 的 `path` / **完全没给 `path`** / 指向一个
不存在的目录，各喂一次，断言都是 exit 2、stderr 只有一句、句子里不含喂进去的值，
且那条 `../` 没有在目录外留下文件。
光断言正则本身是不够的 —— 把 `path` 那个判断删掉，别的用例全都照样绿，而
聊天正文开始往它不该去的文件里追加。
另外那条正则用例是**双向**的：一边喂 `~/.ssh/authorized_keys`、`~/.zshrc`、
`x.jsonl.sh`、`.jsonl`（最后两个是能骗过朴素后缀判断的形状）断言全部不匹配，
一边喂 `/home/u/archive/chat.jsonl` 断言匹配 —— 一个什么都不匹配的正则能让上半
边全绿，同时让这个后端根本没法用。

`--self-test --backend postgres` 在临时目录里**现写一个假的 `psql`** 前置到 PATH，
它把 argv、`PG*` 环境、以及 stdin 的每一个字节都录下来。于是不连库也能断言：SQL 里
有 `ON CONFLICT (stream, seq) DO NOTHING`、COPY 的那一行是单行且反解回来与喂进去的
消息一致、表名固定而 schema 被双引号包住、**argv 里不含 DSN 的任何片段**、
`PGPASSWORD` 等于喂进去的那个特征串、以及**stderr 里同样不含任何片段**（这一条能
断言得干净，是因为两个写 stderr 的地方都通过 `sys.stderr`、都在调用时才查它，换掉
一个对象就全都录得到）。它还会喂一批 150 条的消息、让假 psql 在第二块中途消失，
断言回来的是**第一块最后那个 seq 而不是最后一条消息的** —— 认下后者等于告诉宿主
一百条已经存好了，而它再也不会重发。

假 psql 是运行时生成的，绝不进仓库：`plugins/` 会被整个装进 app bundle（只排除
`.md`），一个叫 `psql` 的可执行文件不该跟着发给用户。

## 工具面能改这里的什么

见 [docs/poltergeist/mcp.md](../../docs/poltergeist/mcp.md)。简短版：

- **能**：把这个插件打开，设 `backend`，把 `dsn` 设成 `env:` / `keychain:` /
  `file:`（后者要落在 polter 的 config/state 目录下，**而且得是写全的绝对路径** ——
  `file:~/…` 会被拒，因为 `~` 要到调用插件那一刻才展开，展开成什么这道检查此刻
  无从知道）。
- **不能**：往 `dsn` 里写明文 —— 清单标了 `"secret": true`，工具面据此拒绝，并
  告诉调用者该改用哪种引用。
- **不能**：写 `cmd:`。`cmd:` 在**每次子进程重起时**由 Polter 自己执行，也就是在
  授权那次工具调用的上下文早就结束之后 —— 那是引入新代码，不是搬运数据。
- 但**手写这个文件时 `cmd:` 完全合法**，上面的例子给的就是它。这个不对称是故意
  的：写文件的是你，调工具的是 agent。
