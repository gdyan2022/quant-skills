---
name: wind-db
description: 访问 Wind（万得）金融数据库。当用户需要从 Wind 数据库读取金融数据（A股/B股/债券/基金/指数等）、提及 Wind、万得、AShare、AIndex、BShare、CBond 等 Wind 表名、或要用 Wind 数据做量化/研究时使用。强制"先查数据字典、再写查询"工作流，支持 SQL Server / Oracle 等 Wind 实例，并阻止 MCP 拉取大量数据造成上下文爆炸。
---

# Wind 金融数据库访问

## 0. 触发条件

- 用户让你"查 Wind 数据"、"从 Wind 读 xxx 表"
- 代码里出现 `AShareIncome`、`AShareBalanceSheet`、`CBondDescription`、`AIndexEOD` 等 Wind 表名
- 任何涉及 Wind 金融数据的分析 / 量化研究任务

---

## 1. 使用前提：每次调 bash 前先推导 `$CLAUDE_PLUGIN_ROOT`

Claude Code 的 Bash 工具**不保证**把 `$CLAUDE_PLUGIN_ROOT` 注入给子进程。每次会话**第一次**执行本 skill 的脚本前，请先跑这段推导（找到真实 plugin 根目录）：

```bash
PLUGIN_ROOT=""

# 1. 环境变量
[ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -d "${CLAUDE_PLUGIN_ROOT}" ] && PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT"

# 2. Plugin install 模式：~/.claude/plugins/cache/<marketplace>/wind-db/<version>/
if [ -z "$PLUGIN_ROOT" ]; then
  for cand in "$HOME"/.claude/plugins/cache/*/wind-db/*; do
    [ -d "$cand/scripts" ] && PLUGIN_ROOT="$cand" && break
  done
fi

# 3. Symlink 开发模式
if [ -z "$PLUGIN_ROOT" ] && [ -L "$HOME/.claude/skills/wind-db" ]; then
  t=$(readlink "$HOME/.claude/skills/wind-db")
  case "$t" in /*) ;; *) t="$HOME/.claude/skills/$t" ;; esac
  cand=$(cd "$t/../.." 2>/dev/null && pwd)
  [ -d "$cand/scripts" ] && PLUGIN_ROOT="$cand"
fi

[ -z "$PLUGIN_ROOT" ] && { echo "✗ 找不到 wind-db plugin，请 /plugin install wind-db@quant-skills" >&2; exit 1; }
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
```

之后所有命令都用 `$CLAUDE_PLUGIN_ROOT/scripts/...`。**绝不硬编码路径。**

---

## 2. 首次安装

用户第一次用时，先执行：

```
/wind-db:setup
```

这个 slash command 会引导用户粘 DSN（或逐项填字段）、填字典站凭据，写入 `.env`（存放在 plugin 持久化目录 `$CLAUDE_PLUGIN_DATA`，升级不丢；该变量在别的 plugin 的会话里会指向别处，脚本只认目录名为 `wind-db*` 的，否则回落 plugin 根），并可选注册数据库 MCP。**MCP 实现由 `.env` 的 `WIND_DB_DIALECT` 决定**：

| `WIND_DB_DIALECT` | MCP 名 | 工具名 |
|---|---|---|
| `mssql+pyodbc` / mysql / mariadb / postgres / sqlite | `dbhub-wind`（@bytebase/dbhub） | `search_objects_dbhub_wind` / `execute_sql_dbhub_wind` |
| `oracle+oracledb` | `dbmcp-wind`（FreePeak db-mcp-server） | `query_wind` / `schema_wind`（见 §5.4） |

**没跑过 `/wind-db:setup` 之前，本 skill 的其他命令（dict.sh / MCP 查询）都会因为缺少 `.env` 失败。**

如果 `claude mcp list` 里没有对应的 `dbhub-wind` / `dbmcp-wind`，说明 MCP 没注册，需要跑：

```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/setup-mcp.sh"
```

然后**重启 Claude Code**。

---

## 3. 标准工作流（每次读 Wind 数据按这个顺序）

