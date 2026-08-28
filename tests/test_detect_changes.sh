S="$ROOT/scripts/detect-changes.sh"

d="$(mktemp -d)"
git -C "$d" init -q -b main
git -C "$d" config user.email t@t.io; git -C "$d" config user.name t
mkdir -p "$d/src/main/resources/db/migration" "$d/apps/api/src/user" "$d/apps/api/src/test"
echo base > "$d/README"; git -C "$d" add -A; git -C "$d" commit -q -m base
BASE="$(git -C "$d" rev-parse HEAD)"

echo "-- v1" > "$d/src/main/resources/db/migration/V33__excursion_history.sql"
echo "-- v2" > "$d/src/main/resources/db/migration/V34__auto_arrival.sql"
echo "x" > "$d/apps/api/src/user/user.controller.ts"
echo "x" > "$d/apps/api/src/test/user.controller.spec.ts"
git -C "$d" add -A; git -C "$d" commit -q -m change
HEAD_SHA="$(git -C "$d" rev-parse HEAD)"

out="$(cd "$d" && bash "$S" "$BASE" "$HEAD_SHA" \
        'src/main/resources/db/migration/V*.sql' \
        'apps/*/src/**/*.controller.ts' \
        '**/*.spec.ts' 2>/dev/null)"

assert_json_eq "마이그레이션 2건 basename" \
  "$(printf '%s' "$out" | jq '.migrations')" \
  '["V33__excursion_history.sql","V34__auto_arrival.sql"]'
assert_json_eq "API 표면 변경 감지" "$(printf '%s' "$out" | jq '.api_touched')" 'true'
assert_json_eq "spec.ts 는 제외" \
  "$(printf '%s' "$out" | jq '.api_files')" '["user.controller.ts"]'

# api_glob 미지정이면 감지 생략
out="$(cd "$d" && bash "$S" "$BASE" "$HEAD_SHA" 'src/main/resources/db/migration/V*.sql' 2>/dev/null)"
assert_json_eq "api_glob 미지정 → api_touched false" \
  "$(printf '%s' "$out" | jq '{api_touched, api_files}')" '{"api_touched":false,"api_files":[]}'

# 변경 없는 범위
out="$(cd "$d" && bash "$S" "$HEAD_SHA" "$HEAD_SHA" 'src/**/V*.sql' 'apps/**/*.ts' 2>/dev/null)"
assert_json_eq "변경 없음" "$(printf '%s' "$out" | jq '{migrations, api_touched}')" \
  '{"migrations":[],"api_touched":false}'

assert_fail "migration_glob 누락 시 실패" bash "$S" "$BASE" "$HEAD_SHA"

# 변경 없는 범위에서 stdout 뿐 아니라 **종료코드도 0** 이어야 한다.
# 이것이 실운영에서 가장 흔한 경우다.
( cd "$d" && bash "$S" "$HEAD_SHA" "$HEAD_SHA" 'src/**/V*.sql' 'apps/**/*.ts' '**/*.spec.ts' >/dev/null 2>&1 )
if [ $? -eq 0 ]; then _pass "변경 없음에서 종료코드 0"; else _fail "변경 없음에서 종료코드 0"; fi

# glob 이 아무것도 안 잡는 경우도 종료코드 0
( cd "$d" && bash "$S" "$BASE" "$HEAD_SHA" 'nonexistent/**/*.sql' >/dev/null 2>&1 )
if [ $? -eq 0 ]; then _pass "매치 없는 glob 에서 종료코드 0"; else _fail "매치 없는 glob 에서 종료코드 0"; fi

# 같은 파일이 여러 커밋에서 변경돼도 중복 없이 한 번만 나온다
assert_json_eq "basename 중복제거" \
  "$(cd "$d" && bash "$S" "$BASE" "$HEAD_SHA" 'src/main/resources/db/migration/V*.sql' 2>/dev/null | jq '.migrations | length')" '2'

# --- bash 경로전개 회귀 테스트 ---
# `**` 는 git 이 해석해야 한다. bash 가 먼저 전개하면 globstar 없는 bash 3.2 가
# `**` 를 `*` 로 취급해 깊이 1과 깊이 4의 파일이 조용히 누락된다.
# 아래는 그 누락을 정확히 잡는다.
mkdir -p "$d/apps/api/src/a/b/c"
echo x > "$d/apps/api/src/shallow.controller.ts"
echo x > "$d/apps/api/src/a/b/c/deep.controller.ts"
git -C "$d" add -A; git -C "$d" commit -q -m depth
DEEP_HEAD="$(git -C "$d" rev-parse HEAD)"

out="$(cd "$d" && bash "$S" "$BASE" "$DEEP_HEAD" \
        'src/main/resources/db/migration/V*.sql' \
        'apps/*/src/**/*.controller.ts' '**/*.spec.ts' 2>/dev/null)"
assert_json_eq "깊이 1과 깊이 4 컨트롤러 모두 잡힌다 (bash 전개 아님, git glob)" \
  "$(printf '%s' "$out" | jq -c '.api_files')" \
  '["deep.controller.ts","shallow.controller.ts","user.controller.ts"]'

# --- 빈 pathspec 회귀 테스트 ---
# 공백만·쉼표만인 glob 은 조립 결과가 비고, 빈 pathspec 으로 git diff 를
# 부르면 경로 제한이 사라져 전 파일이 매치된다. 그 경로를 막는다.
out="$(cd "$d" && bash "$S" "$BASE" "$HEAD_SHA" \
        'src/main/resources/db/migration/V*.sql' ' ' '**/*.spec.ts' 2>/dev/null)"
assert_json_eq "공백만인 api_path_glob → 감지 건너뜀 (전체 매치 금지)" \
  "$(printf '%s' "$out" | jq -c '{api_touched, api_files}')" \
  '{"api_touched":false,"api_files":[]}'
assert_json_eq "그때도 마이그레이션 감지는 정상" \
  "$(printf '%s' "$out" | jq '.migrations | length')" '2'

out="$(cd "$d" && bash "$S" "$BASE" "$HEAD_SHA" \
        'src/main/resources/db/migration/V*.sql' ',,' 2>/dev/null)"
assert_json_eq "쉼표만인 api_path_glob → 감지 건너뜀" \
  "$(printf '%s' "$out" | jq '.api_touched')" 'false'

err="$(cd "$d" && bash "$S" "$BASE" "$HEAD_SHA" \
        'src/main/resources/db/migration/V*.sql' ' ' 2>&1 >/dev/null || true)"
case "$err" in
  *'::warning::'*) _pass "건너뛸 때 ::warning:: 으로 알린다" ;;
  *)               _fail "건너뛸 때 ::warning:: 으로 알린다" ;;
esac

# migration_glob 은 필수이므로 공백만인 값은 조용히 넘기지 않고 크게 실패한다.
assert_fail "공백만인 migration_glob 은 die" bash "$S" "$BASE" "$HEAD_SHA" '  '
