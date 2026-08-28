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

# `-c` 필수: 이 출력은 워크플로에서 `$GITHUB_OUTPUT` 에 `name=value` 로
# 기록된다. jq 의 기본 출력은 여러 줄이고, 여러 줄 값은 GitHub 의 줄 단위
# 파서를 깨뜨려 **임의의 output 주입**을 허용한다.
jq -n -c \
  --arg base "$BASE" --arg head "$HEAD_SHA" \
  --argjson commits "$TOTAL" --argjson truncated "$TRUNCATED" \
  '{base:$base, head:$head, commits:$commits, truncated:$truncated}'
