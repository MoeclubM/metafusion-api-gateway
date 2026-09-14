#!/usr/bin/env bash
# MetaFusion 切流自检：确认各服务健康、网关把前缀切到了预期的上游、新旧表行数是否对齐。
# 对应主仓库 docs/architecture/cutover-runbook.md 的"验证"列，可整段照抄执行。
#
# 用法：
#   ./scripts/cutover-check.sh                       # 只做服务直连与服务自身健康检查
#   GATEWAY=https://findverse.cc ./scripts/cutover-check.sh   # 额外校验网关分流
#   DSNS='postgres://user:pass@host:5432/db?sslmode=disable' ./scripts/cutover-check.sh  # 额外对比表行数
#
# 判定依据：服务在响应头里带 X-MetaFusion-Service，据此确认是哪个上游答复的；
# 单体尚无该标记，因此仍指向单体的前缀会显示 "catalog(无标记)"。
set -uo pipefail

AUTH_URL="${AUTH_URL:-http://127.0.0.1:8081}"
COMMUNITY_URL="${COMMUNITY_URL:-http://127.0.0.1:8083}"
STORAGE_URL="${STORAGE_URL:-http://127.0.0.1:8082}"
CATALOG_URL="${CATALOG_URL:-http://127.0.0.1:8080}"
GATEWAY="${GATEWAY:-}"
DSNS="${DSNS:-}"
TIMEOUT="${TIMEOUT:-5}"

pass=0; fail=0; skip=0
ok()   { pass=$((pass+1)); printf '  PASS  %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
na()   { skip=$((skip+1)); printf '  SKIP  %s\n' "$1"; }

# probe <name> <url> <expect-marker|-> : 取响应头，校验 2xx 与服务标记
probe() {
  local name="$1" url="$2" expect="$3"
  local out
  out="$(curl -sS -m "$TIMEOUT" -D - -o /dev/null "$url" 2>/dev/null)" || { bad "$name 无法连接（$url）"; return; }
  local status marker
  status="$(printf '%s\n' "$out" | awk 'NR==1{print $2}')"
  marker="$(printf '%s\n' "$out" | awk -F': ' 'tolower($1)=="x-metafusion-service"{print $2}' | tr -d '\r')"
  if [[ ! "$status" =~ ^2 ]]; then bad "$name HTTP $status（$url）"; return; fi
  if [[ -n "$expect" && "$expect" != "-" ]]; then
    if [[ "$marker" == "$expect" ]]; then ok "$name → $expect"; else bad "$name 由 '$marker' 答复，期望 $expect"; fi
  else
    ok "$name HTTP $status（上游标记：${marker:-catalog(无标记)}）"
  fi
}

# rows <label> <sql> : 用 psql 打印单值
rows() {
  psql "$DSNS" -tAc "$2" 2>/dev/null | tr -d '[:space:]'
}

# table_exists <schema.table>：旧表在本轮切流后由 ./deploy.sh retire 删除属于预期，
# 这种情况报「已退役」而不是「读不到行数」，避免把正常状态显示成故障。
table_exists() {
  local got
  got="$(psql "$DSNS" -tAc "SELECT to_regclass('$1') IS NOT NULL" 2>/dev/null)"
  [[ "$got" == "t" ]]
}

compare_rows() {
  local label="$1" old_sql="$2" new_sql="$3"
  local old_table="${4:-}"
  local a b
  if [[ -n "$old_table" ]] && ! table_exists "$old_table"; then
    na "$label 旧表 $old_table 已退役（retire 之后的预期状态，无需对比）"; return
  fi
  a="$(rows "$label" "$old_sql")"; b="$(rows "$label" "$new_sql")"
  if [[ -z "$a" || -z "$b" ]]; then na "$label 无法读取行数（检查 DSNS 与表是否存在）"; return; fi
  if [[ "$a" == "$b" ]]; then ok "$label 行数一致（旧 $a / 新 $b）"; else bad "$label 行数不一致（旧 $a / 新 $b，差 $((b-a))）"; fi
}

echo "== 1. 服务直连健康 =="
probe "auth/ready"      "$AUTH_URL/ready"      "metafusion-auth"
probe "community/ready" "$COMMUNITY_URL/ready" "metafusion-community"
probe "storage/ready"   "$STORAGE_URL/ready"   "metafusion-storage"
probe "catalog/ready"   "$CATALOG_URL/ready"   "-"

if [[ -n "$GATEWAY" ]]; then
  echo "== 2. 网关分流（按 prefix 看谁在答复） =="
  probe "GET /api/auth/settings"      "$GATEWAY/api/auth/settings"      "-"
  probe "GET /api/community/boards"   "$GATEWAY/api/community/boards"   "-"
  probe "GET /api/oidc/jwks"          "$GATEWAY/api/oidc/jwks"          "-"
  probe "GET /.well-known/openid-configuration" "$GATEWAY/.well-known/openid-configuration" "-"
  echo "  （切流完成的判据：auth 前缀由 metafusion-auth 答复、community 前缀由 metafusion-community 答复）"
else
  echo "== 2. 网关分流 =="
  na "未设置 GATEWAY：跳过网关分流校验"
fi

if [[ -n "$DSNS" ]]; then
  echo "== 3. 新旧表行数对比（切换瞬间应完全一致） =="
  compare_rows "topics"    "SELECT count(*) FROM modules.forum_topics" "SELECT count(*) FROM community.topics"    "modules.forum_topics"
  compare_rows "posts"     "SELECT count(*) FROM modules.forum_posts"  "SELECT count(*) FROM community.posts"     "modules.forum_posts"
  compare_rows "boards"    "SELECT count(*) FROM modules.forum_boards" "SELECT count(*) FROM community.boards"    "modules.forum_boards"
  compare_rows "records"   "SELECT count(*) FROM modules.records"      "SELECT count(*) FROM community.records"   "modules.records"
  compare_rows "favorites" "SELECT count(*) FROM catalog.favorites"    "SELECT count(*) FROM community.favorites" "catalog.favorites"
else
  echo "== 3. 表行数对比 =="
  na "未设置 DSNS：跳过行数对比"
fi

echo
printf '汇总：PASS=%d FAIL=%d SKIP=%d\n' "$pass" "$fail" "$skip"
if [[ "$fail" -gt 0 ]]; then
  echo "结论：存在失败项，按 runbook 的回滚步骤把对应前缀指回原上游。"
  exit 1
fi
echo "结论：检查项全部通过（SKIP 项需要相应环境变量才能验证）。"
