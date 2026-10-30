---
description: wind-db plugin 首次安装向导：收集数据库/字典凭据 → 写入 .env → 可选注册 dbhub-wind MCP
argument-hint: (可选 --reset 重新填所有字段)
allowed-tools: Bash, Read, Write
---

# /wind-db:setup — wind-db 首次安装向导

你现在要**作为配置向导**帮用户完成 wind-db plugin 的首次安装。不要自己 bash 跑交互式脚本（read -s 在 Claude 会话里没有 tty，会卡住），而是通过对话依次收集字段，最后调用非交互的 `setup-env.sh` 落地。

## 第 1 步：推导 plugin 根路径并检查现状

**⚠️ 不要硬编码路径**（如 `~/workspace/quant-skills/...`）——那是开发者机器。

按以下优先级推导 `PLUGIN_ROOT`：

```bash
PLUGIN_ROOT=""

# 1. Plugin 正式安装模式：Claude Code 有时注入 $CLAUDE_PLUGIN_ROOT
#    （但并不是所有版本/场景都注入，所以不能只靠这个）
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -d "$CLAUDE_PLUGIN_ROOT" ]; then
  PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT"
fi

# 2. Plugin install 模式：~/.claude/plugins/cache/<marketplace>/wind-db/<version>/
#    扫所有 marketplace，找到 wind-db plugin 目录即可
if [ -z "$PLUGIN_ROOT" ]; then
  for cand in "$HOME"/.claude/plugins/cache/*/wind-db/*; do
    if [ -d "$cand" ] && [ -d "$cand/scripts" ]; then
      PLUGIN_ROOT="$cand"
      break
    fi
  done
fi

# 3. Symlink 开发模式：~/.claude/skills/wind-db 是符号链接
if [ -z "$PLUGIN_ROOT" ] && [ -L "$HOME/.claude/skills/wind-db" ]; then
  SKILL_TARGET=$(readlink "$HOME/.claude/skills/wind-db")
  case "$SKILL_TARGET" in
    /*) ;;
    *) SKILL_TARGET="$HOME/.claude/skills/$SKILL_TARGET" ;;
  esac
  # skills/wind-db/ 往上两级是 plugin 根
  candidate=$(cd "$SKILL_TARGET/../.." 2>/dev/null && pwd)
  if [ -n "$candidate" ] && [ -d "$candidate/scripts" ]; then
    PLUGIN_ROOT="$candidate"
  fi
fi

if [ -z "$PLUGIN_ROOT" ]; then
  echo "✗ 找不到 wind-db plugin。查找过的位置：" >&2
  echo "  - \$CLAUDE_PLUGIN_ROOT: ${CLAUDE_PLUGIN_ROOT:-未设置}" >&2
  echo "  - ~/.claude/plugins/cache/*/wind-db/*/: 未找到包含 scripts/ 的目录" >&2
  echo "  - ~/.claude/skills/wind-db (symlink): 不存在" >&2
  echo "" >&2
  echo "  可能的解决办法：" >&2
  echo "  - 通过 /plugin install wind-db@quant-skills 装 plugin" >&2
  echo "  - 或手动 symlink：git clone 仓库后" >&2
  echo "    ln -s <repo>/plugins/wind-db/skills/wind-db ~/.claude/skills/wind-db" >&2
  exit 1
fi

# $CLAUDE_PLUGIN_DATA 是「当前正在执行的 plugin」的数据目录；在别的 plugin 的会话里它指向别处
# （如 .../plugins/data/codex-xxx），所以只有目录名是 wind-db 的才用，否则回落 plugin 根
ENV_DIR="$PLUGIN_ROOT"
case "${CLAUDE_PLUGIN_DATA:-}" in
  */wind-db|*/wind-db-*) ENV_DIR="$CLAUDE_PLUGIN_DATA" ;;
esac
echo "PLUGIN_ROOT=$PLUGIN_ROOT"
echo "ENV_DIR=$ENV_DIR"

if [ -f "$ENV_DIR/.env" ]; then
  echo "✓ 已存在 .env：$ENV_DIR/.env"
else
  echo "✗ 无 .env，进入首次向导"
fi
```

