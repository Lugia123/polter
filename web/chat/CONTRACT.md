# 群聊页 ↔ 宿主 · 桥协议 v1

> 设计来源：`polter-artifacts/engine-2026-11-06/DESIGN-CHAT-TRANSCRIPT-V3.md` §二。
> 本文是**最终版**：两端宿主（mac WKWebView、Windows WebView2）按本表接；页面实现
> `index.html` / `chat.js` 按本表发和收。字段名、方向、语义以本文为准，改协议必须
> 同时改这里与 `chat.js` 顶部的 `PROTOCOL`。
>
> 页面只画和滚：加载哪一页、淘汰、搜索命中、引用/链接解析、图片 ticket、主题值
> 都在宿主与核心。页面不读文件、不联网、不导航。

## 0. 协议版本

页面启动后第一条消息带版本号：

```json
{ "type": "chat.ready", "protocol": 2 }
```

宿主收到 `chat.ready` 后才发 `page.reset`。版本不同宿主应记录并仍按 v1 的最小集
尝试，或直接回退纯文本列表。

**v2 新增**（task 3096）：`page.reset.reading`、`chat.reading`、`chat.jumpLatest`、
`chat.restoreFailed`。它们都是**增量**：v1 宿主不看 `reading`、把三条新消息当
未知记一行，仍能工作（只是离开群后回到最新）。契约里写的"页面→宿主 8 条"自
v2 起是 11 条。

## 1. 传输

### 页面 → 宿主

页面按顺序尝试，用第一个存在的：

| 宿主 | 通道 |
|---|---|
| mac | `window.webkit.messageHandlers.polterChat.postMessage(obj)` |
| Windows | `window.polter.postMessage(obj)`（即 `window.chrome.webview.postMessage` 的别名，页面两种都认） |
| 任意（宿主注入） | `window.polter.postMessage(obj)` |

每条消息是一个对象，`type` 是消息名，其余字段平铺：

```json
{ "type": "chat.loadOlder", "before": 41 }
```

宿主侧建议只注册一个名字 `polterChat` 的 message handler，按 `type` 分发；
**不要**为每条消息注册一个 handler。

### 宿主 → 页面

页面认三种投递方式，任选其一（同一条消息不要投两次）：

1. `window.polterChat.receive(obj)` —— 宿主用 `evaluateJavaScript` 直接调（mac 最省事）。
2. `window.postMessage(obj, "*")` —— 页面在 `window` 上监听（`e.source === window`）。
3. Windows `chrome.webview.postMessage(obj)` —— 页面已经监听了 `chrome.webview` 的
   `message` 事件；`e.data` 可以是对象，也可以是 JSON 字符串。

也接受老式 `{ "method": "page.reset", "argument": { … } }` 信封（与现有
`WKScriptMessageHandler` 桥一致），`argument` 的字段会平铺到消息上。

### CSP（宿主必须放行）

页面要注入 CSS 变量（`page.theme`，详见 §5），因此：

```
default-src 'none';
script-src 'self';
style-src 'self' 'unsafe-inline';
img-src polter-file: data:;
font-src 'self';
connect-src 'none';
frame-src 'none';
```

`img-src` 必须包含 `polter-file:`（图片 ticket）与 `data:`（页面自测/占位）。
页面自身的资源（`chat.css`、两个 vendor 脚本）由宿主自己的 scheme 提供。

## 2. 共同类型

### 2.1 Message

```json
{
  "id": "m120",
  "seq": 120,
  "at": 1794165603513,
  "author": "◐ Claude Code",
  "role": "polter-supervisor",
  "text": "## 标题\n\n正文 **md**",
  "dayBreak": false,
  "speakerRule": true,
  "images": [{ "src": "/Users/…/shot.png", "width": 1024, "height": 640, "alt": "截图" }]
}
```

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `id` | string \| number | 是 | 页面内唯一；`page.update`/`page.locate`/`chat.menu` 用它。页面统一按字符串存 |
| `seq` | number | 是 | 全局递增序号；`chat.loadOlder.before` 用它 |
| `at` | number | 是 | epoch 毫秒（本地时区显示） |
| `author` | string | 是 | 作者显示名（含角色符号可以） |
| `role` | string | 否 | 角色色：含 `supervisor` → 紫；`user`/`human` → 绿；其余 → 蓝 |
| `text` | string | 是 | **原始 md 字符串**，页面解析一次 |
| `dayBreak` | boolean | 否 | 这条之前画一条日期分隔线（宿主在跨天首条上置 true） |
| `speakerRule` | boolean | 否 | 这条之前画一条更重的分隔线（换发言人时用） |
| `images` | array | 否 | 见 2.2；与 `text` 里的 md 图片并存 |

