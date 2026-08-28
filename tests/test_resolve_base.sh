S="$ROOT/scripts/resolve-base.sh"

# 1) deployed/{env} 태그가 없으면 HEAD~1 로 부트스트랩
d="$(make_repo)"
out="$(cd "$d" && bash "$S" prod 2>/dev/null)"
assert_json_eq "태그 없음 → 커밋 1개 범위" \
  "$(printf '%s' "$out" | jq '{commits, truncated}')" '{"commits":1,"truncated":false}'

# 2) 태그가 있으면 그 지점부터
git -C "$d" tag deployed/prod HEAD~2
out="$(cd "$d" && bash "$S" prod 2>/dev/null)"
assert_json_eq "태그 있음 → 커밋 2개 범위" \
  "$(printf '%s' "$out" | jq '.commits')" '2'
assert_json_eq "base가 태그 커밋" \
  "$(printf '%s' "$out" | jq -r '.base' | jq -R .)" \
  "$(git -C "$d" rev-parse HEAD~2 | jq -R .)"

# 3) 상한 초과 시 truncated
out="$(cd "$d" && MAX_COMMITS=1 bash "$S" prod 2>/dev/null)"
assert_json_eq "상한 초과 → truncated true" \
  "$(printf '%s' "$out" | jq '.truncated')" 'true'

# 4) 커밋 1개뿐인 repo에서도 죽지 않는다
e="$(mktemp -d)"; git -C "$e" init -q -b main
git -C "$e" config user.email t@t.io; git -C "$e" config user.name t
echo a > "$e/a"; git -C "$e" add -A; git -C "$e" commit -q -m only
out="$(cd "$e" && bash "$S" prod 2>/dev/null)"
assert_json_eq "단일 커밋 repo → 0개 범위" \
  "$(printf '%s' "$out" | jq '.commits')" '0'

# 5) environment 누락은 실패
assert_fail "environment 누락 시 실패" bash "$S"

# 6) MAX_COMMITS 가 정수가 아니면 경고하고 기본값 100으로 진행한다.
#    (bash 원시 에러가 새어나가거나 truncated 가 조용히 false 가 되면 안 된다.)
out="$(cd "$d" && MAX_COMMITS=abc bash "$S" prod 2>/dev/null)"
assert_json_eq "비숫자 MAX_COMMITS → 기본값 100 적용" \
  "$(printf '%s' "$out" | jq '{commits, truncated}')" '{"commits":2,"truncated":false}'

err="$(cd "$d" && MAX_COMMITS=abc bash "$S" prod 2>&1 >/dev/null || true)"
case "$err" in
  *'::warning::'*) _pass "비숫자 MAX_COMMITS 는 ::warning:: 으로 알린다" ;;
  *)               _fail "비숫자 MAX_COMMITS 는 ::warning:: 으로 알린다" ;;
esac
case "$err" in
  *'integer expression expected'*) _fail "bash 원시 에러가 stderr 로 새어나감" ;;
  *)                               _pass "bash 원시 에러 누출 없음" ;;
esac
