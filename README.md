# Claude Code Skills

我自用的 Claude Code skill 集合。每个子目录是一个独立 skill。

## 已有 skill

| 名字 | 说明 |
|---|---|
| [wind-db](./wind-db/) | 访问 Wind（万得）金融数据库，强制"先查字典、先 probe 再写 SQL"工作流 |

## 安装

克隆整个仓库到任意路径，然后把需要的 skill 符号链接到 `~/.claude/skills/`：

```bash
git clone https://github.com/YOUR_USERNAME/skills.git ~/workspace/skills
ln -s ~/workspace/skills/wind-db ~/.claude/skills/wind-db

每个 skill 有自己的 README 和 .env.example，按各自的说明配置。

License

MIT