1. **理解需求**：需要哪张表、哪些字段、时间范围、筛选条件。判断数据规模：**小样本 / 探索性**（几十行）还是**批量生产**（进 DataFrame 后续处理）
2. **查字典**：**已知英文表名 → `dict.sh -c <英文表名>`**（精确等值，一次拿到表的中文含义 / 归属 / 业务主键 / 所有字段定义 / 值编码 / FAQ 陷阱，不需要额外 WebFetch）；**只知道中文或模糊关键字 → 先 `dict.sh -t <词>` 列候选**，用户确认或你从候选里挑一个英文表名后，再 `dict.sh -c <英文表名>`。别靠英文名猜（`AShareIncomeHis` 是 PIT 不是"历史数据"；§6.3 TAG 变体）。字典**查不到**时 → 明确告知用户"字典里未找到 X"，不要根据英文词根编造表含义或字段列表
3. **probe 一下**（`execute_sql_dbhub_wind`，Oracle 用 `query_wind`；跑 `WHERE 1=0`）：确认本机真的订阅了这张表（见 §6.1）
4. **小样本 / 探索**：直接用 MCP 跑 `LIMIT 20`（SQL Server `TOP 20`，Oracle `ROWNUM <= 20`）/ 聚合 / 抽样查询，结果回对话；**批量数据**：写 Python 脚本，结果落 `./data/*.parquet`
5. **执行**：只把 `df.shape / dtypes / head()` 给用户（Python 路径）
6. **后续分析**都在文件/DataFrame 上做，不再打扰数据库

三种结果要**明确告诉用户**：

| 状态 | 结论 | 用户该做什么 |
|---|---|---|
| ✅ 字典有 + probe 成功 | 已确认可读 | 继续 |
| ⚠️ 字典有 + probe 失败 | 字典里有但本机没订阅 | 续费 Wind 订阅 / 换一张表 |
| ❌ 字典没有 | 表名拼错 / 字典过期 | 确认拼写，或更新字典 |

**不要混淆 2 和 3** —— 两者对用户是完全不同的问题。

---

## 4. 核心纪律（三条红线）

### 4.1 先查字典，再写任何 SQL

Wind 的字段和值编码极其晦涩，不查字典盲写 SQL 几乎必错。见 §6.2 字段陷阱清单。

**必须**先跑 `dict.sh` 或读本地 MD，再写查询。

**⚠️ 不要依赖 dbhub 返回的 comment 或英文名来推理含义**。这条对**字段**和**表名**同等重要：

- **字段含义**：dbhub 返回的字段 comment 往往残缺、过期、无枚举值映射、无 FAQ 陷阱（详见下面）
- **表名含义**：LLM 容易从英文表名 `AShareEODPrices` 猜成"A 股日频收盘价"，但实际字典里可能是"A 股日行情数据"；更坏的情况是 `AShareIncomeHis` 被猜成"利润表历史数据"，**漏掉了 PIT（时点快照）这个关键属性**，直接影响因子回测的前视偏差判断

Wind 表名翻译的常见坑：
- **`His` 后缀 ≠ "历史数据"，是 PIT** —— `AShareIncomeHis` 是时点快照版，不是"往期数据"
- **`LLT` 后缀 = "低延时"**，不是字母缩写拼凑
- **`ZL` 后缀 = "增量"**（Zēng Liàng 拼音首字母），不是 Zhong Liang 之类
- **`AIndex` / `BIndex` 不是 A 股/B 股索引**，而是 Wind A 股指数 / B 股指数相关表
- **相同前缀跨库存在**（`AShare*` 在好几个库都出现），必须查字典看准确的"数据库/模块"归属

**表名和字段的 comment 都有这些问题**：

- **残缺**：大量字段没有 comment（Wind 的 Oracle/MSSQL 实例里很多字段 comment 是空的）；表级 comment 更稀缺
- **过期**：即使有也可能是建表时的简短标注，和字典里的权威定义对不上
- **没有枚举值映射**：比如 `STATEMENT_TYPE` 的 comment 可能只写"报表类型"，但 `408001000`/`408004000` 这些值编码必须查字典才能解码
- **没有字段陷阱**：FAQ 里的"这个字段有前视偏差""那个字段季报不披露"等隐藏规则，comment 里一个字都没有
- **没有变体语义**：`AShareIncome` vs `AShareIncomeHis` vs `AShareIncomeLLT` 三张表的差异（标准/PIT/低延时），comment 无法告诉你

**含义的权威顺序**（对表和字段都适用）：
1. **数据字典**（`dict.sh`、在线字典站、本地 MD）—— **默认唯一来源**
2. 数据库 comment（dbhub schema 返回）—— 仅当字典查不到时作为线索，且**必须**在回复里标注"此信息来自数据库 comment，字典里未查到"
3. 根据英文名推断 —— **最弱的可靠性**，必须明确标注 `(推断)`

### 4.1.5 告诉用户表名/字段含义时必须标注来源

