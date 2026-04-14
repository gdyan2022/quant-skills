#!/usr/bin/env bash
# Wind 数据字典查询：优先本地 grep，fallback 在线 search_index.json
#
# 用法:
#   dict.sh <关键字>           默认：按 title > location > body 加权全文搜索
#   dict.sh -t <关键字>        精确：只搜标题（文件名 / H1 / section 标题）
#   dict.sh -c <关键字>        ⭐ 精确 + 直接输出命中页的完整内容（字段/FAQ/样例）
#                              命中多条时，展示第 1 条并提示其他候选
#   dict.sh -l                 列出所有表名↔中文名映射（供 AI 批量查找）
#   dict.sh -h                 帮助
set -euo pipefail

# 优先用 Claude Code plugin 注入的 $CLAUDE_PLUGIN_ROOT，fallback 到脚本相对位置
SCRIPT_DIR="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

# .env 优先取 plugin 持久化目录（升级不会丢），fallback plugin 根
if [ -n "${CLAUDE_PLUGIN_DATA:-}" ] && [ -f "$CLAUDE_PLUGIN_DATA/.env" ]; then
  ENV_FILE="$CLAUDE_PLUGIN_DATA/.env"
else
  ENV_FILE="$SCRIPT_DIR/.env"
fi

if [ ! -f "$ENV_FILE" ]; then
  echo "✗ 未找到 $ENV_FILE" >&2
  echo "  首次使用请运行：bash \"\${CLAUDE_PLUGIN_ROOT:-$SCRIPT_DIR}/scripts/install.sh\"" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

TITLE_ONLY=0
LIST_MODE=0
CONTENT_MODE=0
QUERY=""

while [ $# -gt 0 ]; do
  case "$1" in
    -t|--title)
      TITLE_ONLY=1
      shift
      ;;
    -c|--content)
      TITLE_ONLY=1
      CONTENT_MODE=1
      shift
      ;;
    -l|--list)
      LIST_MODE=1
      shift
      ;;
    -h|--help)
      cat <<EOF
用法:
  $(basename "$0") <关键字>           全文搜索（title/location 加权）
  $(basename "$0") -t <关键字>        只搜标题（精确模式，避开推荐产品等噪声）
  $(basename "$0") -c <关键字>        精确搜索 + 输出命中页的完整内容
                                      （拼接简介/字段/样例/FAQ 所有 section）
  $(basename "$0") -l                 列出所有表名 → 中文名 → 路径 映射
                                      （供 AI 后续 grep，推荐重定向到文件）

示例:
  $(basename "$0") AShareIncome          按表名搜
  $(basename "$0") -t AShareIncome       只看表主页面 URL 列表
  $(basename "$0") -c AShareIncome       ⭐ 直接读出 AShareIncome 的全部字段/FAQ
  $(basename "$0") STATEMENT_TYPE        按字段名搜
  $(basename "$0") -l > /tmp/wind_tables.tsv    导出全量对照表
  $(basename "$0") -l | grep 利润表      直接 grep
EOF
      exit 0
      ;;
    --)
      shift
      QUERY="${1:-}"
      shift || true
      ;;
    -*)
      echo "未知参数: $1" >&2
      exit 1
      ;;
    *)
      QUERY="$1"
      shift
      ;;
  esac
done

if [ "$LIST_MODE" = "0" ] && [ -z "$QUERY" ]; then
  echo "用法: $(basename "$0") [-t|-l] <关键字>  (更多见 -h)" >&2
  exit 1
fi

MAX_RESULTS=30

# 段落标题黑名单：这些段落通常只是列出其他表名，会造成误匹配
EXCLUDE_SECTIONS='推荐产品'

# ═══════════════════════════════════════════════════════
# LIST MODE: 列出所有表名 → 中文名 → 路径 映射
# ═══════════════════════════════════════════════════════
if [ "$LIST_MODE" = "1" ]; then
  # ── 本地优先 ─────────────────────────────────────────
  if [ -n "${WIND_DICT_LOCAL:-}" ] && [ -d "$WIND_DICT_LOCAL" ]; then
    python3 - "$WIND_DICT_LOCAL" <<'PY'
import sys, os, re
from signal import signal, SIGPIPE, SIG_DFL
signal(SIGPIPE, SIG_DFL)  # 让 | head / | grep 提前关 stdin 时静默退出

