S="$ROOT/scripts/next-version.sh"

# 태그 없는 repo → v1.0.0 (4개 repo 전부 이 경로로 시작한다)
d="$(make_repo)"
out="$(cd "$d" && bash "$S" '["fix"]' 2>/dev/null)"
assert_json_eq "태그 없음 → v1.0.0" "$out" \
  '{"previous":null,"next":"v1.0.0","bump":"initial"}'

git -C "$d" tag v1.7.0
assert_json_eq "fix → patch"      "$(cd "$d" && bash "$S" '["fix"]' 2>/dev/null)" \
  '{"previous":"v1.7.0","next":"v1.7.1","bump":"patch"}'
assert_json_eq "라벨 없음 → patch" "$(cd "$d" && bash "$S" '[]' 2>/dev/null)" \
  '{"previous":"v1.7.0","next":"v1.7.1","bump":"patch"}'
assert_json_eq "feature → minor"  "$(cd "$d" && bash "$S" '["fix","feature"]' 2>/dev/null)" \
  '{"previous":"v1.7.0","next":"v1.8.0","bump":"minor"}'
assert_json_eq "breaking 우선"    "$(cd "$d" && bash "$S" '["fix","feature","breaking"]' 2>/dev/null)" \
  '{"previous":"v1.7.0","next":"v2.0.0","bump":"major"}'
assert_json_eq "override 우선"    "$(cd "$d" && bash "$S" '["breaking"]' minor 2>/dev/null)" \
  '{"previous":"v1.7.0","next":"v1.8.0","bump":"minor"}'

# --- 태그 선택 규칙 ---
# 모든 태그를 지우는 헬퍼. 케이스마다 상태를 깨끗이 만든다.
clear_tags() { for t in $(git -C "$d" tag); do git -C "$d" tag -d "$t" >/dev/null; done; }

# prerelease 태그는 후보에서 제외한다. git 기본 versionsort 는 rc 를 정식
# 릴리즈보다 크게 정렬하므로, 제외하지 않으면 rc 가 기준이 된다.
git -C "$d" tag v1.9.0-rc1
assert_json_eq "prerelease 태그는 무시되고 정식 태그가 기준" \
  "$(cd "$d" && bash "$S" '["fix"]' 2>/dev/null)" \
  '{"previous":"v1.7.0","next":"v1.7.1","bump":"patch"}'

# core 가 더 높은 버려진 rc 도 릴리즈 라인을 가로채지 못한다.
# (제외하지 않으면 v1.7.0 다음이 v2.0.1 로 튀어 v1.x 계열을 건너뛴다.)
git -C "$d" tag v2.0.0-rc1
assert_json_eq "core 가 더 높은 rc 도 라인을 가로채지 못한다" \
  "$(cd "$d" && bash "$S" '["fix"]' 2>/dev/null | jq -c '.next')" '"v1.7.1"'

# 숫자로 파싱되지 않는 태그도 제외한다. 포함하면 next 가 previous 보다 낮아진다.
git -C "$d" tag v1x
assert_json_eq "v1x 같은 태그는 후보에서 제외" \
  "$(cd "$d" && bash "$S" '["fix"]' 2>/dev/null | jq -c '.previous')" '"v1.7.0"'

# 4자리 태그도 이 시스템이 만드는 형태가 아니므로 제외한다.
git -C "$d" tag v1.2.3.4
assert_json_eq "v1.2.3.4 는 후보에서 제외" \
  "$(cd "$d" && bash "$S" '["fix"]' 2>/dev/null | jq -c '.previous')" '"v1.7.0"'

# 도달 불가한 태그(다른 브랜치)는 제외한다.
clear_tags
git -C "$d" tag v1.7.0
git -C "$d" checkout -q -b other
echo z > "$d/z"; git -C "$d" add -A; git -C "$d" commit -q -m other
git -C "$d" tag v9.9.9
git -C "$d" checkout -q main
assert_json_eq "도달 불가한 태그는 무시된다" \
  "$(cd "$d" && bash "$S" '["fix"]' 2>/dev/null | jq -c '.previous')" '"v1.7.0"'

# --- 입력 검증 ---
assert_fail "labels 누락 시 실패" bash "$S"
assert_fail "labels 가 null 이면 die"          bash "$S" 'null'
assert_fail "labels 가 문자열이면 die"          bash "$S" '"notanarray"'
assert_fail "labels 가 잘린 JSON 이면 die"      bash "$S" '["breaking"'
assert_fail "override 가 명시적 빈 문자열이면 die" bash "$S" '["fix"]' ''
assert_fail "override 대소문자 틀리면 die"       bash "$S" '["fix"]' 'Patch'

# --- 8진수 함정 회귀 테스트 ---
clear_tags
git -C "$d" tag v1.09.0
assert_json_eq "선행 0 이 든 태그도 산술 가능 (8진수 오해 없이)" \
  "$(cd "$d" && bash "$S" '["feature"]' 2>/dev/null)" \
  '{"previous":"v1.09.0","next":"v1.10.0","bump":"minor"}'

# 누출 검사는 **minor bump** 로 해야 한다. patch bump 는 PATCH(="0") 만 만지고
# 선행 0 이 든 MINOR(="09") 를 건드리지 않아, dec() 가 없어도 통과한다
# (실제로 그렇게 위약이었던 것을 리뷰가 잡았다).
err="$(cd "$d" && bash "$S" '["feature"]' 2>&1 >/dev/null || true)"
case "$err" in
  *'value too great for base'*) _fail "선행 0 태그 minor bump 에서 8진수 원시 에러 누출" ;;
  *)                            _pass "선행 0 태그 minor bump 에서 원시 에러 누출 없음" ;;
esac

# 자릿수가 빠진 태그도 죽지 않는다.
clear_tags
git -C "$d" tag v2
assert_json_eq "v2 처럼 자릿수가 빠진 태그" \
  "$(cd "$d" && bash "$S" '["fix"]' 2>/dev/null)" \
  '{"previous":"v2","next":"v2.0.1","bump":"patch"}'