### 2.2 Image

```json
{ "src": "/Users/me/…/shot.png", "width": 1024, "height": 640, "alt": "截图" }
```

`src` 是宿主/核心给的原值。页面**不**直接加载本地路径：它发 `chat.imageTicket`
（§4.7），宿主回 `page.image`（§3.8）换成 `polter-file://…` 的 URL。尺寸能给就给，
页面用 `width`/`height` 属性 + `aspect-ratio` 先占位，迟加载不跳。

### 2.3 Range（字符区间）

```json
[12, 16]
```
或
```json
{ "start": 12, "end": 16 }
```

`start` 含、`end` 不含；**偏移量是被渲染正文的可见文本**（DOM `textContent`），
不是原始 md 字符串（md 记号、代码高亮标签不占字符）。页面两种形状都收。

## 3. 宿主 → 页面

| 消息 | 字段 | 页面行为 |
|---|---|---|
| `page.reset` | `messages: Message[]`、`theme?: Theme`、`locale?: string`、`hasEarlier?: boolean`、`reading?: {id, offset}`、`error?: string` | 清空、渲染；有 `reading` 就落位到那里，否则贴底；恢复跟随。带 `error` 表示这一读失败，页面显示重试而不是当成空群 |
| `page.prepend` | `messages: Message[]`、`hasEarlier: boolean`、`error?: string` | 插在顶部并按元素锚点补偿视口。带 `error` 表示更早的记录读失败，页面显示重试（不是「到头了」） |
| `page.append` | `message: Message`、`pending?: number` | 底部追加；不跟随时画面不动并浮出跳转按钮 |
| `page.update` | `id`、`text: string` | 重渲染该条正文，锚点补偿 |
| `page.follow` | — | 立即回到底部并恢复跟随 |
| `page.locate` | `id`、`ranges?: Range[]` | 滚到该条并高亮；有 `ranges` 时只标词 |
| `page.search` | `query: string`、`hits: [{ id, ranges?: Range[] }]` | 标出命中（`<mark>`），清掉上一次 |
| `page.image` | `src`、`url`、`width?`、`height?` | 把占位图换成 ticket URL 并补尺寸 |
| `page.notImage` | `src` | 宿主读不了这个路径、或文件头不是图片：把占位换成**原文可点文件链接**（点击发 `chat.openLink`） |
| `page.theme` | `CSS 变量…`、`mode?: "dark" \| "light"` | 注入变量；`mode` 切内置明暗底 |

### 3.1 `page.reset`

```json
{
  "type": "page.reset",
  "messages": [ { "id": "m80", "seq": 80, "at": 1794165603513, "author": "✳ Claude Code", "role": "dev-worker", "text": "…" } ],
  "theme": { "mode": "dark", "bg": "#1b1f24", "fg": "#d5dae0" },
  "locale": "zh-CN",
  "hasEarlier": true,
  "reading": { "id": "m120", "offset": -40 }
}
```

- `hasEarlier` 缺省按 `true`：宿主还不知道有没有更早的。
- 页面渲染后 `scrollTop = scrollHeight`（第一眼就是最新一条）；若内容不足一屏且
  `hasEarlier` 为真，页面会自己发一次 `chat.loadOlder` 把屏填满。
