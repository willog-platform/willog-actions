S="$ROOT/scripts/bootstrap-labels.sh"

# 호출 인자를 기록하는 가짜 gh
LOG="$(mktemp)"
BIN="$(mktemp -d)/gh"
cat > "$BIN" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
exit 0
FAKE
chmod +x "$BIN"

GH="$BIN" GH_LOG="$LOG" bash "$S" o/r1 o/r2 >/dev/null 2>&1

assert_json_eq "repo 2개 × 라벨 3개 = 6회 호출" \
  "$(grep -c 'label create' "$LOG" | jq -R 'tonumber')" '6'
assert_json_eq "breaking 라벨 포함" \
  "$(grep -c 'breaking' "$LOG" | jq -R 'tonumber')" '2'
assert_fail "repo 인자 없으면 실패" bash "$S"

# 재실행(idempotent) — --force 로 다시 돌려도 실패하지 않고 동일하게 6회 호출한다.
LOG2="$(mktemp)"
GH="$BIN" GH_LOG="$LOG2" bash "$S" o/r1 o/r2 >/dev/null 2>&1
assert_json_eq "재실행해도 6회 호출" \
  "$(grep -c 'label create' "$LOG2" | jq -R 'tonumber')" '6'
assert_json_eq "재실행 시 모든 호출에 --force 포함" \
  "$(grep -c -- '--force' "$LOG2" | jq -R 'tonumber')" '6'