root = sys.argv[1]
# 订阅库过滤：空白 = 不过滤
include_dbs = {d.strip() for d in os.environ.get('WIND_LIST_DBS', '').split(',') if d.strip()}

for dirpath, dirs, files in os.walk(root):
    for fname in sorted(files):
        if not fname.endswith('.md') or fname == 'index.md':
            continue
        path = os.path.join(dirpath, fname)
        table_en = fname[:-3]
        cn = ''
        try:
            with open(path, 'r', encoding='utf-8') as f:
                for i, raw in enumerate(f):
                    if i >= 10:
                        break
                    m = re.match(r'^title:\s*"?([^"\n]+?)"?\s*$', raw)
                    if m:
                        cn = m.group(1).strip()
                        break
        except Exception:
            continue
        rel = os.path.relpath(dirpath, root)
        # 按订阅的数据库过滤（rel 的第一段 = 库中文名）
        if include_dbs:
            db_name = rel.split(os.sep)[0] if rel and rel != '.' else ''
            if db_name not in include_dbs:
                continue
        # 从表名后缀 + 模块路径双重判断分类
        if table_en.endswith('ZL') or '增量' in rel:
            tag = 'ZL'    # 增量更新版本
        elif 'PIT' in rel or table_en.endswith('His'):
            tag = 'PIT'   # 时点快照（point-in-time）
        elif '低延时' in rel or table_en.endswith('LLT'):
            tag = 'LLT'   # 低延时版
        else:
            tag = 'STD'   # 标准版
        print(f"{table_en}\t{cn}\t[{tag}]\t{rel}")
PY
    exit 0
  fi

  # ── 在线 fallback ────────────────────────────────────
  : "${WIND_DICT_URL:?在线字典未配置 WIND_DICT_URL}"
  : "${WIND_DICT_USER:?在线字典未配置 WIND_DICT_USER}"
  : "${WIND_DICT_PASS:?在线字典未配置 WIND_DICT_PASS}"

  INDEX_URL="${WIND_DICT_URL%/}/search/search_index.json"
  TMP=$(mktemp)
  trap 'rm -f "$TMP"' EXIT
  if ! curl -sSfu "$WIND_DICT_USER:$WIND_DICT_PASS" "$INDEX_URL" -o "$TMP"; then
    echo "✗ 获取在线字典索引失败" >&2
    exit 1
  fi

  python3 - "$TMP" <<'PY'
import sys, json, os, re
from urllib.parse import unquote
from signal import signal, SIGPIPE, SIG_DFL
signal(SIGPIPE, SIG_DFL)

include_dbs = {d.strip() for d in os.environ.get('WIND_LIST_DBS', '').split(',') if d.strip()}

with open(sys.argv[1], 'r', encoding='utf-8') as f:
    data = json.load(f)

for d in data.get('docs', []):
    location = d.get('location', '') or ''
    title = (d.get('title', '') or '').strip()
    # 清理 mkdocs-material 嵌入的 <code>EnglishName</code> 后缀和其他 HTML 标签
    title = re.sub(r'\s*<code>[^<]*</code>\s*', '', title)
    title = re.sub(r'<[^>]+>', '', title).strip()

    # 只要根条目：没有 #anchor
    if '#' in location:
        continue
    # URL 解码每段（真实站点的 location 是 %XX 编码的）
    segments = [unquote(s) for s in location.rstrip('/').split('/') if s]
    if len(segments) < 2:
        continue  # 跳过 index 根页 / DB 根页
    table_en = segments[-1]
    # 英文表名必须是纯 ASCII（过滤中文模块/DB 的 index 页）
    if not table_en.isascii() or not table_en:
        continue
    # 按订阅的数据库过滤（第一段 = 库中文名）
    if include_dbs and segments[0] not in include_dbs:
        continue
    rel = '/'.join(segments[:-1])
    # 从表名后缀 + 模块路径双重判断分类（与本地分支保持一致）
    if table_en.endswith('ZL') or '增量' in rel:
        tag = 'ZL'
    elif 'PIT' in rel or table_en.endswith('His'):
        tag = 'PIT'
    elif '低延时' in rel or table_en.endswith('LLT'):
        tag = 'LLT'
    else:
        tag = 'STD'
    print(f"{table_en}\t{title}\t[{tag}]\t{rel}")
PY
  exit 0
fi

