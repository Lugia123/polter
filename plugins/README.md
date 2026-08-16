# 插件

放通知插件的地方。设计见 [docs/poltergeist/plugins.md](../docs/poltergeist/plugins.md)。

一个插件是一个目录：

```text
plugins/
  feishu/
    plugin.yaml     元数据：key、kind、参数 schema、要哪些凭据
    send.sh         可执行；Polter 把事件作为一行 JSON 写进它的 stdin
```

**尚未实现** —— 这个目录先占位，等宿主写完再放第一个插件进来。

三处查找，后者覆盖前者：

1. 随 Polter 安装的：`<resources>/polter/plugins/`
2. 用户自己的：`$XDG_CONFIG_HOME/polter/plugins/`
3. 配置里显式指定的目录

凭据**不放在这里**。这个目录是要被分享和被 git 管理的；凭据在
`$XDG_STATE_HOME/polter/credentials.json`，权限 0600。
