#!/usr/bin/env bash
# wind-db 非交互式 .env 写入脚本
#
# 用法：给所有字段通过环境变量传入，脚本负责 shell-safe 引号化 + 写回 + 权限 600
#
# 必需的环境变量：
#   WIND_DB_DIALECT WIND_DB_HOST WIND_DB_PORT WIND_DB_USER WIND_DB_PASSWORD WIND_DB_NAME
#   WIND_DICT_URL WIND_DICT_USER WIND_DICT_PASS
# 可选：
#   WIND_DICT_LOCAL WIND_LIST_DBS
#   WIND_DB_REGISTER_MCP=1   ← 非空则顺带注册 dbhub-wind MCP
#
# 为什么做成非交互：交互式 read -s 在 Claude Code 会话里跑会卡住没有 tty。
# /wind-db:setup 命令由 Claude 作为向导收集字段，再调用本脚本做落地。
set -euo pipefail

# 定位 plugin 根和 .env 目标路径
SCRIPT_DIR="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

if [ -n "${CLAUDE_PLUGIN_DATA:-}" ]; then
  mkdir -p "$CLAUDE_PLUGIN_DATA"
  ENV_FILE="$CLAUDE_PLUGIN_DATA/.env"
else
  ENV_FILE="$SCRIPT_DIR/.env"
fi

# 必填检查
: "${WIND_DB_DIALECT:?缺少 WIND_DB_DIALECT}"
: "${WIND_DB_HOST:?缺少 WIND_DB_HOST}"
: "${WIND_DB_USER:?缺少 WIND_DB_USER}"
: "${WIND_DB_PASSWORD:?缺少 WIND_DB_PASSWORD}"
: "${WIND_DB_NAME:?缺少 WIND_DB_NAME}"
: "${WIND_DICT_URL:?缺少 WIND_DICT_URL}"
: "${WIND_DICT_USER:?缺少 WIND_DICT_USER}"
: "${WIND_DICT_PASS:?缺少 WIND_DICT_PASS}"

# 默认值
WIND_DB_PORT="${WIND_DB_PORT:-1433}"
WIND_DICT_LOCAL="${WIND_DICT_LOCAL:-}"
WIND_LIST_DBS="${WIND_LIST_DBS:-基础代码表,中国A股数据库,中国香港股票数据库,中国共同基金数据库,指数数据库}"
WIND_DB_SSLMODE="${WIND_DB_SSLMODE:-}"
WIND_DB_INSTANCE="${WIND_DB_INSTANCE:-}"

# 防呆：Oracle 方言用户会踩坑，直接提示
case "$WIND_DB_DIALECT" in
  oracle*)
    echo "✗ dbhub 不支持 Oracle（源码：https://github.com/bytebase/dbhub/tree/main/src/connectors）" >&2
    echo "  如果你确实要用 Oracle，请不要装 dbhub MCP；只用 dict.sh 部分功能。" >&2
    exit 1
    ;;
esac

# shell 安全单引号包裹（值里的 ' 转义成 '\''）
quote() {
  local s="$1"
  printf "'%s'" "${s//\'/\'\\\'\'}"
}

cat > "$ENV_FILE" <<EOF
# Wind 数据库访问配置（由 /wind-db:setup 生成，可手动编辑）

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
EOF

chmod 600 "$ENV_FILE"
echo "✓ .env 已写入：${ENV_FILE}（权限 600）"

# 可选：注册 MCP
if [ -n "${WIND_DB_REGISTER_MCP:-}" ]; then
  echo "==> 注册 dbhub-wind MCP"
  bash "$SCRIPT_DIR/scripts/setup-mcp.sh"
fi