当你回复**表名含义、字段含义、值编码、业务规则**时，**必须在括号里标注信息来源**，让用户知道这条结论的权威性。格式：

- `(来源：数据字典)` 或简写 `(字典)` —— 权威
- `(来源：数据库 comment)` 或简写 `(DB comment)` —— 线索级，用户需要自行验证
- `(综合：字典 + FAQ)` —— 来自字典的"常见问题"段
- `(推断)` —— 没有明确出处，Claude 自己根据英文名推理 —— **最弱的可靠性，尽量避免**

示例：

> `AShareIncome` **(字典)** 中国A股利润表，标准版（STD）。业务主键是 `S_INFO_WINDCODE + REPORT_PERIOD + STATEMENT_TYPE`。**(字典)** 做回测请改用 `AShareIncomeHis` **(字典，PIT 版，避免前视偏差)**。

> `NET_PROFIT_EXCL_MIN_INT_INC` **(字典)** 归属母公司股东的净利润，单位万元。与 `NET_PROFIT_INCL_MIN_INT_INC` **(字典 + FAQ)** 的区别：后者含少数股东损益，且来源于现金流量表间接法部分（而不是利润表）。

> `S_INFO_COMPCODE` **(DB comment: "公司 id")** ——字典里没查到这个字段的专门页，但在 `AShareRDexpenditure` 的 FAQ 里提到可以通过它 join 到 `AShareDescription.S_INFO_COMPCODE` 拿 `S_INFO_WINDCODE`。**(FAQ)**

> `XxxYyyZzz` **(推断)** 根据表名推测是 XXX 的 YYY 表，但字典没查到这张表——**强烈建议你用 `dict.sh -t XxxYyyZzz` 确认是否存在，或检查拼写**。

这个标注习惯保护用户不会把 Claude 的猜测当成权威结论。**特别是表名**：用户说"查 XXX 表"时，如果字典里查不到，**不要自行翻译+编造字段列表**，而是告诉用户查不到、让他确认拼写或换词重查。

### 4.2 dbhub MCP：**可以读少量数据，不能读大批量**

dbhub 的 `execute_sql` 结果会直接回到上下文，Wind 单表动辄千万~上亿行。只要控制返回行数和列宽，dbhub 可以用来**探索数据、sanity check、抽样看值形状**；**大批量拉数据**（整张表、整年、完整分组聚合）必须走 Python（§4.3）。

经验阈值（供参考）：**≤ 100 行 × ≤ 20 列**走 dbhub 没问题；更大的规模请走 Python。

| 合理用法（dbhub） | 禁止 |
|---|---|
| `search_objects_dbhub_wind` 列表/搜表名（Oracle：§5.4.1 目录 SQL） | `execute_sql` 不带行数限制（`LIMIT` / `TOP` / `ROWNUM`）且不带聚合 |
| `WHERE 1=0` probe 检查权限 | `SELECT *` 一整张表 |
| `LIMIT 5-20`（Oracle `ROWNUM <= 20`）sanity check 看字段值 | 返回 > ~100 行的明细数据 |
| 探索性聚合：`SELECT COUNT(*) / MIN / MAX / DISTINCT` | 读整个时间范围 / 所有代码的明细 |
| 小范围分组：`GROUP BY ... HAVING count < 50` | 百行级以上的 GROUP BY 明细 |
| 查单只股票/单张报表的个位数行 | 批量因子/回测数据提取 |

**决策依据**：问自己"这个结果打算带回到 Python 里做后续处理吗？"
- 是 → 直接用 Python 拉（§4.3 + §7），不用 dbhub 中转
- 否，只是为了**看看 / 确认 / 决定下一步怎么写 SQL** → dbhub 合适

### 4.3 大批量数据用 Python，结果写文件不回对话

当你需要的数据会**进入下游处理**（DataFrame 分析、回测、建模、写入文件）时，直接用 pandas/sqlalchemy 连数据库 → 存 parquet → 只回显 `df.head() / df.shape / df.dtypes`。**绝不** `print(df)` 或 `df.to_string()`。模板见 §7。

理由：数据从 dbhub → 上下文 → 再让 Python 处理这条链会双倍耗 token 且容易截断；直接 Python → 文件落地才是 scalable 的路径。

---

## 5. 工具参考

### 5.1 `dict.sh` — Wind 数据字典查询

**入口**：`bash "$CLAUDE_PLUGIN_ROOT/scripts/dict.sh" ...`

**已知英文表名时用 `-c`（精确等值）直接取内容**；只知道中文名或一类关键字时用 `-t`（子串匹配）先找候选。三种模式语义正交：

