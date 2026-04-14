#!/usr/bin/env bash
# wind-db skill 首次安装向导
#
# 做三件事：
#   1. 如果没有 .env，从 .env.example 复制
#   2. 交互式让用户填关键字段（带默认值 / 密码隐藏）
#   3. 可选：调用 setup-mcp.sh 注册 dbhub-wind MCP 到 Claude Code
#
# 幂等：重跑会检测已填字段，询问是否覆盖，不会无脑重写。
#
# 用法：
#   Plugin 模式：  bash "$CLAUDE_PLUGIN_ROOT/scripts/install.sh"
#   手动 clone：   bash ~/workspace/quant-skills/plugins/wind-db/scripts/install.sh
set -euo pipefail

# 优先用 Claude Code plugin 注入的 $CLAUDE_PLUGIN_ROOT，fallback 到脚本相对位置
SCRIPT_DIR="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

# .env 存放位置：优先 $CLAUDE_PLUGIN_DATA（plugin 升级时不会丢），fallback plugin 根
if [ -n "${CLAUDE_PLUGIN_DATA:-}" ]; then
  mkdir -p "$CLAUDE_PLUGIN_DATA"
  ENV_FILE="$CLAUDE_PLUGIN_DATA/.env"
else
  ENV_FILE="$SCRIPT_DIR/.env"
fi

EXAMPLE_FILE="$SCRIPT_DIR/.env.example"
MCP_SCRIPT="$SCRIPT_DIR/scripts/setup-mcp.sh"

c_dim()  { printf '\033[2m%s\033[0m' "$*"; }
c_bold() { printf '\033[1m%s\033[0m' "$*"; }
c_ok()   { printf '\033[32m%s\033[0m' "$*"; }
c_warn() { printf '\033[33m%s\033[0m' "$*"; }
c_err()  { printf '\033[31m%s\033[0m' "$*"; }

echo ""
c_bold "Wind 数据库 skill 安装向导"; echo ""
c_dim  "  skill 目录：$SCRIPT_DIR"; echo ""
echo ""

# ── 1. .env 文件 ────────────────────────────────────────
if [ ! -f "$EXAMPLE_FILE" ]; then
  c_err "✗ 未找到 .env.example ($EXAMPLE_FILE)"; echo ""
  echo "  skill 目录不完整，请重新从仓库拉取。"
  exit 1
fi

if [ -f "$ENV_FILE" ]; then
  c_warn "⚠ 已存在 .env 文件。"; echo ""
  read -r -p "  是否进入交互式填写并覆盖现有值？[y/N] " overwrite
  if [[ ! "$overwrite" =~ ^[yY]$ ]]; then
    c_dim "  跳过 .env 填写阶段，使用当前值。"; echo ""
    SKIP_EDIT=1
  else
    SKIP_EDIT=0
  fi
else
  cp "$EXAMPLE_FILE" "$ENV_FILE"
  c_ok "✓ 已从 .env.example 创建 .env"; echo ""
  SKIP_EDIT=0
fi

# 读入现有值作为默认
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

