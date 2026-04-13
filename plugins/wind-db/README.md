# wind-db

访问 Wind（万得）金融数据库的 Claude Code skill。强制 Claude 走"先查字典、先 probe 再写 SQL、结果写文件"的工作流，避免 Wind 数据常见陷阱（字段晦涩、选错版本、订阅 mismatch、context 爆炸）。

## 解决什么问题

用 LLM 查 Wind 数据有几个"每次都踩"的坑：

1. **字段命名晦涩**：`S_INFO_WINDCODE`、`STATEMENT_TYPE`、`ANN_DT` 等字段的中文含义和枚举值编码不查字典几乎必错
2. **选错表变体**：`AShareIncome`（标准）、`AShareIncomeHis`（PIT）、`AShareIncomeLLT`（低延时）同名不同意，回测选错 PIT 变体会引入前视偏差
3. **订阅边界不明**：Wind 按**表级**订阅，字典里有的表不代表本机能读，盲写 SQL 后权限报错
4. **Context 爆炸**：通过 MCP 执行 `SELECT *` 会把千万行数据拖进对话

这个 skill 把上述规则固化进 Claude 的行为：**每次读 Wind 数据前先查字典，先用 `WHERE 1=0` probe 权限，真正读数据用 Python 写文件，只回显 `head()`/`shape()`**。

## 功能

- **`scripts/dict.sh`** — 三模式数据字典查询
  - `-t <词>` 精确标题搜索（默认）
  - `<词>` 全文搜索（字段/概念 fallback）
  - `-l` 全量表对照 TSV（英文名 / 中文名 / [TAG] / 路径）
- **`scripts/setup-mcp.sh`** — 读 `.env` 一键注册 `dbhub-wind` MCP 服务器
- **`SKILL.md`** — Claude 加载后遵循的工作规范（工具路由、订阅语义、probe 工作流、字段陷阱）

## 架构：两个数据源互补

```
┌─────────────────────────┐      ┌──────────────────────────┐
│  dbhub-wind MCP         │      │  dict.sh                 │
│  (search_objects,       │      │  (本地 MD grep /          │
│   execute_sql)          │      │   在线 mkdocs 字典站)     │
├─────────────────────────┤      ├──────────────────────────┤
│ 我的真实数据库           │      │ Wind 产品目录 + 说明书     │
│                         │      │                          │
│ 我订阅 / 入库的表和列     │      │ Wind 官方提供什么表        │
│ SQL 能执行的那些对象      │      │ 字段中文名、枚举值         │
│ schema metadata         │      │ FAQ、样例数据              │
└─────────────────────────┘      └──────────────────────────┘
    回答 "我有什么"                    回答 "这是什么意思"
```

两者**不可替换**：dbhub 不知道字段含义（schema 里没有中文描述），dict.sh 不知道你实际订阅了什么（它是产品目录，不是数据库快照）。

## 依赖

