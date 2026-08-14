---
name: new-version
description: 创建 Ghostty 仓库新版本分支
disable-model-invocation: true
allowed-tools: Bash(git *), Read
---

创建 Ghostty 仓库的新版本分支。

## 流程

1. 获取当前所有 `feature/v*` 分支，找到最大版本号
2. 版本号 +1 作为新分支名（如当前最大是 v1.5，则创建 feature/v1.6）
3. 从当前分支创建新分支
4. 推送到 origin

## 参数

如果用户指定了版本号（如 `/new-version 1.7`），使用指定版本；否则自动递增。

用户输入的参数: $ARGUMENTS

## 版本号来源

本仓库还没有任何 `feature/v*` 分支或 tag。首次运行时，以 `build.zig.zon` 的
`.version` 字段作为基准（当前为 `1.3.2-dev`），去掉 `-dev` 后缀后递增次版本号。

## 步骤

```bash
# 1. 查看现有版本分支
git branch -a | grep 'feature/v'

# 2. 没有匹配分支时，读取 build.zig.zon 的 .version 作为基准
grep '\.version' build.zig.zon

# 3. 确定新版本号（自动递增或用户指定）
# 4. git checkout -b feature/v<new>
# 5. git push -u origin feature/v<new>
```

## 注意

- 推送前先确认远端是 `git@github.com:Lugia123/ghostty.git`（个人 fork），
  不要推到 ghostty-org 上游。
- 创建分支前检查工作区是否干净（`git status --porcelain`），有未提交改动时
  先告知用户再决定是否继续。

执行完成后告知用户新分支名，以及当前分支的最新 commit。
