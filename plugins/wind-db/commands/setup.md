---
description: wind-db plugin 首次安装向导：收集数据库/字典凭据 → 写入 .env → 可选注册 dbhub-wind MCP
argument-hint: (可选 --reset 重新填所有字段)
allowed-tools: Bash, Read, Write
---

# /wind-db:setup — wind-db 首次安装向导

你现在要**作为配置向导**帮用户完成 wind-db plugin 的首次安装。不要自己 bash 跑交互式脚本（read -s 在 Claude 会话里没有 tty，会卡住），而是通过对话依次收集字段，最后调用非交互的 `setup-env.sh` 落地。

## 第 1 步：检查现状

先看一下 plugin 根和 .env 状态：

```bash
echo "CLAUDE_PLUGIN_ROOT=${CLAUDE_PLUGIN_ROOT:-未设置（可能是 symlink 模式）}"
echo "CLAUDE_PLUGIN_DATA=${CLAUDE_PLUGIN_DATA:-未设置}"

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$HOME/workspace/quant-skills/plugins/wind-db}"
ENV_DIR="${CLAUDE_PLUGIN_DATA:-$PLUGIN_ROOT}"

if [ -f "$ENV_DIR/.env" ]; then
  echo "✓ 已存在 .env：$ENV_DIR/.env"
  echo "  （若用户传了 --reset 则覆盖，否则告知用户'已配置'并退出）"
else
  echo "✗ 无 .env，进入首次向导"
fi
```

**如果用户传入 `$ARGUMENTS` 包含 `--reset`**，覆盖现有 `.env`；否则检测到 `.env` 已存在时，告诉用户"已配置，如需重填请运行 `/wind-db:setup --reset`"并停止。

## 第 2 步：收集字段（通过对话）

按以下顺序**一次问一个**（或一次问一组相关字段，由用户判断），用中文，不要一次性给用户一个表单。每次问完等用户回答再问下一个。遇到可以给合理默认值的，**明确告诉用户默认值**，让他直接回复"默认"即可。

### 数据库连接
1. **dialect**：**dbhub 只支持这些**（源码见 https://github.com/bytebase/dbhub/tree/main/src/connectors）：
   - `mssql+pyodbc`（SQL Server）← Wind 官方数据库最常见，**强烈建议选这个**
   - `mysql+pymysql`
   - `mariadb+pymysql`
   - `postgresql+psycopg2`
   - `sqlite`

   **⚠️ dbhub 不支持 Oracle**。如果用户想用 Oracle，告诉他 dbhub MCP 装不了，只能用 `dict.sh` 部分功能（查字典），不能走 `execute_sql` probe 和 schema 查询。
2. **host**：数据库服务器地址（IP 或域名）
3. **port**：默认按 dialect 给建议（mssql=1433, mysql/mariadb=3306, postgres=5432, sqlite 不用填）
4. **user**：数据库用户名
5. **password**：数据库密码。**⚠️ 提醒用户**：这条消息会出现在 Claude 对话历史里，如果他担心留痕可以先输一个占位符，等 `.env` 写好后手动 `vim` 改。不要替用户决定要不要脱敏。
6. **database**：数据库名（默认 `wind`）

### SQL Server 专用（只在 dialect = mssql 时问）
6b. **sslmode**（可选）：默认 `disable`（适合内网 / 自签证书 / Wind 自建环境）。如果是云上 SQL Server 且强制 TLS，填 `require`。不确定就用默认。
6c. **instanceName**（可选）：命名实例名（如 `SQLEXPRESS`）。普通 SQL Server 不用填，留空即可。

### 数据字典站
7. **WIND_DICT_URL**：默认 `https://winddict.081188.xyz`（用户如果有自己部署的字典站，填他自己的）
8. **WIND_DICT_USER**：字典站 basic auth 用户名，默认 `admin`
9. **WIND_DICT_PASS**：字典站 basic auth 密码

### 可选项（给默认值，用户回复"默认"即跳过）
10. **WIND_DICT_LOCAL**：本地字典目录路径（可选，填了 dict.sh 会优先走本地 grep 更快）。默认留空。
11. **WIND_LIST_DBS**：`dict.sh -l` 的库白名单。默认 `基础代码表,中国A股数据库,中国香港股票数据库,中国共同基金数据库,指数数据库`。

## 第 3 步：确认并落地

收集完后，**用一个紧凑的表格复述所有字段**（密码用 `***` 脱敏显示），问用户"确认写入吗？[y/n]"。用户确认后执行：

```bash
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$HOME/workspace/quant-skills/plugins/wind-db}"

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
bash "$PLUGIN_ROOT/scripts/setup-env.sh"
```

**传环境变量时值要用单引号**，避免 `$` / 空格 / `#` 被 shell 解析。

## 第 4 步：问是否注册 MCP

`.env` 写好后，再问用户："要现在注册 `dbhub-wind` MCP 吗？（之后在会话里可以用 `search_objects` / `execute_sql` 探查 schema）[y/n]"

如果 yes，执行：

```bash
bash "${CLAUDE_PLUGIN_ROOT:-$HOME/workspace/quant-skills/plugins/wind-db}/scripts/setup-mcp.sh"
```

注册成功后提醒用户：**重启 Claude Code 让 MCP 生效**。

## 第 5 步：结束提示

- 告诉用户 `.env` 写在哪里（`$CLAUDE_PLUGIN_DATA/.env` 或 plugin 根）
- 告诉用户后续改配置可以 `vim` 那个文件，或重跑 `/wind-db:setup --reset`
- 简单提示 skill 的两个主要工具：`bash "$CLAUDE_PLUGIN_ROOT/scripts/dict.sh" -t <表名>` 查字典，`search_objects_dbhub_wind` / `execute_sql_dbhub_wind` 查真实数据库

## 异常处理

- 如果 `setup-env.sh` 失败（比如缺字段），读脚本输出的错误，告诉用户哪个字段有问题，重新问那一个
- 如果 `setup-mcp.sh` 失败（比如 `claude` CLI 没在 PATH 里），告诉用户手动跑一下，给出命令
- 整个过程中如果用户说"算了"/"退出"，干净退出，不要写半成品 .env

## 参数

- `$ARGUMENTS` 含 `--reset`：即使 `.env` 存在也继续问；否则默认幂等（已有就退出）