- **`reading`（v2，可选）**：这个群上次被离开时读者在哪里。`offset` 是
  `anchor.offsetTop - scrollTop`，**≤ 0**（锚点行顶在视口顶或之上），单位 CSS px。
  页面把它夹到 `[0, scrollHeight - clientHeight]` 后落位，并**再校验一次
  `findAnchor() === anchor`**（迟到的图片会改行高，夹紧也可能把锚点挤出视口）。
  校验不过就退回贴底，并发 `chat.restoreFailed`（§4.12）——**不静默**。缺省 /
  null 就是贴底。
- **`reading` 只在宿主重新打开一个被关掉的群时出现一次**；reload / return-to-latest
  的 reset 不带它（那些的落点按定义是最新）。
- `theme` 用**完整变量集**；页面收到新 theme 会先清掉上一轮注入的变量。只发
  `{ "mode": "light" }` 时回落到内置浅色皮肤。
- **`error`（协议 2 增量，可选，task 3098）**：这一页读失败时的说明。页面把它显示成
  「读不到，点这里重试」，**不**把空页当成「没有消息」，并重新对首屏计时。带
  `error` 的 reset 不算「首屏已经拿到」：页面仍可在读者点重试时再发
  `chat.ready`。

### 3.2 `page.prepend`

```json
{ "type": "page.prepend", "messages": [ … ], "hasEarlier": false }
```

- 页面插入前记下「第一个 bottom 越过 `scrollTop` 的行」及其相对视口偏移，插入后
  按新几何还原，视口不动（§三.2）。
- `hasEarlier: false` → 顶部显示「到头了」，不再发 `chat.loadOlder`。
- 空数组 + `hasEarlier: true` 会被页面当成「到头了」处理（避免死循环）。
- **`error`（协议 2 增量，可选，task 3098）**：这一页读失败。页面顶部显示
  「更早的记录读不到，点这里重试」（可点，重发 `chat.loadOlder`），`hasEarlier`
  保持为真，**不**显示「到头了」。
- **每一次 `chat.loadOlder` 都必须有一次 `page.prepend`**：到达开头时发
  `{ messages: [], hasEarlier: false }` 也是答案，读失败时发
  `{ messages: [], hasEarlier: false, error: "…" }`。不许什么都不发。

### 3.3 `page.append`

```json
{ "type": "page.append", "message": { … }, "pending": 3 }
```

- 页面用**当下几何**判断是否贴底（`scrollHeight - scrollTop - clientHeight < 24`），
  不依赖上一次滚动事件。
- 贴底：追加后滚到新底部。
- 不贴底：画面完全不动，跳转按钮显示 `(n)`；`pending` 是宿主给出的未读数，页面
  取 `max(本地计数, pending)`。
- 注意：页面**不会**自己预取新消息；要不要拉，由宿主根据 `chat.follow` 决定。

### 3.4 `page.update`

```json
{ "type": "page.update", "id": "m121", "text": "改过的 **md**" }
```

同一条消息的文本被改写（重发、流式更新的预留口）。页面重渲染该条正文；
如果它整体在视口上方，按锚点补偿，不动画面。

### 3.5 `page.follow`

```json
{ "type": "page.follow" }
```

回到底部、清未读数、恢复跟随。

### 3.6 `page.locate`

```json
{ "type": "page.locate", "id": "m42", "ranges": [[12, 16]] }
```

滚到该条（离顶部约 80px），并对 `ranges` 标 `<mark>`；无 `ranges` 时整条淡底色
闪一下。搜索的「上下一个」由宿主对每个命中发一次本消息即可；页面另外暴露
`window.polterChat.searchStep(±1)` 给想省事的宿主。

### 3.7 `page.search`

```json
{
  "type": "page.search",
  "query": "滚动",
  "hits": [
    { "id": "m42", "ranges": [[12, 14]] },
    { "id": "m77" }
  ]
}
```

- 有 `ranges`：按字符区间标 `<mark class="hit">`。
- 无 `ranges`：在该条正文里按 `query` 字面（大小写不敏感）标。
- 再发一条 `{ "query": "", "hits": [] }` 清空。
- 页面不滚到命中；滚动是 `page.locate` 的事。

### 3.8 `page.image`

```json
{
  "type": "page.image",
  "src": "/Users/me/…/shot.png",
  "url": "polter-file://tk_abc/shot.png",
  "width": 1024,
  "height": 640
}
```

