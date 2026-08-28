S="$ROOT/scripts/bootstrap-labels.sh"

# --- 상태를 가진 가짜 gh (항목 5) ---
# 이전 버전은 무조건 exit 0 이라 "재실행해도 6회 호출" 을 실패시킬 방법이
# 없었다(--force 를 지워도 그대로 통과했다). 이 가짜는 실제 `gh label create`
# 처럼 동작한다: 레포+이름 조합이 이미 만들어졌는데 --force 가 없으면 실패한다
# (exit 1). 호출 인자는 성공/실패와 무관하게 항상 로그에 남긴다 — "몇 번
# 불렸는가" 를 세는 기존 어서션들이 그대로 유효해야 한다.
# 상태는 $STATE_DIR 에 파일로 남기고, 여러 번의 스크립트 실행(재실행 시나리오)
# 에 걸쳐 같은 $STATE_DIR 을 주면 그 사이의 "이미 있음" 을 재현한다.
# usage: GH_LOG=<file> STATE_DIR=<dir> <바이너리> label create <name> --repo <repo> ... [--force]
make_fake_gh() {
  local bin
  bin="$(mktemp -d)/gh"
  cat > "$bin" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
if [ "$1" = "label" ] && [ "$2" = "create" ]; then
  name="$3"
  repo="" force=0 prev=""
  for a in "$@"; do
    if [ "$prev" = "--repo" ]; then repo="$a"; fi
    if [ "$a" = "--force" ]; then force=1; fi
    prev="$a"
  done
  key="${STATE_DIR}/$(printf '%s' "${repo}__${name}" | tr -cs 'A-Za-z0-9_' '_')"
  if [ -f "$key" ] && [ "$force" -ne 1 ]; then
    exit 1
  fi
  : > "$key"
fi
exit 0
FAKE
  chmod +x "$bin"
  printf '%s' "$bin"
}

BIN="$(make_fake_gh)"
STATE="$(mktemp -d)"
LOG="$(mktemp)"

GH="$BIN" GH_LOG="$LOG" STATE_DIR="$STATE" bash "$S" o/r1 o/r2 >/dev/null 2>&1

assert_json_eq "repo 2개 × 라벨 3개 = 6회 호출" \
  "$(grep -c 'label create' "$LOG" | jq -R 'tonumber')" '6'
assert_json_eq "breaking 라벨 포함" \
  "$(grep -c 'breaking' "$LOG" | jq -R 'tonumber')" '2'
assert_fail "repo 인자 없으면 실패" bash "$S"

# 재실행(idempotent) — **같은 STATE_DIR** 을 재사용해 "라벨이 이미 있음" 을
# 실제로 재현한다. 실제 스크립트는 매 호출에 --force 를 붙이므로 실패하지
# 않고 동일하게 6회 호출해야 한다. (이전 버전의 이 어서션은 가짜 gh가
# 무조건 성공했으므로 --force 를 지워도 통과했다 — 아래 별도 스크래치
# 검증으로 이 어서션이 실제로 --force 유무를 구별함을 증명한다.)
LOG2="$(mktemp)"
GH="$BIN" GH_LOG="$LOG2" STATE_DIR="$STATE" bash "$S" o/r1 o/r2 >/dev/null 2>&1
assert_json_eq "재실행해도 6회 호출 (라벨이 이미 있어도 --force 로 실패하지 않는다)" \
  "$(grep -c 'label create' "$LOG2" | jq -R 'tonumber')" '6'
assert_json_eq "재실행 시 모든 호출에 --force 포함" \
  "$(grep -c -- '--force' "$LOG2" | jq -R 'tonumber')" '6'

# --- 부하검증(load-bearing) 증명: --force 를 지운 스크래치 복사본은 재실행에서 죽는다 ---
# 위 "재실행해도 6회 호출" 어서션이 실제로 무언가를 검사하는지 직접 증명한다.
# bootstrap-labels.sh 를 복사해 `--force` 를 지우고, 같은 상태-가진 가짜 gh 로
# 똑같은 재실행 시나리오를 돌리면 **두 번째 실행에서 6회에 못 미쳐야 한다**
# (첫 호출에서 이미 있는 라벨과 부딛혀 set -e 로 죽으므로).
SCRATCH="$(mktemp -d)/bootstrap-labels-noforce.sh"
sed 's/ --force//g' "$S" > "$SCRATCH"
chmod +x "$SCRATCH"

BIN2="$(make_fake_gh)"
STATE2="$(mktemp -d)"
LOG3="$(mktemp)"; LOG4="$(mktemp)"
GH="$BIN2" GH_LOG="$LOG3" STATE_DIR="$STATE2" bash "$SCRATCH" o/r1 o/r2 >/dev/null 2>&1
GH="$BIN2" GH_LOG="$LOG4" STATE_DIR="$STATE2" bash "$SCRATCH" o/r1 o/r2 >/dev/null 2>&1
NOFORCE_COUNT="$(grep -c 'label create' "$LOG4" | tr -d ' ')"
printf '  [증명] --force 제거 스크래치의 재실행 label-create 호출 수: %s (6 미만이어야 어서션이 부하검증임을 증명)\n' "$NOFORCE_COUNT"
if [ "$NOFORCE_COUNT" -lt 6 ]; then
  _pass "증명: --force 를 지우면 '재실행해도 6회 호출' 이 실제로 깨진다 (부하검증 확인됨)"
else
  _fail "증명 실패: --force 를 지웠는데도 6회 호출이 유지됐다 (어서션이 부하검증이 아님)"
fi