| 模式 | 匹配方式 | 输出 | 何时用 |
|---|---|---|---|
| **`-c` 内容** ⭐ | **精确等值**（大小写不敏感） | **完整 Markdown**（简介/字段/样例/FAQ） | **首选，已知英文表名**。`-c AShareIncome` 只命中 `AShareIncome` 本身，**不会**命中 `AShareIncomeTaxADJProc` 等子串；同名表跨多库时自动选内容最丰富的版本 |
| **`-t` URL 列表** | title/slug **子串匹配** | URL 列表 | 只知道中文名或模糊关键字时。`-t 利润表` / `-t Income`，得到候选后用 `-c <具体英文表名>` 再取内容 |
| **全文搜索（默认）** | title/location 加权 + 正文 | URL 列表 | `-c` 0 命中时查字段含义、业务概念、FAQ 交叉讨论（`dict.sh STATEMENT_TYPE` / `dict.sh 合并报表`） |
| **`-l` 列表** | — | TSV 全量表 | `dict.sh -l \| grep <词>`：批量筛选字典（**不是**查本机订阅）。见下条 |

**典型链路**：
- 已知表名 → `dict.sh -c AShareIncome`（一次到位）
- 只有中文 → `dict.sh -t 利润表` 列候选 → 从英文名里选一个 → `dict.sh -c <英文名>`
- 查字段含义 → `dict.sh <字段名>`（全文模式）

**`-c` 0 命中时脚本会给出三条建议**：拼写错 / 换成 `-t` 看子串候选 / 字段名改用全文。遵循建议。

**`-l` 陷阱**：输出的是 Wind **产品目录**（官方提供什么），**不是本机数据库快照**。用户问"我的数据库有什么表"时**永远不要**用 `-l` 回答 —— 要用 `search_objects_dbhub_wind`。

**冷启动推荐**：大任务前缓存一次 `-l` 到临时文件，后续 grep：
```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/dict.sh" -l > /tmp/wind_tables.tsv
```

### 5.2 `dbhub-wind` MCP —"我的数据库"（非 Oracle）

注册后工具名形如 `search_objects_dbhub_wind` / `execute_sql_dbhub_wind`。**永远用带 `_wind` 后缀的版本**，不要污染其他 dbhub 实例。**Oracle 用户**的 MCP 是 `dbmcp-wind`，工具名不同，看 §5.4；本节的用法原则同样适用。两个都注册了时，以 `.env` 的 `WIND_DB_DIALECT` 为准。

| 工具 | 用法 |
|---|---|
| `search_objects_dbhub_wind(pattern='AShare%', type='table')` | 列本机订阅的表、看 schema、主键、索引 |
| `execute_sql_dbhub_wind(sql='SELECT ... WHERE 1=0')` | **probe** 权限（0 行不污染上下文） |
| `execute_sql_dbhub_wind(sql='SELECT ... LIMIT 5')` | sanity check 看字段值形状 |
| `execute_sql_dbhub_wind(sql='SELECT COUNT(*)... GROUP BY ...')` | 探索性聚合、看数据分布 |
| `execute_sql_dbhub_wind(sql='SELECT ... WHERE ... LIMIT 20')` | 查单只股票 / 单张报表的少量明细 |

**结果行数 ≤ ~100 的查询都可以走 dbhub**；批量数据（进 DataFrame 做后续处理的）走 Python（§7）。详见 §4.2 的决策依据。

**⚠️ dbhub schema 返回的字段 comment 只是线索，不是权威**。字段中文含义、值编码映射、业务规则请以 `dict.sh` 为准。如果只能从 dbhub comment 获得信息（字典查不到），回复时必须标注 `(DB comment)` 让用户知道可靠性等级。见 §4.1 / §4.1.5。

### 5.3 `dict.sh` vs `dbhub` 路由速查

| 用户的话 / 意图 | 用这个 | 不要用 |
|---|---|---|
| "**我的**数据库有什么表" | `search_objects_dbhub_wind` | ~~`dict.sh -l`~~ |
| "A 股相关表" / "bond 开头" | `search_objects_dbhub_wind(pattern=...)` | ~~`dict.sh`~~ |
| "字段**类型**" / "**物理**主键/索引" | `search_objects_dbhub_wind` | ~~`dict.sh`~~ |
| "**表**的中文含义 / 归属 / 业务主键 / 表变体" | `dict.sh -t <表>` 读 MD | ~~dbhub~~（英文表名和 comment 不足以判断 STD/PIT/LLT/ZL 变体、也没有业务主键） |
| "**字段**的中文含义 / 值编码 / 枚举解码" | `dict.sh <字段>` 或 `dict.sh -t <表>` | ~~dbhub schema comment 只是线索~~ |
| "Wind **有没有**提供 X 表" / "有 PIT 版吗" | `dict.sh -l` 或 `dict.sh <关键字>` | ~~dbhub~~（问的是目录） |