`src` 必须与页面发 `chat.imageTicket` / `chat.image` 时用的 `src` 逐字一致。`width`/`height`
同时给出时页面用它们占位；只给 `width` 就只设 `width`。页面替换后按锚点补偿（或贴底）。

### 3.10 `page.notImage`

```json
{ "type": "page.notImage", "src": "/tmp/report.pdf" }
```

宿主读不到这个路径（`stat` 失败）、超过单张 8 MB 上限、或文件头不是
PNG/JPEG/GIF/WebP/BMP/TIFF/HEIC 时回这条。页面把对应的 `chat.image` 占位换成
**原文可点文件链接**（`<a class="filelink">`，点击照常发 `chat.openLink`）；Markdown
图片则把 alt（没有 alt 时用 `src`）做成链接。其余消息不移动。

### 3.9 `page.theme`

```json
{
  "type": "page.theme",
  "mode": "light",
  "--bg": "#fbfbfc",
  "--bg-code": "#f1f3f5",
  "--fg": "#23272d",
  "--muted": "#6b747d",
  "--rule": "#d8dde2",
  "--accent": "#0b62c4",
  "--hit": "#f2cc60",
  "--hit-fg": "#23272d",
  "--font-size": "13.5px",
  "--gutter": "150px"
}
```

- 键名可以是 CSS 变量（`--bg`），也可以是驼峰/短名（`bg`、`fontSize`）——
  页面会自动补 `--` 并把驼峰转 kebab。
- **每次发完整集合**：收到新 theme 时页面先删掉上一轮注入的变量，没给的就用内置
  皮肤，不会残留上一套颜色。
- 内置两套：默认深色（样张那套），`mode: "light"` 时浅色。
- `--font-size` / `--gutter` / `--font-mono` 也走同一条通道；改字号后页面按锚点
  重新落位一次。

## 4. 页面 → 宿主

| 消息 | 字段 | 何时发 |
|---|---|---|
| `chat.ready` | `protocol: number` | 页面脚本就绪，只发一次 |
| `chat.loadOlder` | `before: number \| null` | `scrollTop < 240` 且不在加载中；`before` 是当前最旧一条的 `seq` |
| `chat.follow` | `follow: boolean`、`pending: number` | 跟随状态或未读数变化；reset 后必发一次 |
| `chat.openLink` | `href: string` | 点击 md 链接（图片走 `chat.openImage`） |
| `chat.openImage` | `src: string` | 点击渲染出来的图片；`src` 是原图来源，不是 ticket URL |
| `chat.menu` | `id`、`x`、`y` | 在消息上右键；`x`/`y` 是视口 CSS 像素，整数 |
| `chat.copy` | `text: string` | 选区复制（原生复制照常发生）、代码块「复制」按钮 |
| `chat.imageTicket` | `src`、`id` | **Markdown 图片**（`![](...)` / `images[]`）的路径页面读不了，要一个 ticket URL |
| `chat.image` | `src`、`id` | **正文里整段只有一条裸路径**（`/…`、`~/…`、`file://…`、`http(s)://…`）时，问宿主这是不是图片 |
| `chat.error` | `message: string` | 页面内部异常（例如一次渲染抛错） |
| `chat.reading` | `anchor: string \| null`、`offset: number`、`following: boolean` | 读者位置变化；滚动中最多 200ms 一次，reset 落位后与 `pagehide`/隐藏时各强制一次 |
| `chat.jumpLatest` | — | 读者点了「↓ 跳到最新」 |
| `chat.restoreFailed` | `why`、`id`、`offset`、`want`、`got` | `page.reset.reading` 恢复失败，页面已退回贴底 |

### 4.1 `chat.ready`

```json
{ "type": "chat.ready", "protocol": 2 }
```

- 页面启动后发一次。**若 10 秒内没有收到不带 `error` 的 `page.reset`，页面会重发**
  （task 3098）：10 s、20 s、40 s、封顶 60 s；读者点了「重试」则退回 10 s。宿主按
  「每条 `chat.ready` 必回一次 `page.reset`」处理即可，重发是正常的。
