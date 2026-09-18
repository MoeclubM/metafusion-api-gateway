#!/usr/bin/env bash
# MetaFusion 切流自检：确认各服务自身健康、网关把每个前缀切到了预期的上游。
# 对应主仓库 docs/architecture/cutover-runbook.md 的“验证”列，可整段照抄执行。
#
# 用法：
#   ./scripts/cutover-check.sh --self-check                    # 只校验本脚本的断言表（不联网，CI 用）
#   ./scripts/cutover-check.sh                                 # 只做服务直连健康检查
#   GATEWAY=https://<host> ./scripts/cutover-check.sh          # 额外校验网关分流
#   DSNS='postgres://user:pass@host:5432/db?sslmode=disable' ./scripts/cutover-check.sh  # 额外对比新旧表行数
# 设了 DSNS 之后就不再"静默跳过"：行数读不到、表存在性读不到、甚至本机没有 psql，
# 都按 FAIL 计——连不上库却报"旧表已退役（预期状态）"，等于把故障说成正常。
#
# 判定依据：每个服务在响应头里带 X-MetaFusion-Service（metafusion-catalog / -auth / -community /
# -storage，定义在各自仓库的 cmd/server/main.go）。这个标记是**必填断言**：早先的实现把它写成
# 占位符 “-”，等于没校验——只看 HTTP 状态码的话，“前缀又指回目录服务”同样是 200，看不出事故。
set -uo pipefail

AUTH_URL="${AUTH_URL:-http://127.0.0.1:8081}"
COMMUNITY_URL="${COMMUNITY_URL:-http://127.0.0.1:8083}"
STORAGE_URL="${STORAGE_URL:-http://127.0.0.1:8082}"
CATALOG_URL="${CATALOG_URL:-http://127.0.0.1:8080}"
GATEWAY="${GATEWAY:-}"
# 断言表里的网关 URL 也要是合法 http(s)（--self-check 不联网，但仍校验形状）；
# 没设 GATEWAY 时用这个占位域名拼表，实际不会发起请求（下面整段 SKIP）。
GATEWAY_BASE="${GATEWAY:-https://gateway.invalid}"
DSNS="${DSNS:-}"
TIMEOUT="${TIMEOUT:-5}"

