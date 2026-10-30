#!/usr/bin/env bash
# 一次性把 Wind 数据库注册成 Claude Code 的 MCP
#
#   WIND_DB_DIALECT             MCP 实现                           MCP 名      工具名
#   mssql / mysql / mariadb /   @bytebase/dbhub（npx 启动）          dbhub-wind  search_objects_dbhub_wind / execute_sql_dbhub_wind
#   postgres / sqlite
#   oracle                      FreePeak db-mcp-server（Go 二进制）  dbmcp-wind  query_wind / schema_wind / execute_wind
#
# 为什么 Oracle 不走 dbhub：dbhub 1.5+ 的 Oracle connector 只有 node-oracledb Thin 模式，要求服务器 ≥ 12.1，
# Wind 现网大量 11.2.0.4 会报 NJS-138。FreePeak 用纯 Go 驱动 go-ora（Oracle 10.2+），不需要 Instant Client，
# 并自带 read_only / max_rows / query_timeout 护栏。
#
# 用法：bash setup-mcp.sh [--dry-run]
#   --dry-run  只打印将要执行的动作和生成的配置（密码脱敏），不下载、不注册
set -euo pipefail

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

SCRIPT_DIR="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

# $CLAUDE_PLUGIN_DATA 是「当前正在执行的 plugin」的数据目录；在别的 plugin 的会话里它指向别处，
# 所以只有目录名确实是 wind-db 的才用，否则回落到 plugin 根。
DATA_DIR=""
case "${CLAUDE_PLUGIN_DATA:-}" in
  */wind-db|*/wind-db-*) DATA_DIR="$CLAUDE_PLUGIN_DATA" ;;
esac
DATA_DIR="${DATA_DIR:-$SCRIPT_DIR}"
ENV_FILE="$DATA_DIR/.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "✗ 未找到 ${ENV_FILE}，请先运行 /wind-db:setup（或 cp .env.example .env 并填写）" >&2
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

command -v claude  >/dev/null 2>&1 || { echo "✗ 未检测到 claude CLI" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "✗ 需要 python3（URL 编码 / 生成 JSON）" >&2; exit 1; }

mcp_registered() { claude mcp list 2>/dev/null | grep -q "^$1:"; }

# dry-run 下只打印不执行
run() {
  if [ "$DRY_RUN" = 1 ]; then printf '  [dry-run] %s\n' "$*"; else "$@"; fi
}

# 带超时运行（macOS 默认没有 GNU timeout，退化为后台 + kill）
run_with_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  else
    "$@" & local pid=$!
    ( sleep "$secs"; kill "$pid" 2>/dev/null ) & local watchdog=$!
    wait "$pid" 2>/dev/null || true
    kill "$watchdog" 2>/dev/null || true
  fi
}

DIALECT_SHORT="${WIND_DB_DIALECT%%+*}"