Oracle 用户把表里的 `search_objects_dbhub_wind` 换成 `query_wind` + §5.4.1 的目录 SQL，`execute_sql_dbhub_wind` 换成 `query_wind`。

**组合查询**：
- "找一张 A 股利润表做因子" → `search_objects_dbhub_wind(pattern='%Income%')` 看本机有什么 → `dict.sh -t <候选>` 查语义和 PIT 变体 → `WHERE 1=0` probe → 写 Python
- "NET_PROFIT 什么意思" → `dict.sh AShareIncome` 读数据字典段，**不**用 dbhub
- "AShareXxx 是什么表" → `dict.sh -t AShareXxx` 取准确表名中文含义；**不要**根据英文拼猜翻译。字典查不到时明说"查不到，请确认拼写"，不要靠英文词根编造

### 5.4 Oracle 用户：MCP 走 FreePeak db-mcp-server，不走 dbhub

**为什么**：dbhub 1.5+ 虽有 Oracle connector，但只用 node-oracledb **Thin 模式**，要求服务器 ≥ 12.1；Wind 现网 Oracle 大量是 11.2.0.4，连上去直接报 `NJS-138`。FreePeak 用纯 Go 驱动 go-ora（支持 10.2+，不需要 Instant Client，ZHS16GBK 库的中文解码正常），并自带 `read_only` / `max_rows` / `query_timeout` 护栏。`setup-mcp.sh` 看到 `WIND_DB_DIALECT=oracle+*` 自动走这条路：下载预编译二进制到 `<数据目录>/bin/`，配置写 `<数据目录>/dbmcp-wind.json`（`read_only`、`max_rows: 200`、`query_timeout: 120`），试启动一次确认连接，再注册为 `dbmcp-wind`，日志在 `<数据目录>/logs/`。

**`read_only` 的真实语义**：FreePeak 的 Oracle 只读不是过滤 SQL，而是启动时审计账号权限，账号持有 `CREATE TABLE` 等任一写权限就**拒绝启动**。Wind 只读账号常常自带 `CREATE TABLE`（用户自建辅助表），这时 `setup-mcp.sh` 会停下来让用户选：请 DBA 收权保留护栏，或 `.env` 设 `WIND_DBMCP_READ_ONLY=false` 关掉护栏、改靠纪律并在 Claude Code `permissions.deny` 里禁掉 `mcp__dbmcp-wind__execute_wind` / `transaction_wind`。**这是用户的安全决策，不要替用户改。**

**工具名对照**（工作流完全一致）：

| dbhub（非 Oracle） | FreePeak（Oracle） | 作用 |
|---|---|---|
| `search_objects_dbhub_wind` | `query_wind(query=...)` + §5.4.1 的目录 SQL | 列表、字段、主键、索引 |
| `execute_sql_dbhub_wind` | `query_wind(query=...)` | SELECT / probe。结果超过 `max_rows`（200）会被截到 200 行并附 `Truncated: showing first 200 rows` 提示 → 收窄查询，不要翻页硬拉 |
| — | `health_wind` | 看连接是否正常、当前 `read_only` / `max_rows` 设置。排障时用 |
| — | `schema_wind(format)` / `describe_wind(table)` / `filter_tables(pattern)` | ⚠️ 三个都只查 `USER_*` 视图 = **登录账号自己的表**。Wind 表在 `WIND` schema 下、登录账号另有其人，实测对 Wind 表返回空（`describe_wind` 连写 `WIND.ASHAREINCOME` 也是空），**别用**，走 §5.4.1 |
| — | `execute_wind` / `transaction_wind` | DML / 事务。Wind 是只读数据源，**任何情况下都不要用**，不管 `read_only` 开没开 |
| — | `explain_wind` / `performance_wind` | 执行计划 / 慢查询分析，日常用不到 |

#### 5.4.1 Oracle 目录查询（代替 `search_objects`）

Wind 的 Oracle 版把表建在 `WIND` 用户下，登录账号（如 `RWIND`）靠同义词访问，**同义词不一定覆盖全部表**（实测 740 张里 42 张没有）。所以：