# ── 2. 交互式填写 ───────────────────────────────────────
if [ "$SKIP_EDIT" = "0" ]; then
  echo ""
  c_bold "[1/3] 数据库连接"; echo ""
  c_dim  "  dbhub 支持：mssql+pyodbc / mysql+pymysql / mariadb+pymysql / postgresql+psycopg2 / sqlite"; echo ""
  c_dim  "  ⚠️ 不支持 Oracle（填了 dbhub MCP 会装不上）"; echo ""

  ask() {
    # ask <var_name> <prompt> [current_value]
    local var="$1" prompt="$2" cur="${3:-}" input
    if [ -n "$cur" ] && [ "$cur" != "your_user" ] && [ "$cur" != "your_password_here" ] \
       && [ "$cur" != "your_caddy_basic_auth_password" ] && [ "$cur" != "db.internal" ]; then
      read -r -p "  $prompt [$cur]: " input
      input="${input:-$cur}"
    else
      read -r -p "  $prompt: " input
    fi
    printf -v "$var" '%s' "$input"
  }

  # 强制必填版：不显示默认、不允许空、直到用户输入非空值才继续
  ask_required() {
    local var="$1" prompt="$2" input
    while true; do
      read -r -p "  $prompt: " input
      [ -n "$input" ] && break
      c_warn "  不能留空"; echo ""
    done
    printf -v "$var" '%s' "$input"
  }

  ask_secret_required() {
    local var="$1" prompt="$2" input
    while true; do
      read -r -s -p "  $prompt: " input
      echo ""
      [ -n "$input" ] && break
      c_warn "  不能留空"; echo ""
    done
    printf -v "$var" '%s' "$input"
  }

  ask_secret() {
    # ask_secret <var_name> <prompt> [current_value]
    local var="$1" prompt="$2" cur="${3:-}" input
    if [ -n "$cur" ] && [ "$cur" != "your_password_here" ] && [ "$cur" != "your_caddy_basic_auth_password" ]; then
      read -r -s -p "  $prompt (留空保持当前值): " input
      echo ""
      input="${input:-$cur}"
    else
      read -r -s -p "  $prompt: " input
      echo ""
    fi
    printf -v "$var" '%s' "$input"
  }

  # 先问用户要粘 DSN 还是逐项填
  echo "  A. 粘一个完整 DSN（SQLAlchemy / URL / JDBC / ADO.NET / 键值对都行）"
  echo "  B. 逐项填（dialect/host/port/user/password/database 一个个输）"
  read -r -p "  选择 [A/b]: " MODE
  MODE="${MODE:-A}"

  if [[ "$MODE" =~ ^[Aa]$ ]]; then
    echo ""
    c_dim "  粘你的 DSN（密码里有 '、\$、! 等特殊字符也没关系，整行粘就行）"; echo ""
    read -r -p "  DSN: " DSN_RAW
    if [ -z "$DSN_RAW" ]; then
      c_err "✗ DSN 为空，改用逐项填"; echo ""
      MODE="B"
    else
      # 用 parse-dsn.py 解析，输出的 shell 赋值语句 eval 到当前 shell
      PARSE_OUTPUT=$(python3 "$SCRIPT_DIR/scripts/parse-dsn.py" "$DSN_RAW" 2>&1) || {
        c_err "✗ $PARSE_OUTPUT"; echo ""
        c_warn "  解析失败，改用逐项填"; echo ""
        MODE="B"
      }
      if [[ "$MODE" =~ ^[Aa]$ ]]; then
        eval "$PARSE_OUTPUT"
        NEW_DIALECT="$WIND_DB_DIALECT"
        NEW_HOST="$WIND_DB_HOST"
        NEW_PORT="${WIND_DB_PORT:-}"
        NEW_USER="${WIND_DB_USER:-}"
        NEW_PASSWORD="${WIND_DB_PASSWORD:-}"
        NEW_DB_NAME="${WIND_DB_NAME:-wind}"
        echo ""
        c_ok "✓ DSN 解析成功："; echo ""
        echo "    dialect:  $NEW_DIALECT"
        echo "    host:port $NEW_HOST:$NEW_PORT"
        echo "    user:     $NEW_USER"
        echo "    password: ***（已收到，长度 ${#NEW_PASSWORD}）"
        echo "    database: $NEW_DB_NAME"
        # 缺字段兜底（粘的 DSN 没带 user/password 的常见情况）
        [ -z "$NEW_USER" ]     && ask NEW_USER     "补填 WIND_DB_USER" ""
        [ -z "$NEW_PASSWORD" ] && ask_secret NEW_PASSWORD "补填 WIND_DB_PASSWORD" ""
      fi
    fi
  fi

  if [[ "$MODE" =~ ^[Bb]$ ]]; then
    ask NEW_DIALECT  "WIND_DB_DIALECT"  "${WIND_DB_DIALECT:-mssql+pyodbc}"
    ask NEW_HOST     "WIND_DB_HOST"     "${WIND_DB_HOST:-}"
    ask NEW_PORT     "WIND_DB_PORT"     "${WIND_DB_PORT:-1433}"
    ask NEW_USER     "WIND_DB_USER"     "${WIND_DB_USER:-}"
    ask_secret NEW_PASSWORD "WIND_DB_PASSWORD" "${WIND_DB_PASSWORD:-}"
    ask NEW_DB_NAME  "WIND_DB_NAME"     "${WIND_DB_NAME:-wind}"
  fi

  echo ""
  c_bold "[2/3] 数据字典站（在线版）"; echo ""
  ask NEW_DICT_URL  "WIND_DICT_URL"  "${WIND_DICT_URL:-https://winddict.081188.xyz}"
  # 字典站 basic auth：没有通用默认值，必填
  # 如果 .env 里已有真实值（不是占位符），允许回车保持
  if [ -n "${WIND_DICT_USER:-}" ] && [ "$WIND_DICT_USER" != "admin" ]; then
    ask NEW_DICT_USER "WIND_DICT_USER" "$WIND_DICT_USER"
  else
    ask_required NEW_DICT_USER "WIND_DICT_USER (basic auth 用户名，必填)"
  fi
  if [ -n "${WIND_DICT_PASS:-}" ] && [ "$WIND_DICT_PASS" != "your_caddy_basic_auth_password" ]; then
    ask_secret NEW_DICT_PASS "WIND_DICT_PASS (basic auth)" "$WIND_DICT_PASS"
  else
    ask_secret_required NEW_DICT_PASS "WIND_DICT_PASS (basic auth 密码，必填)"
  fi

  echo ""
  c_bold "[3/3] 本地字典（可选）"; echo ""
  c_dim  "  如果你本地 clone 了 wind-data-dict 仓库，填写 wind_data_dict/ 目录的绝对路径，dict.sh 会优先走本地 grep（更快）"; echo ""
  ask NEW_DICT_LOCAL "WIND_DICT_LOCAL (可留空)" "${WIND_DICT_LOCAL:-}"

  # WIND_LIST_DBS 保持 .env 里的值不问（默认 5 个库足够），除非为空
  NEW_LIST_DBS="${WIND_LIST_DBS:-基础代码表,中国A股数据库,中国香港股票数据库,中国共同基金数据库,指数数据库}"

  # ── 写回 .env（shell 安全引号）─────────────
  quote() {
    # 单引号包裹，内部 ' 替换成 '\''
    local s="$1"
    printf "'%s'" "${s//\'/\'\\\'\'}"
  }

  cat > "$ENV_FILE" <<EOF
