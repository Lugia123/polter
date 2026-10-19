# Windows：新建标签页时选 shell（任务 #1778 ②、#1804）

用户定的是 1778 v1 设计图里的 **B**（`polter-artifacts/1778-shell-profile/v1/`）：标签栏「+」右边紧挨一个 14px 的下拉三角。

| 操作 | 结果 |
|---|---|
| 点「+」 | 和以前一样：用默认 shell（配置里的 `command`，没写就由核心自己挑）开新标签 |
| 点三角 | 弹出 shell 列表（原生菜单）。选一项就开一个跑它的新标签，起始目录是当前正在打字的那一格最后报告的目录 |
| 列表末尾「更改默认 Shell…」 | 打开 设置 › 通用 › 终端，里面有「默认 Shell」一行 |

## 列表里有什么

由 `windows/settings-shell/src/shell_profiles.rs` 定，可以在 mac 上测：

- 先列 Windows 的 shell，顺序和核心挑默认值的顺序一样（`src/os/default_shell.zig` 的 `pick`）：
  1. PowerShell 7：装了才有，在 `%ProgramFiles%` 或应用商店别名两处找；
  2. Windows PowerShell；
  3. 命令提示符。
- 有 WSL 发行版时，画一条线，再按注册表顺序列各发行版。数据读自 `HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss` 下每个子键的 `DistributionName`。以下几种不列：
  - Docker Desktop 自带的两个；
  - 正在安装或卸载的；
  - 没有名字的；
  - 同名的重复项（只列第一个）。
- 「默认」两个字标在新标签真会启动的那一项上：
  - 配置写了某个 shell，就标那一项；
  - 没写，就标第一个不是 WSL 的那一项；
  - 写的不是列表里任何一项，就哪项都不标。

## 「默认 Shell」一行（设置 › 通用 › 终端）

- `form.zig` 给 `command` 加了一行：`group = .terminal`，`os = .windows`，所以 mac 不显示。
- 核心把它当文本发给宿主，因为可选项取决于这台机器，核心不知道。Windows 宿主在读表时把它换成下拉框（`shell_profiles::offer`）。
- 选项依次是：
  - 「自动」；
  - 探测到的各个 shell；
  - 配置里写的值不在列表中时，单独一项，原样显示。

| 选的是 | 写进配置文件 |
|---|---|
| 自动 | 删掉 `command` 这一行。写成今天挑出来的那个 shell 会把选择冻住：以后装了 PowerShell 7 也不会换过去 |
| 某个 shell | `command = <它的命令>`。带空格的路径由 form 的 `appendValue` 再包一层引号，读回来仍是一个参数 |
| 配置里原来那个值 | 不写 |

- 文件里没写 `command` 时，生效的是核心自己挑的，这一行显示「自动」。
- 「所有选项」里它仍是一行文本。自动时那一格是空的，因为文件里确实没有写。

## 没验的

- 宿主的接线都只能在 Windows 上验，包括：画三角、点击、弹菜单、读注册表、开新标签、设置窗口里的下拉框和写回。
- 应用商店别名的 `pwsh.exe` 是重解析点，用 `symlink_metadata` 判断它在不在，没上真机核过。
