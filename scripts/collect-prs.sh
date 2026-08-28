#!/usr/bin/env bash
# usage: collect-prs.sh <owner/repo> <base_sha> <head_sha>
# stdout: PR 번호 JSON 배열 (오름차순, 중복제거)
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

REPO="$(require repo "${1-}")"
BASE="$(require base "${2-}")"
HEAD_SHA="$(require head "${3-}")"
GH="${GH:-gh}"
MAX_COMMITS="$(int_or_default MAX_COMMITS "${MAX_COMMITS:-}" 100)"

SHAS="$(git rev-list --max-count="$MAX_COMMITS" "${BASE}..${HEAD_SHA}")"

if [ -z "$SHAS" ]; then
  printf '[]\n'
  exit 0
fi

# 커밋당 API 1회. squash/merge/rebase 모두에서 동작하는 유일한 방법.
NUMS=""
for sha in $SHAS; do
  if got="$("$GH" api "repos/${REPO}/commits/${sha}/pulls" \
             -H 'Accept: application/vnd.github+json' \
             --jq '.[].number' 2>/dev/null)"; then
    if [ -n "$got" ]; then
      NUMS="${NUMS}${got}
"
    fi
  else
    # 조회 실패를 "PR 없음" 과 같게 취급하면 PR 목록이 조용히 불완전해진다.
    # 스펙 §8의 "조용한 절단 금지" 원칙에 따라 크게 실패한다.
    # 크게 실패해도 안전한 이유가 설계에 이미 있다: 알림 job 은 배포 job 의
    # needs 가 아니므로 배포는 영향받지 않고, deployed/{env} 태그는 전송
    # 성공 후에만 이동하므로 다음 배포의 노트가 이 범위를 함께 담아
    # 자동 복구된다.
    die "PR 조회 실패: ${sha} (gh api 오류 — 인증·레이트리밋·네트워크 확인). 목록을 조용히 불완전하게 내지 않는다."
  fi
done

# jq 한 번으로 필터·정렬·중복제거를 모두 한다.
# grep 을 쓰면 매치 0건일 때 exit 1 이고, 이 스크립트의 `set -o pipefail` +
# `set -e` 아래에서는 파이프라인 전체가 1 로 끝난다 — stdout 은 `[]` 로 옳은데
# 종료코드만 실패가 되어, 호출하는 워크플로 step 이 실패로 표시된다.
# (PR 없는 커밋만 있는 배포는 실제로 흔하다.)
# `unique` 는 오름차순 정렬까지 함께 처리한다.
printf '%s' "$NUMS" \
  | jq -Rsc 'split("\n") | map(select(test("^[0-9]+$")) | tonumber) | unique'
