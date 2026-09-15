# 渲染管线与字体栈

> 最后更新对应的 git commit：`f81dcadc8`（`f81dcadc82ea2afdcf2dc92929037701122f05b5`，2026-08-14）
> 校验方式：`git log -1 --format='%H %h %ad %s'`

## 本文覆盖什么

- `src/renderer/` 的分层：后端无关的泛型主体 `generic.zig`，加上 Metal / OpenGL 两个图形 API 适配层。
- 一帧的产生路径：渲染线程定时器 → `updateFrame` 抓终端快照 → `rebuildCells` → `drawFrame` 发 draw call。
- 着色器来源：Metal 的 `.metal` 编成 metallib，OpenGL 的 `.glsl` 走 `@embedFile`，以及自定义 shader 的 GLSL → SPIR-V → 目标语言转译链路。
- `src/font/` 字体栈：Collection / CodepointResolver / SharedGrid / SharedGridSet / Atlas / Metrics / shaper / face 后端。
- 构建选项 `-Drenderer` 与 `-Dfont-backend` 的取值、默认值与 comptime 分派点。

## 本文不覆盖什么

- 终端状态机、`Screen`/`PageList`/`Page`、VT 解析 —— 见 [terminal-core.md](terminal-core.md)。
- 线程模型全景与 mailbox 总体设计 —— 见 [architecture.md](architecture.md)，本文只展开渲染线程这一根。
- Metal layer 如何挂到 `NSView`、apprt 抽象与用户配置项 —— 见 [platform-and-config.md](platform-and-config.md)。
- 构建、运行、调试命令的展开说明 —— 见 [preview-manual.md](preview-manual.md)，本文只在必要处写一行并指过去。

## 一句话概括

渲染器把 `terminal.Terminal` 的状态快照成一组 GPU 单元格数据交给 comptime 选定的图形后端画出来；字体栈负责把「码点 → 字体面 → 字形位图 → 图集坐标」这条链路做成可跨 surface 共享的缓存。

三个锚点：

- 渲染器职责的原始定义写在包头注释里：把内部屏幕状态转成输出格式，并假定窗口系统已经准备好渲染上下文（`src/renderer.zig:1-8`）。
- 具体实现 comptime 三选一，注释明确「每次构建恰好有一个渲染器实现」（`src/renderer.zig:36-42`）。
- 字体侧的公共 API 面是 `src/font/main.zig:7-31` 的那一组导出。

## 关键文件地图

渲染侧（行数为 `wc -l` 实测）：

| 路径                         | 行数 | 职责                             |
| ---------------------------- | ---- | -------------------------------- |
| `src/renderer.zig`           | 66   | 包入口，comptime 选定 `Renderer` |
| `src/renderer/generic.zig`   | 3379 | 后端无关的渲染主体               |
| `src/renderer/Metal.zig`     | 496  | Metal 图形 API 适配层            |
| `src/renderer/OpenGL.zig`    | 461  | OpenGL 图形 API 适配层           |
| `src/renderer/WebGL.zig`     | 2    | 空占位，无实现                   |
| `src/renderer/Thread.zig`    | 866  | 渲染线程与各类定时器             |
| `src/renderer/cell.zig`      | 680  | 单元格 GPU 数据容器              |
| `src/renderer/image.zig`     | 1038 | Kitty 图片与 overlay 的贴图/放置 |
| `src/renderer/shadertoy.zig` | 429  | 自定义 shader 转译               |
| `src/renderer/size.zig`      | 458  | 尺寸与坐标系换算                 |

字体侧：

| 路径                                | 行数 | 职责                      |
| ----------------------------------- | ---- | ------------------------- |
| `src/font/nerd_font_attributes.zig` | 2774 | 生成的 Nerd Font 约束表   |
| `src/font/shaper/coretext.zig`      | 2679 | CoreText 整形器           |
| `src/font/shaper/harfbuzz.zig`      | 2236 | HarfBuzz 整形器           |
| `src/font/Collection.zig`           | 1524 | 按 style 分组的字体面列表 |
| `src/font/face/freetype.zig`        | 1440 | FreeType 光栅化           |
| `src/font/discovery.zig`            | 1416 | 字体发现（fontconfig/CT） |
| `src/font/Atlas.zig`                | 889  | 二维矩形装箱图集（atlas） |
| `src/font/SharedGridSet.zig`        | 853  | 按配置 key 复用 grid      |
| `src/font/Metrics.zig`              | 818  | 网格尺寸与用户修饰        |
| `src/font/SharedGrid.zig`           | 664  | 跨 surface 共享的字形缓存 |

## src/renderer：三个后端与一个泛型主体

### comptime 选定的渲染器

`Renderer` 按 `build_config.renderer` 三选一：`.metal` → `GenericRenderer(Metal)`、`.opengl` → `GenericRenderer(OpenGL)`、`.webgl` → `WebGL`（`src/renderer.zig:38-42`）。默认后端由目标平台决定：wasm32 + browser → `webgl`，Darwin → `metal`，其余 → `opengl`（`src/renderer/backend.zig:14-21`）。

`src/renderer/WebGL.zig` 全文只有 2 行，是一个 `pub const WebGL = @This();` 的空结构，没有任何字段与方法，因此不可能满足 generic 要求的 GraphicsAPI 接口。至于当初为什么不让 WebGL 也走 generic，仓库里没有注释或文档说明（未核实：`grep` 未在 `src/renderer/` 找到相关说明，只能从代码形态反推）。