- **一个已经拿到好 reset 的页面不会再发它**：那时再 reset 会把读者正看的位置冲掉。

### 4.2 `chat.loadOlder`

```json
{ "type": "chat.loadOlder", "before": 41 }
```

- 页面同时把顶部指示器置为「正在加载更早…」。
- 宿主回 `page.prepend`（**必须回**，见 §3.2）。若 15 秒没有回应，页面解除
  「加载中」并把顶部换成「还在读，可以点这里重试」（**是慢，不是坏**）；点它重发
  `chat.loadOlder`，宿主仍可迟到投递（页面按新页插入，并清掉那句提示）。
- 到达真实开头后宿主必须回 `hasEarlier: false`，页面显示「到头了」并停止再要。

### 4.3 `chat.follow`

```json
{ "type": "chat.follow", "follow": false, "pending": 2 }
```

- `follow = scrollHeight - scrollTop - clientHeight < 24`。
- 状态不变时不重复发（reset 后强制发一次）。
- 宿主可据此停/开新消息预取；`pending > 0` 表示读者停在上方、底部有 n 条新内容。

### 4.4 `chat.openLink`

```json
{ "type": "chat.openLink", "href": "https://example.com/x" }
```

页面已经 `preventDefault`，不会自己导航。`href` 可能是外链、文件引用、终端路径，
由宿主判定。**点击图片不走这条，走 `chat.openImage`（§4.8）**：2026-11-09 曾把原图
路径交给文件预览，而预览的票按群的工作目录校验，读不了 `/tmp`。宿主另有一道：
`href` 指向本地图片文件时**既不预览也不打开**（mac 与 Windows 同一答案），要打开
图片请点图片本身，那条走 §4.8。

### 4.5 `chat.menu`

```json
{ "type": "chat.menu", "id": "m42", "x": 812, "y": 455 }
```

宿主弹原生菜单；页面已 `preventDefault`，不会弹 WebView 自带菜单。

### 4.6 `chat.copy`

```json
{ "type": "chat.copy", "text": "选中的文字" }
```

- 选区复制：页面监听 `copy`，把选区文本上报，但**不**阻止默认复制——即使宿主
  不接，系统剪贴板照常拿到内容。
- 代码块按钮：上报整块代码（去掉末尾换行）。

### 4.7 `chat.imageTicket` 与 `chat.image`

两条请求、一种回答：宿主用 `page.image`（§3.8）或 `page.notImage`（§3.10）回，页面
都按 `src` 匹配替换。

**`chat.imageTicket`**——Markdown 图片的 `src`：

```json
{ "type": "chat.imageTicket", "src": "/Users/me/…/shot.png", "id": "m118" }
```

页面只对「不是 data:/http(s):/polter-file:/blob:」的 `src` 发这条，并先画占位框。
宿主按 `src` 找到原文件，回 `page.image`（§3.8），页面按 `src` 匹配替换。

**`chat.image`**——正文里**整段只有一条裸路径**的文本节点（路径和文件链接由程序
解析，不靠作者写 `![]()`）：

```json
{ "type": "chat.image", "src": "/tmp/shot.png", "id": "m119" }
```

- 候选：`/…`、`~/…`、`file://…`、`http(s)://…`；**无扩展名也算候选**，由宿主判定。
- 只扫文本节点，**跳过 `pre` / `code` / `a` 内部**；行内夹在句子里的路径这轮不做
  （仍按原文显示）。
- 页面把这段原文换成 `<span class="pathref">`，宿主答 `page.image` 就换成一个
  块级 `<img>`，答 `page.notImage` 就换成可点文件链接。
- **远程 `http(s)://` 这轮只识别、不加载**：`connect-src 'none'`，`img-src` 里也没有
  它；宿主回 `page.notImage` 是预期结果（可点链接交给宿主打开）。

### 4.8 `chat.openImage`

```json
{ "type": "chat.openImage", "src": "/tmp/shot.png" }
```

