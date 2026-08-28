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