在非 macOS / iOS 上选 `-Drenderer=metal` 会直接编译失败，`Metal.init` 开头有 `comptime switch (builtin.os.tag)` 守卫（`src/renderer/Metal.zig:64-68`）。`webgl` 侧没有任何等价守卫：`webgl` 在 `src/` 与 `build.zig` 里只出现三处——`src/renderer.zig:41` 的分派、`src/renderer/backend.zig:8` 的枚举值、`src/renderer/backend.zig:16` 的 wasm 默认值。因此 `-Drenderer=webgl` 配非 wasm 目标不会被提前拒绝，只会在调用点因 `WebGL` 缺少方法而编译失败（未核实：本机 PATH 无 `zig`，无法实际编译验证）。

### 抽象层级

`generic.zig` 3379 行 vs `Metal.zig` 496 行 / `OpenGL.zig` 461 行——绝大部分逻辑与图形 API 无关。抽象层级在泛型入口的文档注释里画出来了。

出处：`src/renderer/generic.zig:56-77`

```zig
/// [ GraphicsAPI ] - Responsible for configuring the runtime surface
///    |     |        and providing render `Target`s that draw to it,
///    |     |        as well as `Frame`s and `Pipeline`s.
///    |     V
///    | [ Target ] - Represents an abstract target for rendering, which
///    |              could be a surface directly but is also used as an
///    |              abstraction for off-screen frame buffers.
///    V
/// [ Frame ] - Represents the context for drawing a given frame,
///    |        provides `RenderPass`es for issuing draw commands
///    |        to, and reports the frame health when complete.
///    V
/// [ RenderPass ] - Represents a render pass in a frame, consisting of
///   :              one or more `Step`s applied to the same target(s),
/// [ Step ] - - - - each describing the input buffers and textures and
///   :              the vertex/fragment functions and geometry to use.
///   :_ _ _ _ _ _ _ _ _ _/
///   v
/// [ Pipeline ] - Describes a vertex and fragment function to be used
///                for a `Step`; the `GraphicsAPI` is responsible for
///                these and they should be constructed and cached
///                ahead of time.
```

泛型入口是 `pub fn Renderer(comptime GraphicsAPI: type) type`（`src/renderer/generic.zig:83`）。

### 两个后端目录的对称文件集

`metal/` 与 `opengl/` 共有 8 个同名文件：`buffer.zig`、`Frame.zig`、`Pipeline.zig`、`RenderPass.zig`、`Sampler.zig`、`shaders.zig`、`Target.zig`、`Texture.zig`。`metal/` 额外有 `api.zig`（447 行的 Objective-C/Metal 绑定）与 `IOSurfaceLayer.zig`（187 行）；OpenGL 侧没有 `api.zig`，因为 GL 绑定来自外部 Zig 依赖 `@import("opengl")`（`src/renderer/OpenGL.zig:7`）。

两个 `Frame.zig` 的差异最能说明后端间的取舍：

- Metal 版持有 `MTLCommandBuffer` 与一个完成回调 block（`src/renderer/metal/Frame.zig:24-28`）。
- OpenGL 版只有 `renderer` 与 `target` 两个指针，`Options` 是空结构体，`begin()` 不发任何 API 调用（`src/renderer/opengl/Frame.zig:18-38`）。

由此得出 `swap_chain_count`：Metal = 3（三重缓冲，`src/renderer/Metal.zig:36-37`），OpenGL = 1，注释解释「OpenGL 的帧完成永远是同步的，不需要多缓冲」（`src/renderer/OpenGL.zig:30-32`）。OpenGL 后端要求至少 4.3（`src/renderer/OpenGL.zig:36-38`）。

## 渲染线程

### 定时器与常量

`DRAW_INTERVAL = 8`（注释标 120 FPS）、`CURSOR_BLINK_INTERVAL = 600`（`src/renderer/Thread.zig:21-22`）。信箱是 `BlockingQueue(rendererpkg.Message, 64)`（`src/renderer/Thread.zig:37`）。

线程结构里有多组 xev 原语，其中两个定时器要分清：

- `render_h` —— 重建帧数据。
- `draw_h` —— 只重绘。注释说明 draw 调用不更新终端状态所以便宜得多，用于动画，且在终端未聚焦时暂停（`src/renderer/Thread.zig:60-65`）。
- `draw_now` —— 不合并的立即绘制（`src/renderer/Thread.zig:67-70`）。

### 一次 render 回调

1. `renderCallback` 先查 `flags.visible`，不可见直接 `.disarm`，注释说等 `.visible` 消息翻回来再补（`src/renderer/Thread.zig:646-648`）。
2. 调 `renderer.updateFrame(state, cursor_blink_visible)`（`src/renderer/Thread.zig:651-655`）。
3. 调 `t.drawFrame(false)`（`src/renderer/Thread.zig:658`）。

### must_draw_from_app_thread（GTK 例外）

`must_draw_from_app_thread` 是 duck-typing 检测：`apprt.App` 若声明该 decl 就取其值，否则为 `false`（`src/renderer/Thread.zig:28-32`）。唯一声明者是 GTK，注释写明原因是 GTK 的 `GLArea` 不支持从其它线程绘制（`src/apprt/gtk/App.zig:21-24`）。

线程侧的 `drawFrame` 有三条分支（`src/renderer/Thread.zig:527-544`）：

1. `!self.flags.visible` → 直接返回。
2. `!now and self.renderer.hasVsync()` → 直接返回，由渲染器/apprt 负责触发 `draw_now`。
3. `must_draw_from_app_thread` 为 `true` → 向 `app_mailbox` 推 `.redraw_surface`；否则直接调 `renderer.drawFrame(false)`。

