# 判据：分屏动作作用在**指名的**那一格

**这份文件覆盖 382 那一族四条动作**：`new_split` / `goto_split` / `resize_split` /
`toggle_split_zoom`。它们从前一律作用在**当前有焦点**的那一格，所以一个指名了 pane 的
工具调用会改到别的 pane 上，**而日志说它成功了**。

## 自核：这份判据还适用吗

⚠️ **不要用提交范围判断**（这份文件的第一版就是那么写的：「`git log <提交>..HEAD --
tabs.rs` 为空即可用」）。**那条前提在同族另外三条落地的当天就失效了**，而失效之后它会
把一棵健康的树判成「判据不可用」。**改成按内容核**：

    grep -c 'acting_pane' windows/host/src/tabs.rs        # ≥ 5：一个定义 + 四处调用
    grep -c 'unwrap_or(tab.focused)' windows/host/src/tabs.rs   # 必须是 1

**第二条是这一族的全部要害**：回落到焦点的规则只许有一处。出现第二处，就是这个缺陷
开始重新长回来。

## 键位

⚠️ **以 `Config.zig` 里 `Keybinds.init` 的非 darwin 分支为准，不是 macOS 的拼法。**
判据写错键位的表现和功能真坏了一样：**按下去没反应。**

| 动作 | Windows 上的键 |
|---|---|
| `new_split:right` | `Ctrl+Shift+O` |
| `new_split:down` | `Ctrl+Shift+E` |
| `goto_split:上/下/左/右` | `Ctrl+Alt+↑ / ↓ / ← / →` |
| `resize_split` | `Win+Ctrl+Shift+↑ / ↓ / ← / →` |
| `toggle_split_zoom` | `Ctrl+Shift+Enter` |

## 布置：焦点和 target 必须是两格不同的

1. 开一个终端，记它在 `terminal_list` 里的 id 为 **A**。
2. 在 A 上按 `Ctrl+Shift+E` 分出 **B**。**点一下 B，让焦点落在 B 上。**
3. 从**别处**（另一个终端或总管）对 **A** 发动作。

⚠️ **第 2 步是这四格的全部。** 焦点和 target 是同一格时，**修好和没修长得一模一样**。

| 动作 | 发什么 | ✅ 修好 | 🔴 旧行为 |
|---|---|---|---|
| new_split | `terminal_action(id=A, "new_split:down")` | 新 pane 在 **A** 下方 | 在 **B** 下方 |
| goto_split | `terminal_action(id=A, "goto_split:down")` | 从 **A** 出发往下找 | 从 **B** 出发 |
| resize_split | `terminal_action(id=A, "resize_split:down,10")` | **A** 那条边动了 | **B** 那条边动了 |
| toggle_split_zoom | `terminal_action(id=A, "toggle_split_zoom")` | **A** 铺满 | **B** 铺满 |

## 日志：`None` 是有意义的

四条都把落点打了出来（`from=Some(P)` / `pane=Some(P)` / `cwd=…`）。
⚠️ **`Some`/`None` 的读法**：`None` 表示这次动作没有指名 surface，或者指名的那格已经
不在这棵树里，于是回落到焦点。**用键位触发时 `None` 不是缺陷；用 `terminal_action(id=…)`
触发时，`None` 就是缺陷。**

## 回归：键位那条老路不许变

在 **A** 上直接按上表里的键（不是工具调用），效果应当仍在 **A** 上。
⚠️ **四条共用同一段落点解析，所以键位是这次改动最可能弄坏的东西。** 四条各测一次。

## 这份判据不覆盖什么

- **`equalize_splits`**：它对整棵树生效，本来就没有 per-pane target，**没有改过**。
- ⚠️ **mac**：那边 `new_split` 走通知 + `SurfaceConfiguration`，**是不是同一族——未查。**
  **未查不是「没问题」。**
- **没有人跑过这份判据。** 写下的每一格都还是预期，不是读数。
