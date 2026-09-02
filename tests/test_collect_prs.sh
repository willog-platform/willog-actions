S="$ROOT/scripts/collect-prs.sh"

d="$(make_repo)"
BASE="$(git -C "$d" rev-parse HEAD~2)"
HEAD_SHA="$(git -C "$d" rev-parse HEAD)"
S1="$(git -C "$d" rev-parse HEAD~1)"
S2="$HEAD_SHA"

# gh 응답 준비: 두 커밋이 각각 PR을 가리키고, 하나는 같은 PR 중복
RESP="$(mktemp -d)"
slug() { printf '%s' "$*" | tr -cs 'A-Za-z0-9' '_'; }
# 주의: collect-prs.sh 는 `gh api … --jq '.[].number'` 로 호출하므로 실제 gh는
# JSON이 아니라 맨몸 숫자를 줄단위로 낸다. 픽스처도 그 형식이어야 한다.
printf '94\n' > "$RESP/$(slug api repos/o/r/commits/$S1/pulls -H Accept: application/vnd.github+json --jq .[].number).json"
printf '95\n94\n' > "$RESP/$(slug api repos/o/r/commits/$S2/pulls -H Accept: application/vnd.github+json --jq .[].number).json"

GHBIN="$(fake_gh "$RESP")"
out="$(cd "$d" && GH="$GHBIN" FAKE_GH_DIR="$RESP" bash "$S" o/r "$BASE" "$HEAD_SHA" 2>/dev/null)"
assert_json_eq "PR 번호 중복제거·정렬" "$out" '[94,95]'

# PR이 없는 커밋만 있으면 빈 배열
EMPTY="$(mktemp -d)"
out="$(cd "$d" && GH="$GHBIN" FAKE_GH_DIR="$EMPTY" bash "$S" o/r "$BASE" "$HEAD_SHA" 2>/dev/null)"
assert_json_eq "PR 없으면 빈 배열" "$out" '[]'

# 범위가 비면 빈 배열 (gh 호출 0회)
out="$(cd "$d" && GH=/nonexistent/gh bash "$S" o/r "$HEAD_SHA" "$HEAD_SHA" 2>/dev/null)"
assert_json_eq "빈 범위면 gh 호출 없이 빈 배열" "$out" '[]'

assert_fail "인자 누락 시 실패" bash "$S" o/r

# PR이 0건일 때 stdout 뿐 아니라 **종료코드도 0** 이어야 한다.
# grep 기반 꼬리는 매치 0건에서 pipefail 로 1을 내며, stdout만 보는
# 위의 테스트들은 그것을 통과시킨다.
( cd "$d" && GH="$GHBIN" FAKE_GH_DIR="$EMPTY" bash "$S" o/r "$BASE" "$HEAD_SHA" >/dev/null 2>&1 )
if [ $? -eq 0 ]; then _pass "PR 0건에서 종료코드 0"; else _fail "PR 0건에서 종료코드 0"; fi

( cd "$d" && GH=/nonexistent/gh bash "$S" o/r "$HEAD_SHA" "$HEAD_SHA" >/dev/null 2>&1 )
if [ $? -eq 0 ]; then _pass "빈 범위에서 종료코드 0"; else _fail "빈 범위에서 종료코드 0"; fi

# gh 조회가 실패하면 "PR 없음" 으로 삼키지 않고 크게 실패한다.
# 삼키면 레이트리밋 한 번에 PR 목록이 조용히 불완전해진다.
FAILBIN="$(mktemp -d)/gh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAILBIN"; chmod +x "$FAILBIN"
assert_fail "gh 조회 실패 시 die" \
  bash -c "cd '$d' && GH='$FAILBIN' bash '$S' o/r '$BASE' '$HEAD_SHA'"

err="$( cd "$d" && GH="$FAILBIN" bash "$S" o/r "$BASE" "$HEAD_SHA" 2>&1 >/dev/null || true )"
case "$err" in
  *'::error::'*) _pass "gh 조회 실패는 ::error:: 로 알린다" ;;
  *)             _fail "gh 조회 실패는 ::error:: 로 알린다" ;;
esac

# gh 가 stderr 로 낸 진짜 원인(403·레이트리밋·네트워크)이 ::error:: 안에 그대로
# 보여야 한다. 버리면 실패 원인을 러너 로그에서 알 수 없다 — 2026-09-02 첫
# stage 실배포에서 pull-requests:read 누락 403 이 "gh api 오류" 로만 남아
# 원인 추적에 시간을 썼다.
FAILBIN2="$(mktemp -d)/gh"
printf '#!/usr/bin/env bash\necho "gh: Resource not accessible by integration (HTTP 403)" >&2\nexit 1\n' > "$FAILBIN2"; chmod +x "$FAILBIN2"
err="$( cd "$d" && GH="$FAILBIN2" bash "$S" o/r "$BASE" "$HEAD_SHA" 2>&1 >/dev/null || true )"
case "$err" in
  *'::error::'*'Resource not accessible by integration (HTTP 403)'*)
    _pass "gh 조회 실패 시 gh 의 stderr 원문이 ::error:: 에 포함된다" ;;
  *) _fail "gh 조회 실패 시 gh 의 stderr 원문이 ::error:: 에 포함된다 (got: $(printf '%s' "$err" | head -c 200))" ;;
esac
# ::error:: 는 한 줄이어야 러너가 워크플로 커맨드로 해석한다 — 여러 줄 stderr 는 한 줄로 접힌다.
FAILBIN3="$(mktemp -d)/gh"
printf '#!/usr/bin/env bash\nprintf "line one\\nline two\\n" >&2\nexit 1\n' > "$FAILBIN3"; chmod +x "$FAILBIN3"
err="$( cd "$d" && GH="$FAILBIN3" bash "$S" o/r "$BASE" "$HEAD_SHA" 2>&1 >/dev/null || true )"
n="$(printf '%s\n' "$err" | grep -c '::error::')"
case "$err" in
  *'line one'*'line two'*) [ "$n" = "1" ] && _pass "여러 줄 gh stderr 는 ::error:: 한 줄로 접힌다" || _fail "여러 줄 gh stderr 는 ::error:: 한 줄로 접힌다 (::error:: ${n}개)" ;;
  *) _fail "여러 줄 gh stderr 는 ::error:: 한 줄로 접힌다 (내용 누락)" ;;
esac