`hasVsync()` 只在 macOS 且 display link 正在运行时为 `true`（`src/renderer/generic.zig:1009-1013`，非 macOS 上 `DisplayLink == void` 直接返回 `false`，见 `src/renderer/generic.zig:41-44`）。

## 渲染器与终端状态的接口

### renderer.State

`State` 的 mutex 保护的是成员值（`terminal`、inspector 等）而不是 `State` 本身，`State` 本身不是线程安全的（`src/renderer/State.zig:13-17`）。字段有 `terminal` / `inspector` / `preedit` / `mouse`（`src/renderer/State.zig:19-34`）。

比较特别的是让渡机制：`demand` 与 `handoff_gen` 两个原子量配合 `lockDemand` / `unlockDemand` / `yieldToDemand`，超时 `handoff_timeout_ns = 1ms`（`src/renderer/State.zig:36-52`）。注释解释得很直接：`std.Thread.Mutex` 与 os_unfair_lock 都是不公平锁，持续 pty 输出下 IO 解析线程的热循环会把渲染线程饿死（`src/renderer/State.zig:61-66`）。所以 `updateFrame` 的临界区用的是 `state.lockDemand` 而非直接锁 mutex（`src/renderer/generic.zig:1193-1194`）。

### Options 与 message

`renderer.Options` 六个字段：`config`（DerivedConfig）、`font_grid`、`size`、`surface_mailbox`、`rt_surface`、`thread`（`src/renderer/Options.zig:7-24`）。

可发给渲染线程的消息共 11 种：`crash` / `focus` / `visible` / `reset_cursor_blink` / `font_grid` / `resize` / `change_config` / `search_viewport_matches` / `search_selected_match` / `inspector` / `macos_display_id`（`src/renderer/message.zig:10-68`）。其中 `font_grid` 同时带 `new_key` 与 `old_key`，注释说明换 grid 失败时要保留旧 grid 但仍需 deref 新 key（`src/renderer/message.zig:31-43`）。

### size.zig 的一组概念

- **`Size`** —— `screen` + `cell` + `padding` 三部分；`grid()` 是「屏幕尺寸减 padding 再除以单元格尺寸」（`src/renderer/size.zig:28-38`）。
- **`Coordinate`** —— surface / terminal / grid 三套坐标系的 tagged union，注释逐条写清原点与单位（`src/renderer/size.zig:89-107`）；转换统一先转 surface 再转目标，注释说是为了避免组合爆炸（`src/renderer/size.zig:114-125`）。
- **`CellSize` / `ScreenSize` / `GridSize` / `Padding`** —— 四个 extern struct，分别定义在 `src/renderer/size.zig:186`、`:194`、`:238`、`:271`。
- **`PaddingBalance`** —— 三态 `false` / `true` / `equal`；`true` 会把顶部 padding 上限设为「水平 padding 之和加一个单元格宽度的一半」，超出部分挪到底部（`src/renderer/size.zig:8-18`、`:64-77`）。

组装点在 Surface 侧：`screen` 取自 `rt_surface.getSize()`，`cell` 取自 `font_grid.cellSize()`，padding 按 `window_padding_balance` 决定走不走 `balancePadding`（`src/Surface.zig:527-552`）。

## 一帧是怎么产生的

### updateFrame：抓终端状态快照

1. 一进来就 `defer self.font_shaper.endFrame()`，注释说明 CoreText 整形会在一帧内累积待释放对象，即使重建失败也必须冲刷（`src/renderer/generic.zig:1149-1152`）。
2. 每 100000 帧（注释算作 120Hz 下约 12 分钟）整体 deinit 并重置 `terminal_state`，避免长期保留过大内存（`src/renderer/generic.zig:1154-1165`）。
3. 临界区用 `state.lockDemand` 进入（`src/renderer/generic.zig:1193-1194`）。
4. 处于 `synchronized_output` 模式时整帧直接 return（`src/renderer/generic.zig:1196-1200`）。
5. `scroll_to_bottom_on_output`：比较屏幕右下角 pin 的 node 指针与 y 有没有变，变了就 `scrollViewport(.bottom)`（`src/renderer/generic.zig:1202-1220`）。
6. `terminal_state.beginUpdate`，注释说明不需要访问终端的工作（如 style 反规范化）被推迟到临界区外的 `endUpdate`，以缩短持锁时间（`src/renderer/generic.zig:1222-1230`）。
7. 临界区里还取出 scrollbar 与 preedit 副本（`src/renderer/generic.zig:1238-1249`）。
8. Kitty 图片状态变更时进入注释明写 "SLOW SLOW SLOW" 的路径，只在 dirty 时进入；存在虚拟引用时每帧都要重建（`src/renderer/generic.zig:1251-1263`）。

临界区最后再取 OSC8 悬停链接（注释说明这一步需要终端状态，因为要看 URL）与 inspector 的 overlay 特性，然后 `break :critical` 出块（`src/renderer/generic.zig:1273-1307`）。

出临界区后依次是：`terminal_state.endUpdate()` 补完临界区内推迟的工作，注释强调必须在任何人读 render state（例如 `rebuildCells`）之前做（`src/renderer/generic.zig:1309-1312`）→ `config.links.renderCellMap` 把正则结果写进链接（`:1314-1324`）→ 搜索高亮的清除与重建，注释说明加入顺序决定优先级（`:1326-1371`）→ 本函数自己的 `errdefer comptime unreachable`（`:1373-1374`）→ `rebuildOverlay`（`:1381`）→ 持 `draw_mutex` 调 `rebuildCells`（`:1392-1396`）→ `images.overlayUpdate` 与 `updateCustomShaderUniformsFromState`（`:1442-1450`）。`updateFrame` 到 `:1452` 结束，`drawFrame` 是另一个函数（`:1458`）。

