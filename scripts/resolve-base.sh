#!/usr/bin/env bash
# usage: resolve-base.sh <environment> [head_sha]
# stdout: {"base","head","commits","truncated"}
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

ENVIRONMENT="$(require environment "${1-}")"
HEAD_SHA="${2:-$(git rev-parse HEAD)}"
MAX_COMMITS="$(int_or_default MAX_COMMITS "${MAX_COMMITS:-}" 100)"

TAG="deployed/${ENVIRONMENT}"
BASE="$(git rev-parse --verify --quiet "refs/tags/${TAG}^{commit}" || true)"

if [ -z "$BASE" ]; then
  note "태그 ${TAG} 없음 — ${HEAD_SHA}~1 로 부트스트랩"
  BASE="$(git rev-parse --verify --quiet "${HEAD_SHA}^" || true)"
  # 루트 커밋이면 범위가 빈다. 그것이 정답이다.
  [ -n "$BASE" ] || BASE="$HEAD_SHA"
fi

TOTAL="$(git rev-list --count "${BASE}..${HEAD_SHA}")"

TRUNCATED=false
if [ "$TOTAL" -gt "$MAX_COMMITS" ]; then
  TRUNCATED=true
  warn "커밋 ${TOTAL}개가 상한 ${MAX_COMMITS}을 초과 — PR 목록이 절단된다"
fi

# 짧은 sha 로 노출한다 (스펙 §3.3 목업: `a1b2c3d..6185be5`). 전체 40자는
# render-simple.jq 의 범위 필드를 2열 레이아웃에서 81자로 만들어 잘려 보이고,
# render-thread.jq·GitHub Release 본문에도 그대로 번진다. 짧은 sha 는 git 의
# 커밋 lookup(rev-list/diff/rev-parse)·`gh api commits/{sha}/pulls` 모두에서
# 그대로 동작하므로(전부 이 스크립트 밖에서 git 이 해석하는 참조다) 표시용
# 축약이 하류 계산에 영향을 주지 않는다. 위 rev-list --count·rev-parse 는
# 전체 sha 로 이미 계산을 마쳤으므로 정확도에도 영향이 없다.
BASE_SHORT="$(git rev-parse --short "$BASE")"
HEAD_SHORT="$(git rev-parse --short "$HEAD_SHA")"

# `-c` 필수: 이 출력은 워크플로에서 `$GITHUB_OUTPUT` 에 `name=value` 로
# 기록된다. jq 의 기본 출력은 여러 줄이고, 여러 줄 값은 GitHub 의 줄 단위
# 파서를 깨뜨려 **임의의 output 주입**을 허용한다.
jq -n -c \
  --arg base "$BASE_SHORT" --arg head "$HEAD_SHORT" \
  --argjson commits "$TOTAL" --argjson truncated "$TRUNCATED" \
  '{base:$base, head:$head, commits:$commits, truncated:$truncated}'