# ───────────────────────────── Oracle → FreePeak db-mcp-server ─────────────────────────────
register_oracle() {
  local ver="${WIND_DBMCP_VERSION:-v1.14.0}"
  local bin="${WIND_DBMCP_BIN:-$DATA_DIR/bin/db-mcp-server}"
  local cfg="$DATA_DIR/dbmcp-wind.json"
  local port="${WIND_DB_PORT:-1521}"
  local read_only="${WIND_DBMCP_READ_ONLY:-true}"
  case "$read_only" in
    true|false) ;;
    *) echo "✗ WIND_DBMCP_READ_ONLY 只能是 true / false（当前：$read_only）" >&2; exit 1 ;;
  esac

  if [ -z "${WIND_DB_NAME:-}" ] && [ -z "${WIND_DB_SID:-}" ]; then
    echo "✗ Oracle 需要 WIND_DB_NAME（service name）或 WIND_DB_SID" >&2
    exit 1
  fi

  # 1. 二进制：优先复用已有；否则从 GitHub release 下载预编译版并校验 SHA256（不需要 Go 工具链）
  if [ -x "$bin" ]; then
    echo "==> 复用已有二进制：$bin"
  else
    local os arch asset url
    os=$(uname -s | tr '[:upper:]' '[:lower:]')   # darwin / linux
    case "$(uname -m)" in
      arm64|aarch64) arch=arm64 ;;
      x86_64|amd64)  arch=amd64 ;;
      *) echo "✗ 不支持的架构 $(uname -m)；请自行编译后在 .env 填 WIND_DBMCP_BIN=<路径>" >&2; exit 1 ;;
    esac
    case "$os" in
      darwin|linux) ;;
      *) echo "✗ 不支持的系统 $os；请到 release 页下载后在 .env 填 WIND_DBMCP_BIN=<路径>" >&2; exit 1 ;;
    esac
    asset="db-mcp-server-${os}-${arch}"
    url="https://github.com/FreePeak/db-mcp-server/releases/download/${ver}/${asset}"
    echo "==> 下载 FreePeak db-mcp-server ${ver}（${asset}）"
    echo "    $url"
    echo "    → $bin"
    if [ "$DRY_RUN" = 0 ]; then
      mkdir -p "$(dirname "$bin")"
      local tmp
      tmp=$(mktemp -d)
      curl -fsSL -o "$tmp/$asset" "$url"
      curl -fsSL -o "$tmp/SHA256SUMS" "${url%/*}/SHA256SUMS"
      # SHA256SUMS 里的文件名带构建路径前缀（如 release/db-mcp-server-darwin-arm64），
      # 不能直接 `sha256sum -c`；按 basename 取期望值，再和本地算出的哈希比对
      local expected actual
      expected=$(awk -v a="$asset" '{ n = $2; sub(/^\*/, "", n); sub(/.*\//, "", n); if (n == a) { print $1; exit } }' "$tmp/SHA256SUMS")
      actual=$( { command -v sha256sum >/dev/null 2>&1 && sha256sum "$tmp/$asset" || shasum -a 256 "$tmp/$asset"; } | awk '{ print $1 }')
      if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
        echo "✗ SHA256 校验失败，已放弃安装" >&2
        echo "    期望（SHA256SUMS 中 ${asset} 的条目）：${expected:-<未找到该文件名的条目>}" >&2
        echo "    实际（下载文件）                    ：${actual}" >&2
        rm -rf "$tmp"
        exit 1
      fi
      mv "$tmp/$asset" "$bin"
      chmod +x "$bin"
      rm -rf "$tmp"
      # curl 下载不会带 quarantine 属性，这里只是兜底（用户若用浏览器下载过来会被 Gatekeeper 拦）
      [ "$os" = darwin ] && xattr -d com.apple.quarantine "$bin" 2>/dev/null || true
      echo "    ✓ 已安装"
    fi
  fi

  # 2. 配置文件：密码不落盘，用 password_env 让 server 从环境变量读；环境变量由 claude mcp add -e 注入
  echo "==> 写入 $cfg"
  local cfg_json
  cfg_json=$(python3 - "$WIND_DB_HOST" "$port" "${WIND_DB_NAME:-}" "${WIND_DB_SID:-}" "$WIND_DB_USER" "$read_only" <<'PY'
import json, sys
host, port, service, sid, user, read_only = sys.argv[1:7]
conn = {
    "id": "wind", "type": "oracle",
    "host": host, "port": int(port), "user": user,
    "password_env": "WIND_DB_PASSWORD",
    # 引擎级只读护栏。注意 FreePeak 的 Oracle 实现会在启动时审计账号权限：
    # 账号持有 CREATE TABLE 等任一写权限就拒绝启动（下面的试启动会把这个错误提前暴露）
    "read_only": read_only == "true",
    "max_rows": 200,         # 单次结果超过 200 行截断并提示，防止上下文爆炸（批量数据走 Python）
    "query_timeout": 120,    # 秒；Wind 大表聚合可能较慢
}
if sid:
    conn["sid"] = sid
else:
    conn["service_name"] = service
print(json.dumps({"schema_version": 1, "connections": [conn]}, ensure_ascii=False, indent=2))
PY
)
  if [ "$DRY_RUN" = 1 ]; then
    printf '%s\n' "$cfg_json" | sed 's/^/    /'
  else
    ( umask 077; printf '%s\n' "$cfg_json" > "$cfg" )
    chmod 600 "$cfg"
  fi

  # 3. 试启动：把连接 / 权限问题在注册前暴露出来，而不是等 Claude Code 启动时才失败
  local log_dir="$DATA_DIR/logs"   # 不传 -log-dir 的话 FreePeak 会在当前工作目录乱建 logs/
  if [ "$DRY_RUN" = 0 ]; then
    local probe_dir
    probe_dir=$(mktemp -d)
    echo "==> 试启动 db-mcp-server 探测连接与权限（最多 25 秒）"
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"wind-db-setup","version":"0"}}}' \
      | WIND_DB_PASSWORD="$WIND_DB_PASSWORD" run_with_timeout 25 "$bin" -t stdio -c "$cfg" -log-dir "$probe_dir" >"$probe_dir/out" 2>/dev/null || true
    if grep -qs 'read_only cannot hold' "$probe_dir"/*.log; then
      cat >&2 <<EOF
✗ 账号 ${WIND_DB_USER} 持有写权限，FreePeak 的 read_only=true 拒绝启动：
    $(grep -h 'read_only cannot hold' "$probe_dir"/*.log | sed 's/.*failed to ping database: //' | head -1)
  这是安全策略选择，请你决定：
    a) 让 DBA 收回该账号的写权限（只保留 CREATE SESSION + SELECT 授权），然后重跑本脚本 —— 保留引擎级只读护栏
    b) 在 .env 里加 WIND_DBMCP_READ_ONLY=false 后重跑 —— 关闭 FreePeak 的只读护栏，改靠 skill 纪律。
       强烈建议同时在 Claude Code 的 permissions.deny 里禁掉写工具：
         "mcp__dbmcp-wind__execute_wind"  和  "mcp__dbmcp-wind__transaction_wind"
EOF
      rm -rf "$probe_dir"
      exit 1
    elif grep -qs 'ERROR' "$probe_dir"/*.log; then
      echo "✗ db-mcp-server 启动失败：" >&2
      grep -h 'ERROR' "$probe_dir"/*.log | sed 's/\x1b\[[0-9;]*m//g' | cut -c1-300 >&2
      rm -rf "$probe_dir"
      exit 1
    elif [ ! -s "$probe_dir/out" ]; then
      echo "  ⚠ 25 秒内没收到 MCP 响应，可能只是网络慢；继续注册。若 Claude Code 启动报错请看 $log_dir/" >&2
    else
      echo "    ✓ 连接正常，权限审计通过"
    fi
    rm -rf "$probe_dir"
    mkdir -p "$log_dir"
  fi

  # 4. 注册
  echo "==> 注册 MCP 'dbmcp-wind'"
  echo "    oracle ${WIND_DB_HOST}:${port}/${WIND_DB_NAME:-<sid=$WIND_DB_SID>}  user ${WIND_DB_USER}  read_only=${read_only}  (密码通过环境变量注入)"
  if mcp_registered dbmcp-wind; then
    echo "    检测到已存在的 dbmcp-wind，先移除旧配置"
    run claude mcp remove dbmcp-wind --scope user
  fi
  if [ "$DRY_RUN" = 1 ]; then
    echo "  [dry-run] claude mcp add dbmcp-wind --scope user -e WIND_DB_PASSWORD=*** -- $bin -t stdio -c $cfg -log-dir $log_dir"
  else
    claude mcp add dbmcp-wind --scope user -e "WIND_DB_PASSWORD=${WIND_DB_PASSWORD}" -- "$bin" -t stdio -c "$cfg" -log-dir "$log_dir"
  fi
  if mcp_registered dbhub-wind; then
    echo "  ⚠ 另一条 dbhub-wind（非 Oracle）仍在注册中。如已不用：claude mcp remove dbhub-wind --scope user"
  fi
  cat <<EOF

✓ 已注册 dbmcp-wind。请重启 Claude Code 使 MCP 生效（验证：claude mcp list）。
  Oracle 模式下的工具名：
    query_wind    SELECT / probe（结果 > 200 行会被截断并提示）
    schema_wind   只查登录账号自己的表；Wind 表在 ${WIND_DB_SCHEMA:-WIND} schema 下，改用 query_wind 查 ALL_* 视图（SKILL.md §5.4.1）
    execute_wind  DML。Wind 是只读数据源，任何情况下都不要用（read_only=${read_only}）
  日志目录：${log_dir}
EOF
}

# ───────────────────────────── 其他方言 → @bytebase/dbhub ─────────────────────────────
register_dbhub() {
  : "${WIND_DB_NAME:?缺少 WIND_DB_NAME}"

  # 根据 @bytebase/dbhub 源码（src/connectors/*/index.ts）的 isValidDSN 校验：
  #   PostgreSQL → postgres:// 或 postgresql://
  #   MySQL      → mysql://
  #   MariaDB    → mariadb://
  #   SQL Server → sqlserver://    （不是 mssql://！）
  #   SQLite     → sqlite://
  local scheme
  case "$DIALECT_SHORT" in
    mysql)                scheme="mysql" ;;
    mariadb)              scheme="mariadb" ;;
    postgresql|postgres)  scheme="postgres" ;;
    mssql|sqlserver)      scheme="sqlserver" ;;
    sqlite)               scheme="sqlite" ;;
    *)                    scheme="$DIALECT_SHORT" ;;
  esac

  local port
  if [ -n "${WIND_DB_PORT:-}" ]; then
    port="$WIND_DB_PORT"
  else
    case "$scheme" in
      sqlserver) port=1433 ;;
      postgres)  port=5432 ;;
      *)         port=3306 ;;
    esac
  fi

  local user_enc pass_enc
  user_enc=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=''))" "$WIND_DB_USER")
  pass_enc=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=''))" "$WIND_DB_PASSWORD")

  # SQL Server 的 query 参数：
  #   - dbhub 默认 encrypt=true, trustServerCertificate=false，连内网/自签证书的 SQL Server 常失败
  #   - sslmode=disable 映射到 encrypt=false（适合多数 Wind 自建环境），可用 WIND_DB_SSLMODE 覆盖
  #   - WIND_DB_INSTANCE 指定命名实例
  local query=""
  if [ "$scheme" = "sqlserver" ]; then
    query="?sslmode=${WIND_DB_SSLMODE:-disable}"
    [ -n "${WIND_DB_INSTANCE:-}" ] && query="${query}&instanceName=${WIND_DB_INSTANCE}"
  fi

  local dsn="${scheme}://${user_enc}:${pass_enc}@${WIND_DB_HOST}:${port}/${WIND_DB_NAME}${query}"

  echo "==> 注册 MCP 'dbhub-wind'"
  echo "    scheme  : $scheme"
  echo "    host    : $WIND_DB_HOST:$port"
  echo "    db      : $WIND_DB_NAME"
  echo "    user    : $WIND_DB_USER"
  echo "    (密码已 URL 编码，不在终端显示)"

  if mcp_registered dbhub-wind; then
    echo "    检测到已存在的 dbhub-wind，先移除旧配置"
    run claude mcp remove dbhub-wind --scope user
  fi
  if [ "$DRY_RUN" = 1 ]; then
    echo "  [dry-run] claude mcp add dbhub-wind --scope user -- npx -y @bytebase/dbhub --dsn ${scheme}://${user_enc}:***@${WIND_DB_HOST}:${port}/${WIND_DB_NAME}${query}"
  else
    claude mcp add dbhub-wind --scope user -- npx -y @bytebase/dbhub --dsn "$dsn"
  fi
  if mcp_registered dbmcp-wind; then
    echo "  ⚠ 另一条 dbmcp-wind（Oracle）仍在注册中。如已不用：claude mcp remove dbmcp-wind --scope user"
  fi
  echo ""
  echo "✓ 已注册 dbhub-wind。请重启 Claude Code 使 MCP 生效（验证：claude mcp list）。"
  echo "  工具名：search_objects_dbhub_wind / execute_sql_dbhub_wind"
}

case "$DIALECT_SHORT" in
  oracle)                                                  register_oracle ;;
  mysql|mariadb|postgresql|postgres|mssql|sqlserver|sqlite) register_dbhub ;;
  *) echo "✗ 未知 dialect：$WIND_DB_DIALECT（支持 mssql+pyodbc / oracle+oracledb / mysql+pymysql / mariadb+pymysql / postgresql+psycopg2 / sqlite）" >&2; exit 1 ;;
esac