**关键**：后面所有涉及脚本路径的命令（调用 `parse-dsn.py` / `setup-env.sh` / `setup-mcp.sh` 等），**一律用 `$PLUGIN_ROOT`**，**不要**在 Bash 命令里写 `$HOME/workspace/quant-skills/...` 这种硬编码。

**如果用户传入 `$ARGUMENTS` 包含 `--reset`**，覆盖现有 `.env`；否则检测到 `.env` 已存在时，告诉用户"已配置，如需重填请运行 `/wind-db:setup --reset`"并停止。

## 第 2 步：收集数据库连接（**先问用户选哪种方式**）

**不要一字段一字段问**——那样太啰嗦。先问用户：

> 我可以通过两种方式收集数据库连接信息：
>
> **A. 粘 DSN（推荐，一步到位）** — 把你手边已有的数据库连接串粘过来，我自动解析。支持的格式：
>   - SQLAlchemy：`mssql+pyodbc://user:pass@host:1433/db`
>   - 标准 URL：`sqlserver://user:pass@host:1433/db?sslmode=disable`
>   - Oracle：`oracle://user:pass@host:1521/service_name`（老式 SID 写 `?sid=ORCL`，或 JDBC `jdbc:oracle:thin:@host:1521:sid`）
>   - JDBC：`jdbc:sqlserver://host:1433;databaseName=db;user=x;password=y`
>   - ADO.NET：`Server=host,1433;Database=db;User Id=x;Password=y`
>   - 键值对：`host=x port=1433 user=scott password=tiger database=db dialect=mssql`
>
> **B. 逐项填（兜底）** — 如果你手边没有现成 DSN，我会一项一项问 dialect/host/port/user/password/database。
>
> 回复 A 或 B。

### 方式 A：粘 DSN

用户选 A 后，请他粘 DSN，然后**调一次 parse-dsn.py** 解析：

```bash
# $PLUGIN_ROOT 已在第 1 步推导好，这里直接用
python3 "$PLUGIN_ROOT/scripts/parse-dsn.py" '<用户粘贴的 DSN>'
```

**⚠️ 调用时参数要用单引号包起来**，避免 `$` / `!` / 空格等被 shell 误解析。如果用户粘的 DSN 自己含单引号，改用 stdin 模式：

```bash
echo '<DSN>' | python3 "$PLUGIN_ROOT/scripts/parse-dsn.py"
```

脚本输出形如：
```
WIND_DB_DIALECT='mssql+pyodbc'
WIND_DB_HOST='1.2.3.4'
WIND_DB_PORT='1433'
WIND_DB_USER='scott'
WIND_DB_PASSWORD='tiger'
WIND_DB_NAME='winddb'
```

**把识别结果以表格形式展示给用户**（密码脱敏为 `***`），然后问：
- "字段对吗？有没有要改的？" — 如果用户要改某字段，继续对话收集补丁
- 如果识别出 dialect = `oracle+oracledb`：**不用停**，Oracle 是正式支持的方言（MCP 走 FreePeak db-mcp-server，`setup-mcp.sh` 自动处理）。继续问下面的"Oracle 可选项"
- 如果识别出的字段不全（比如 user/password 缺失），追问缺失的那几个

**解析失败时**：脚本会在 stderr 打出支持的格式列表，告诉用户重新粘一个更清晰的 DSN，或者直接转方式 B。

### 方式 B：逐项填（兜底）

只在用户明确选 B 或方式 A 失败时使用。按以下顺序问，一次一个：

1. **dialect**：
   - `mssql+pyodbc`（SQL Server）← Wind 官方数据库最常见，**不确定就选这个**
   - `oracle+oracledb`（Oracle）← Wind 官方 Oracle 版。MCP 走 FreePeak db-mcp-server（纯 Go，`setup-mcp.sh` 自动下载预编译二进制），不走 dbhub（dbhub 的 Oracle connector 只有 Thin 模式，连不上 Wind 常见的 11g）
   - `mysql+pymysql` / `mariadb+pymysql` / `postgresql+psycopg2` / `sqlite`（走 dbhub）
