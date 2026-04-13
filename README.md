# quant-skills

量化研究相关的 Claude Code **plugin marketplace**。仓库本身就是一个 marketplace，内部 `plugins/` 目录下是具体 plugin。

## 包含的 plugin

| 名字 | 说明 |
|---|---|
| [wind-db](./plugins/wind-db/) | 访问 Wind（万得）金融数据库，强制"先查字典、先 probe 再写 SQL"工作流，防止 dbhub MCP 拉大表撑爆上下文 |

## 安装（Claude Code Plugin 方式，推荐）

在 Claude Code 会话里：

```
/plugin marketplace add gdyan2022/quant-skills
/plugin install wind-db@quant-skills
```

然后按各 plugin 目录下 README 做首次配置（通常是 `bash "$CLAUDE_PLUGIN_ROOT/scripts/install.sh"`）。

## 安装（手动 clone + 符号链接，开发者模式）

```bash
git clone https://github.com/gdyan2022/quant-skills.git ~/workspace/quant-skills

# 把某个 plugin 的 skill 子目录链到 Claude skills 目录
ln -s ~/workspace/quant-skills/plugins/wind-db/skills/wind-db ~/.claude/skills/wind-db
```

`.env` 这类凭据不会进 git（`.gitignore` 排除），每台机器单独配一份。

## 仓库结构

```
quant-skills/
├── .claude-plugin/
│   └── marketplace.json          # marketplace manifest
├── plugins/
│   └── wind-db/                  # 第一个 plugin
│       ├── .claude-plugin/
│       │   └── plugin.json       # plugin manifest
│       ├── skills/
│       │   └── wind-db/
│       │       └── SKILL.md      # Claude 加载的 skill 规范
│       ├── scripts/
│       │   ├── install.sh        # 首次安装向导
│       │   ├── setup-mcp.sh      # dbhub MCP 注册
│       │   └── dict.sh           # Wind 数据字典查询
│       ├── .env.example
│       └── README.md
└── README.md
```

## License

MIT
