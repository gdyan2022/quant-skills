# wind-db

访问 Wind（万得）金融数据库的 Claude Code plugin。把"每次都踩"的坑（字段晦涩、选错表变体、订阅 mismatch、context 爆炸）固化成 Claude 的行为规范：**先查字典 → probe 权限 → 写 Python 落文件，只回显 head/shape**。

## 解决什么问题

用 LLM 直接查 Wind 数据有几个高频坑：

1. **字段晦涩** — `S_INFO_WINDCODE`、`STATEMENT_TYPE`、`ANN_DT` 等字段的中文含义和枚举值编码，不查字典几乎必错
2. **选错表变体** — `AShareIncome`（标准）、`AShareIncomeHis`（PIT）、`AShareIncomeLLT`（低延时）同名不同意，回测选错 PIT 变体会引入前视偏差
3. **订阅边界不明** — Wind 按**表级**订阅，字典里有的表 ≠ 本机能读，盲写 SQL 会在 SQL 执行时才报权限错误
4. **context 爆炸** — `SELECT *` 千万行结果拖进对话等于废掉一次会话
5. **数据库 comment 不靠谱** — Wind 实例里大量字段 comment 残缺/过期，LLM 读 comment 推字段含义会被带偏
6. **表名翻译陷阱** — LLM 容易从英文表名 `AShareIncomeHis` 猜成"利润表历史数据"，但 `His` 后缀实际是 **PIT 时点快照**，回测选错直接前视偏差。表名中文含义、归属、变体（STD/PIT/LLT/ZL）必须查字典

## 两个数据源的分工

```
┌─────────────────────────┐      ┌──────────────────────────┐
│  dbhub-wind / dbmcp-wind│      │  dict.sh                 │
│  MCP (search_objects /  │      │  (本地 MD grep /          │
│   execute_sql / query)  │      │   在线 mkdocs 字典站)     │
├─────────────────────────┤      ├──────────────────────────┤
│ 我的真实数据库           │      │ Wind 产品目录 + 说明书     │
│                         │      │                          │
│ 我订阅 / 入库的表和列     │      │ Wind 官方提供什么表        │
│ SQL 能执行的那些对象      │      │ 字段中文名、枚举值         │
│ schema metadata         │      │ FAQ、样例数据              │
└─────────────────────────┘      └──────────────────────────┘
    回答 "我有什么"                    回答 "这是什么意思"
```

两者**不可替换**：
- dbhub 不知道字段中文含义（schema comment 只是线索）
- dict.sh 不知道你实际订阅了什么（那是产品目录，不是数据库快照）

详细工具路由规则见 [SKILL.md](./skills/wind-db/SKILL.md)。

## 安装

### 方式一：Plugin Marketplace（推荐）

在 Claude Code 会话里：

```
/plugin marketplace add gdyan2022/quant-skills
/plugin install wind-db@quant-skills
```

然后跑 slash command 引导向导：

```
/wind-db:setup
```

Claude 会通过对话收集数据库/字典凭据（支持粘 DSN 一步到位，或逐项填），写入 `.env`（存放在 plugin 持久化目录，升级不丢），并可选注册数据库 MCP（非 Oracle → `dbhub-wind`；Oracle → `dbmcp-wind`）。最后**重启 Claude Code** 让 MCP 生效。

想重新配置：`/wind-db:setup --reset`。

### 方式二：手动 clone + symlink（开发者模式）

```bash
git clone https://github.com/gdyan2022/quant-skills.git ~/workspace/quant-skills
ln -s ~/workspace/quant-skills/plugins/wind-db/skills/wind-db ~/.claude/skills/wind-db
cd ~/workspace/quant-skills/plugins/wind-db
bash scripts/install.sh
```

交互式 bash 向导（终端 tty）—— 适合想改 skill 代码、`git pull` 拿更新的场景。

### 验证

新会话里问 Claude："查一下 AShareIncome 的主键字段"，Claude 会自动：
1. 跑 `dict.sh -t AShareIncome` 读字典
2. 用 `execute_sql_dbhub_wind`（Oracle：`query_wind`）做 `WHERE 1=0` probe 确认可读
3. 汇报业务主键 + 可读性结果

## 使用示例

Claude 按用户问题语义自动路由：

