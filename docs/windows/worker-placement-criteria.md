# 判据：总管开出来的 worker 落在哪

**覆盖 362 前半段**：`terminal_open` 不再一律新开 tab，而是按一份住在核心里的预算
把 worker 摆进总管自己的 tab。预算是 `App.zig` 里的 `WorkerPlacement.decide`，
**两个 apprt 里没有它的任何一个数字**——它们只回答一个事实：这个 tab 里有几格。

## ⚠️ 最要紧的一条，以及它今天为什么应该是红的

> **主管说 1+1+2+2，得到的就是 1+1+2+2，且那个 2+2 是田字。**

**这一版达不到它，而且是设计上达不到，不是坏了。** 今天能摆出来的只有
**主管在左 + 右边一列最多三个 worker**，第 4 个起一律新开 tab。

⇒ **拿这条判据去测这一版，正确的结果是「不符合，且日志说明了为什么」，不是绿。**

**留着它的理由就是这个**：今天没有任何别的判据能抓住「形状对不上」——
「开了 4 个 worker」绿的时候，形状可以是错的。**一条判据在它保护的能力还没做出来
之前，答案应该是红，而不是把判据改软。** 缺的那一半是「切子树」，归 346。

## 1. 主线：连开 5 个 worker

从一个只有总管的窗口开始，让总管连开 5 个 worker（`terminal_open`，各带不同 `cwd`）。

| 第几个 | 期望 | 日志里应有 |
|---|---|---|
| 1 | 在总管**右边**；总管仍在最左、占满高 | `[split] Right -> pane N (cwd …)` |
| 2 | 在**第 1 个的下方** | `[split] Down -> pane N (cwd …)` |
| 3 | 在**第 2 个的下方**（右列三格） | 同上 |
| 4 | **新开一个 tab** | `falling back to a tab -- 3 workers already here, and a fourth would need a second column, which means splitting a subtree (not possible today)` |
| 5 | 也在新 tab 里 | 同上 |

⚠️ **每个 worker 的 shell 必须真的在它自己的 `cwd` 里**——在每一格里 `pwd` 看一眼。
这是那条硬约束：**要么在请求的目录里，要么根本没被分屏。**

## 2. `place` 三档

| 发什么 | 期望 |
|---|---|
| `terminal_open(cwd=…)`（不给 `place`） | 走 `auto`。⚠️ **不是 tab**——这个默认值在 362 里变过 |
| `terminal_open(cwd=…, place="tab")` | **一定是新 tab**，永远不会变成分屏。这是保证不是偏好 |
| `terminal_open(cwd=…, place="here")` | 在总管的 tab 里分屏；没位置时回落 tab，**并且多打一行说明「你明确要的东西没拿到」** |

## 3. 四处回落，各自要有那一行

| 怎么造 | 日志里那句 |
|---|---|
| 在 Linux/GTK 上开 worker | `this apprt would not split into …`（GTK 给不了目录 ⇒ 不分屏） |
| apprt 答不出「几格」 | `this apprt does not say how full a tab is` |
| 先手动 `Ctrl+Shift+E` 分一屏，再让总管开 worker | `this tab has N terminals that were not opened as workers…` |
| 开 2 个 worker、**关掉第 2 个**、再开一个 | `the last worker is gone; falling back to a tab rather than guessing which pane replaced it` |

⚠️ **最后一条是「有洞」那一格，它的行为是刻意的**：不填洞、不猜，退到新 tab。
**右列会留一个空位**——**这是这一版的已知形状，不是缺陷。** 填洞需要「洞在哪」的概念，
而那取决于用户在它关掉之后做了什么；不填洞才使「同一串操作永远得到同一个形状」成立，
**而上面每一格判据都建立在这一点上**。

## 4. 一格只有人能答

**总管自己那一格的进程有没有被重建。** 开工前在总管里 `echo $$` 记下 pid，
连开 5 个之后再 `echo $$`。
⚠️ **pid 变了 = 杀掉了总管自己**，比形状错严重得多，**撞到就停下别继续测。**
（这一版不重排，所以理论上不会——**但理论不是读数。**）

## 这份判据不覆盖什么

- ⚠️ **设计里那条「开 12 个 worker 得 2 个 tab」现在不能用**：这一版一个 tab 只放 3 个
  worker，12 个会得到 **1 + 4 个 tab**。**拿它去量只会量到一个已知的数**，并且会让人
  报一个不存在的缺陷。它要等切子树落地才有意义。
- ⚠️ **mac**：mac 侧照做了、构建过了，**没有人按过**。
- **没有人跑过这份判据。**

---

# 这两份判据背后的欠账

**都不在任何补丁里，写在这里是为了它们不跟着会话消失。**

1. **第 4 个 worker 起要「切子树」。** 核心的 `SplitTree.split` 接受任意节点（含 split
   节点）⇒ **数据结构支持，缺的是动作**；Windows 的 `polter_split_tree` 的 `insert`
   **只接叶子** ⇒ **连数据结构都还没有**（有 `remove_subtree`，没有对应的 insert）。
   ⇒ **Windows 是更重的一边。** 归 346。
2. **`terminal_action` 的成功回执是裸 `ok`，不带新 pane 的 id。** ⇒ 手工摆布局必然
   退化成一行或一列，因为调用方只能一直对着它已知的那一格分。归 346；
   `supervising` skill 里已经写了今天可用的三步配方（分屏前后各 `terminal_list` 取差集）。
3. ⚠️ **mac 上 `new_split` 那一族是不是同样拿焦点当 target —— 未查。不是「没问题」。**
4. **`windows/host/src/ffi.rs` 的 `payload` 是 24 字节**，`new_split` 的新结构
   （一个 i32 加两个指针）**正好填满**。**下一个带三个字段的动作会溢出**，而溢出的表现
   是读到别的字节，不是编译错误。
5. **这两份判据都没有人跑过。** 每一格都是预期。
