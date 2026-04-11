---
name: wind-db
description: 访问 Wind（万得）金融数据库。当用户需要从 Wind 数据库读取金融数据（A股/B股/债券/基金/指数等）、提及 Wind、万得、AShare、AIndex、BShare、CBond 等 Wind 表名、或要用 Wind 数据做量化/研究时使用。强制"先查数据字典、再写查询"工作流，并阻止 dbhub MCP 拉取大量数据造成上下文爆炸。
---

# Wind 金融数据库访问

## 触发条件

- 用户让你"查 Wind 数据"、"从 Wind 读 xxx 表"
- 代码里出现 `AShareIncome`、`AShareBalanceSheet`、`CBondDescription`、`AIndexEOD` 这类 Wind 表名
- 任何涉及 Wind 金融数据的分析 / 量化研究任务

## ⚠️ 工具路由：dbhub = "我的数据库"，dict.sh = "Wind 的说明书"

**区分这两个工具的事实边界是用好 skill 的核心**：

| 权威 | 工具 | 回答什么 |
|---|---|---|
| **本机真实数据库** | `dbhub-wind` MCP（`search_objects_dbhub_wind` / `execute_sql_dbhub_wind`） | 我**实际订阅、入库、能读**的表和列是什么 |
| **Wind 产品目录+说明书** | `scripts/dict.sh` + wind 字典站 | Wind **官方提供**什么表，每张表的字段、枚举值、FAQ、样例数据 |

**两者不可替换**：
- dbhub 不知道字段含义（Wind 不把中文描述存进 schema）
- dict.sh 不知道你实际订阅了什么（那是个产品目录，不是你的数据库快照）

### 按用户问题类型路由

| 用户的话 / 意图 | 应该用 | 不要用 |
|---|---|---|
| "**我的**数据库有什么表" / "**我**都订阅了什么" / "本机有没有 X 表" | `search_objects_dbhub_wind` | ~~`dict.sh -l`~~ |
| "A 股相关的表有哪些" / "列出所有 bond 开头的表" | `search_objects_dbhub_wind(pattern="AShare%")` | ~~`dict.sh`~~ |
| "这张表有什么列" / "字段类型是什么" | `search_objects_dbhub_wind(pattern='AShareIncome', type='table')`（拿 schema） | ~~`dict.sh`~~（字典的字段中文名不在 schema 里，后面补） |
| "**字段的中文含义**是什么" / "STATEMENT_TYPE 的值怎么解码" | `dict.sh <字段名>` 或 `dict.sh -t <表名>` + WebFetch / Read | ~~dbhub~~（数据库没存这些说明） |
| "Wind **有没有**提供 X 类型的表" / "Wind 有什么 PIT 数据" | `dict.sh -l` 或 `dict.sh <关键字>` | ~~dbhub~~（问的是产品目录） |
| "这表和那表有什么区别" / "业务概念 X 涉及哪些表" | `dict.sh <概念词>`（FAQ 里有交叉讨论） | ~~dbhub~~ |
| "这张表怎么 join"、"主键是什么" | `dict.sh -t <表名>` 读 MD 的"业务主键"段 | ~~dbhub~~（索引信息在 schema 里但没有业务语义） |

**典型的组合查询**：
- "给我找一张 A 股利润表来做因子" → 1) `search_objects_dbhub_wind(pattern="%Income%")` 看本机有什么 income 类表 → 2) `dict.sh -t <候选表>` 查每个候选的语义和 PIT 变体 → 3) 选定后 `WHERE 1=0` probe → 4) 写 Python 拉数据
- "这个 NET_PROFIT 字段什么意思" → `dict.sh AShareIncome`（或用户提的具体表），从数据字典段找字段定义。**不**用 dbhub，dbhub 只有列名和类型，没有中文解释。

## ⚠️ Wind 订阅模型：**按表订阅，不是按库订阅**