### rebuildCells：从状态到单元格

- 网格尺寸变化时 `cells.resize` 并同步 `uniforms.grid_size`（`src/renderer/generic.zig:2328-2341`）。
- `state.dirty == .full` 或尺寸变化触发全量重建并 `cells.reset()`，否则走按行 dirty 的增量路径（`src/renderer/generic.zig:2343-2346`）。
- `padding_color` 为 `.extend` / `.extend-always` 时先假定四向都延伸，后续再按启发式收回（`src/renderer/generic.zig:2348-2362`）。
- 从某一点起写了 `errdefer comptime unreachable`，注释是「从这里开始永不失败，即使不正确也要产出一个能用的终端画面」（`src/renderer/generic.zig:2365-2367`）。

逐行走 `rebuildRow`（`src/renderer/generic.zig:2615`），装饰线与字形分别走 `addUnderline`（`:3064`）、`addOverline`（`:3105`）、`addStrikethrough`（`:3136`）、`addGlyph`（`:3167`）、`addCursor`（`:3229`）、`addPreeditCell`（`:3318`）。

### drawFrame：发 draw call

1. 先拿 `draw_mutex`，注释说是为了防止绘制期间数据被改（`src/renderer/generic.zig:1462-1465`）。
2. `needs_redraw` 判据是「尺寸变化 or `cells_rebuilt` or `hasAnimations()` or `sync`」；不满足时只调 `api.presentLastTarget()` 重呈上一帧，因为 apprt 可能在交换缓冲（`src/renderer/generic.zig:1489-1508`）。`hasAnimations()` 就是 `has_custom_shaders`（`src/renderer/generic.zig:1002-1004`）。
3. `swap_chain.nextFrame()` 等一个可用帧槽（`src/renderer/generic.zig:1511`）。`SwapChain` 用 `buf_count = GraphicsAPI.swap_chain_count` 个 `FrameState`，靠 `std.Io.Semaphore` 控制在飞帧数（`src/renderer/generic.zig:246-260`）。
4. 同步 uniforms / bg cells / fg cells，其中 `fg_count` 就是后面文本绘制的 instance 数（`src/renderer/generic.zig:1576-1579`）。
5. 图集纹理按 `atlas.modified` 原子计数增量同步，只有大于上次记录才在持 `font_grid.lock` 共享锁的情况下调 `syncAtlasTexture`，grayscale 与 color 两张分别处理（`src/renderer/generic.zig:1588-1604`）。
6. 主 render pass 里的固定绘制顺序（`src/renderer/generic.zig:1610-1708`）：背景图（有则一并画主背景色）或纯背景色 → `kitty_below_bg` → cell 背景 → `kitty_below_text` → 文本 → `kitty_above_text` → 调试 overlay。注释特别说明背景色不用 `clear_color` 画，因为那样需要在 CPU 侧做色彩空间转换（`src/renderer/generic.zig:1626-1629`）。
7. 有自定义 shader 时，每个 post pipeline 一个 pass，前 N-1 个画到 `front_texture`、最后一个画到真正的 `frame.target`，每轮结束 `state.swap()`（`src/renderer/generic.zig:1711-1738`）。

## 单元格数据与辅助模块

- **`cell.zig`** —— `Key` 五种内容 bg / text / underline / strikethrough / overline，`bg` 映射到 `shaderpkg.CellBg`，其余四种都映射到 `shaderpkg.CellText`（`src/renderer/cell.zig:12-31`）。`Contents` 用一维 `bg_cells`（索引 `row * columns + col`）加按行分桶的 `fg_rows`，注释说明这个结构是为了能按行清除 GPU 数据、配合按行 dirty 追踪（`src/renderer/cell.zig:33-50`）。`fg_rows` 索引是 `y + 1`，第 0 个列表留给光标，因为光标必须是缓冲区里的第一项（`src/renderer/cell.zig:67-69`）。
- **`row.zig`** —— `neverExtendBg` 的启发式：语义提示行（`prompt` / `prompt_continuation`）不延伸；任何单元格背景等于默认背景则不延伸；powerline 码点 `0xE0B0..0xE0C8`、`0xE0CA`、`0xE0CC..0xE0D2`、`0xE0D4` 因为是精确贴合的所以不延伸（`src/renderer/row.zig:8-62`）。
- **`cursor.zig`** —— 渲染器的光标样式是终端样式的超集：终端侧是 `bar` / `block` / `underline` / `block_hollow` 四种（`src/terminal/cursor.zig:9-25`），渲染器在此之上只多一个用于密码输入的 `lock`（`src/renderer/cursor.zig:4-26`）。注意文件头注释举的例子是 hollow block，但那个样式终端侧本来就有。`style()` 的优先级顺序有注释说明：不在视口内不画 → preedit 时强制 block → 密码输入时 lock → 终端模式隐藏则不画 → 未聚焦时 `block_hollow`（`src/renderer/cursor.zig:40-60`）。
- **`link.zig`** —— `Link` 持一个 oniguruma 正则加高亮条件（`always` / `always_mods` / `hover` / `hover_mods`），`Set.fromConfig` 从配置构造（`src/renderer/link.zig:13-50`）。它作为渲染器 DerivedConfig 的 `links` 字段落地（`src/renderer/generic.zig:574`、构造点 `:609`）。
- **`image.zig`** —— `State` 管 `images` 映射、`kitty_placements`、`overlay_placements`，并用 `kitty_bg_end` / `kitty_text_end` 两个下标把 kitty 放置切成三段（`src/renderer/image.zig:19-47`）。`DrawPlacements` 四个绘制区带 `kitty_below_bg` / `kitty_below_text` / `kitty_above_text` / `overlay`，`draw()` 按区带取对应切片（`src/renderer/image.zig:94-117`）。
- **`Overlay.zig`** —— 调试覆盖层全部用 z2d 在 CPU 上画，再通过 `renderer.image.State` 当成一张图片合成上去；文件头解释理由是覆盖层不常用、z2d 够快、且省去为每个平台写 shader（`src/renderer/Overlay.zig:1-13`）。可用特性只有 `highlight_hyperlinks` 与 `semantic_prompts`（`src/renderer/Overlay.zig:70-73`），配色是硬编码的三种（`src/renderer/Overlay.zig:28-39`）。