# Wind 数据库访问配置（由 install.sh 生成，可手动编辑）

# ── 数据库连接 ───────────────────────────────────────────
WIND_DB_DIALECT=$(quote "$NEW_DIALECT")
WIND_DB_HOST=$(quote "$NEW_HOST")
WIND_DB_PORT=$(quote "$NEW_PORT")
WIND_DB_USER=$(quote "$NEW_USER")
WIND_DB_PASSWORD=$(quote "$NEW_PASSWORD")
WIND_DB_NAME=$(quote "$NEW_DB_NAME")

# ── 数据字典（在线版）────────────────────────────────────
WIND_DICT_URL=$(quote "$NEW_DICT_URL")
WIND_DICT_USER=$(quote "$NEW_DICT_USER")
WIND_DICT_PASS=$(quote "$NEW_DICT_PASS")

# ── 数据字典（本地版，可选）─────────────────────────────
WIND_DICT_LOCAL=$(quote "$NEW_DICT_LOCAL")

# ── 列表模式过滤（dict.sh -l 的库白名单）────────────────
WIND_LIST_DBS=$(quote "$NEW_LIST_DBS")
EOF

  chmod 600 "$ENV_FILE"
  echo ""
  c_ok "✓ .env 已写入（权限 600）"; echo ""
fi

# ── 3. 注册 dbhub-wind MCP ──────────────────────────────
echo ""
c_bold "dbhub-wind MCP 注册"; echo ""
c_dim  "  这一步会用 .env 里的数据库连接信息注册一个名为 'dbhub-wind' 的 MCP 到 Claude Code，"; echo ""
c_dim  "  之后在会话里可以用 search_objects / execute_sql 探查 schema。"; echo ""

if command -v claude >/dev/null 2>&1 && claude mcp list 2>/dev/null | grep -q 'dbhub-wind'; then
  c_warn "⚠ 检测到已存在的 dbhub-wind MCP 注册。"; echo ""
  read -r -p "  是否重新注册（会用 .env 最新值覆盖）？[y/N] " reinstall
  if [[ "$reinstall" =~ ^[yY]$ ]]; then
    bash "$MCP_SCRIPT"
  else
    c_dim "  跳过 MCP 重新注册。"; echo ""
  fi
else
  read -r -p "  是否现在注册？[Y/n] " do_mcp
  if [[ ! "$do_mcp" =~ ^[nN]$ ]]; then
    bash "$MCP_SCRIPT"
  else
    c_dim "  跳过 MCP 注册。后续可手动运行：bash $MCP_SCRIPT"; echo ""
  fi
fi

echo ""
c_ok "✓ 安装向导结束"; echo ""
echo ""
c_bold "后续步骤："; echo ""
echo "  1. 重启 Claude Code 让 MCP 生效"
echo "  2. 在新会话里验证：问 Claude '用 wind-db skill 查 AShareIncome 的主键'"
echo "  3. 任何时候想改配置：重跑 bash $SCRIPT_DIR/scripts/install.sh"
echo ""