Wind 数据库的订阅粒度是 **表级**，**不是库级**。一个用户的订阅可能是：

- 中国A股数据库里 **部分** 表（比如只有财务数据和行情数据，没有公司公告）
- 中国香港股票数据库里 **部分** 表
- 基础代码表里 **大部分** 表

**这意味着**：

1. **字典里有的表 ≠ 本机能读**。`dict.sh` 查到一张表不代表 SQL 能执行，可能是 "ORA-00942: table or view does not exist" 或类似权限错误。
2. **`WIND_LIST_DBS` 只是库级粗筛**，用来把明显无关的库（比如完全没订阅的"宏观经济数据库"）从 `-l` 输出里排掉。它**不代表 "白名单里的库的所有表都能读"**。
3. **真实的订阅边界只有数据库自己知道**。Claude 必须把"表是否可读"当成一个运行时才能确认的事实。

### 用户问问题时的必备区分

| 用户的话 | 你必须先想 |
|---|---|
| "读一下 A 股利润表" | 他指的是 `AShareIncome` 吗？还是有自定义别名？**表是否订阅了** |
| "我需要 A 股的 PIT 财务数据" | `AShareIncomeHis` 等 PIT 家族是单独订阅的，不一定有 |
| "从港股读基本信息" | 港股库大部分表单独订阅，别假设 |
| "查 X 和 Y 两张表 join" | 两张表**都要**订阅才能 join，缺一张就整个 workflow 报废 |

### 工作流：先 probe 再 commit

写任何 SQL 脚本之前，**先对每张要用的表做一次轻量可用性探测**：

```sql
SELECT TOP 1 * FROM AShareIncome WHERE 1=0
-- 或 MySQL/Postgres: SELECT * FROM AShareIncome WHERE 1=0 LIMIT 1
```

`WHERE 1=0` 不返回数据但会暴露权限错误。用 `execute_sql_dbhub_wind` 跑这个探测是 OK 的（0 行回上下文，没有 context explosion 风险）。

**如果 probe 失败**：
- **立刻停止** 不要写完整 SQL 脚本
- **明确告诉用户**："`AShareIncome` 查字典存在但本机没订阅（权限错误：`<原始错误消息>`）。我能找到的替代：..."
- 找替代表的正确姿势：**先** `search_objects_dbhub_wind(pattern="%<相关>%")` 看本机实际订阅了什么类似表，**再**用 `dict.sh -t` 查每个候选的语义
- **绝对不要** 重试、不要 `sudo`、不要把权限错误当成"网络抖动"忽略

**如果 probe 成功**：可以信任这张表能用，继续写查询。

### 给用户的回复里必须区分这三种状态

1. ✅ **字典有 + probe 成功** → "已确认可读，写 SQL 中"
2. ⚠️ **字典有 + probe 失败** → "字典里有这张表但本机没订阅，需要你去买 / 换一张表"
3. ❌ **字典没有** → "字典里都没找到，请确认表名拼写，或检查字典是否最新"

不要混淆 2 和 3。**"读不到"对用户来说是两种完全不同的问题**：
- 字典有但读不到 = 订阅问题（用户可以去续费/扩展订阅）
- 字典都没有 = 拼写/版本问题（用户可能记错了名字）

## 核心纪律（违背任一项都会出事）

### 1. 先查数据字典，再写任何 SQL

Wind 的字段和值编码极其晦涩，**不查字典盲写 SQL 几乎必错**。典型陷阱：

- `S_INFO_WINDCODE` 是带交易所后缀的代码（`000001.SZ`），不是纯数字
- `REPORT_PERIOD`、`ANN_DT` 都是 `VARCHAR2(8)` 字符串格式 `YYYYMMDD`，不是 DATE
- `STATEMENT_TYPE` 是枚举编码（`408001000`=合并报表、`408004000`=合并报表(调整)、`408005000`=合并报表(更正前)…），直接 `=` 会漏数据
- 同一概念可能在多张表里，例如 `NET_PROFIT` 在利润表和现金流量表里口径完全不同