## 着色器

### 内置着色器

Metal 侧是单文件 `src/renderer/shaders/shaders.metal`（853 行）。开头是 `Uniforms` 结构（projection matrix、screen/cell/grid 尺寸、`padding_extend`、`min_contrast`、光标位置与颜色、`use_display_p3` 等，`src/renderer/shaders/shaders.metal:12-27`），紧接着是硬编码的 D50 适配 sRGB→XYZ 与 XYZ→Display P3 两个矩阵，复合成 sRGB→Display P3；注释留了 TODO 说这个矩阵应该动态计算并作为 uniform 传入（`src/renderer/shaders/shaders.metal:34-58`）。

构建期链路：

1. `MetallibStep` 通过 `RunStep` 调 `/usr/bin/xcrun -sdk macosx metal` 把 `.metal` 编成 `.ir` 再打包成 `.metallib`；非 macOS 目标 `create()` 直接返回 `null`（`src/build/MetallibStep.zig:24-50`）。
2. 产物以匿名 import `ghostty_metallib` 注入模块，仅在 Darwin 目标下进行（`src/build/SharedDeps.zig:498-506`）。
3. 运行期通过 `@embedFile("ghostty_metallib")` 读回来建 `MTLLibrary`（`src/renderer/metal/shaders.zig:332-336`）。

OpenGL 侧是 `src/renderer/shaders/glsl/` 下 10 个文件，按 pipeline 成对引用。五条内置 pipeline 是 `bg_color` / `cell_bg` / `cell_text` / `image` / `bg_image`，各自指定顶点与片元文件（`src/renderer/opengl/shaders.zig:10-43`）。`loadShaderCode` 用 `@embedFile` 读取后再跑自实现的 `processIncludes` 把 `#include` comptime 展开（`src/renderer/opengl/shaders.zig:341-343`、`:346-369`），这是 `common.glsl` 能被复用的原因。Metal 侧是同名的五条 pipeline，只是把 GLSL 文件名换成 metallib 里的函数名，例如 `bg_color` 用 `full_screen_vertex` + `bg_color_fragment`（`src/renderer/metal/shaders.zig:13-46`）。

### 自定义 shader（shadertoy）

`Uniforms` 是 shadertoy 风格 uniform 的超集：`iResolution` / `iTime` / `iTimeDelta` / `iFrameRate` / `iFrame` / `iChannelTime` / `iChannelResolution` / `iMouse` / `iDate` / `iSampleRate`，外加 Ghostty 扩展的当前与上一个光标位置、颜色、样式、`cursor_visible`、`cursor_change_time`、`time_focus`、`focus`、256 色调色板以及前景背景与选区颜色（`src/renderer/shadertoy.zig:13-42`）。GLSL 侧的对照声明在 `src/renderer/shaders/shadertoy_prefix.glsl:1-13`，以 `#version 430 core` 开头，把这些量放进一个 `binding = 1` 的 std140 `Globals` block。

目标语言只有两个：`glsl` / `msl`（`src/renderer/shadertoy.zig:45`），由后端各自声明，同时声明 fragCoord 的 Y 轴朝向差异——Metal 是 `+Y = down`（`src/renderer/Metal.zig:32-34`），OpenGL 是 `+Y = up`（`src/renderer/OpenGL.zig:26-28`）。

转译链路在 `loadFromFile`（`src/renderer/shadertoy.zig:80-132`）：读文件（上限 4MB）→ `glslFromShader` 拼 prefix 成完整 GLSL → `spirvFromGlsl` 编成 SPIR-V（注释说明 SPIR-V 指针必须按 4 字节对齐，因为要当作 word 切片）→ 再转目标语言。glslang 与 spirv-cross 直接 `@import`（`src/renderer/shadertoy.zig:5-6`），且它们的 `systemIntegrationOption` 默认为 `false`，注释说明因为很少作为系统包提供，所以通常静态链接（`src/build/Config.zig:548-556`）。

## src/font：字体栈

链路一句话：`SharedGridSet` →（按配置 key 复用）`SharedGrid` → `CodepointResolver` → `Collection` → `DeferredFace` → `Face` → `Glyph` → `Atlas`。导出面见 `src/font/main.zig:7-31`。`Style` 是 4 值 `enum(u3)`，`Presentation` 是 `enum(u1)`（`src/font/main.zig:53-65`）。

### Collection

文件头自述：按 style 分组、组内按优先级排序，同一 collection 内所有字体共享尺寸以便互换；Collection 不负责查找回调与光栅化，那是 CodepointResolver 的事；可同时存放已加载与延迟加载的 face，后者用于高效判断码点支持而不必完整加载字体（`src/font/Collection.zig:1-15`）。

