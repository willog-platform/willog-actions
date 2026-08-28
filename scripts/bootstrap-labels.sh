#!/usr/bin/env bash
# usage: bootstrap-labels.sh <owner/repo> [<owner/repo>...]
# semver bump 에 쓰이는 라벨 3종을 생성한다. 이미 있으면 --force 가 색상·설명을
# 갱신한다 (실패하지 않는다). 롤아웃 중 재실행해도 안전하게 설계됨.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

[ "$#" -gt 0 ] || die "repo를 하나 이상 지정하세요: bootstrap-labels.sh owner/repo ..."
GH="${GH:-gh}"

for repo in "$@"; do
  note "라벨 생성: ${repo}"
  "$GH" label create breaking --repo "$repo" --color B60205 \
    --description "호환성 파괴 — major 증가" --force
  "$GH" label create feature  --repo "$repo" --color 0E8A16 \
    --description "기능 추가 — minor 증가" --force
  "$GH" label create fix      --repo "$repo" --color 1D76DB \
    --description "버그 수정 — patch 증가" --force
done