- 页面点击一张已经渲染出来的图片时发这条。`src` 是**原图来源**（`img.dataset.src`），
  不是宿主给内联显示用的 `data:` ticket；`data:` / `blob:` / `polter-file:` 不发。
- **由宿主打开，不铸 ticket、不进侧栏预览**：宿主要用自己的判据确认这确实是一张
  图片（mac `ControlRoomChatTranscriptPage.isImagePath`、Windows
  `chat_page::local_image_path`，都读文件头），再交给系统默认程序（mac
  `NSWorkspace.shared.open`、Windows `ShellExecuteW`）。页面报的后缀不算数。
- **这是唯一一条有意绕开 workdir 边界的路径**：其他本地路径都由 core 的
  `files_open` 按群的工作目录校验（`src/poltergeist/files/Tickets.zig`），
  `/tmp` 这类目录外的图片会被拒绝。这条只对图片开口；非图片一律不打开、不预览。
- 宿主读不了或不是图片：记日志并丢弃，**不得**回落到文件预览或系统程序。

### 4.9 `chat.error`

```json
{ "type": "chat.error", "message": "…" }
```

页面处理某条宿主消息时抛出的异常；宿主应记日志。页面不会因此白屏，坏的那条
消息保持原样。

### 4.10 `chat.reading`

```json
{ "type": "chat.reading", "anchor": "m120", "offset": -40.5, "following": false }
```

- **`anchor`**：`findAnchor()` 那一行（第一个 `bottom > scrollTop` 的行）的 id；
  文档没有行时是 `null`。
- **`offset`**：`anchor.offsetTop - scrollTop`（CSS px）。≤ 0；`0` 是锚点行顶正好
  在视口顶。它和 `page.reset.reading.offset` 是同一个数，宿主原样存、原样还。
- **`following`**：读者是否贴底。**贴底不是位置**：宿主应只把 `following=false`
  的报告记成"读者在这里"，`following=true` 只用来维护读位置（页面 trim）——否则
  一个"读到底就离开"的群会被记成某一行，下次回来被扔到中间。
- **节流**：滚动中最多 200ms 一次（末次一定发）；`page.reset` 落位后、页面隐藏
  （`visibilitychange→hidden` / `pagehide`）各强制一次。宿主不必回任何消息。
- 页面**不存**这个位置：它的文档可能是一个搜索命中周围的窗口，和"这个群读到哪"
  不是一回事。

### 4.11 `chat.jumpLatest`

```json
{ "type": "chat.jumpLatest" }
```

- 读者点了「↓ 跳到最新」。页面自己会 `scrollTop = scrollHeight`，但那只到**已加载
  文档的底**——一个定位窗口（搜索结果的 around 页）的底不是会话的最新。
- 宿主收到后：如果正拿着定位窗口（mac `feed.locatedAnchor != nil`），重建到最新
  首页（mac `feed.returnToLatest()`）；否则什么都不用做（页面已经到底）。
- 和 `chat.follow` **分开**：`chat.follow` 是状态回报（滚动到哪都发），`chat.jumpLatest`
  是读者的一个动作。

### 4.12 `chat.restoreFailed`

```json
{ "type": "chat.restoreFailed", "why": "not-anchor", "id": "m120", "offset": -40, "want": 3812, "got": 3778 }
```

- `page.reset.reading` 恢复失败时发；页面已经退回贴底。
- `why`：`row-missing`（锚点行不在这一页）、`not-anchor`（落位后视口第一条不是
  锚点）、`clamp-miss`（`want` 超出可滚范围，夹紧后锚点不在视口顶）。`want`/`got`
  是夹紧前后的 `scrollTop`（CSS px，四舍五入）。
- **宿主必须记日志**：页面自己的 `console` 在真机上没人看，而"为什么我回来时在
  底部"将来只能靠这一行解释。mac 的日志是
  `reading: restore failed why=… id=… offset=… want=… got=…; back to the bottom`。

## 5. 生命周期