```
用户："我数据库里有什么 A 股相关表"
→ search_objects_dbhub_wind(pattern='AShare%', type='table')

用户："STATEMENT_TYPE 的枚举值是什么"
→ dict.sh -c AShareIncome
  一次拿到完整字段定义表 + 所有 FAQ（包括 Q5 的 STATEMENT_TYPE 码值映射）
  回复 408001000=合并报表 / 408004000=合并报表(调整) / ... 并标注 (来源：字典)

用户："利润表里哪些字段是主键"
→ 1) dict.sh -t 利润表               知道中文名但不知英文表名，先 -t 列候选
  2) 从候选里选 AShareIncome
  3) dict.sh -c AShareIncome         -c 精确匹配英文表名，拿完整内容
  4) 从"数据字典"段挑出业务主键三列（来源：字典）

用户："拉 2023 年所有 A 股的净利润"
→ 1) dict.sh -c AShareIncome        查表结构、业务主键、字段陷阱
  2) execute_sql_dbhub_wind: SELECT TOP 1 * FROM AShareIncome WHERE 1=0（probe）
  3) 写 Python 用 sqlalchemy 拉数据，存 ./data/*.parquet
  4) 回显 df.shape / df.dtypes / df.head()
```

手动在终端里跑字典查询：

```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/dict.sh" -c AShareIncome        # ⭐ 精确匹配英文表名，直接输出整页内容
bash "$CLAUDE_PLUGIN_ROOT/scripts/dict.sh" -t 利润表                # 子串匹配，列出候选 URL
bash "$CLAUDE_PLUGIN_ROOT/scripts/dict.sh" STATEMENT_TYPE         # 全文查字段含义
bash "$CLAUDE_PLUGIN_ROOT/scripts/dict.sh" -l | grep 利润表        # 批量筛选全量对照
bash "$CLAUDE_PLUGIN_ROOT/scripts/dict.sh" -h                     # 帮助
```

`$CLAUDE_PLUGIN_ROOT` 在 Claude 会话里由 plugin 运行时注入；命令行里可手动推导，或走方式二后用 `~/workspace/quant-skills/plugins/wind-db` 代替。

## 组件清单

| 文件 | 作用 |
|---|---|
| `skills/wind-db/SKILL.md` | Claude 加载的工作规范（工具路由、工作流、字段陷阱、来源标注纪律） |
| `commands/setup.md` | `/wind-db:setup` slash command，Claude 作为向导引导首次配置 |
| `scripts/install.sh` | 终端 tty 交互向导（方式二或手动拆步时用） |
| `scripts/setup-env.sh` | 非交互 `.env` 写入（供 `/wind-db:setup` 调用） |
| `scripts/setup-mcp.sh` | 读 `.env` 按 dialect 注册 MCP：非 Oracle → dbhub `dbhub-wind`；Oracle → FreePeak db-mcp-server `dbmcp-wind`（下载预编译二进制 + SHA256 校验 + 生成 `dbmcp-wind.json`）。支持 `--dry-run` |
| `scripts/parse-dsn.py` | 解析 SQLAlchemy / URL / JDBC / ADO.NET / 键值对 DSN 到字段 |
| `scripts/dict.sh` | Wind 数据字典查询（三模式：`-t` / 全文 / `-l`） |
| `.env.example` | 凭据模板 |

## 支持的数据库方言

