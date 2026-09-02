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

# --- migration_glob=none : 마이그레이션이 없는 repo(프론트엔드 등)의 명시 옵트아웃 ---
# 필수 input 으로 둔 이유는 "있는데 없다고 조용히 보고"를 막기 위해서다. 그러면
# 진짜로 없는 repo 는 그 사실을 **명시**할 수 있어야 한다. 빈 값(=설정 누락)과
# `none`(=없다고 선언함)은 다르게 다룬다.
out="$(cd "$d" && bash "$S" "$BASE" "$HEAD_SHA" none 'apps/*/src/**/*.controller.ts' '**/*.spec.ts' 2>/dev/null)"
assert_json_eq "migration_glob=none → 마이그레이션 없음 (V*.sql 이 범위에 있어도)" \
  "$(printf '%s' "$out" | jq '.migrations')" '[]'
assert_json_eq "none 이어도 API 표면 감지는 그대로 동작한다" \
  "$(printf '%s' "$out" | jq '{api_touched, api_files}')" \
  '{"api_touched":true,"api_files":["user.controller.ts"]}'

out="$(cd "$d" && bash "$S" "$BASE" "$HEAD_SHA" '  NONE  ' 2>/dev/null)"
assert_json_eq "none 은 대소문자·앞뒤 공백을 가리지 않는다" \
  "$(printf '%s' "$out" | jq '.migrations')" '[]'

# 부하검증: `none` 이 pathspec 으로 흘러 우연히 0건이 되는 것이 아니라
# **센티널로 처리**됨을 증명한다. `none` 이라는 이름의 파일을 실제로 추가하면
# pathspec 해석에서는 1건이 잡히지만, 센티널 처리에서는 여전히 0건이어야 한다.
d2="$(mktemp -d)"
git -C "$d2" init -q -b main
git -C "$d2" config user.email t@t.io; git -C "$d2" config user.name t
echo base > "$d2/README"; git -C "$d2" add -A; git -C "$d2" commit -q -m base
B2="$(git -C "$d2" rev-parse HEAD)"
echo x > "$d2/none"; git -C "$d2" add -A; git -C "$d2" commit -q -m add-none
H2="$(git -C "$d2" rev-parse HEAD)"
assert_json_eq "증명: 'none' 이름의 파일이 추가돼도 센티널은 0건을 낸다 (pathspec 이 아님)" \
  "$(cd "$d2" && bash "$S" "$B2" "$H2" none 2>/dev/null | jq '.migrations')" '[]'
assert_json_eq "증명 전제: 같은 파일이 일반 glob 으로는 1건으로 잡힌다" \
  "$(cd "$d2" && bash "$S" "$B2" "$H2" 'non?' 2>/dev/null | jq '.migrations')" '["none"]'

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

# --- 항목 6: --diff-filter=A 는 "추가된" 마이그레이션만 잡아야 한다 ---
# 스펙 §4.2: "추가된 마이그레이션만 (A). 수정은 릴리즈 노트에 무의미하다."
# ACMR 로 바꿔도 스위트가 green 이었다(기존 픽스처는 추가와 수정을 같은
# 범위/커밋에 함께 넣지 않았다). 마이그레이션을 한 커밋에서 추가하고 **다음
# 커밋에서 수정**한 뒤, 수정만 포함하는 범위(BASE=추가 커밋, HEAD=수정 커밋)
# 로 호출하면 migrations 는 빈 배열이어야 한다 — 이 범위에서 그 파일의 diff
# 상태는 M(수정) 뿐이고 A(추가)가 아니다.
ADD_SHA="$(git -C "$d" rev-parse HEAD)"
echo "-- v1 변경" >> "$d/src/main/resources/db/migration/V33__excursion_history.sql"
git -C "$d" add -A; git -C "$d" commit -q -m "modify migration"
MOD_SHA="$(git -C "$d" rev-parse HEAD)"

out="$(cd "$d" && bash "$S" "$ADD_SHA" "$MOD_SHA" 'src/main/resources/db/migration/V*.sql' 2>/dev/null)"
assert_json_eq "추가 커밋 이후 수정만 있는 범위는 migrations 가 비어야 한다 (--diff-filter=A)" \
  "$(printf '%s' "$out" | jq '.migrations')" '[]'