`Index` 是 16 位 packed struct，`idx_bits` 由「backing 位宽减去 `Style` 的 tag 位宽」算出；`Style` 是 `enum(u3)`（`src/font/main.zig:54`），所以 style 占 3 位、idx 占 13 位，注释说明每 style 最多 8192 个字体（`src/font/Collection.zig:883-898`）。`Special.sprite` 从 idx 的最大值开始，`special()` 靠 `idx >= Special.start` 判断（`src/font/Collection.zig:900-928`）；`font.sprite_index` 就是 `Collection.Index.initSpecial(.sprite)`（`src/font/main.zig:68`）。

### CodepointResolver

自述：把码点映射到字体，比 Collection 更动态，支持把码点范围映射到指定字体、搜索 fallback 字体（`src/font/CodepointResolver.zig:1-11`）。字段有 `collection`（拥有所有权）、`styles`、`discover`（可空）、`codepoint_map`（可空，内存由调用方拥有）、`descriptor_cache`、`sprite`（`src/font/CodepointResolver.zig:33-59`）。`sprite` 不设的话注释说「终端渲染大概率是错的」（`src/font/CodepointResolver.zig:55-59`）。

### SharedGrid / SharedGridSet

文件头明确写了 `SharedGrid` **不支持** resize、换字体族、从 collection 移除 face——因为共享意味着改一个 surface 会影响所有 surface；配置变更的正确做法是重新初始化一个 grid 并让所有 surface 切换过去（`src/font/SharedGrid.zig:1-18`）。

内部结构：两级缓存（`codepoints`: 码点 → `Collection.Index`，`glyphs`: `GlyphKey` → `Render`）、两张图集 `atlas_grayscale` / `atlas_color`、一个 `CodepointResolver`、一份 `Metrics`，以及一把 `std.Io.RwLock`（`src/font/SharedGrid.zig:41-64`）。两张图集初始尺寸都是 512，格式分别 `.grayscale` 与 `.bgra`；`codepoints` 初始容量 128，注释说是按作者自己的终端使用经验取的经验值（`src/font/SharedGrid.zig:92-108`）。公开 API 是 `cellSize`（`:143`）、`getIndex`（`:156`）、`hasCodepoint`（`:201`）、`renderCodepoint`（`:224`）、`renderGlyph`（`:379`）。

`SharedGridSet` 按唯一字体配置为 key 存放一组 `SharedGrid`，自述理由是大多数 surface 字体配置相同，共享可以复用字体图集、字形缓存、字体面等昂贵资源（`src/font/SharedGridSet.zig:1-9`）。它持有 `map`、`font_lib`、可选 `font_discover` 与一把保护 map 的 `std.Io.Mutex`（`src/font/SharedGridSet.zig:35-48`）。整个 App 只有一份（`src/App.zig:53-55`），Surface 创建时 `ref` 取出 `(key, grid)`（`src/Surface.zig:522-525`）。

### Atlas

实现基于 Jukka Jylänki 的《A Thousand Ways to Pack the Bin》二维矩形装箱论文，参考 Nicolas P. Rougier 的 freetype-gl 与 Jukka 的 RectangleBinPack；文件头列了两条已知限制：写入数据必须紧凑（不支持自定义 stride）、纹理必须是正方形（`src/font/Atlas.zig:1-15`）。

`modified` 与 `resized` 两个原子计数器就是渲染器判断「要不要重传纹理 / 能不能原地更新」的依据（`src/font/Atlas.zig:42-51`，消费点 `src/renderer/generic.zig:1588-1604`）。`Format` 三种：`grayscale`（1 字节/像素）、`bgr`（3）、`bgra`（4）（`src/font/Atlas.zig:53-68`）。

### Metrics

一个 `Metrics` 就是一套网格尺寸：`cell_width` / `cell_height` / `cell_baseline`、下划线、删除线、上划线（position 可为负）、`box_thickness`、`cursor_thickness`（默认 1，注释说这个由用户配置而非字体决定）、`cursor_height`、`icon_height`、`face_width` / `face_height` / `face_y`（`src/font/Metrics.zig:6-54`）。`Minimums` 给各类线宽设了最小值，注释说是为了防止用户 modifier 把下划线压成 0 厚度（`src/font/Metrics.zig:56-71`）。`FaceMetrics` 是从字体元数据表和字形测量中提取的原始量（`src/font/Metrics.zig:73-75`）。

`calc()` 把 face 指标折成整数像素网格，`cell_width` 与 `cell_height` 都用 `@round` 而非 ceil。注释解释这样与「真实」宽度的偏差不超过 0.5px，更贴近字体作者意图，且高低 DPI 下间距表现更一致；代价是无边距字形可能溢出一个像素，注释建议用户加 `adjust-cell-height` 配置解决（`src/font/Metrics.zig:236-266`）。用户 `adjust-*` 类配置的落点是 `apply(mods)` 与 `ModifierSet`（`src/font/Metrics.zig:337`、`:448`）。

## face 后端 × shaper 后端：正交组合

`font_backend` 有 8 个取值，每个都带注释说明谁负责发现、谁负责光栅化、谁负责整形（`src/font/backend.zig:3-34`）：`freetype`、`freetype_windows`、`fontconfig_freetype`、`coretext`、`coretext_freetype`、`coretext_harfbuzz`、`coretext_noshape`、`web_canvas`。

四张 comptime 分派表：