# ── 本地字典优先 ─────────────────────────────────────────
if [ -n "${WIND_DICT_LOCAL:-}" ] && [ -d "$WIND_DICT_LOCAL" ]; then
  echo "==> 本地字典: $WIND_DICT_LOCAL"

  if [ "$TITLE_ONLY" = "1" ]; then
    # 精确：文件名 OR front matter title OR 第一个 H1
    matches=$(
      find "$WIND_DICT_LOCAL" -name '*.md' -type f 2>/dev/null | while read -r f; do
        base=$(basename "$f" .md)
        if echo "$base" | grep -qiF -- "$QUERY"; then
          echo "$f"
          continue
        fi
        # 抓前 10 行里的 front matter title 或第一个 H1，再检查是否包含关键字
        if awk 'NR<=10 && /^(title:|# )/' "$f" 2>/dev/null | grep -qiF -- "$QUERY"; then
          echo "$f"
        fi
      done | sort -u | head -n "$MAX_RESULTS"
    )
  else
    matches=$(grep -rl --include='*.md' -iF -- "$QUERY" "$WIND_DICT_LOCAL" 2>/dev/null | head -n "$MAX_RESULTS" || true)
  fi

  if [ -n "$matches" ]; then
    count=$(echo "$matches" | wc -l | tr -d ' ')
    if [ "$CONTENT_MODE" = "1" ]; then
      first=$(echo "$matches" | head -n 1)
      echo "==> 展示内容: $first"
      echo ""
      cat "$first"
      if [ "$count" -gt 1 ]; then
        echo ""
        echo "---"
        echo "(还有 $((count - 1)) 个候选文件未展示：)"
        echo "$matches" | tail -n +2
      fi
    else
      echo "$matches"
      echo ""
      echo "(本地命中 $count 个文件。用 Read 工具读取具体内容，或加 -c 直接输出内容。)"
    fi
    exit 0
  fi
  echo "  本地未命中，尝试在线..." >&2
fi

# ── 在线字典 fallback ────────────────────────────────────
: "${WIND_DICT_URL:?在线字典未配置 WIND_DICT_URL}"
: "${WIND_DICT_USER:?在线字典未配置 WIND_DICT_USER}"
: "${WIND_DICT_PASS:?在线字典未配置 WIND_DICT_PASS}"

INDEX_URL="${WIND_DICT_URL%/}/search/search_index.json"
echo "==> 在线字典: $INDEX_URL"

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

if ! curl -sSfu "$WIND_DICT_USER:$WIND_DICT_PASS" "$INDEX_URL" -o "$TMP"; then
  echo "✗ 获取在线字典索引失败（HTTP 错误或认证失败）" >&2
  exit 1
fi

python3 - "$QUERY" "${WIND_DICT_URL%/}" "$MAX_RESULTS" "$TMP" "$TITLE_ONLY" "$EXCLUDE_SECTIONS" "$CONTENT_MODE" <<'PY'
import json, sys, re
from urllib.parse import unquote

query = sys.argv[1]
base_url = sys.argv[2]
max_results = int(sys.argv[3])
index_path = sys.argv[4]
title_only = sys.argv[5] == '1'
exclude_patterns = [s.strip() for s in sys.argv[6].split(',') if s.strip()]
content_mode = sys.argv[7] == '1'

with open(index_path, 'r', encoding='utf-8') as f:
    data = json.load(f)

docs = data.get('docs', [])
pattern = re.compile(re.escape(query), re.IGNORECASE)

def clean_title(t):
    t = re.sub(r'\s*<code>[^<]*</code>\s*', '', t)
    return re.sub(r'<[^>]+>', '', t).strip()

def html_to_text(s):
    """轻量 HTML → 纯文本。search_index 里的 text 多是 <p>...</p> <ul>... 这类。"""
    if not s:
        return ""
    # 常见块级元素换行
    s = re.sub(r'</(p|li|h[1-6]|tr|div|br)>', '\n', s, flags=re.IGNORECASE)
    s = re.sub(r'<li[^>]*>', '- ', s, flags=re.IGNORECASE)
    s = re.sub(r'<br\s*/?>', '\n', s, flags=re.IGNORECASE)
    # 删掉剩余所有标签
    s = re.sub(r'<[^>]+>', '', s)
    # 反转义 HTML 实体
    s = (s.replace('&amp;', '&')
           .replace('&lt;', '<').replace('&gt;', '>')
           .replace('&quot;', '"').replace('&#39;', "'")
           .replace('&nbsp;', ' '))
    # 折叠多余空行
    s = re.sub(r'\n{3,}', '\n\n', s)
    return s.strip()

