# `ghostty_surface_*`：导出了什么，宿主接了什么，剩下的那些是什么

## ⚠️ 这份文件此刻是什么

**一次定性，不是一道闸。** 它把 C 头文件导出的 `ghostty_surface_*` 逐条分了四档，
每条给了出处。**没有任何一条被真机验过**，也**没有任何东西守着这张表**——它明天就可能
过期，而过期的样子和准确的样子一模一样。

⚠️ **故意没有写闸。** 一道闸如果生下来就要配一份 22 行的例外名单，它和没有闸的区别
只是多了一份没人维护的名单。**先定性，定完之后才谈得上守法。**

这一族的起因是 408：`ghostty_surface_refresh` 在头文件里一直都有，**而宿主一个绑定
都没有，也没人发现**。「C API 导出了入口、宿主从来没绑」是一个真实的类，这份表是把
那个类数出来。

---

## 数法（连同它的四个陷阱）

今天的数字，**在 `ac197ec5f` 上数的**：

| | |
|---|---|
| `include/ghostty.h` 导出的 `ghostty_surface_*` | **45** |
| 宿主里能找到符号名字面量的（＝解析过） | **23** |
| **一次都没有出现过的** | **22** |

⚠️ **这个 22 与最早口头传的「25」不同。** 差别在数法，不在树——所以数法写在这里，
比数字重要：

**判定「解析过」= 去掉注释之后，`windows/host/src/**.rs` 里出现精确字面量
`"ghostty_surface_x"`。** 四个陷阱，每一个都会把数字推向不同方向：

1. ⚠️ **grep 到名字 ≠ 接上了。** `ffi.rs` 里只有一个字段声明、没有任何调用者，也是
   「没绑」。所以每条要分两问：**解析了吗 / 被叫了吗**。
2. ⚠️ **`sym!(` 会跨行。** 我第一版用单行正则 `sym!(internal, "…")` 数，
   **把 `surface_complete_clipboard_request` 判成了「从未绑定」**——它的 `sym!` 写成
   了三行。⇒ 漏判的方向是**把已绑说成没绑**，也就是把这张表撑大。
3. ⚠️ **不是所有绑定都走 `ffi::Api`。** `surface_key_is_binding` 是
   `GetProcAddress` + 懒解析（故意不进 `Api`：`Api` 用 `sym!` 加载，缺符号就中止启动，
   而这一条只是个诊断，旧 DLL 应当仍能启动）。只认 `Api` 表的数法会漏掉它。
4. ⚠️ **绑了也可能等于没绑。** 见下面「已解析，但只在实验开关后面」。

**第三问的结论无法只靠正则得出**：`key_is_binding` 的调用点在
`key_is_binding_fn()` 的调用者那里，正则找不到。这几条是人读出来的。

---

## 已解析，但只在实验开关后面（1 条）

- **`ghostty_surface_draw`** —— 唯一的调用点在 `if crate::draw_on_paint()` 里面，
  也就是 `--draw-on-paint`。⚠️ **出货构建里等于没有。** 头文件原文：

  > `GHOSTTY_API void ghostty_surface_draw(ghostty_surface_t);`

  `ffi.rs` 自己写着为什么：`surface_refresh` 排一次渲染（`refreshCallback` →
  `queueRender`），`surface_draw` 在调用线程上直接渲染。⭐ **408 的出货路径就是这么
  被吞掉的**：躲在实验开关后面的调用，在出货构建里等于没有。

---

## 22 条：四档

出处一律给**头文件原文**和**宿主里的 grep 结果**，不给行号——行号会过期，引文不会。
所有 22 条的宿主侧结果都是同一句：**去掉注释后，`windows/host/src/**.rs` 里 0 处
出现。**

### ① 该绑没绑（有真实用途，只是没人接）—— 4 条