| 维度                | 分派位置                       |
| ------------------- | ------------------------------ |
| Face（光栅化）      | `src/font/face.zig:11-24`      |
| Shaper（整形）      | `src/font/shape.zig:20-36`     |
| Discover（发现）    | `src/font/discovery.zig:20-30` |
| Library（进程状态） | `src/font/library.zig:10-24`   |

几处值得记住的约束：

- `coretext_freetype` 不能用 CoreText shaper，注释原话是「coretext shaper requests CoreText font faces」（`src/font/shape.zig:28-30`）。
- `freetype` 与 `web_canvas` 的 `Discover` 是 `void`，即无发现能力（`src/font/discovery.zig:21`、`:24`）。
- Library 只有 freetype 系需要 `FreetypeLibrary`，CoreText 与 web_canvas 用 `NoopLibrary`（`src/font/library.zig:10-24`）。
- 便捷谓词 `hasFreetype` / `hasCoretext` / `hasFontconfig` / `hasHarfbuzz` 既可 comptime 也可运行时调用（`src/font/backend.zig:63-127`）。
- 默认 DPI：macOS 为 72，其余为 96（`src/font/face.zig:26-29`）。

### 默认值与构建选项

| 构建选项         | 定义位置                       | 默认值来源                                                    |
| ---------------- | ------------------------------ | ------------------------------------------------------------- |
| `-Dfont-backend` | `src/build/Config.zig:168-172` | `FontBackend.default`（`src/font/backend.zig:39-61`）         |
| `-Drenderer`     | `src/build/Config.zig:180-184` | `RendererBackend.default`（`src/renderer/backend.zig:10-22`） |

`font_backend` 默认：wasm32 + browser → `web_canvas`；Windows → `freetype_windows`（注释说明是为了避开 fontconfig，因为它依赖的 libxml2 可能因符号链接无法解包）；Darwin → `coretext`；其余 → `fontconfig_freetype`。注释还补了一句：macOS 也支持 `coretext_freetype`，但只留给偏好 freetype 观感的自编译用户（`src/font/backend.zig:49-60`）。

`Config` 结构体的字段初值 `renderer = .opengl` / `font_backend = .freetype` 只是占位，实际取值总是被 `default()` 覆盖（`src/build/Config.zig:26-28`）。两者都通过 `step.addOption` 写进 build_options 供运行期代码读取（`src/build/Config.zig:622-623`），字体侧读取点在 `src/font/main.zig:44-51`——注意 wasm 目标下会强制为 `.web_canvas`，注释指出这是因为 build.zig 目前在所有 exe 之间共享同一份 build config。

这两个选项的实际使用方式见 [preview-manual.md](preview-manual.md)。

## 整形与缓存

- `Shaper` 接口层：`Cell` 只包含 `x` / `x_offset` / `y_offset` / `glyph_index`，注释说明并非所有终端单元格都会出现，只有需要渲染字形的才有（`src/font/shape.zig:38-58`）；`Options.features` 是全局字体特性（`src/font/shape.zig:60-68`）；`RunOptions` 含 `grid`（可变，因为整形过程中缓存值会更新）、`cells`、`selection`、`cursor_x`，后者用于在光标处打断整形，可通过 `font-shaping-break` 配置关闭（`src/font/shape.zig:70-93`）。
- `TextRun` 永不跨行，因此保证总在一行内；它自带一个位置无关的 hash（用相对 cluster 位置计算）供缓存复用，注释承认哈希冲突会导致渲染问题但核心数据仍正确（`src/font/shaper/run.zig:10-38`）。`RunIterator` 会先裁掉行尾的空单元格，再跳过带 `invisible` 样式的单元格（`src/font/shaper/run.zig:53-67`）。
- `Cache.zig` 的存在理由写在文件头：整形曾是渲染文本中最贵的部分，在作者机器上占帧时间的 96%（`src/font/shaper/Cache.zig:1-10`）。渲染器持有 `font_shaper_cache`，换 grid 时整体丢弃重建（`src/renderer/generic.zig:1111-1116`）。
- 默认启用的 OpenType 特性只有一个 `liga`（`src/font/shaper/feature.zig:285-289`）。
- 两个真实 shaper 的规模：harfbuzz 2236 行 / coretext 2679 行。CoreText shaper 的文件头注释承认它与 HarfBuzz 有细微差异、可能导致跨平台渲染不一致，但也修复了很多问题（`src/font/shaper/coretext.zig:27-31`）。

## sprite、Nerd Font 与 opentype