2. **host**：数据库服务器地址（IP 或域名）
3. **port**：默认按 dialect 给建议（mssql=1433, oracle=1521, mysql/mariadb=3306, postgres=5432, sqlite 不用填）
4. **user**：数据库用户名
5. **password**：数据库密码。**⚠️ 提醒用户**：这条消息会出现在 Claude 对话历史里，如果他担心留痕可以先输一个占位符，等 `.env` 写好后手动 `vim` 改。不要替用户决定要不要脱敏。
6. **database**：数据库名（默认 `wind`）。Oracle 填 **service name**（如 `windb`）；只有老式 SID 的话这里留空，在下面 Oracle 可选项里填 `WIND_DB_SID`

### 方式 A/B 都适用：SQL Server 可选项（只在 dialect = mssql 时问）
- **sslmode**（可选）：默认 `disable`（适合内网 / 自签证书 / Wind 自建环境）。如果是云上 SQL Server 且强制 TLS，填 `require`。不确定就用默认。
  - 方式 A：如果用户粘的 URL 里 query 参数带了 `?sslmode=xxx`，脚本已经识别成 `WIND_DB_SSLMODE`，不用再问
- **instanceName**（可选）：命名实例名（如 `SQLEXPRESS`）。普通 SQL Server 不用填，留空即可。

### 方式 A/B 都适用：Oracle 可选项（只在 dialect = oracle 时问）
- **WIND_DB_SCHEMA**：Wind 表所在 schema（owner）。Oracle 版 Wind 通常把表建在 `WIND` 用户下，而登录账号是另一个只读用户（如 `RWIND`），靠同义词访问；同义词不一定覆盖全部表，所以 SQL 里带 `WIND.` 前缀最稳。**默认 `WIND`**，用户不清楚就用默认。
- **WIND_DB_SID**（可选）：只有没有 service name、用老式 SID 连接时才填。DSN 里带了 `?sid=` 或 JDBC `host:port:sid` 形式时脚本已识别成 `WIND_DB_SID`，不用再问。
- **WIND_ORACLE_CLIENT_LIB_DIR**（可选）：Oracle Instant Client 目录，只给 Python 批量读数用（MCP 不需要）。**服务器是 11g 时必填**：python-oracledb thin 模式连 11g 报 `DPY-3010`，必须 thick 模式；服务器 ≥ 12.1 可留空。用户不知道服务器版本就先留空，等 Python 读数报 `DPY-3010` 再补。macOS ARM64 免登录下载 `https://download.oracle.com/otn_software/mac/instantclient/instantclient-basiclite-macos-arm64.dmg`，挂载后把全部文件拷到如 `~/.local/opt/instantclient_23_3`，把这个路径填进来。

### 数据字典站
7. **WIND_DICT_URL**：默认 `https://winddict.081188.xyz`（用户如果有自己部署的字典站，填他自己的）
8. **WIND_DICT_USER**：字典站 basic auth 用户名。**直接让用户输，不要给默认值** —— 默认的 `admin` 是占位符，登不进去
9. **WIND_DICT_PASS**：字典站 basic auth 密码。**直接让用户输，不要建议默认** —— 没有通用默认密码

### 可选项（给默认值，用户回复"默认"即跳过）
10. **WIND_DICT_LOCAL**：本地字典目录路径（可选，填了 dict.sh 会优先走本地 grep 更快）。默认留空。
11. **WIND_LIST_DBS**：`dict.sh -l` 的库白名单。默认 `基础代码表,中国A股数据库,中国香港股票数据库,中国共同基金数据库,指数数据库`。

## 第 3 步：确认并落地

收集完后，**用一个紧凑的表格复述所有字段**（密码用 `***` 脱敏显示），问用户"确认写入吗？[y/n]"。用户确认后执行：