**必须**先调用 `scripts/dict.sh <表名或字段名>` 查字典，或读取本地 MD 文件，确认字段含义和值编码，**再**写查询。

### 2. dbhub MCP 只用于 schema inspection，不读数据

dbhub 的 `search_objects` 和 `execute_sql` 结果会直接回到上下文。Wind 单表动辄千万~上亿行，`SELECT *` 会秒爆上下文。

| 允许 | 禁止 |
|---|---|
| `search_objects` 列表、搜表名 | `execute_sql` 不带 `LIMIT` |
| 看列类型、主键、索引 | `SELECT *` 或无 `WHERE` |
| 带 `LIMIT 5` 的 sanity check | 返回 > 100 行的任何查询 |

dbhub 里实例名是 **`dbhub-wind`**（用 `setup-mcp.sh` 注册），其他 dbhub 实例不要混用。

### 3. 真正读数据用项目原生语言，结果写文件不回对话

Python / Go / Node 直连数据库，pandas/sqlalchemy 等读到 DataFrame 后：

- **写到文件**（parquet / csv / feather），路径告诉用户
- **只回显 `df.shape`、`df.dtypes`、`df.head()`** 让用户和你检查
- **不要**把 `df.to_string()` 或整个结果贴回对话

## 凭据和配置

所有凭据在 `~/.claude/skills/wind-db/.env`（此文件 gitignored）。

首次使用：
```bash
cd ~/.claude/skills/wind-db
cp .env.example .env
vim .env  # 填真实值
```

`.env` 里需要的键（见 `.env.example`）：

- `WIND_DB_DIALECT` / `WIND_DB_HOST` / `WIND_DB_PORT` / `WIND_DB_USER` / `WIND_DB_PASSWORD` / `WIND_DB_NAME`
- `WIND_DICT_URL`（默认 `https://winddict.081188.xyz`）
- `WIND_DICT_USER` / `WIND_DICT_PASS`（在线字典站的 basic auth）
- `WIND_DICT_LOCAL`（可选，本地字典目录。如果设置，`dict.sh` 会优先走本地）

读 `.env` 的方式（在任何 bash 脚本里）：
```bash
set -a; source ~/.claude/skills/wind-db/.env; set +a
```

## 查数据字典

**唯一入口**：`scripts/dict.sh`。**默认一律用 `-t` 精确模式**，只有在 `-t` 返回 0 结果时才回退到全文模式。

### 模式 1（默认/首选）：精确标题搜索 `-t`

```bash
bash ~/.claude/skills/wind-db/scripts/dict.sh -t AShareIncome   # 按英文表名
bash ~/.claude/skills/wind-db/scripts/dict.sh -t 利润表          # 按中文名
```

只匹配**根页面的 title 或 URL slug**，不展开任何 section，不搜正文。优势：
- 返回结果干净（通常 1 条），不会被"推荐产品""常见问题"等段落里的交叉引用污染
- 查表名、中文概念词都是一次就中
- 速度快、token 省

**限制**：查字段名（`STATEMENT_TYPE`、`S_INFO_WINDCODE`）返回 0 结果，因为字段只存在于表的正文里，不在 title。遇到这种情况才改用模式 2。

### 模式 2（fallback）：全文搜索

```bash
bash ~/.claude/skills/wind-db/scripts/dict.sh STATEMENT_TYPE    # 字段名
bash ~/.claude/skills/wind-db/scripts/dict.sh 合并报表          # 业务概念，想看 FAQ 交叉讨论
```

按 title/location 加权 + section 正文匹配，自动过滤"推荐产品"段的交叉引用噪声。返回多条结果，**只在需要查字段含义或业务概念时使用**。

### ⚠️ `-l` 是 Wind 产品目录筛选器，不是"我的数据库"