```
页面加载
  └─ chat.ready {protocol:2}
        ← page.reset {messages, theme, locale, hasEarlier, reading?}
        ├─ 渲染；有 reading 就落位（失败则发 chat.restoreFailed 并贴底）
        ├─ chat.follow {follow:…, pending:0}
        └─ chat.reading {anchor, offset, following}

读者滚动
  └─ chat.reading（200ms 节流）+ chat.follow（状态变化时）

读者上滚到 <240px
  ├─ 顶部「正在加载更早…」
  ├─ chat.loadOlder {before}
  ← page.prepend {messages, hasEarlier}
  └─ 插入 + 元素锚点补偿（视口不动）

读者停在中间时来新消息
  ← page.append {message, pending}
  ├─ 画面不动
  └─ 右下角「↓ 跳到最新 (n)」
读者点它
  ├─ chat.jumpLatest（宿主若在定位窗口里，重建到最新）
  ├─ 页面自己 scrollTop = scrollHeight
  └─ chat.follow {follow:true, pending:0}
```

## 6. 页面自己负责的滚动规则（宿主不必重复实现）

1. 贴底判定 `< 24px`；`page.reset` 后贴底，无顶部滑落。
2. 追加不跟随时画面不动，只更新角标。
3. 顶部加载：`scrollTop < 240` 触发，防重入，15 秒自愈。
4. 插入更早一页用元素锚点（锚点 = 第一个 `bottom > scrollTop` 的行）补偿。
5. 图片：`width`/`height` + `aspect-ratio` 占位；没有尺寸时 `load` 里按高度差补
   一次 `scrollTop`（只在该图整体位于视口上方时）。
6. 改宽/字号：`ResizeObserver` + 锚点元素恢复一次，不记绝对 `scrollTop`。
7. **溢出的代码块/表格横向滚动归自己，纵向滚轮归整页**：块上是
   `overscroll-behavior-x: contain`（只隔离横向）。⚠️ 早先写的 `overscroll-behavior:
   contain`（两轴）只在**块自己横向溢出时**才生效，于是同一块在宽视口能滚、被
   侧栏挤窄后开始吞纵向轮——看起来像"开搜索才坏"。
8. **整页右侧没有任何滚动条**：`scrollbar-width:none` +
   `::-webkit-scrollbar{display:none}`；位置提示只有右下角「↓ 跳到最新 (n)」。
   代码块自己的横向滚动条保留（块内，不是页面边缘）。
9. 「正在加载更早…」是**零高度的 sticky 浮层**：不占布局高度（所以出现/消失
   不推正文），在会触发加载的 `scrollTop < 240` 范围内始终可见；「到头了」只在
   `scrollTop < 24` 时出现，滚离顶部就收起。

## 7. 渲染约定

- Markdown：**marked 12.0.2**（MIT），`gfm: true` → 表格、删除线、任务列表。
  设计文档里写的 markdown-it 被交付清单里的 `vendor/marked.min.js` 取代，以本页为准。
- 代码高亮：**highlight.js 11.12.0**（BSD-3），只处理 `pre code`：
  - 有 `language-xxx` 且 hljs 认识 → 按该语言；
  - 有 `language-xxx` 但 hljs 不认识 → 保持纯文本（不猜）；
  - 无语言标记 → 自动检测（超长块跳过）。
- 链接点击 → `chat.openLink`（不导航）；图片点击 → `chat.openImage`（§4.8，
  宿主用系统默认程序打开）；右键 → `chat.menu`。
- 消息里的原始 HTML 会被清洗：移除 `script/iframe/form/style/link/meta/object/embed`
  等标签、所有 `on*` 与 `style` 属性、`javascript:` 协议的 URL；任务列表的
  `input[type=checkbox]` 保留并强制 `disabled`。
- 标题用 `#`/`##`/`###` 前缀 + 加粗；引用左边线；代码块深底细边框；表格真表格；
  分隔线；图片细边框圆角；搜索命中 `<mark>` 底色 `#F2CC60`、字色 `#23272D`。

## 8. 主题变量（内置默认）