- [Claude Code](https://claude.ai/code) CLI
- Python 3.8+（已安装在 macOS/Linux 绝大多数环境里）
- Node.js（dbhub MCP 通过 `npx` 启动）
- 对应 dialect 的数据库驱动（SQL Server → ODBC Driver / pyodbc, MySQL → pymysql, PostgreSQL → psycopg2, Oracle → cx_oracle）

## 安装

### 方式一（推荐）：Claude Code Plugin Marketplace

```
# 在 Claude Code 会话里：
/plugin marketplace add gdyan2022/quant-skills
/plugin install wind-db@quant-skills
```

然后在 Claude Code 会话里跑：

```
/wind-db:setup
```

Claude 作为向导通过对话收集数据库/字典凭据，最后写入 `.env`（放在 plugin 持久化目录，升级不丢）并可选注册 `dbhub-wind` MCP。**重启 Claude Code** 让 MCP 生效。

> 老的交互式 bash 向导 `bash "$CLAUDE_PLUGIN_ROOT/scripts/install.sh"` 依然保留，但**需要真实终端 tty**；Claude 会话内推荐用 `/wind-db:setup`。

### 方式二：手动 clone + 符号链接（开发者模式）

```bash
git clone https://github.com/gdyan2022/quant-skills.git ~/workspace/quant-skills
ln -s ~/workspace/quant-skills/plugins/wind-db/skills/wind-db ~/.claude/skills/wind-db
cd ~/workspace/quant-skills/plugins/wind-db
bash scripts/install.sh
```

这种方式 `.env` 落在 `plugins/wind-db/.env`，`git pull` 能拿更新，适合想对 skill 自己改代码的场景。

### 验证

在新会话里问 Claude："用 wind-db skill 查一下 AShareIncome 的主键字段"，Claude 应该自动加载 skill，调用 `dict.sh -t AShareIncome`，然后用 `execute_sql_dbhub_wind` 做 `WHERE 1=0` probe。

## 数据字典来源

Skill 依赖一份 Wind 数据字典。两种模式：

- **在线模式**：指向一个部署了 [mkdocs-material](https://squidfunk.github.io/mkdocs-material/) 站点，内容从 Wind 官方数据服务门户（`wds.wind.com.cn`）抓取的字典仓库。站点应该有 basic auth 保护。
- **本地模式**：`WIND_DICT_LOCAL` 指向一个包含字典 MD 文件的目录，`dict.sh` 会优先走本地 grep（更快）。

相关项目：字典站本身由一个独立的爬取/生成项目维护（`wind-data-dict`）—— 从 Wind 的 RDF 接口抓表结构、样例数据、FAQ，生成 MD 文件，通过 mkdocs 发布。

## 使用示例

Claude 会根据用户问题的语义自动选择工具：

```
用户："我数据库里有什么 A 股相关表"
Claude: search_objects_dbhub_wind(pattern='AShare%', type='table')

用户："AShareIncome 的 STATEMENT_TYPE 字段什么意思"
Claude: dict.sh AShareIncome
        → 读 MD 文件的"数据字典"段，找到 STATEMENT_TYPE 的枚举值

用户："给我拉 2023 年 A 股所有公司的净利润"
Claude: 1) dict.sh -t AShareIncome 看表结构和业务主键
        2) execute_sql_dbhub_wind: SELECT TOP 1 * FROM AShareIncome WHERE 1=0（probe）
        3) 写 Python 脚本用 sqlalchemy 拉数据，存到 ./data/*.parquet
        4) 回显 df.head() / df.shape / df.dtypes
```

也可以手动运行：

```bash
bash ~/.claude/skills/wind-db/scripts/dict.sh -t AShareIncome
bash ~/.claude/skills/wind-db/scripts/dict.sh STATEMENT_TYPE
bash ~/.claude/skills/wind-db/scripts/dict.sh -l | grep 利润表
bash ~/.claude/skills/wind-db/scripts/dict.sh -h
```

## `-l` 输出格式（TSV 四列）

```
AShareIncome       中国A股利润表          [STD]  中国A股数据库/中国A股-财务数据
AShareIncomeHis    中国A股利润表（PIT）    [PIT]  中国A股数据库/中国A股-财务数据（PIT）
AShareIncomeLLT    中国A股利润表（低延时）  [LLT]  中国A股数据库/中国A股-财务数据（低延时）
```

TAG 语义：
- `[STD]` 标准版 — 默认选这个
- `[PIT]` 时点快照版（Point-in-Time）— 因子回测必用，避免前视偏差
- `[LLT]` 低延时版 — 实盘接入
- `[ZL]` 增量版 — 只需要变动数据时用

## 安全

- `.env` 已被 `.gitignore` 排除，**不会**进 git
- `setup-mcp.sh` 注册 MCP 时对密码做 URL 编码，不在命令行裸露明文
- dbhub MCP 实例名固定为 `dbhub-wind`，不污染其他 dbhub 配置

## 已知限制

- 字段查询（`dict.sh <字段名>`）需要字典站或本地字典支持全文搜索。只有表名时 `-t` 精确模式更快
- `-l` 输出约 600-1200 行（取决于 `WIND_LIST_DBS` 过滤范围），大会话里建议 `| grep` 按需过滤，不要整份加载到上下文
- probe SQL 用的是 `WHERE 1=0`，不同 dialect 的 `LIMIT`/`TOP` 语法不同，skill 默认按 MSSQL 写；如果你用 MySQL/Postgres，自己改 probe 模板

## 贡献

发现新的 Wind 陷阱、或想补充某个数据库模块的语义规则，欢迎 PR。核心文件：

- `SKILL.md` — 工作流和规范
- `scripts/dict.sh` — 字典查询实现
- `scripts/setup-mcp.sh` — MCP 注册逻辑

## License

MIT