- **`ghostty_surface_set_color_scheme`**
  > `GHOSTTY_API void ghostty_surface_set_color_scheme(ghostty_surface_t, ghostty_color_scheme_e);`

  mac 在 `BaseTerminalController.swift` 里跟着系统外观调用它。**宿主有自己的深浅主题**
  （`theme.rs`，窗口收 `WM_SYSCOLORCHANGE`），**而核心从来没有被告知过**。核心据此
  回答终端程序的配色查询，所以这是「宿主知道、核心不知道」的真缺口。

- **`ghostty_surface_set_occlusion`**
  > `GHOSTTY_API void ghostty_surface_set_occlusion(ghostty_surface_t, bool);`

  mac 在窗口可见性变化时调用。Windows 侧**完全没有这条路**：被完全遮住的窗口照样
  按原速渲染。不是正确性问题，是电和帧的问题。

- **`ghostty_surface_needs_confirm_quit`** / **`ghostty_surface_process_exited`**
  > `GHOSTTY_API bool ghostty_surface_needs_confirm_quit(ghostty_surface_t);`
  > `GHOSTTY_API bool ghostty_surface_process_exited(ghostty_surface_t);`

  这一对是「里面还跑着东西，真要关吗」。mac 在 `SurfaceView_AppKit.swift` 里两条都用。
  宿主里 `grep -i confirm` 在关闭路径上**一处都没有**：关标签直接走
  `Op::ClosePane` → `surface_free`。⇒ **今天关掉一个正在跑东西的标签，不会问。**

### ② 平台无关，但这个宿主用不上 —— 11 条

- **`ghostty_surface_split`** / **`_split_equalize`** / **`_split_focus`** / **`_split_resize`**
  > `GHOSTTY_API void ghostty_surface_split(ghostty_surface_t, ghostty_action_split_direction_e);`
  > `GHOSTTY_API void ghostty_surface_split_equalize(ghostty_surface_t);`
  > `GHOSTTY_API void ghostty_surface_split_focus(ghostty_surface_t, ghostty_action_goto_split_e);`
  > `GHOSTTY_API void ghostty_surface_split_resize(ghostty_surface_t, ghostty_action_resize_split_direction_e, uint16_t);`

  **分屏树在宿主侧**（`polter-split-tree` 加 `tabs.rs`）。核心这四条是给「自己管树的
  apprt」用的；Windows 走的是反方向——核心发 `ACTION_NEW_SPLIT` 等动作，宿主执行。
  ⚠️ 绑上它们不是补一个缺口，而是**造出第二棵树**。

- **`ghostty_surface_app`** / **`ghostty_surface_userdata`**
  > `GHOSTTY_API ghostty_app_t ghostty_surface_app(ghostty_surface_t);`
  > `GHOSTTY_API void* ghostty_surface_userdata(ghostty_surface_t);`

  Swift 用它们从一个 surface 反查回自己的上下文。宿主自己持有 pane↔surface 映射
  （`tabs::surface_of_pane` 那一族），**不需要向核心问它已经知道的事**。

- **`ghostty_surface_size`**
  > `GHOSTTY_API ghostty_surface_size_s ghostty_surface_size(ghostty_surface_t);`

  尺寸的**来源**就是宿主：它算好客户区，用 `surface_set_size` 告诉核心。反过来问一遍
  只会得到自己刚说的话。

- **`ghostty_surface_mouse_pressure`**
  > `GHOSTTY_API void ghostty_surface_mouse_pressure(ghostty_surface_t, uint32_t, double);`

  Force Touch：mac 在 `pressureChange` 事件里调用。**Windows 没有对应的输入**——普通
  鼠标和大多数精确式触控板不报压力级。

- **`ghostty_surface_quicklook_font`** / **`ghostty_surface_quicklook_word`**
  > `GHOSTTY_API void* ghostty_surface_quicklook_font(ghostty_surface_t);`
  > `GHOSTTY_API bool ghostty_surface_quicklook_word(ghostty_surface_t, ghostty_text_s*);`

  macOS Quick Look（三指查词）。**Windows 没有这个系统服务**，而且 `_font` 返回的是
  一个 `NSFont*`。