| 变量 | 深色 | 浅色 | 用途 |
|---|---|---|---|
| `--bg` | `#1b1f24` | `#fbfbfc` | 页面底色 |
| `--bg-code` | `#16191d` | `#f1f3f5` | 代码/表头/按钮底 |
| `--fg` | `#d5dae0` | `#23272d` | 正文 |
| `--muted` | `#7d8790` | `#6b747d` | 时间、辅助 |
| `--rule` | `#2b3138` | `#d8dde2` | 分隔线/边框 |
| `--rule-soft` | `rgba(43,49,56,.45)` | `rgba(216,221,226,.8)` | 消息间细线 |
| `--accent` | `#8ab4f8` | `#0b62c4` | 作者名 |
| `--link` | `#7fd1ff` | `#0b62c4` | 链接 |
| `--who-supervisor` | `#c3a6ff` | `#6f42c1` | supervisor 作者 |
| `--who-user` | `#8fd18a` | `#2f7d32` | 用户作者 |
| `--hit` / `--hit-fg` | `#F2CC60` / `#23272D` | 同左 | 搜索/定位命中 |
| `--locate` | `rgba(138,180,248,.14)` | `rgba(11,98,196,.10)` | 定位整条淡底 |
| `--sel` | `rgba(138,180,248,.28)` | `rgba(11,98,196,.18)` | 选区 |
| `--font-mono` | `"SF Mono",Menlo,…` | 同左 | 等宽字体 |
| `--font-size` | `13.5px` | 同左 | 正文大小 |
| `--line-height` | `1.6` | 同左 | 行高 |
| `--gutter` | `150px` | 同左 | 左列（时间/作者） |

## 9. 语言

`page.reset.locale` 决定页面内少数几个字符串：`正在加载更早…` / `到头了` /
`↓ 跳到最新` / `复制` / `已复制` / 图片 alt 兜底。以 `en` 开头用英文，其余中文；
同时设 `<html lang>`。宿主自己的按钮/菜单文案不受影响。

## 10. 自测（不需要宿主）

```
open web/chat/dev.html
```

- 内置 140 条假消息，首次显示最新 60 条；每次上滚到顶由假宿主在 **300ms** 后
  回 20 条更早的，直到 0（然后 `hasEarlier:false`，顶部显示「到头了」）。
- 工具栏可以追加新消息、切明暗、搜索（字面/ranges）、定位到 `m120`。
- 右侧**没有任何滚动条**，用滚轮/触控板上滚；停在中间追加新消息时画面不动，
  右下角出现「↓ 跳到最新 (n)」。
- 图片：一条带尺寸（占位）、一条不带尺寸（load 补滚动）、一条本地路径
  （先 `chat.imageTicket`，假宿主 300ms 后回 `page.image`）。

## 11. 资产

| 文件 | 版本 | 许可 |
|---|---|---|
| `vendor/marked.min.js` | 12.0.2 | MIT |
| `vendor/highlight.min.js` | 11.12.0（common 构建） | BSD-3-Clause |

两文件随 app 字节一致嵌入，两端不各自打包不同版本。

## 12. 已知差异（v2）

**协议共享，行为可以不同；这里是写死的差异，不是"未做"。**

| 项 | mac | Windows |
|---|---|---|
| 离开群再回来，恢复上次阅读位置（`page.reset.reading`） | **已接**：`ControlRoomChatFeed.restoredPlace` → bridge 第一条 reset → 页面落位；失败发 `chat.restoreFailed` | **目前仍恢复到底部**：`chat_page.rs` 接受 `chat.reading`，但窗口侧不按群存位置，也不在 reset 里发 `reading` |
| 「↓ 跳到最新」在定位窗口里回到会话最新（`chat.jumpLatest`） | **已接**：`feed.locatedAnchor != nil` → `feed.returnToLatest()` | **目前只到已加载窗口的底**：`chat_page.rs` 接受并忽略这条；页面自己的 `scrollTop = scrollHeight` 仍然发生 |

Windows 这一半的起点：`windows/host/src/chat_page.rs` 的 `Snapshot` /
`reset()` 加 `reading` 字段，分派里把 `chat.reading` 变成窗口侧事件并按群存，
`chat.jumpLatest` 接窗口自己的"回到最新"。**在那之前，Windows 的这两条按上表
行为，不是 bug 报告里的"没实现"。**