- SQL 里**一律写 `WIND.表名`**。前缀来自 `.env` 的 `WIND_DB_SCHEMA`，为空才省略
- 查目录用 `ALL_*` 视图并带 `OWNER = 'WIND'`，**不要用 `USER_*`**（那是登录账号自己的）
- 目录视图里表名、列名要写**大写**（Oracle 不加引号的标识符自动转大写）

```sql
-- 我订阅了哪些表（替代 search_objects pattern）
SELECT table_name, num_rows FROM all_tables
WHERE owner = 'WIND' AND table_name LIKE 'ASHARE%' ORDER BY table_name;

-- 字段 + 类型 + 注释（注释只是线索，权威含义看 dict.sh，见 §4.1）
SELECT c.column_name, c.data_type, c.data_length, c.nullable, m.comments
FROM all_tab_columns c
LEFT JOIN all_col_comments m
  ON m.owner = c.owner AND m.table_name = c.table_name AND m.column_name = c.column_name
WHERE c.owner = 'WIND' AND c.table_name = 'ASHAREINCOME'
ORDER BY c.column_id;

-- 物理主键 / 唯一约束
SELECT c.constraint_name, c.constraint_type, cc.column_name, cc.position
FROM all_constraints c
JOIN all_cons_columns cc ON cc.owner = c.owner AND cc.constraint_name = c.constraint_name
WHERE c.owner = 'WIND' AND c.table_name = 'ASHAREINCOME' AND c.constraint_type IN ('P', 'U')
ORDER BY c.constraint_name, cc.position;

-- 索引
SELECT i.index_name, i.uniqueness, ic.column_name, ic.column_position
FROM all_indexes i
JOIN all_ind_columns ic ON ic.index_owner = i.owner AND ic.index_name = i.index_name
WHERE i.owner = 'WIND' AND i.table_name = 'ASHAREINCOME'
ORDER BY i.index_name, ic.column_position;
```

#### 5.4.2 Oracle SQL 方言差异（按 11g 写，12c+ 也兼容）

| 要做的事 | SQL Server（dbhub 默认） | Oracle |
|---|---|---|
| probe | `SELECT TOP 1 * FROM AShareIncome WHERE 1=0` | `SELECT * FROM WIND.AShareIncome WHERE 1=0` |
| 取样 N 行 | `SELECT TOP 20 ...` | `SELECT ... FROM WIND.X WHERE ROWNUM <= 20`。**没有** `LIMIT`，11g **也没有** `FETCH FIRST`（报 `ORA-00933`） |
| 带排序取前 N | `TOP 20 ... ORDER BY` | 先子查询 `ORDER BY`，外层再 `WHERE ROWNUM <= 20`（`ROWNUM` 在排序前生效，直接写会取错） |
| 字符串拼接 | `+` | `\|\|` |
| 当前日期 | `GETDATE()` | `SYSDATE`；常量表用 `DUAL` |
| 标识符 | 大小写不敏感 | 不加引号时自动转大写；写 `AShareIncome` 没问题，但目录视图里的值是 `ASHAREINCOME` |

字符串型日期比较（`REPORT_PERIOD BETWEEN '20230101' AND '20231231'`）和枚举值写法两边一致。pandas 读 Oracle 时 SQLAlchemy 会把列名转成**小写**（`s_info_windcode`），后续代码按小写取列。
---

## 6. 概念参考

### 6.1 Wind 订阅模型：**按表订阅，不是按库订阅**

Wind 数据库的订阅粒度是**表级**。一个用户可能只订阅了：

- 中国A股数据库里**部分**表（比如只有财务和行情，没有公告）
- 中国香港股票数据库里**部分**表
- 基础代码表里**大部分**表

**关键事实**：

1. **字典里有 ≠ 本机能读**。`dict.sh` 查到一张表不代表 SQL 能执行
2. **`WIND_LIST_DBS` 只是库级粗筛**，不代表白名单内的所有表都能读
3. **真实订阅边界只有数据库自己知道** —— 必须 probe

**probe 工作流**：

```sql
SELECT TOP 1 * FROM AShareIncome WHERE 1=0
-- MySQL/Postgres: SELECT * FROM AShareIncome WHERE 1=0 LIMIT 1
-- Oracle:         SELECT * FROM WIND.AShareIncome WHERE 1=0      （带 schema 前缀，见 §5.4.1）
```

用 `execute_sql_dbhub_wind`（Oracle：`query_wind`）跑这个 probe 是 OK 的（0 行回上下文）。