| dialect | MCP | 备注 |
|---|---|---|
| `mssql+pyodbc` | dbhub `sqlserver://` | **Wind 官方 SQL Server 版，最常见**。默认带 `?sslmode=disable`（内网 / 自签证书）。支持 `WIND_DB_SSLMODE`、`WIND_DB_INSTANCE` |
| `oracle+oracledb` | [FreePeak db-mcp-server](https://github.com/FreePeak/db-mcp-server) | **Wind 官方 Oracle 版**。纯 Go 驱动 go-ora（Oracle 10.2+，含 Wind 常见的 11.2.0.4），不需要 Instant Client；`read_only` + `max_rows` 护栏（`read_only` 要求账号不持有任何写权限，否则拒绝启动，见 `.env.example` 的 `WIND_DBMCP_READ_ONLY`）。可选 `WIND_DB_SCHEMA`（建议 `WIND`）、`WIND_DB_SID`。为什么不走 dbhub：dbhub 1.5+ 的 Oracle connector 只有 node-oracledb Thin 模式，要求服务器 ≥ 12.1，连 11g 报 `NJS-138` |
| `mysql+pymysql` | dbhub `mysql://` | |
| `mariadb+pymysql` | dbhub `mariadb://` | |
| `postgresql+psycopg2` | dbhub `postgres://` | |
| `sqlite` | dbhub `sqlite://` | 单机测试 |

## 数据字典来源

Skill 依赖一份 Wind 数据字典。两种模式：

- **在线模式**（默认）：指向部署了 [mkdocs-material](https://squidfunk.github.io/mkdocs-material/) 的字典站（示例：`https://winddict.081188.xyz`，basic auth 保护）。内容从 Wind 官方数据服务门户 `wds.wind.com.cn` 抓取
- **本地模式**（可选推荐）：`WIND_DICT_LOCAL=/path/to/wind_data_dict` 指向本地 MD 目录，`dict.sh` 优先走本地 grep（更快、不依赖网络）

字典站本身由独立的爬取/生成项目维护（`wind-data-dict`）—— 从 Wind RDF 接口抓表结构 / 样例数据 / FAQ，生成 MD，通过 mkdocs 发布。

## `-l` 输出格式（TSV 四列）

```
AShareIncome       中国A股利润表          [STD]  中国A股数据库/中国A股-财务数据
AShareIncomeHis    中国A股利润表（PIT）    [PIT]  中国A股数据库/中国A股-财务数据（PIT）
AShareIncomeLLT    中国A股利润表（低延时）  [LLT]  中国A股数据库/中国A股-财务数据（低延时）
```

TAG 含义：`[STD]` 标准（默认）/ `[PIT]` 时点快照（回测必用）/ `[LLT]` 低延时 / `[ZL]` 增量。详细选型规则见 SKILL.md §6.3。

## 依赖

- [Claude Code](https://claude.ai/code) CLI
- Python 3.8+（系统自带）
- Node.js（非 Oracle：dbhub MCP 通过 `npx` 启动，自动下载）
- Oracle：**不需要** Node / Go，`setup-mcp.sh` 直接下载 FreePeak 预编译二进制（darwin / linux × arm64 / amd64）
- 对应 dialect 的 Python 驱动（若要从 Python 批量读数据）：MSSQL → `pyodbc` + ODBC Driver 18；Oracle → `oracledb`（服务器是 11g 时还要 Instant Client 走 thick 模式，路径填 `WIND_ORACLE_CLIENT_LIB_DIR`）；MySQL → `pymysql`；Postgres → `psycopg2`

## 安全

- `.env` 被 `.gitignore` 排除，不会进 git；`/wind-db:setup` 写入时文件权限 600
- `setup-mcp.sh` 注册 MCP 时密码做 URL 编码，不在命令行明文裸露
- MCP 实例固定名 `dbhub-wind` / `dbmcp-wind`，不污染其他配置；Oracle 的 FreePeak 配置文件不含密码（`password_env` 从环境变量读）

> ⚠️ `/wind-db:setup` 通过对话收集密码时，密码会出现在对话历史里。对安全敏感的生产环境，推荐先输占位符跑完向导，再 `vim "$CLAUDE_PLUGIN_DATA/.env"` 手动改密码。

## 已知限制

- **字段粒度查询**（`dict.sh <字段名>`）依赖字典全文搜索；纯表名查询用 `-t` 精确模式更快
- `-l` 输出约 600-1200 行（取决于 `WIND_LIST_DBS` 过滤），建议 `| grep` 按需过滤，不要整份加载到对话
- Oracle 走 FreePeak，工具名和 dbhub 不同（`query_wind` / `schema_wind`）；且 FreePeak 的 `schema_wind` / `describe_wind` / `filter_tables` 只查登录账号自己的 `USER_*` 视图，对建在 `WIND` schema 下的表返回空，要用 `query_wind` 查 `ALL_*` 视图（SKILL.md §5.4.1 给了现成 SQL）
- Claude 读数据库返回的字段 comment 时可能过度依赖；SKILL.md §4.1 规定了"权威来源排序 + 来源标注"纪律对抗这个问题

## 贡献

发现新的 Wind 陷阱、或想补充某个数据库模块的语义规则，欢迎 PR。核心文件：

- `skills/wind-db/SKILL.md` — Claude 的工作规范
- `scripts/dict.sh` — 字典查询
- `scripts/setup-mcp.sh` — MCP 注册逻辑
- `commands/setup.md` — `/wind-db:setup` 向导 prompt

## License

MIT