- **`sprite.zig`** —— sprite 码点从 `std.math.maxInt(u21) + 1` 起，放在 U+10FFFF 之上。注释说明这些码点仅用于渲染、绝不写入文本文件或任何导出格式，所以没有使用 Unicode 私有使用区（`src/font/sprite.zig:10-19`）。枚举含五种下划线、删除线、上划线与四种光标形状（`src/font/sprite.zig:22-35`）。
- **`sprite/Face.zig`** —— 文件头说它「不是真的字体面，但像字体面一样呱呱叫」，这样 GroupCache、Shaper 等上层就不需要感知 sprite 的特殊处理（`src/font/sprite/Face.zig:1-12`）。`DrawFn` 签名是 `fn(cp, canvas, width, height, metrics)`，错误类型是 `Allocator.Error` 加 z2d 的 Path/Fill/Stroke 错误再加 `MathError`（`src/font/sprite/Face.zig:30-47`）。
- **`sprite/draw/`** —— 特殊目录，`Face.zig` 扫描其中形如 `draw<CODEPOINT>` 或 `draw<MIN>_<MAX>`（大写十六进制）的 pub 函数来分派绘制。README 明确警告新增文件必须手动在 `Face.zig` 里加 import，作者试过动态列目录但代价太大（`src/font/sprite/draw/README.md:1-12`）。目录下现有 `block.zig`、`box.zig`、`braille.zig`、`branch.zig`、`common.zig`、`geometric_shapes.zig`、`powerline.zig`、`special.zig`、`symbols_for_legacy_computing.zig`、`symbols_for_legacy_computing_supplement.zig`。
- **`nerd_font_attributes.zig`** —— `nerd_font_codegen.py` 生成的 2774 行表，文件头写明 DO NOT EDIT BY HAND；`getConstraint(cp)` 返回 `Glyph.RenderOptions.Constraint`（`src/font/nerd_font_attributes.zig:1-10`），渲染器直接 import 它（`src/renderer/generic.zig:32`）。
- **`opentype.zig`** —— 导出 SVG / OS2 / Post / Hhea / Head / Glyf 六张表的解析器（`src/font/opentype.zig:1-15`）。`glyf_rasterize.zig` 用 z2d 光栅化 glyf 轮廓，文件头解释它刻意放在 `font/` 而不是 `font/opentype/`，是为了让后者保持对 font 包零依赖（`src/font/glyf_rasterize.zig:1-5`）。
- **`embedded.zig`** —— 内置 JetBrains Mono 可变字体（正体与斜体）、symbols-only Nerd Font、`NotoColorEmoji.ttf` 与 `NotoEmoji-Regular.ttf`，文件头说明只有被代码引用的字体才会真的进入二进制（`src/font/embedded.zig:1-23`）。
- **`DeferredFace.zig`** —— 延迟保存加载一个字体面所需的全部信息，这样可以持有很多 fallback 字体用于查找字形而只在真正需要时才载入（`src/font/DeferredFace.zig:1-6`）。用四个 comptime 条件字段承载不同发现后端的描述符：`fc` / `ct` / `win` / `wc`（`src/font/DeferredFace.zig:21-35`）。
- **`Glyph.zig`** —— 记录单个字形的 `width` / `height` / `offset_x`（左边距）/ `offset_y`（上边距）以及图集中左上角坐标 `atlas_x` / `atlas_y`；注释说明这两个坐标在给 shader 用之前需要归一化到 0..1（`src/font/Glyph.zig:1-22`）。
- **`CodepointMap.zig`** —— 码点范围 → 字体发现描述符的用户级覆盖，描述符匹配不到字体则该码点回落到默认字体（`src/font/CodepointMap.zig:1-4`）。

## 常见坑 / 注意事项

1. **Debug 构建渲染极慢。** 程序启动时自己打三行警告（`src/main_ghostty.zig:61-65`）。跑 benchmark 必须 `-Doptimize=ReleaseFast`，`src/benchmark/AGENTS.md:34-38` 重复强调了这一点。命令细节见 [preview-manual.md](preview-manual.md)。
2. **`-Drenderer` 的帮助文本是错的。** `src/build/Config.zig:183` 写成 `"The app runtime to use. Not all values supported on all platforms."`，与 `-Dapp-runtime`（`:177`）完全重复。别被它误导，取值来自 `RendererBackend`。
3. **`SharedGrid` 不能 resize。** 改字号/字体族必须重建 grid 并让所有 surface 切换（`src/font/SharedGrid.zig:12-18`），对应的 `font_grid` 消息带新旧两个 key（`src/renderer/message.zig:31-43`），接收端 `setFontGrid` 会清零所有 frame 的纹理修改计数、丢弃 shaper 缓存并 `markDirty()` 强制全量重建（`src/renderer/generic.zig:1091-1131`）。
4. **改 GTK 相关渲染代码要考虑 `must_draw_from_app_thread`。** GTK 下 `drawFrame` 不在渲染线程里跑（`src/renderer/Thread.zig:535-543`、`src/apprt/gtk/App.zig:21-24`）。
5. **`rebuildCells` 里 `errdefer comptime unreachable` 之后不能引入可失败调用**（`src/renderer/generic.zig:2365-2367`），否则编译期就会炸。
6. **Kitty 图片是慢路径。** 注释里直接写了 "SLOW SLOW SLOW"，只有 dirty 或存在虚拟引用时才走（`src/renderer/generic.zig:1251-1258`）。
7. **新增 sprite 绘制文件必须手动加 import**，否则不会被扫描到（`src/font/sprite/draw/README.md:7-12`）。
8. **`nerd_font_attributes.zig` 是生成文件，禁止手改**（`src/font/nerd_font_attributes.zig:1-2`）。
9. **WebGL 后端目前只是 2 行占位**（`src/renderer/WebGL.zig:1-2`），不要按「三个可用后端」来理解。
10. **`src/renderer.zig:34` 的 `@import("lib/main.zig")` 解析到的是 `src/lib/main.zig`**，不是 `src/renderer/lib/main.zig`（后者不存在）。它用于 `Health` 枚举与 `ghostty.h` 的一致性测试（`src/renderer.zig:44-54`）。

## 延伸阅读

- [../AGENTS.md](../AGENTS.md)（根目录 `CLAUDE.md` 是指向它的符号链接）
- [../HACKING.md](../HACKING.md)
- [../src/benchmark/AGENTS.md](../src/benchmark/AGENTS.md)
- [../src/font/sprite/draw/README.md](../src/font/sprite/draw/README.md)
- docs 内：[architecture.md](architecture.md)、[terminal-core.md](terminal-core.md)、[platform-and-config.md](platform-and-config.md)、[preview-manual.md](preview-manual.md)
