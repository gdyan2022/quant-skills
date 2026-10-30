#!/usr/bin/env bash
# wind-db 非交互式 .env 写入脚本
#
# 用法：给所有字段通过环境变量传入，脚本负责 shell-safe 引号化 + 写回 + 权限 600
#
# 必需的环境变量：
#   WIND_DB_DIALECT WIND_DB_HOST WIND_DB_USER WIND_DB_PASSWORD
#   WIND_DB_NAME（Oracle 可改填 WIND_DB_SID）
#   WIND_DICT_URL WIND_DICT_USER WIND_DICT_PASS
# 可选：
#   WIND_DB_PORT（缺省按 dialect 给默认）WIND_DICT_LOCAL WIND_LIST_DBS
#   WIND_DB_SSLMODE WIND_DB_INSTANCE                       ← SQL Server
#   WIND_DB_SCHEMA WIND_DB_SID WIND_ORACLE_CLIENT_LIB_DIR   ← Oracle
#   WIND_DBMCP_VERSION WIND_DBMCP_BIN WIND_DBMCP_READ_ONLY ← Oracle MCP
#   WIND_DB_REGISTER_MCP=1   ← 非空则顺带注册 MCP
#
# 为什么做成非交互：交互式 read -s 在 Claude Code 会话里跑会卡住没有 tty。
# /wind-db:setup 命令由 Claude 作为向导收集字段，再调用本脚本做落地。
set -euo pipefail

SCRIPT_DIR="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

# .env 放在 plugin 持久化目录（升级不丢）。$CLAUDE_PLUGIN_DATA 是「当前正在执行的 plugin」的数据目录，
# 在别的 plugin 的会话里它会指向别处（如 .../plugins/data/codex-xxx），所以必须校验目录名是 wind-db 的。
DATA_DIR=""
case "${CLAUDE_PLUGIN_DATA:-}" in
  */wind-db|*/wind-db-*) DATA_DIR="$CLAUDE_PLUGIN_DATA" ;;
esac
DATA_DIR="${DATA_DIR:-$SCRIPT_DIR}"
mkdir -p "$DATA_DIR"
ENV_FILE="$DATA_DIR/.env"

# 必填检查
: "${WIND_DB_DIALECT:?缺少 WIND_DB_DIALECT}"
: "${WIND_DB_HOST:?缺少 WIND_DB_HOST}"
: "${WIND_DB_USER:?缺少 WIND_DB_USER}"
: "${WIND_DB_PASSWORD:?缺少 WIND_DB_PASSWORD}"
: "${WIND_DICT_URL:?缺少 WIND_DICT_URL}"
: "${WIND_DICT_USER:?缺少 WIND_DICT_USER}"
: "${WIND_DICT_PASS:?缺少 WIND_DICT_PASS}"

# dialect 规范化 + 默认端口
DIALECT_SHORT="${WIND_DB_DIALECT%%+*}"
case "$DIALECT_SHORT" in
  oracle)
    # cx_Oracle 已停更且必须装 Instant Client；统一用 python-oracledb（oracle+oracledb）
    if [ "$WIND_DB_DIALECT" != "oracle+oracledb" ]; then
      echo "  ℹ dialect '$WIND_DB_DIALECT' 规范化为 oracle+oracledb（python-oracledb 驱动）" >&2
      WIND_DB_DIALECT="oracle+oracledb"
    fi
    DEFAULT_PORT=1521
    ;;
  mssql|sqlserver)      DEFAULT_PORT=1433 ;;
  mysql|mariadb)        DEFAULT_PORT=3306 ;;
  postgresql|postgres)  DEFAULT_PORT=5432 ;;
  *)                    DEFAULT_PORT="" ;;
esac
WIND_DB_PORT="${WIND_DB_PORT:-$DEFAULT_PORT}"