**probe 失败时**：
- **立刻停止**，不要写完整 SQL 脚本
- **告诉用户**："`AShareIncome` 字典里有但本机没订阅（原始错误：`...`）。我能找到的替代：..."
- 找替代的正确姿势：先 `search_objects_dbhub_wind(pattern="%<相关>%")`（Oracle：`query_wind` 查 `all_tables`，§5.4.1）看本机实际有什么类似表，再 `dict.sh -t` 查每个候选语义
- **不要**重试、不要 `sudo`、不要把权限错误当网络抖动

### 6.2 字段陷阱清单

| 字段 | 陷阱 |
|---|---|
| `S_INFO_WINDCODE` | 带交易所后缀（`000001.SZ`），不是纯数字 |
| `REPORT_PERIOD` / `ANN_DT` | `VARCHAR2(8)`，字符串格式 `YYYYMMDD`，不是 DATE |
| `STATEMENT_TYPE` | 枚举编码（`408001000`=合并、`408004000`=合并(调整)、`408005000`=合并(更正前)…），直接 `=` 会漏数据 |
| `NET_PROFIT` | 在利润表和现金流量表里**口径完全不同** |

查询日期区间推荐字符串比较：
```sql
REPORT_PERIOD BETWEEN '20230101' AND '20231231'
```

查询枚举字段显式写值：
```sql
STATEMENT_TYPE IN ('408001000', '408004000')
```

### 6.3 表变体 TAG：`[STD]` / `[PIT]` / `[LLT]` / `[ZL]`

`dict.sh -l` 输出的第 3 列。同一张表常有多个变体，**选错版本是常见错误**。

| TAG | 含义 | 场景 |
|---|---|---|
| `[STD]` | **标准版**（~94%） | **默认都选这个**。最完整、更新频率正常 |
| `[ZL]` | 增量版（~4%） | 只需要最近变动的数据，减扫描量 |
| `[PIT]` | **时点快照**（~1%） | **因子回测、避免前视偏差**时必选。表名一般带 `His` 后缀 |
| `[LLT]` | 低延时版（<1%） | 实盘接入、对延时敏感 |

**典型陷阱**：做历史回测选了 `[STD]` 而不是 `[PIT]`，拿到的是当前最新数据而非 T 日真实可用数据，**回测结果不可信**。

### 6.4 用户问话要多想一层

| 用户的话 | 你必须先想 |
|---|---|
| "读一下 A 股利润表" | 指 `AShareIncome` 还是自定义别名？**本机订阅了吗** |
| "需要 A 股 PIT 财务" | `AShareIncomeHis` 等 PIT 家族**单独订阅**，不一定有 |
| "从港股读基本信息" | 港股库大部分表**单独订阅**，别假设 |
| "X 和 Y 两表 join" | **两张都要**订阅，缺一张整个 workflow 报废 |
| "AShareXxx 是什么表" | **先 `dict.sh -t`**，不要从英文名直接翻译；查不到就明说"字典没找到" |
| "YyyHis 里有啥" | `His` 后缀是 **PIT 时点快照**，不是"历史数据" |
| "这表和那表啥区别" | 大概率是 STD/PIT/LLT/ZL 变体（§6.3），查字典看 TAG 列 |

---

## 7. Python 读数据模板