**再次强调**：`dict.sh -l` 输出的是 Wind **产品目录**（官方提供什么），不是本机**数据库快照**（实际有什么）。

- `WIND_LIST_DBS` 留空 → 输出 Wind 目录里全部 25 个库 ~2657 张
- `WIND_LIST_DBS` 填值 → 只输出指定库的目录条目（你**可能**订阅了其中一部分）

**用户问"我的数据库有什么表"时永远不要用 `-l` 回答**。应该用 `search_objects_dbhub_wind` 查真实数据库。`-l` 的正确用途是"Wind 有没有提供 X 类型的表"这种**目录查询**。

**什么时候用 `-l`**：
- 想在本机订阅范围之外看看 Wind 还提供了什么（可能要加购）
- 想做"有没有某种变体"的探索（比如"有没有 PIT 版"）
- 批量筛选字典做语义 grep

**查表是否可读的唯一可靠办法是 probe SQL**（`SELECT ... WHERE 1=0`），不是 `-l`。

### 模式 3：全量表名对照表 `-l` ⭐ AI 速查利器

```bash
bash ~/.claude/skills/wind-db/scripts/dict.sh -l                    # 全量 TSV，约 315 KB
bash ~/.claude/skills/wind-db/scripts/dict.sh -l | grep -F 利润表    # 按中文名管道过滤
bash ~/.claude/skills/wind-db/scripts/dict.sh -l | grep -v '\[PIT\]' # 过滤掉 PIT 版本
bash ~/.claude/skills/wind-db/scripts/dict.sh -l | awk -F'\t' '$3=="[STD]" && $4~/^中国A股/'   # A 股的标准表
```

**输出格式（TSV 四列）**：
```
<英文表名>  <中文名>  <[TAG]>  <数据库/模块路径>
```

**TAG 语义**（一张 Wind 表通常有多个变体，**选错版本是常见错误**）：

| TAG | 含义 | 使用场景 |
|---|---|---|
| `[STD]` | **标准版**（~94%） | **默认都选这个**。最完整、更新频率正常 |
| `[ZL]` | 增量版（~4%） | 只需要最近变动的数据，减少扫描量 |
| `[PIT]` | **时点快照**（~1%） | **做因子回测、避免前视偏差**时必选。表名一般带 `His` 后缀 |
| `[LLT]` | 低延时版（<1%） | 实盘接入、对延时敏感 |

**典型陷阱**：做历史回测时选了 `[STD]` 而不是 `[PIT]`，拿到的是当前最新数据而非 T 日真实可用数据，**回测结果不可信**。

### 何时用哪种模式？

**默认：永远先试 `-t`**。只有 `-t` 0 命中、或明确在查字段/业务概念时才换全文模式。

| 场景 | 首选命令 | 说明 |
|---|---|---|
| "这张表叫什么" | `dict.sh -t <名>` | **默认就这个** |
| "有这张表吗 / 怎么拼写" | `dict.sh -t <猜测>` | **默认就这个** |
| "有没有现成的表能做 X" | `dict.sh -l \| grep <关键字>` | 批量筛选用 `-l` |
| "A 股所有财务类表" | `dict.sh -l \| awk '$4~/中国A股.*财务/'` | 批量筛选用 `-l` |
| "这个字段什么意思" | `dict.sh <字段名>` | fallback 到全文（字段不在 title） |
| "这个业务概念涉及哪些表" | `dict.sh <概念词>` | fallback 到全文（想看 FAQ 交叉讨论） |

### 首次冷启动的推荐用法

大任务开始前，把 `-l` 的输出**保存到临时文件**，后续所有表名查找都从文件 grep，避免重复调用：

```bash
bash ~/.claude/skills/wind-db/scripts/dict.sh -l > /tmp/wind_tables.tsv
# 后续 grep /tmp/wind_tables.tsv
```

文件约 315KB，值得一次性加载；如果任务只涉及 1-2 张表，直接 `dict.sh -t` 更省资源。

