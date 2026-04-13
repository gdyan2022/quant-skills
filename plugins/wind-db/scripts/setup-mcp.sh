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
  echo "✗ 未找到 $ENV_FILE，请先 cp .env.example .env 并填写"
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

# dbhub 用纯 dialect 名（mysql / postgres / oracle / mssql），去掉 sqlalchemy 的 driver 后缀
DIALECT_SHORT=$(echo "$WIND_DB_DIALECT" | cut -d'+' -f1)
case "$DIALECT_SHORT" in
  mysql|mariadb) DB_SCHEME="mysql" ;;
  postgresql|postgres) DB_SCHEME="postgres" ;;
  oracle) DB_SCHEME="oracle" ;;
  mssql|sqlserver) DB_SCHEME="mssql" ;;
  *) DB_SCHEME="$DIALECT_SHORT" ;;
esac

PORT="${WIND_DB_PORT:-3306}"

USER_ENC=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=''))" "$WIND_DB_USER")
PASS_ENC=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=''))" "$WIND_DB_PASSWORD")

DSN="${DB_SCHEME}://${USER_ENC}:${PASS_ENC}@${WIND_DB_HOST}:${PORT}/${WIND_DB_NAME}"

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