```bash
# $PLUGIN_ROOT 沿用第 1 步推导的值

WIND_DB_DIALECT='<用户填的>' \
WIND_DB_HOST='<用户填的>' \
WIND_DB_PORT='<用户填的>' \
WIND_DB_USER='<用户填的>' \
WIND_DB_PASSWORD='<用户填的>' \
WIND_DB_NAME='<用户填的>' \
WIND_DICT_URL='<用户填的>' \
WIND_DICT_USER='<用户填的>' \
WIND_DICT_PASS='<用户填的>' \
WIND_DICT_LOCAL='<用户填的或空>' \
WIND_LIST_DBS='<用户填的或默认>' \
WIND_DB_SSLMODE='<只在 mssql 且用户填了时传>' \
WIND_DB_INSTANCE='<只在 mssql 且用户填了时传>' \
WIND_DB_SCHEMA='<只在 oracle 时传，默认 WIND>' \
WIND_DB_SID='<只在 oracle 且用 SID 时传>' \
WIND_ORACLE_CLIENT_LIB_DIR='<只在 oracle 且用户填了时传>' \
bash "$PLUGIN_ROOT/scripts/setup-env.sh"
```

**传环境变量时值要用单引号**，避免 `$` / 空格 / `#` 被 shell 解析。

## 第 4 步：问是否注册 MCP

`.env` 写好后，再问用户："要现在注册数据库 MCP 吗？（之后在会话里可以直接探查 schema、跑小查询）[y/n]"。按 dialect 说明会注册哪个：
- 非 Oracle → `dbhub-wind`（@bytebase/dbhub，npx 启动），工具 `search_objects_dbhub_wind` / `execute_sql_dbhub_wind`
- Oracle → `dbmcp-wind`（FreePeak db-mcp-server：脚本从 GitHub release 下载预编译二进制并校验 SHA256，配置写到 `$ENV_DIR/dbmcp-wind.json`，密码通过环境变量注入不落盘；默认 `read_only: true`、`max_rows: 200`；注册前会试启动一次），工具 `query_wind` / `schema_wind`。可以先 `bash "$PLUGIN_ROOT/scripts/setup-mcp.sh" --dry-run` 给用户看将要做什么
- Oracle 试启动若报"账号持有写权限，read_only=true 拒绝启动"：这是 FreePeak 在启动时审计账号权限（持有 `CREATE TABLE` 等就拒绝）。**把两个选项原样转述给用户并等他决定**，不要自行改成 `false`：a) 请 DBA 收回写权限后重跑；b) `.env` 加 `WIND_DBMCP_READ_ONLY=false` 重跑，并建议在 Claude Code `permissions.deny` 加 `mcp__dbmcp-wind__execute_wind`、`mcp__dbmcp-wind__transaction_wind`

如果 yes，执行：

```bash
bash "$PLUGIN_ROOT/scripts/setup-mcp.sh"
```

注册成功后提醒用户：**重启 Claude Code 让 MCP 生效**。

## 第 5 步：结束提示

- 告诉用户 `.env` 写在哪里（`$CLAUDE_PLUGIN_DATA/.env` 或 plugin 根）
- 告诉用户后续改配置可以 `vim` 那个文件，或重跑 `/wind-db:setup --reset`
- 简单提示 skill 的两个主要工具：`bash "$CLAUDE_PLUGIN_ROOT/scripts/dict.sh" -t <表名>` 查字典，`search_objects_dbhub_wind` / `execute_sql_dbhub_wind`（Oracle：`query_wind`）查真实数据库

## 异常处理

- 如果 `setup-env.sh` 失败（比如缺字段），读脚本输出的错误，告诉用户哪个字段有问题，重新问那一个
- 如果 `setup-mcp.sh` 失败（比如 `claude` CLI 没在 PATH 里），告诉用户手动跑一下，给出命令
- 如果 Oracle 的二进制下载步骤被拦（内网 / 权限），告诉用户到 `https://github.com/FreePeak/db-mcp-server/releases` 手动下载对应平台文件，放到任意路径后在 `.env` 填 `WIND_DBMCP_BIN=<路径>` 重跑
- 整个过程中如果用户说"算了"/"退出"，干净退出，不要写半成品 .env

## 参数

- `$ARGUMENTS` 含 `--reset`：即使 `.env` 存在也继续问；否则默认幂等（已有就退出）
