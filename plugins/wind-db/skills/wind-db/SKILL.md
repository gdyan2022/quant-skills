---
name: wind-db
description: 访问 Wind（万得）金融数据库。当用户需要从 Wind 数据库读取金融数据（A股/B股/债券/基金/指数等）、提及 Wind、万得、AShare、AIndex、BShare、CBond 等 Wind 表名、或要用 Wind 数据做量化/研究时使用。强制"先查数据字典、再写查询"工作流，并阻止 dbhub MCP 拉取大量数据造成上下文爆炸。
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

这个 slash command 会引导用户粘 DSN（或逐项填字段）、填字典站凭据，写入 `.env`（存放在 plugin 持久化目录 `$CLAUDE_PLUGIN_DATA`，升级不丢），并可选注册 `dbhub-wind` MCP。

**没跑过 `/wind-db:setup` 之前，本 skill 的其他命令（dict.sh / execute_sql）都会因为缺少 `.env` 失败。**

如果 dbhub MCP 列表里还没有 `dbhub-wind`（`claude mcp list` 看），说明 MCP 没注册，需要跑：

```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/setup-mcp.sh"
```

然后**重启 Claude Code**。

---

## 3. 标准工作流（每次读 Wind 数据按这个顺序）

1. **理解需求**：需要哪张表、哪些字段、时间范围、筛选条件
2. **查字典**（`dict.sh -t <表名>`）：确认表的业务含义、关键字段的值编码、FAQ 里的陷阱（见 §5.1）
3. **probe 一下**（`execute_sql_dbhub_wind` 跑 `WHERE 1=0`）：确认本机真的订阅了这张表（见 §6.1）
4. **写 Python 脚本**：结果落到 `./data/*.parquet`，不回对话
5. **执行脚本**：只把 `df.shape / dtypes / head()` 给用户
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

### 4.2 dbhub MCP 只用于 schema inspection，不读数据

dbhub 的 `execute_sql` 结果会直接回到上下文。Wind 单表动辄千万~上亿行，`SELECT *` 秒爆上下文。

| 允许用 dbhub MCP | 禁止 |
|---|---|
| `search_objects_dbhub_wind` 列表/搜表名 | `execute_sql` 不带 `LIMIT` |
| `WHERE 1=0` probe 检查权限 | `SELECT *` 或无 `WHERE` |
| 带 `LIMIT 5` 的 sanity check | 返回 > 100 行的任何查询 |

### 4.3 真正读数据用 Python，结果写文件不回对话

用 pandas/sqlalchemy 直连数据库 → 存 parquet → 只回显 `df.head() / df.shape / df.dtypes`。**绝不** `print(df)` 或 `df.to_string()`。模板见 §7。

---

## 5. 工具参考

### 5.1 `dict.sh` — Wind 数据字典查询

**入口**：`bash "$CLAUDE_PLUGIN_ROOT/scripts/dict.sh" ...`

**默认一律用 `-t` 精确模式**，0 命中时才退到全文模式。

| 模式 | 命令 | 何时用 |
|---|---|---|
| **`-t` 精确** | `dict.sh -t AShareIncome`<br>`dict.sh -t 利润表` | **首选**。查表（英文名或中文名），干净、1 条结果 |
| **全文（默认）** | `dict.sh STATEMENT_TYPE`<br>`dict.sh 合并报表` | `-t` 0 命中时。查字段含义、业务概念、FAQ 交叉讨论 |
| **`-l` 列表** | `dict.sh -l \| grep <词>`<br>`dict.sh -l \| awk ...` | 批量筛选字典（**不是**查本机订阅）。见下条 |

**`-l` 陷阱**：输出的是 Wind **产品目录**（官方提供什么），**不是本机数据库快照**。用户问"我的数据库有什么表"时**永远不要**用 `-l` 回答 —— 要用 `search_objects_dbhub_wind`。

**冷启动推荐**：大任务前缓存一次 `-l` 到临时文件，后续 grep：
```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/dict.sh" -l > /tmp/wind_tables.tsv
```

### 5.2 `dbhub-wind` MCP —"我的数据库"

注册后工具名形如 `search_objects_dbhub_wind` / `execute_sql_dbhub_wind`。**永远用带 `_wind` 后缀的版本**，不要污染其他 dbhub 实例。

| 工具 | 用法 |
|---|---|
| `search_objects_dbhub_wind(pattern='AShare%', type='table')` | 列本机订阅的表、看 schema、主键、索引 |
| `execute_sql_dbhub_wind(sql='SELECT ... WHERE 1=0')` | **probe** 权限（0 行不污染上下文） |
| `execute_sql_dbhub_wind(sql='SELECT ... LIMIT 5')` | sanity check 几行，看字段值的形状 |

**不要用 dbhub 读真数据** —— 那是 Python 脚本的职责（§7）。

### 5.3 `dict.sh` vs `dbhub` 路由速查

