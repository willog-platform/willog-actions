#!/usr/bin/env bash
# usage: fetch-prs.sh <owner/repo> <numbers_json>
# stdout: raw PR JSON 배열
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

REPO="$(require repo "${1-}")"
NUMS_JSON="$(require numbers "${2-}")"
GH="${GH:-gh}"

NUMS="$(printf '%s' "$NUMS_JSON" | jq -r '.[]')"

if [ -z "$NUMS" ]; then
  printf '[]\n'
  exit 0
fi

# collect-prs.sh 과 같이 변수에 모은다. 임시 파일을 쓰면 ① 중간에 실패했을
# 때 정리되지 않고 ② 한 PR 의 깨진 응답이 공유 버퍼를 오염시켜 배치 전체의
# 출력을 날린다(한 건 실패가 전건 손실이 된다).
RAW=""
for n in $NUMS; do
  got=""
  if got="$("$GH" pr view "$n" --repo "$REPO" \
             --json number,title,author,labels,body,url 2>/dev/null)" \
     && printf '%s' "$got" | jq -e 'type == "object"' >/dev/null 2>&1; then
    :
  else
    # 조회 실패한 PR 을 목록에서 조용히 빼지 않는다. 번호와 링크는 이미
    # 알고 있으므로 자리표시자를 넣어 PR 자체는 노트에 남긴다 —
    # 스펙 §8의 "조용한 절단 금지". 알림은 계속 발송된다.
    warn "PR #${n} 조회 실패 — 자리표시자로 대체한다"
    got="$(jq -n --argjson number "$n" \
            --arg url "https://github.com/${REPO}/pull/${n}" \
            '{number:$number, title:"(PR 조회 실패)", url:$url,
              author:{login:"unknown"}, labels:[], body:null}')"
  fi
  RAW="${RAW}${got}
"
done

printf '%s' "$RAW" | jq -sc '.'
