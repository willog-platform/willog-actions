#!/usr/bin/env bash
# usage: detect-changes.sh <base> <head> <migration_glob> [api_glob] [api_exclude_glob]
# glob 은 쉼표로 여러 개 지정 가능. git pathspec :(glob) 문법을 쓴다.
# stdout: {"migrations":[],"api_touched":bool,"api_files":[]}
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

BASE="$(require base "${1-}")"
HEAD_SHA="$(require head "${2-}")"
MIGRATION_GLOB="$(require migration_glob "${3-}")"
API_GLOB="${4-}"
API_EXCLUDE_GLOB="${5-}"

# 쉼표 구분 glob 을 git pathspec 배열로. bash 3.2 이므로 IFS 루프를 쓴다.
build_pathspec() {
  local magic="$1" patterns="$2" old_ifs="$IFS" p
  # `set -f` (noglob) 가 필수다. `for p in $patterns` 의 비인용 확장은
  # IFS 분리만 하는 것이 아니라 **경로 확장까지** 수행하므로, bash 가 CWD
  # 기준으로 패턴을 먼저 전개해 `:(glob)` 이 붙기 전에 값이 바뀐다.
  # bash 3.2 에는 globstar 가 없어 `**` 를 `*` 로 취급하므로 깊은 경로가
  # 조용히 누락된다 (실측: 컨트롤러 15개 중 2개만 잡혔다).
  # 이 스크립트의 설계 전제가 "glob 해석을 git 에 위임"이므로 bash 쪽
  # 전개는 반드시 꺼야 한다.
  set -f
  IFS=','
  for p in $patterns; do
    # 앞뒤 공백 제거
    p="$(printf '%s' "$p" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$p" ] && printf '%s\n' ":(${magic})${p}"
  done
  IFS="$old_ifs"
  # `set +f` 가 마지막 명령이라 함수 종료코드는 항상 0이다.
  # (패턴 목록이 빈 문자열로 끝나면 루프의 `[ -n "$p" ] &&` 가 1을 내는데,
  #  호출부가 명령치환 + set -e 이므로 그대로 두면 스크립트가 죽는다.)
  set +f
}

# git diff 출력(경로 목록) → basename 정렬·중복제거 JSON 배열.
# jq 한 번으로 끝낸다. `while read | sort | jq -R . | jq -sc` 조합은
# 빈 입력에서 `set -euo pipefail` 과 맞물려 종료코드가 1이 되기 쉽고
# (루프 본문의 `[ -n "$f" ] &&` 가 마지막 명령이 되어 1을 낸다),
# 변경이 하나도 없는 배포는 가장 흔한 경우다.
# `sub(".*/"; "")` 는 탐욕적 매칭으로 마지막 `/` 까지 잘라 basename 을 낸다.
# `unique` 가 정렬과 중복제거를 함께 처리한다.
basenames_json() {
  jq -Rsc 'split("\n")
           | map(select(length > 0) | sub(".*/"; ""))
           | unique'
}

# ── 빈 pathspec 의 위험 ────────────────────────────────────────────
# `git diff ... -- $SPEC` 에서 $SPEC 가 비면 `--` 뒤에 아무것도 없는 것과
# 같아 **경로 제한이 아예 사라진다** (변경된 전 파일이 매치된다).
# 제외 패턴만 남은 경우도 git 은 "그것 빼고 전부"로 해석해 똑같이 위험하다.
# 따라서 raw 인자가 아니라 **조립된 포함 pathspec** 이 비었는지를 검사한다.
# 공백만·쉼표만인 값(`' '`, `',,'`)은 raw 검사를 통과하지만 조립 결과가 빈다.

# 추가된 마이그레이션만 (A). 수정은 릴리즈 노트에 무의미하다.
MIG_SPEC="$(build_pathspec glob "$MIGRATION_GLOB")"
# migration_glob 은 필수 input 이다. 공백만인 값이 조용히 "마이그레이션 없음"
# 으로 보고되면 필수로 만든 이유가 사라진다 — 있는데 없다고 하는 것이 최악.
[ -n "$MIG_SPEC" ] \
  || die "migration_glob 이 유효한 패턴을 만들지 못했다: '${MIGRATION_GLOB}'"
# 2>/dev/null 을 붙이지 않는다. 잘못된 pathspec 이나 없는 sha 는
# 조용히 "변경 없음" 으로 보고되면 안 된다 — set -e 로 크게 실패한다.
# shellcheck disable=SC2086
MIGRATIONS="$(git diff --name-only --diff-filter=A "${BASE}..${HEAD_SHA}" -- $MIG_SPEC | basenames_json)"

API_FILES='[]'
if [ -n "$API_GLOB" ]; then
  INC_SPEC="$(build_pathspec glob "$API_GLOB")"
  if [ -n "$INC_SPEC" ]; then
    SPEC="$INC_SPEC"
    if [ -n "$API_EXCLUDE_GLOB" ]; then
      EXC_SPEC="$(build_pathspec 'glob,exclude' "$API_EXCLUDE_GLOB")"
      if [ -n "$EXC_SPEC" ]; then
        SPEC="${SPEC}
${EXC_SPEC}"
      fi
    fi
    # shellcheck disable=SC2086
    API_FILES="$(git diff --name-only --diff-filter=ACMR "${BASE}..${HEAD_SHA}" -- $SPEC | basenames_json)"
  else
    # API 감지는 선택 기능이므로 die 하지 않는다. 다만 조용히 "변경 없음"이
    # 아니라 건너뛴다는 사실을 남긴다.
    warn "api_path_glob 이 유효한 패턴을 만들지 못했다: '${API_GLOB}' — API 표면 감지를 건너뛴다"
  fi
fi

jq -n --argjson m "$MIGRATIONS" --argjson a "$API_FILES" \
  '{migrations:$m, api_touched:(($a|length) > 0), api_files:$a}'