| 用户的话 / 意图 | 用这个 | 不要用 |
|---|---|---|
| "**我的**数据库有什么表" | `search_objects_dbhub_wind` | ~~`dict.sh -l`~~ |
| "A 股相关表" / "bond 开头" | `search_objects_dbhub_wind(pattern=...)` | ~~`dict.sh`~~ |
| "字段类型" / "主键" | `search_objects_dbhub_wind` | ~~`dict.sh`~~ |
| "**字段的中文含义**" / "STATEMENT_TYPE 值怎么解码" | `dict.sh <字段>` 或 `dict.sh -t <表>` | ~~dbhub~~（schema 里没中文） |
| "Wind **有没有**提供 X 表" / "有 PIT 版吗" | `dict.sh -l` 或 `dict.sh <关键字>` | ~~dbhub~~（问的是目录） |
| "这表怎么 join" / "业务主键" | `dict.sh -t <表>` 读 MD | ~~dbhub~~（索引无业务语义） |

**组合查询**：
- "找一张 A 股利润表做因子" → `search_objects_dbhub_wind(pattern='%Income%')` 看本机有什么 → `dict.sh -t <候选>` 查语义和 PIT 变体 → `WHERE 1=0` probe → 写 Python
- "NET_PROFIT 什么意思" → `dict.sh AShareIncome` 读数据字典段，**不**用 dbhub

### 5.4 Oracle 用户：不走 dbhub，走 FreePeak

dbhub 不支持 Oracle。运行 `setup-mcp.sh` 时如果 `WIND_DB_DIALECT=oracle+*` 会直接给出 FreePeak/db-mcp-server（纯 Go 驱动，**不需要 Oracle Instant Client**）的 5 步手动集成指引。

**Oracle 模式下工具名不同**（工作流完全一致）：

| dbhub | FreePeak | 作用 |
|---|---|---|
| `search_objects_dbhub_wind` | `schema_wind` | 列表、DDL、索引 |
| `execute_sql_dbhub_wind` | `query_wind` | SELECT 查询 / probe |
| — | `execute_wind` | DML（谨慎） |

Oracle 用户阅读本 SKILL.md 时，把 `search_objects_dbhub_wind` 替换为 `schema_wind`，`execute_sql_dbhub_wind` 替换为 `query_wind`。

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
```

用 `execute_sql_dbhub_wind` 跑这个 probe 是 OK 的（0 行回上下文）。

**probe 失败时**：
- **立刻停止**，不要写完整 SQL 脚本
- **告诉用户**："`AShareIncome` 字典里有但本机没订阅（原始错误：`...`）。我能找到的替代：..."
- 找替代的正确姿势：先 `search_objects_dbhub_wind(pattern="%<相关>%")` 看本机实际有什么类似表，再 `dict.sh -t` 查每个候选语义
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

---

## 7. Python 读数据模板

```python
import os
import pandas as pd
from sqlalchemy import create_engine
from dotenv import load_dotenv
from urllib.parse import quote_plus
from pathlib import Path

# 优先读 plugin 持久化目录，fallback plugin 根
env_dir = os.environ.get('CLAUDE_PLUGIN_DATA') or os.environ['CLAUDE_PLUGIN_ROOT']
load_dotenv(Path(env_dir) / '.env')

# URL 编码，防止密码特殊字符
user = quote_plus(os.environ['WIND_DB_USER'])
pwd  = quote_plus(os.environ['WIND_DB_PASSWORD'])
host = os.environ['WIND_DB_HOST']
port = os.environ.get('WIND_DB_PORT', '1433')
db   = os.environ['WIND_DB_NAME']
dialect = os.environ['WIND_DB_DIALECT']

# dialect 常见值：mssql+pyodbc / mysql+pymysql / postgresql+psycopg2 / oracle+cx_oracle
engine = create_engine(f"{dialect}://{user}:{pwd}@{host}:{port}/{db}")

sql = """
SELECT
    S_INFO_WINDCODE,
    ANN_DT,
    REPORT_PERIOD,
    STATEMENT_TYPE,
    NET_PROFIT_EXCL_MIN_INT_INC
FROM AShareIncome
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

**绝对禁止**脚本末尾 `print(df)` 或 `print(df.to_string())` —— 只 `head / dtypes / shape`。

---

## 8. 外部资源

- **脚本**
  - `$CLAUDE_PLUGIN_ROOT/scripts/dict.sh` — Wind 数据字典查询
  - `$CLAUDE_PLUGIN_ROOT/scripts/setup-mcp.sh` — dbhub MCP 一次性注册
  - `$CLAUDE_PLUGIN_ROOT/scripts/install.sh` — 交互式首次安装向导（终端 tty）
  - `$CLAUDE_PLUGIN_ROOT/scripts/parse-dsn.py` — DSN 字符串解析器
- **配置**
  - `.env.example` — 凭据模板（plugin 根）
  - `.env` — 实际凭据（优先 `$CLAUDE_PLUGIN_DATA/.env`）
- **外部字典**
  - 在线：`https://winddict.081188.xyz`（默认，basic auth）
  - 本地：`$WIND_DICT_LOCAL`（可选，dict.sh 优先走本地）
- **Slash commands**
  - `/wind-db:setup` — 首次安装向导
  - `/wind-db:setup --reset` — 重置 `.env` 重填