# 库名：Oracle 允许用 SID 代替 service name
WIND_DB_NAME="${WIND_DB_NAME:-}"
WIND_DB_SID="${WIND_DB_SID:-}"
if [ -z "$WIND_DB_NAME" ] && [ -z "$WIND_DB_SID" ]; then
  echo "✗ 缺少 WIND_DB_NAME（Oracle 也可以改填 WIND_DB_SID）" >&2
  exit 1
fi

# 默认值
WIND_DICT_LOCAL="${WIND_DICT_LOCAL:-}"
WIND_LIST_DBS="${WIND_LIST_DBS:-基础代码表,中国A股数据库,中国香港股票数据库,中国共同基金数据库,指数数据库}"
WIND_DB_SSLMODE="${WIND_DB_SSLMODE:-}"
WIND_DB_INSTANCE="${WIND_DB_INSTANCE:-}"
WIND_DB_SCHEMA="${WIND_DB_SCHEMA:-}"
WIND_ORACLE_CLIENT_LIB_DIR="${WIND_ORACLE_CLIENT_LIB_DIR:-}"
WIND_DBMCP_VERSION="${WIND_DBMCP_VERSION:-}"
WIND_DBMCP_BIN="${WIND_DBMCP_BIN:-}"
WIND_DBMCP_READ_ONLY="${WIND_DBMCP_READ_ONLY:-}"

# shell 安全单引号包裹（值里的 ' 转义成 '\''）
quote() {
  local s="$1"
  printf "'%s'" "${s//\'/\'\\\'\'}"
}

cat > "$ENV_FILE" <<EOF
# Wind 数据库访问配置（由 /wind-db:setup 生成，可手动编辑；字段说明见 .env.example）

# ── 数据库连接 ───────────────────────────────────────────
WIND_DB_DIALECT=$(quote "$WIND_DB_DIALECT")
WIND_DB_HOST=$(quote "$WIND_DB_HOST")
WIND_DB_PORT=$(quote "$WIND_DB_PORT")
WIND_DB_USER=$(quote "$WIND_DB_USER")
WIND_DB_PASSWORD=$(quote "$WIND_DB_PASSWORD")
WIND_DB_NAME=$(quote "$WIND_DB_NAME")

# ── 数据字典（在线版）────────────────────────────────────
WIND_DICT_URL=$(quote "$WIND_DICT_URL")
WIND_DICT_USER=$(quote "$WIND_DICT_USER")
WIND_DICT_PASS=$(quote "$WIND_DICT_PASS")

# ── 数据字典（本地版，可选）─────────────────────────────
WIND_DICT_LOCAL=$(quote "$WIND_DICT_LOCAL")

# ── 列表模式过滤（dict.sh -l 的库白名单）────────────────
WIND_LIST_DBS=$(quote "$WIND_LIST_DBS")

# ── SQL Server 专用（可选）──────────────────────────────
WIND_DB_SSLMODE=$(quote "$WIND_DB_SSLMODE")
WIND_DB_INSTANCE=$(quote "$WIND_DB_INSTANCE")

# ── Oracle 专用（可选）──────────────────────────────────
WIND_DB_SCHEMA=$(quote "$WIND_DB_SCHEMA")
WIND_DB_SID=$(quote "$WIND_DB_SID")
WIND_ORACLE_CLIENT_LIB_DIR=$(quote "$WIND_ORACLE_CLIENT_LIB_DIR")
WIND_DBMCP_VERSION=$(quote "$WIND_DBMCP_VERSION")
WIND_DBMCP_BIN=$(quote "$WIND_DBMCP_BIN")
WIND_DBMCP_READ_ONLY=$(quote "$WIND_DBMCP_READ_ONLY")
EOF

chmod 600 "$ENV_FILE"
echo "✓ .env 已写入：${ENV_FILE}（权限 600）"

# 可选：注册 MCP
if [ -n "${WIND_DB_REGISTER_MCP:-}" ]; then
  echo "==> 注册数据库 MCP"
  bash "$SCRIPT_DIR/scripts/setup-mcp.sh"
fi
