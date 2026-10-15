# 判据：整理标签与分屏——只移动，不关掉重开（任务 1571，Windows 真机清单）

这份清单给 Windows 测试员用。要验证的是 1571 在 Windows 宿主上的三件事：

- `terminal_layout` 可以把别的标签、别的窗口里的终端**移**进来；
- `terminal_layout` 可以用 `into` 把形状放进一个新标签或一个新窗口；
- `terminal_tab_move` 可以调整标签的位置，也可以把标签移到另一个窗口；`role_launch` 的 `beside` 会在指定终端所在的标签里开新格。

实现位置：`windows/host/src/tabs.rs` 的 `arrange_layout` 与 `move_tab_for_tool`，`windows/host/src/layout.rs` 的 `parse_envelope` 与 `perform_tab_move`，`windows/host/src/main.rs` 中 tag 82 的分派分支。

⚠️ **这些都还没有在 Windows 真机上跑过。** mac 上只做到交叉编译 `cargo check` / `cargo test --no-run` 和闸全部通过。宿主的单元测试（`the_envelope_says_where_the_shape_goes`）也要上机才能真正执行。mac 宿主的同一组格子已经实测过，读数和截图在 `Polter_Pub/assets/control-room-design/arrange-v1/`，可以作为对照。

## 准备

1. 窗口 W1 里开 3 个标签：标签 1 放总管替身（接 MCP，调 `become_supervisor`）；标签 2 跑计数循环 `cntA`；标签 3 跑计数循环 `cntB`。
2. 另开窗口 W2，里面跑计数循环 `cntC`。
3. 计数循环的写法，PowerShell：`$host.ui.RawUI.WindowTitle='cntA'; $i=0; while($true){$i++; "cntA $i"; sleep 1}`。
4. 用 `terminal_list` 记下四个终端的 id。顺便核对每一行都带 `tab_index` 和 `tab_title`（前者从 0 数起，后者就是标签条上显示的标题）。

**每一格的判据都包含「进程没断」**：移动前后用 `terminal_read` 各读一次计数，移动后的数字必须接着涨。如果数字从 1 重新开始，或者滚动历史没了，就是被关掉又重开了，这一格判红。

## 格子

| # | 调用 | 应当看到 |
|---|---|---|
| ① | `terminal_layout {into:{new_tab_beside:<总管>}, layout:{split:h, left:{pane:cntA}, right:{pane:cntB}}}` | 总管标签右边出现一个新标签，左右两格是 cntA 和 cntB，计数接着涨；原来的标签 2、3 消失；回复的 `moved` 有两项，`from.tab` 是各自原来的标签，`to.tab` 相同 |
| ② | `terminal_layout {id:cntA, layout:{split:h, left:{pane:cntA}, right:{split:v, left:{pane:cntB}, right:{pane:cntC}}}}` | cntC 从 W2 移进来，W2 自动关闭；`moved` 只有 cntC 一项，`from.window` 是 W2，`to.window` 是 W1 |
| ③ | `terminal_layout {into:{new_window:true}, layout:{pane:cntB}}` | 出现一个新窗口，里面只有 cntB，计数接着涨；①里那个标签剩下 cntA 和 cntC |
| ④ | `terminal_layout {into:{new_tab_beside:<总管>}, layout:{stack:[{pane:cntA},{new:null}]}}` | 回 `NotBuiltYet`，什么都没动（这条由核心直接拒绝，不会走到宿主） |
| ⑤ | `terminal_tab_move {id:cntA, index:0}`，再来一次 `index:99` | cntA 所在的标签先到最前，然后到最后；`terminal_list` 的 `tab_index` 和这个一致 |
| ⑥ | `terminal_tab_move {id:cntA, index:0, window:<cntB>}` | cntA 的标签移到 cntB 所在的窗口，排在第一位；如果原窗口因此空了，它会自动关闭 |
| ⑦ | `role_launch {key:<任一角色>, beside:<cntB>}`，连调两次 | 两个新终端都开在 cntB 的标签里（`placed:"split"`），标签总数不变 |
| ⑧ | 在 cntA 里按一个键，紧接着（10 秒内）调一个会移动 cntA 的 layout | 回 `UserPresent`，消息以 cntA 的 id 开头，什么都没动；等 11 秒再调同一个请求就成功（这是对照） |
| ⑨ | 在 cntA 的标签菜单里勾「不让 agent 碰此终端」，然后调一个 layout：`id` 写另一个终端，cntA 只出现在某个格子里 | 回 `Shielded`，什么都没动 |
| ⑩ | 打开总控台，点一个群，让它的总管终端「借给」总控台，然后对这个总管终端调 layout 或 tab_move | 回 `Lent`，什么都没动 |
| ⑪ | 一个 layout 写了某个终端两次，或者漏写目标标签里原有的某一格 | 回 `Refused`，原因写清楚是哪一格；什么都没动，也没有多出空窗口 |

## 任务 1578 补的格子（#1577 真机测出的两点）

| # | 调用 | 应当看到 |
|---|---|---|
| ⑫ | 同 ⑨，被屏蔽的 cntA 只出现在某个格子里 | 回 `Shielded`，**消息以 cntA 的 id 开头**（`0x…: the user has put…`）；`terminal_read` 一个被屏蔽的终端也同样以它的 id 开头 |
| ⑬ | layout 里把 cntA 写两次 | 回 `Refused`，消息是 `the layout names terminal 0x… twice`，里面的 id 就是 cntA 在 terminal_list 里的 id |
| ⑭ | 在 cntA 里切到中文输入法打 `nihao`，**候选框开着先不选字**，然后调一个会移动 cntA 的 layout | 回 `UserPresent`，消息是 `0x…: an input method is composing in that terminal…`，什么都没动 |
| ⑮ | 同 ⑭，但候选框一直开着、不碰键盘等 15 秒再调 | 照样拒绝。组字框开着时，超过 10 秒也算在场 |
| ⑯ | ⑭ 之后选字上屏（或按 Esc 取消），等 11 秒再调 | 成功。这一格是 ⑭ 的对照 |

另有一条保险，真机上不用专门造：组字框开着、但 5 分钟（`Surface.composition_stale_ms`）都没有任何组字更新时，就不再算在场，日志会写 `a composition has been open in this terminal for over 300s with no update`。

## 要特别留意的

- **③ 和 ⑪ 不能留下空窗口。** 新窗口要等所有检查都过了才会创建；一旦被拒，它必须被关掉。
- **② 和 ⑥ 中被移空的窗口必须关掉**，而且下一个窗口要能正常拿到焦点。
- **DPI**：如果 W1 和 W2 在缩放比例不同的两块屏上，移过去的格子字号要跟着目标窗口走（走 `rehome_pane` → `surface_set_content_scale`）。
- 日志里每次排布会有一行 `[layout] arranged; N terminal(s) moved in, M pane(s) made`；标签移动会有 `[tab] moved` 或 `[drag] tab … moved into` 行。