## 配置 dbhub MCP（一次性）

```bash
bash ~/.claude/skills/wind-db/scripts/setup-mcp.sh
```

脚本会：
1. 读 `.env` 拿 DSN 组件
2. URL 编码用户名密码（处理特殊字符）
3. `claude mcp add dbhub-wind --scope user -- npx -y @bytebase/dbhub --dsn <dsn>`
4. 重启 Claude Code 后生效

注册后 dbhub MCP 工具会出现形如 `search_objects_dbhub_wind` / `execute_sql_dbhub_wind`。**永远用带 `_wind` 后缀的版本**，不要污染其他 dbhub 实例。

## 标准工作流

每次用户要读 Wind 数据，按这个顺序：

1. **理解需求**：需要哪张表、哪些字段、时间范围、筛选条件
2. **查字典**：用 `dict.sh` 找表和关键字段的 MD，确认
   - 表的业务主键是什么
   - 筛选字段是字符串还是数字，值编码有哪些
   - 字段的有值率（避免选到几乎全空的字段）
   - 常见问题（FAQ 里往往有隐藏陷阱）
3. **schema sanity check**（可选）：`search_objects_dbhub_wind` 确认列类型
4. **写 Python/SQL 脚本**：
   - 结果保存到 `./data/*.parquet` 或类似路径
   - 必须带 `WHERE` 和 `LIMIT`
   - 日期字段用字符串比较 `'20230101' <= REPORT_PERIOD <= '20231231'`
   - 枚举字段显式写值 `STATEMENT_TYPE IN ('408001000', '408004000')`
5. **跑脚本**：Bash 执行，只把 `df.shape / head / dtypes` 给用户
6. **后续分析**：都在 DataFrame / 文件上做，不再打扰数据库

## Python 读数据模板

```python
import os
import pandas as pd
from sqlalchemy import create_engine
from dotenv import load_dotenv
from urllib.parse import quote_plus
from pathlib import Path

load_dotenv(os.path.expanduser('~/.claude/skills/wind-db/.env'))

# URL 编码，防止密码里有特殊字符
user = quote_plus(os.environ['WIND_DB_USER'])
pwd  = quote_plus(os.environ['WIND_DB_PASSWORD'])
host = os.environ['WIND_DB_HOST']
port = os.environ.get('WIND_DB_PORT', '3306')
db   = os.environ['WIND_DB_NAME']
dialect = os.environ['WIND_DB_DIALECT']

# 常见 dialect: mysql+pymysql / postgresql+psycopg2 / oracle+cx_oracle / mssql+pyodbc
engine = create_engine(f"{dialect}://{user}:{pwd}@{host}:{port}/{db}")

sql = """
SELECT
    S_INFO_WINDCODE,
    ANN_DT,
    REPORT_PERIOD,
    STATEMENT_TYPE,
    NET_PROFIT_EXCL_MIN_INT_INC
FROM AShareIncome
WHERE STATEMENT_TYPE = '408001000'             -- 合并报表
  AND REPORT_PERIOD BETWEEN '20230101' AND '20231231'
  AND S_INFO_WINDCODE IN ('000001.SZ', '600519.SH')
"""

df = pd.read_sql(sql, engine)

out = Path('./data/ashare_income_2023.parquet')
out.parent.mkdir(parents=True, exist_ok=True)
df.to_parquet(out)

print(f"saved {len(df)} rows to {out}")
print(df.dtypes)
print(df.head())
```

**绝对禁止**在脚本最后 `print(df)` 或 `print(df.to_string())`，只 head/dtypes/shape。

## References

- `.env.example` — 凭据模板
- `scripts/dict.sh` — 字典查询入口
- `scripts/setup-mcp.sh` — 一次性 MCP 注册
- 外部：Wind 在线字典 `https://winddict.081188.xyz`
- 外部：本地字典仓库（如果有）`$WIND_DICT_LOCAL`