```python
import os
import pandas as pd
from sqlalchemy import create_engine
from dotenv import load_dotenv
from urllib.parse import quote_plus
from pathlib import Path

# .env 定位：$CLAUDE_PLUGIN_DATA 是「当前执行的 plugin」的数据目录，只有目录名是 wind-db* 时才可信
data_dir = os.environ.get('CLAUDE_PLUGIN_DATA', '')
if not Path(data_dir).name.startswith('wind-db'):
    data_dir = os.environ['CLAUDE_PLUGIN_ROOT']
load_dotenv(Path(data_dir) / '.env')

dialect = os.environ['WIND_DB_DIALECT']          # mssql+pyodbc / oracle+oracledb / mysql+pymysql / ...
user = quote_plus(os.environ['WIND_DB_USER'])    # URL 编码，防止密码特殊字符
pwd  = quote_plus(os.environ['WIND_DB_PASSWORD'])
host = os.environ['WIND_DB_HOST']
port = os.environ['WIND_DB_PORT']
db   = os.environ.get('WIND_DB_NAME', '')
schema = os.environ.get('WIND_DB_SCHEMA', '')     # Oracle 版 Wind 通常是 WIND；其他方言留空
prefix = f'{schema}.' if schema else ''

if dialect.startswith('oracle'):
    # 11g 必须 thick 模式（Instant Client，WIND_ORACLE_CLIENT_LIB_DIR）；≥ 12.1 可留空走 thin
    lib_dir = os.environ.get('WIND_ORACLE_CLIENT_LIB_DIR') or None
    sid = os.environ.get('WIND_DB_SID', '')
    url = (f"oracle+oracledb://{user}:{pwd}@{host}:{port}/{sid}" if sid
           else f"oracle+oracledb://{user}:{pwd}@{host}:{port}/?service_name={db}")
    engine = create_engine(url,
                           thick_mode={'lib_dir': lib_dir} if lib_dir else None,
                           arraysize=5000)         # 默认 fetch 批太小，百万行会非常慢
else:
    engine = create_engine(f"{dialect}://{user}:{pwd}@{host}:{port}/{db}")

sql = f"""
SELECT
    S_INFO_WINDCODE,
    ANN_DT,
    REPORT_PERIOD,
    STATEMENT_TYPE,
    NET_PROFIT_EXCL_MIN_INT_INC
FROM {prefix}AShareIncome
WHERE STATEMENT_TYPE = '408001000'                    -- 合并报表
  AND REPORT_PERIOD BETWEEN '20230101' AND '20231231'
  AND S_INFO_WINDCODE IN ('000001.SZ', '600519.SH')
"""

df = pd.read_sql(sql, engine)

out = Path('./data/ashare_income_2023.parquet')
out.parent.mkdir(parents=True, exist_ok=True)
df.to_parquet(out)

print(f"saved {len(df)} rows to {out}")
print(df.shape)
print(df.dtypes)
print(df.head())
```

依赖：`pandas sqlalchemy python-dotenv pyarrow` + 驱动（Oracle `oracledb`；SQL Server `pyodbc` + ODBC Driver 18；MySQL `pymysql`；Postgres `psycopg2-binary`）。手边没有虚拟环境时可以直接 `uv run --with pandas --with sqlalchemy --with python-dotenv --with pyarrow --with oracledb python script.py`。

Oracle 两个细节：
- SQLAlchemy 会把 Oracle 返回的列名转成**小写**（`df['s_info_windcode']`），后续代码别按大写取列
- thin 模式连 11g 报 `DPY-3010` 就是没配 `WIND_ORACLE_CLIENT_LIB_DIR`；thick 模式连通后 `oracledb.is_thin_mode()` 为 `False`

**绝对禁止**脚本末尾 `print(df)` 或 `print(df.to_string())` —— 只 `head / dtypes / shape`。

---

## 8. 外部资源

- **脚本**
  - `$CLAUDE_PLUGIN_ROOT/scripts/dict.sh` — Wind 数据字典查询
  - `$CLAUDE_PLUGIN_ROOT/scripts/setup-mcp.sh` — 数据库 MCP 一次性注册（非 Oracle → dbhub `dbhub-wind`；Oracle → FreePeak `dbmcp-wind`，自动下载预编译二进制到 `<数据目录>/bin/`，配置写 `<数据目录>/dbmcp-wind.json`；`--dry-run` 只看不做）
  - `$CLAUDE_PLUGIN_ROOT/scripts/install.sh` — 交互式首次安装向导（终端 tty）
  - `$CLAUDE_PLUGIN_ROOT/scripts/parse-dsn.py` — DSN 字符串解析器
- **配置**
  - `.env.example` — 凭据模板（plugin 根）
  - `.env` — 实际凭据（`$CLAUDE_PLUGIN_DATA/.env`，仅当该目录名是 `wind-db*`；否则 plugin 根）
- **外部字典**
  - 在线：`https://winddict.081188.xyz`（默认，basic auth）
  - 本地：`$WIND_DICT_LOCAL`（可选，dict.sh 优先走本地）
- **Oracle 相关**
  - FreePeak db-mcp-server：`https://github.com/FreePeak/db-mcp-server`（Go，go-ora 驱动，Oracle 10.2+，预编译二进制在 Releases）
  - Oracle Instant Client（macOS ARM64 免登录）：`https://download.oracle.com/otn_software/mac/instantclient/instantclient-basiclite-macos-arm64.dmg`
  - python-oracledb thick 模式：`https://python-oracledb.readthedocs.io/en/latest/user_guide/initialization.html`
- **Slash commands**
  - `/wind-db:setup` — 首次安装向导
  - `/wind-db:setup --reset` — 重置 `.env` 重填