- **`ghostty_surface_set_display_id`**
  > `GHOSTTY_API void ghostty_surface_set_display_id(ghostty_surface_t, uint32_t);`

  `CGDirectDisplayID`，mac 用来跟随显示器（刷新率/色彩）。Windows 的对应物是
  `HMONITOR`，**不是同一个命名空间**，核心那一侧也没有接受它的入口。

### ③ inspector / 实验 / 上游专有 —— 1 条

- **`ghostty_surface_inspector`**
  > `GHOSTTY_API ghostty_inspector_t ghostty_surface_inspector(ghostty_surface_t);`

  inspector 整族（`ghostty_inspector_*` 另有十来个导出）由上游的 Dear ImGui 面板使用，
  **这个宿主不接**。⚠️ 宿主里已经有两处注释在说同一件事——`main.rs` 和 `palette.rs`
  都写着「以为它在，其实不在」，因为命令面板里曾经列过它。

### ④ 未查 —— 6 条

⚠️ **这一档是有意留着的**：给它一个猜出来的分类，比空着更坏，因为下一个人会把猜的
当成查过的。

- **`ghostty_surface_foreground_pid`**
  > `GHOSTTY_API uint64_t ghostty_surface_foreground_pid(ghostty_surface_t);`

  mac 用它显示前台进程。**Windows 上核心在 ConPTY 之后能不能得到这个值，我没查。**
  用途是真实的（关闭确认、标题），归属取决于那个答案。

- **`ghostty_surface_tty_name`**
  > `GHOSTTY_API ghostty_string_s ghostty_surface_tty_name(ghostty_surface_t);`

  同上：Windows 上没有 `/dev/ttys00X` 这样的东西，但核心在这个平台上返回什么、是否
  返回管道名，**没查**。

- **`ghostty_surface_inherited_config`**
  > `GHOSTTY_API ghostty_surface_config_s ghostty_surface_inherited_config(ghostty_surface_t, ghostty_surface_context_e);`

  mac 用它让新窗口/新标签继承父 surface 的配置。宿主今天自己填 `surface_config_new`
  的字段。**两者重叠多少、`cwd` 之外还有什么没继承到，没查**——⚠️ 410 那条「tab 路径
  丢 cwd」是这一族的症状之一，所以这条值得单独查。

- **`ghostty_surface_key_translation_mods`**
  > `GHOSTTY_API ghostty_input_mods_e ghostty_surface_key_translation_mods(ghostty_surface_t, ghostty_input_mods_e);`

  mac 在按键翻译时用它换算修饰键。Windows 侧有自己的 `keys.rs` 和 TSF 那一套，
  **两边是不是在回答同一个问题，没查。**

- **`ghostty_surface_mouse_captured`**
  > `GHOSTTY_API bool ghostty_surface_mouse_captured(ghostty_surface_t);`

  终端程序是否捕获了鼠标（影响滚轮该发给谁、光标要不要藏）。宿主里 `SetCapture` 的
  用处是分隔线拖拽和标签条，**与这个问题无关**；宿主今天怎么决定滚轮的归属，没查。

- **`ghostty_surface_request_close`**
  > `GHOSTTY_API void ghostty_surface_request_close(ghostty_surface_t);`

  mac 用它请求关闭（走核心的确认逻辑）。宿主今天是**直接** `Op::ClosePane` →
  `surface_free`。⚠️ 这与 ① 里那对确认入口是同一个问题的两半，**但「核心的
  request_close 在 Windows 上会做什么」我没查**，所以放在这里而不是 ①。

---

## 这份表不覆盖什么

- **其它前缀。** `ghostty_app_*`、`ghostty_config_*`、`ghostty_inspector_*` 一个都没数。
  同一个类几乎肯定也在那些前缀里，⚠️ **没数不是没有。**
- **反方向。** 宿主实现了、而核心从来不调的回调，没查。
- **真机。** 上面每一条「用不上」「该绑没绑」都是读代码读出来的，**没有一条在
  Windows 上验过**。
- **上游的意图。** 「mac 这样用」不等于「设计上就该这样用」；这里只报 mac 怎么用。