pass=0; fail=0; skip=0
ok()   { pass=$((pass+1)); printf '  PASS  %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
na()   { skip=$((skip+1)); printf '  SKIP  %s\n' "$1"; }

usage() {
  sed -n '2,19p' "$0"
}

# 断言表说明（四段式，用 “;” 分隔；不用 “|” 是因为状态码匹配式里就带 “|”）：
#   name;url;expect-marker;status-regex
#   expect-marker —— 必填。X-MetaFusion-Service 的期望值；“any” 表示只要带标记即可。
#                    不允许 “-” 之类的占位符，--self-check 会拦下来。
#   status-regex  —— 可接受的状态码。需要鉴权的端点用 ^(2|4)：标记来自上游，
#                    401/403 同样证明分流正确，而 404/502 才是异常。
DIRECT_CHECKS=(
  "auth/ready;${AUTH_URL}/ready;metafusion-auth;^2"
  "community/ready;${COMMUNITY_URL}/ready;metafusion-community;^2"
  "storage/ready;${STORAGE_URL}/ready;metafusion-storage;^2"
  "catalog/ready;${CATALOG_URL}/ready;metafusion-catalog;^2"
)

GATEWAY_CHECKS=(
  "GET /api/setup;${GATEWAY_BASE}/api/setup;metafusion-auth;^(2|4)"
  "GET /api/auth/settings;${GATEWAY_BASE}/api/auth/settings;metafusion-auth;^(2|4)"
  "GET /api/oidc/jwks;${GATEWAY_BASE}/api/oidc/jwks;metafusion-auth;^2"
  "GET /.well-known/openid-configuration;${GATEWAY_BASE}/.well-known/openid-configuration;metafusion-auth;^2"
  "GET /api/developer/overview;${GATEWAY_BASE}/api/developer/overview;metafusion-auth;^(2|4)"
  "GET /api/community/boards;${GATEWAY_BASE}/api/community/boards;metafusion-community;^(2|4)"
  "GET /api/favorites/status;${GATEWAY_BASE}/api/favorites/status;metafusion-community;^(2|4)"
  "GET /api/storage/stats;${GATEWAY_BASE}/api/storage/stats;metafusion-storage;^(2|4)"
  "GET /api/catalog/definitions;${GATEWAY_BASE}/api/catalog/definitions;metafusion-catalog;^(2|4)"
)

# self_check：不联网，只校验断言表本身没写错（CI 上跑这一条，也用于本脚本自身的回归）。
self_check() {
  local problems=0 row name url expect status_re fields
  for row in "${DIRECT_CHECKS[@]}" "${GATEWAY_CHECKS[@]}"; do
    IFS=';' read -r name url expect status_re <<< "$row"
    fields=$(awk -F';' '{print NF}' <<< "$row")
    if [[ "$fields" -ne 4 ]]; then
      bad "断言表条目字段数不是 4：$row"; problems=$((problems+1)); continue
    fi
    if [[ -z "$expect" || "$expect" == "-" ]]; then
      bad "$name 的期望标记为空或占位符（必须写实际的 X-MetaFusion-Service 值）"; problems=$((problems+1))
    fi
    if [[ ! "$url" =~ ^https?:// ]]; then
      bad "$name 的 URL 不是 http(s)（$url）"; problems=$((problems+1))
    fi
    if [[ ! "$status_re" =~ ^\^ ]]; then
      bad "$name 的状态码匹配式必须以 ^ 开头（$status_re）"; problems=$((problems+1))
    fi
  done
  local label old_sql new_sql old_table
  for row in "${COMPARE_ROWS[@]}"; do
    IFS=';' read -r label old_sql new_sql old_table <<< "$row"
    fields=$(awk -F';' '{print NF}' <<< "$row")
    if [[ "$fields" -ne 4 ]]; then
      bad "行数对比条目字段数不是 4：$row"; problems=$((problems+1)); continue
    fi
    if [[ -z "$label" || -z "$old_table" ]]; then
      bad "行数对比条目缺 label 或旧表名：$row"; problems=$((problems+1))
    fi
    for sql in "$old_sql" "$new_sql"; do
      if ! printf '%s' "$sql" | grep -Eq '^SELECT count\(\*\) FROM [a-z_]+\.[a-z_]+$'; then
        bad "行数对比 SQL 形状不符（应形如 SELECT count(*) FROM schema.table）：$sql"; problems=$((problems+1))
      fi
    done
  done
  printf '  %d 条直连断言 + %d 条网关断言 + %d 条行数对比，%d 个问题\n' "${#DIRECT_CHECKS[@]}" "${#GATEWAY_CHECKS[@]}" "${#COMPARE_ROWS[@]}" "$problems"
  if [[ "$problems" -gt 0 ]]; then
    echo "结论：断言表自检失败。"
    exit 1
  fi
  echo "结论：断言表自检通过（未发起任何网络请求）。"
  exit 0
}

# probe <name> <url> <expect-marker|any> <status-regex>：取响应头，校验状态码与服务标记
probe() {
  local name="$1" url="$2" expect="$3" status_re="$4"
  local out status marker
  out="$(curl -sS -m "$TIMEOUT" -D - -o /dev/null "$url" 2>/dev/null)" || { bad "$name 无法连接（$url）"; return; }
  status="$(printf '%s\n' "$out" | awk 'NR==1{print $2}')"
  marker="$(printf '%s\n' "$out" | awk -F': ' 'tolower($1)=="x-metafusion-service"{print $2}' | tr -d '\r')"
  if [[ -z "$status" ]]; then bad "$name 没有拿到响应状态（$url）"; return; fi
  if [[ ! "$status" =~ $status_re ]]; then bad "$name HTTP $status（$url，可接受：$status_re）"; return; fi
  if [[ "$expect" == "any" ]]; then
    if [[ -n "$marker" ]]; then ok "$name HTTP $status（上游 $marker）"; else bad "$name HTTP $status 但没有 X-MetaFusion-Service 标记"; fi
    return
  fi
  if [[ "$marker" == "$expect" ]]; then ok "$name HTTP $status → $expect"; else bad "$name 由 ${marker:-无标记} 答复，期望 $expect"; fi
}

run_checks() {
  local row
  for row in "$@"; do
    IFS=';' read -r name url expect status_re <<< "$row"
    probe "$name" "$url" "$expect" "$status_re"
  done
}

# rows <sql>：用 psql 打印单值
rows() {
  psql "$DSNS" -tAc "$1" 2>/dev/null | tr -d '[:space:]'
}

# table_state <schema.table>：yes / no / unknown。
# 旧表在本轮切流后由 deploy.sh retire 删除属于预期，这种情况报“已退役”而不是“读不到行数”；
# 但 psql 连不上、SQL 报错时同样是“读不到”——必须与“表不存在”分开，否则故障会被说成预期状态。
table_state() {
  local got rc
  got="$(psql "$DSNS" -tAc "SELECT to_regclass('$1') IS NOT NULL" 2>/dev/null)"; rc=$?
  if [[ "$rc" -ne 0 || -z "$got" ]]; then echo "unknown"; return; fi
  if [[ "$got" == "t" ]]; then echo "yes"; else echo "no"; fi
}

compare_rows() {
  local label="$1" old_sql="$2" new_sql="$3" old_table="${4:-}" a b state
  if [[ -n "$old_table" ]]; then
    state="$(table_state "$old_table")"
    case "$state" in
      no) na "$label 旧表 $old_table 已退役（retire 之后的预期状态，无需对比）"; return ;;
      unknown) bad "$label 读不到 $old_table 是否存在（DSNS/psql 不可用）：没跑检查不算通过"; return ;;
    esac
  fi
  a="$(rows "$old_sql")"; b="$(rows "$new_sql")"
  if [[ -z "$a" || -z "$b" ]]; then
    bad "$label 读不到行数（DSNS/psql/表不可用）：没跑检查不算通过"; return
  fi
  if [[ "$a" == "$b" ]]; then ok "$label 行数一致（旧 $a / 新 $b）"; else bad "$label 行数不一致（旧 $a / 新 $b）"; fi
}

# 新旧表行数对比表（只在切流窗口、设了 DSNS 时执行）：label;旧表 SQL;新表 SQL;旧表名。
# 旧表名必填：没有它就无法把"旧表已由 retire 删除（预期）"与"读不到表（故障）"分开。
# records / community.records 没有这一行：两张表都已删除（主仓库 11de83e 删路由、
# community 000006_drop_records 删表），不存在可对比的新旧表，留着只会永远 SKIP。
# 删除一个域时同步删掉这里的行，否则自检表会继续宣称覆盖它。
COMPARE_ROWS=(
  "topics;SELECT count(*) FROM modules.forum_topics;SELECT count(*) FROM community.topics;modules.forum_topics"
  "posts;SELECT count(*) FROM modules.forum_posts;SELECT count(*) FROM community.posts;modules.forum_posts"
  "boards;SELECT count(*) FROM modules.forum_boards;SELECT count(*) FROM community.boards;modules.forum_boards"
  "favorites;SELECT count(*) FROM catalog.favorites;SELECT count(*) FROM community.favorites;catalog.favorites"
)

# 参数解析
for arg in "$@"; do
  case "$arg" in
    --self-check) self_check ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数：$arg" >&2; usage >&2; exit 2 ;;
  esac