hits = []
for d in docs:
    title = clean_title(d.get('title', '') or '')
    text = d.get('text', '') or ''
    location = d.get('location', '') or ''

    # mkdocs search_index 每条要么是页面根条目（无 #anchor），
    # 要么是一个 H2/H3 section 条目（有 #anchor）
    has_anchor = '#' in location
    anchor_raw = location.rsplit('#', 1)[1] if has_anchor else ''
    try:
        anchor_decoded = unquote(anchor_raw)
    except Exception:
        anchor_decoded = anchor_raw

    # 丢掉黑名单段落（title 含关键字 或 anchor 含关键字，子串匹配）
    if any(p in title for p in exclude_patterns):
        continue
    if has_anchor and any(p in anchor_decoded for p in exclude_patterns):
        continue

    # 页面路径（去掉 #anchor 部分），用于判断是否为根条目
    page_path = location.split('#', 1)[0]

    score = 0

    # URL slug = 页面路径最后一段（英文表名），比如 'AShareIncome' 或 'AShareIncomeTaxADJProc'
    page_segments = [s for s in page_path.rstrip('/').split('/') if s]
    slug = unquote(page_segments[-1]) if page_segments else ''

    if title_only:
        # 精确模式：只看根页面条目（不展开 section），匹配 title 或 URL slug
        if has_anchor:
            continue
        # 完全等于关键字的 slug 权重最高（大小写不敏感）
        if slug.lower() == query.lower():
            score += 100
        elif pattern.search(slug):
            score += 5
        if pattern.search(title):
            score += 10
    else:
        if slug.lower() == query.lower():
            score += 100
        if pattern.search(title):
            score += 10
        if pattern.search(page_path):
            score += 5
        if has_anchor and pattern.search(text):
            score += 1

    if score > 0:
        hits.append((score, title, location))

hits.sort(reverse=True)

if not hits:
    suffix = " (仅标题)" if title_only else ""
    print(f"(在线字典中未找到 '{query}'{suffix})")
    sys.exit(2)

# ─── content 模式：展示第 1 条的完整页面内容（所有 section 聚合）─────
if content_mode:
    _, first_title, first_loc = hits[0]
    page_path = first_loc.split('#', 1)[0]

    # 收集同一个 page_path 下的所有 section（包括根条目和带 #anchor 的）
    sections = []
    for d in docs:
        loc = d.get('location', '') or ''
        if loc.split('#', 1)[0] != page_path:
            continue
        sec_title = clean_title(d.get('title', '') or '')
        sec_text = d.get('text', '') or ''
        # 不展示"推荐产品"这类段落
        if any(p in sec_title for p in exclude_patterns):
            continue
        sections.append((loc, sec_title, sec_text))

    # 排序：根条目（无 #）排最前，再按 location 字面序（维持 mkdocs 编号 _1/_2/... 和 qN 顺序）
    sections.sort(key=lambda x: (0 if '#' not in x[0] else 1, x[0]))

    url = f"{base_url}/{page_path}"
    print(f"# {first_title}")
    print(f"URL: {url}")
    print()

    for loc, sec_title, sec_text in sections:
        body = html_to_text(sec_text)
        if '#' in loc:
            print(f"## {sec_title}")
        # 根条目的 text 可能是重复的"简介"，但一般很短，保留不会有问题
        if body:
            print(body)
        print()

    # 如果还有其他候选页面，提示
    if len(hits) > 1:
        print("---")
        print(f"(还有 {len(hits) - 1} 个候选页面未展示，考虑换关键字缩小范围：)")
        for _, t, loc in hits[1:max_results]:
            print(f"  - {base_url}/{loc}  —  {t}")
    sys.exit(0)

# ─── 默认：URL 列表模式 ─────────────────────────────
for score, title, loc in hits[:max_results]:
    url = f"{base_url}/{loc}" if loc else base_url
    print(f"{url}  —  {title}")

print("")
mode = "仅标题(含根 URL)" if title_only else "全文加权"
print(f"(在线命中 {len(hits)} 项，显示前 {min(len(hits), max_results)} 条，模式: {mode}。")
print(f" 加 -c 参数可直接输出第一条的完整内容，省掉 WebFetch。)")
PY
