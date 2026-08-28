#!/usr/bin/env bash
# usage: next-version.sh <labels_json> [override]
# stdout: {"previous","next","bump"}
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

LABELS_JSON="$(require labels "${1-}")"
# `${2-auto}` 를 쓴다. `${2:-auto}` 는 **명시적으로 넘어온 빈 문자열**까지
# 생략과 동일하게 취급해 조용히 auto 로 떨어진다 — 워크플로 input 오타가
# prod 릴리즈 번호를 조용히 잘못 매기는 경로다. 빈 값은 아래 case 에서 die 된다.
OVERRIDE="${2-auto}"

# labels 가 JSON 배열인지 검증한다. 검증하지 않으면 `null`·`"문자열"`·잘린 JSON
# 이 모두 jq 실패를 거쳐 조용히 patch 로 떨어진다 — breaking 변경이 patch 로
# 저평가되어도 아무 흔적이 남지 않는다. 형제 스크립트들의 "조용한 절단 금지"
# 원칙과 정면 충돌하므로 크게 실패한다.
printf '%s' "$LABELS_JSON" | jq -e 'type == "array"' >/dev/null 2>&1 \
  || die "labels 가 JSON 배열이 아니다: '${LABELS_JSON}'"

# override 형식을 태그 유무 판정보다 먼저 검증한다. 아래 "태그 없음 → v1.0.0"
# 조기 종료 경로 뒤로 미루면, v* 태그가 하나도 없는 4개 대상 repo 전부의
# 주 경로에서 override 오타가 die 로 이어지지 못하고 조용히 통과한다 —
# F3 가 막으려던 바로 그 상황이 태그 부재 경로에서는 무방비였다.
case "$OVERRIDE" in
  auto|patch|minor|major) : ;;
  *) die "version_bump 값이 잘못됨: ${OVERRIDE} (auto|patch|minor|major)" ;;
esac

# 태그 선택에 두 가지 필터가 반드시 필요하다.
# ① `--merged HEAD` — 도달 불가한 태그를 배제한다. `git tag --list` 는 기본적으로
#    reachability 를 보지 않으므로, 버려진 브랜치에 달린 `v9.9.9` 하나가 이후
#    모든 버전 계산을 엉뚱한 번호대로 끌고 간다.
# ② `grep -E '^v[0-9]+(\.[0-9]+){0,2}$'` — 이 시스템이 스스로 만드는 형태
#    (`v{major}[.{minor}[.{patch}]]`)만 후보로 삼는다. 이유가 둘이다:
#    · git 의 기본 versionsort 는 `v1.2.3-rc1` 을 `v1.2.3` 보다 **크게** 정렬한다
#      (semver 우선순위와 반대). 그래서 실제 마지막 릴리즈가 `v1.2.0` 인데
#      버려진 `v2.0.0-rc1` 이 남아 있으면 다음 버전이 `v2.0.1` 로 튀어 v1.x
#      계열 전체를 건너뛴다.
#    · `v1x` 처럼 `v[0-9]*` glob 은 통과하지만 숫자로 파싱되지 않는 태그가
#      들어오면 `next` 가 `previous` 보다 **낮아진다**(v1x → v0.0.1).
#    프로덕션 버전 계산의 기반은 이 시스템이 만든 태그로 한정하는 것이
#    유일하게 건전하다. 사람이 다른 기준을 원하면 정식 형태의 태그를 만든다.
PREV="$(git tag --list 'v[0-9]*' --merged HEAD --sort=-v:refname 2>/dev/null \
        | grep -E '^v[0-9]+(\.[0-9]+){0,2}$' \
        | head -1 || true)"

if [ -z "$PREV" ]; then
  note "v* 태그 없음 — 첫 릴리즈로 v1.0.0 을 낸다"
  jq -n '{previous:null, next:"v1.0.0", bump:"initial"}'
  exit 0
fi

if [ "$OVERRIDE" = "auto" ]; then
  if printf '%s' "$LABELS_JSON" | jq -e 'index("breaking")' >/dev/null 2>&1; then
    BUMP=major
  elif printf '%s' "$LABELS_JSON" | jq -e 'index("feature")' >/dev/null 2>&1; then
    BUMP=minor
  else
    BUMP=patch
  fi
else
  case "$OVERRIDE" in
    major|minor|patch) BUMP="$OVERRIDE" ;;
    *) die "version_bump 값이 잘못됨: ${OVERRIDE} (auto|patch|minor|major)" ;;
  esac
fi

# v1.9.0-rc1 → 1 9 0. prerelease 접미사는 버린다.
CORE="$(printf '%s' "$PREV" | sed 's/^v//; s/[-+].*$//')"
# `cut` 을 쓰면 안 된다. `cut -d. -fN` 은 구분자가 없는 문자열에 대해
# 빈 값이 아니라 **전체 줄**을 반환한다(POSIX 공통 동작). `v2` 같은 태그에서
# MAJOR=MINOR=PATCH=2 가 되어 patch bump 가 `v2.2.3` 을 낸다.
# awk 는 없는 필드에 빈 값을 준다.
MAJOR="$(printf '%s' "$CORE" | awk -F. '{print $1}')"
MINOR="$(printf '%s' "$CORE" | awk -F. '{print $2}')"
PATCH="$(printf '%s' "$CORE" | awk -F. '{print $3}')"

# 산술 전에 `10#` 으로 10진수를 강제하고 빈 자리는 0으로 채운다.
# bash 산술은 선행 0 을 8진수 접두사로 읽으므로 `v1.09.0` 같은 태그에서
# `$((MINOR + 1))` 이 "value too great for base" 에러를 낸다. 실측(bash 3.2.57)
# 결과 이 에러가 `case` 분기 안에서 발생하면 `set -e` 가 전파되지 않고
# **값이 증가하지 않은 채 조용히 계속 진행**된다 — 즉 크래시가 아니라
# 잘못된 버전 번호가 나간다. 어느 쪽이든 막아야 한다. semver 는 선행 0 을 금지하지만
# 사람이 손으로 붙인 태그는 그 규칙을 지키지 않는다.
# 비숫자가 섞인 경우도 여기서 0으로 흡수된다
# (`git tag --list 'v[0-9]*'` 이 첫 글자만 숫자로 제한하므로 v1.x.y 형태의
#  x·y 에는 무엇이든 들어올 수 있다).
dec() {
  case "${1-}" in
    ''|*[!0-9]*) printf '0' ;;
    *)           printf '%s' "$((10#$1))" ;;
  esac
}
MAJOR="$(dec "$MAJOR")"
MINOR="$(dec "$MINOR")"
PATCH="$(dec "$PATCH")"

case "$BUMP" in
  major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
  minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
  patch) PATCH=$((PATCH + 1)) ;;
esac

jq -n --arg prev "$PREV" --arg next "v${MAJOR}.${MINOR}.${PATCH}" --arg bump "$BUMP" \
  '{previous:$prev, next:$next, bump:$bump}'