done

if ! command -v curl >/dev/null 2>&1; then
  echo "FAIL 本机没有 curl：无法执行探针（脚本没跑，不算通过）" >&2
  exit 1
fi

echo "== 1. 服务直连健康（期望各自带 X-MetaFusion-Service） =="
run_checks "${DIRECT_CHECKS[@]}"

if [[ -n "$GATEWAY" ]]; then
  echo "== 2. 网关分流（按前缀看谁在答复） =="
  run_checks "${GATEWAY_CHECKS[@]}"
else
  echo "== 2. 网关分流 =="
  na "未设置 GATEWAY：跳过网关分流校验"
fi

if [[ -n "$DSNS" ]]; then
  if ! command -v psql >/dev/null 2>&1; then
    echo "FAIL 设置了 DSNS 但本机没有 psql：行数对比跑不了（脚本没跑，不算通过）" >&2
    exit 1
  fi
  echo "== 3. 新旧表行数对比（切换瞬间应完全一致） =="
  for row in "${COMPARE_ROWS[@]}"; do
    IFS=';' read -r label old_sql new_sql old_table <<< "$row"
    compare_rows "$label" "$old_sql" "$new_sql" "$old_table"
  done
else
  echo "== 3. 表行数对比 =="
  na "未设置 DSNS：整段未执行（本次自检不覆盖数据搬运的完整性）"
fi

echo
printf '汇总：PASS=%d FAIL=%d SKIP=%d\n' "$pass" "$fail" "$skip"
if [[ "$fail" -gt 0 ]]; then
  echo "结论：存在失败项，按 runbook 的回滚步骤把对应前缀指回原上游。"
  exit 1
fi
echo "结论：没有失败项。SKIP=$skip 项未执行（未设置对应环境变量，或旧表已由 retire 删除）——SKIP 不等于通过。"
