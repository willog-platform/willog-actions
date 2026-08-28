#!/usr/bin/env bash
# 테스트 파일을 각자 별도 프로세스로 실행한다. 한 파일이 exit 를 호출하거나
# 중간에 죽어도 나머지가 계속 돌고, 실패는 SDD_FAIL_LOG 로 프로세스 밖에
# 기록되므로 어떤 종료코드로도 은폐되지 않는다. (source 방식은 실패를 기록한
# 테스트 파일이 뒤에서 `exit 0` 만 하면 harness 전체가 green 이 되었다.)
set -uo pipefail
cd "$(dirname "$0")"

FAIL_LOG="$(mktemp)"
export SDD_FAIL_LOG="$FAIL_LOG"

for t in test_*.sh; do
  [ -f "$t" ] || continue
  printf '\n== %s\n' "$t"
  bash -c 'set -uo pipefail; . ./helpers.sh; . "./$1"; exit 0' _ "$t"
  code=$?
  if [ "$code" -ne 0 ]; then
    printf '  FAIL %s 비정상 종료 (exit %s)\n' "$t" "$code"
    printf '%s 비정상 종료 (exit %s)\n' "$t" "$code" >> "$FAIL_LOG"
  fi
done

N="$(wc -l < "$FAIL_LOG" | tr -d '[:space:]')"
rm -f "$FAIL_LOG"
printf '\n실패 %s건\n' "$N"
[ "$N" -eq 0 ]
