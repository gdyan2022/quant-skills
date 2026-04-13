#!/usr/bin/env bash
# 一次性注册 dbhub-wind MCP 到 Claude Code
set -euo pipefail

# 优先用 Claude Code plugin 注入的 $CLAUDE_PLUGIN_ROOT，fallback 到脚本相对位置
# （兼容 plugin 模式 + 手动 clone 模式）
SCRIPT_DIR="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
# .env 优先放在 plugin 持久化目录（升级不会被删），fallback 到 plugin 根
ENV_FILE="${CLAUDE_PLUGIN_DATA:+$CLAUDE_PLUGIN_DATA/.env}"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"

if [ ! -f "$ENV_FILE" ]; then
  echo "✗ 未找到 ${ENV_FILE}，请先 cp .env.example .env 并填写"
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

: "${WIND_DB_DIALECT:?缺少 WIND_DB_DIALECT}"
: "${WIND_DB_HOST:?缺少 WIND_DB_HOST}"
: "${WIND_DB_USER:?缺少 WIND_DB_USER}"
: "${WIND_DB_PASSWORD:?缺少 WIND_DB_PASSWORD}"
: "${WIND_DB_NAME:?缺少 WIND_DB_NAME}"

command -v claude >/dev/null 2>&1 || { echo "✗ 未检测到 claude CLI"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "✗ 需要 python3 做 URL 编码"; exit 1; }

# 根据 @bytebase/dbhub 源码（src/connectors/*/index.ts）的 isValidDSN 校验：
#   PostgreSQL → postgres:// 或 postgresql://
#   MySQL      → mysql://
#   MariaDB    → mariadb://
#   SQL Server → sqlserver://    （不是 mssql://！）
#   SQLite     → sqlite://
#   Oracle     → 【不支持】dbhub 没有 Oracle connector
DIALECT_SHORT=$(echo "$WIND_DB_DIALECT" | cut -d'+' -f1)
case "$DIALECT_SHORT" in
  mysql)                DB_SCHEME="mysql" ;;
  mariadb)              DB_SCHEME="mariadb" ;;
  postgresql|postgres)  DB_SCHEME="postgres" ;;
  mssql|sqlserver)      DB_SCHEME="sqlserver" ;;
  sqlite)               DB_SCHEME="sqlite" ;;
  oracle)
    echo "✗ dbhub 不支持 Oracle（只支持 Postgres/MySQL/MariaDB/SQL Server/SQLite）" >&2
    echo "  参考：https://github.com/bytebase/dbhub/tree/main/src/connectors" >&2
    exit 1
    ;;
  *) DB_SCHEME="$DIALECT_SHORT" ;;
esac

# 合理的默认端口（按 dialect）
if [ -n "${WIND_DB_PORT:-}" ]; then
  PORT="$WIND_DB_PORT"
else
  case "$DB_SCHEME" in
    sqlserver) PORT=1433 ;;
    postgres)  PORT=5432 ;;
    mariadb)   PORT=3306 ;;
    mysql)     PORT=3306 ;;
    *)         PORT=3306 ;;
  esac
fi

USER_ENC=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=''))" "$WIND_DB_USER")
PASS_ENC=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=''))" "$WIND_DB_PASSWORD")

# SQL Server 的 query 参数：
#   - dbhub 默认 encrypt=true, trustServerCertificate=false，连内网/自签证书的 SQL Server 常失败
#   - sslmode=disable 映射到 encrypt=false, trustServerCertificate=false（适合多数 Wind 自建环境）
#   - 用户可通过 WIND_DB_SSLMODE 覆盖（如 require / disable）
#   - 用户可通过 WIND_DB_INSTANCE 指定命名实例
#   参考：src/connectors/sqlserver/index.ts 的 query 参数解析
QUERY=""
if [ "$DB_SCHEME" = "sqlserver" ]; then
  SSLMODE="${WIND_DB_SSLMODE:-disable}"
  QUERY="?sslmode=${SSLMODE}"
  if [ -n "${WIND_DB_INSTANCE:-}" ]; then
    QUERY="${QUERY}&instanceName=${WIND_DB_INSTANCE}"
  fi
fi

DSN="${DB_SCHEME}://${USER_ENC}:${PASS_ENC}@${WIND_DB_HOST}:${PORT}/${WIND_DB_NAME}${QUERY}"

echo "==> 将注册 MCP 服务器 'dbhub-wind'"
echo "    scheme  : $DB_SCHEME"
echo "    host    : $WIND_DB_HOST:$PORT"
echo "    db      : $WIND_DB_NAME"
echo "    user    : $WIND_DB_USER"
echo "    (密码已 URL 编码，不在终端显示)"
echo ""

# 如果已经存在则先删除（避免 add 失败）
if claude mcp list 2>/dev/null | grep -q 'dbhub-wind'; then
  echo "  检测到已存在的 dbhub-wind，先移除旧配置"
  claude mcp remove dbhub-wind --scope user >/dev/null 2>&1 || true
fi

claude mcp add dbhub-wind \
  --scope user \
  -- npx -y @bytebase/dbhub --dsn "$DSN"

echo ""
echo "✓ 已注册。请重启 Claude Code 使 MCP 生效。"
echo "  验证: claude mcp list"
