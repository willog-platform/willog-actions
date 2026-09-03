TJ="$ROOT/scripts/render-thread.jq"
SJ="$ROOT/scripts/render-simple.jq"
CTX="$ROOT/tests/fixtures/context_prod.json"

th="$(jq -f "$TJ" --arg thread_ts "1724800000.000100" "$CTX")"
assert_json_eq "thread_ts 전달" "$(printf '%s' "$th" | jq '.thread_ts')" '"1724800000.000100"'
assert_json_eq "PR 상세에 라벨 포함" \
  "$(printf '%s' "$th" | jq '.text | test("\\[feature\\]")')" 'true'
assert_json_eq "마이그레이션 파일명 전체" \
  "$(printf '%s' "$th" | jq '.text | test("V33__excursion_history.sql")')" 'true'
assert_json_eq "커밋 범위 표기" \
  "$(printf '%s' "$th" | jq '.text | test("a1b2c3d\\.\\.6185be5")')" 'true'
assert_json_eq "따옴표 보존" \
  "$(printf '%s' "$th" | jq '.text | test("NPE .경계. 수정")')" 'true'

# 간소 형식: start
st="$(jq -f "$SJ" --arg phase start "$CTX")"
assert_json_eq "start 색상" "$(printf '%s' "$st" | jq '.attachments[0].color')" '"#1e90ff"'
assert_json_eq "start 문안" "$(printf '%s' "$st" | jq '.attachments[0].fallback | test("배포 시작")')" 'true'

# --- 헤드라인은 한 메시지에 한 번만 보인다 ---
# 최상단 `text` 와 카드 첫 블록이 같은 헤드라인을 담아 "배포 시작" 이 두 줄로
# 보인다는 제보(2026-09-03 #cicd)의 회귀 방어. 미리보기 문안은 `fallback` 이
# 담당하므로 그쪽에는 남아 있어야 한다.
assert_json_eq "간소 형식에 최상단 text 가 없다" \
  "$(printf '%s' "$st" | jq 'has("text")')" 'false'
assert_json_eq "간소 형식의 렌더 텍스트에 헤드라인이 한 번만 나온다" \
  "$(printf '%s' "$st" | jq '[.attachments[0].blocks | .. | objects | select(.type == "mrkdwn") | .text | select(test("배포 시작"))] | length')" '1'
assert_json_eq "간소 형식의 fallback 은 미리보기 문안을 유지한다" \
  "$(printf '%s' "$st" | jq '.attachments[0].fallback | test("배포 시작 \\[rule-engine\\] Production")')" 'true'

# 간소 형식: failure
fl="$(jq '.deploy_status="failure"' "$CTX" | jq -f "$SJ" --arg phase result)"
assert_json_eq "failure 색상" "$(printf '%s' "$fl" | jq '.attachments[0].color')" '"#dc3545"'

# --- 간소 형식: cancelled (4개 미결 항목 중 하나) ---
# argocd-sync 는 660s 타임아웃을 가지고, 취소는 실패와 구별되는 실제 상태다.
# 현행은 success 가 아닌 모든 것을 ❌ 배포 실패로 뭉뚱그렸다.
cl="$(jq '.deploy_status="cancelled"' "$CTX" | jq -f "$SJ" --arg phase result)"
assert_json_eq "cancelled 색상은 중립(회색)" \
  "$(printf '%s' "$cl" | jq '.attachments[0].color')" '"#808080"'
assert_json_eq "cancelled 헤드라인은 배포 취소" \
  "$(printf '%s' "$cl" | jq '.attachments[0].fallback | test("배포 취소")')" 'true'
assert_json_eq "cancelled 헤드라인에 실패 문구가 없다" \
  "$(printf '%s' "$cl" | jq '.attachments[0].fallback | test("배포 실패")')" 'false'
assert_json_eq "cancelled 푸터는 취소를 실패와 구분해 알린다" \
  "$(printf '%s' "$cl" | jq '[.. | strings | select(test("취소"))] | length | . > 0')" 'true'
assert_json_eq "cancelled 푸터에 오류 발생 문구가 없다" \
  "$(printf '%s' "$cl" | jq '[.. | strings | select(test("오류가 발생했습니다"))] | length')" '0'

# failure/빈 값/알 수 없는 값은 여전히 빨간 실패 분기로 떨어진다.
for bad in failure '' typo_unknown_status; do
  bd="$(jq --arg s "$bad" '.deploy_status=$s' "$CTX" | jq -f "$SJ" --arg phase result)"
  assert_json_eq "deploy_status='${bad}' 는 여전히 실패(빨강) 분기" \
    "$(printf '%s' "$bd" | jq '.attachments[0].color')" '"#dc3545"'
  assert_json_eq "deploy_status='${bad}' 는 배포 실패 헤드라인" \
    "$(printf '%s' "$bd" | jq '.attachments[0].fallback | test("배포 실패")')" 'true'
done

# --- esc 정의가 세 렌더러에서 동일한지 검사 ---
# 이스케이프 함수를 세 파일에 복제했으므로, 하나만 고치고 나머지를 잊는 것이
# 이 설계의 유일한 실패 모드다. 정의 줄이 동일한지 기계적으로 확인한다.
espec="$(grep -h '^def esc:' "$ROOT/scripts/render-main.jq" \
         "$ROOT/scripts/render-thread.jq" "$ROOT/scripts/render-simple.jq" | sort -u | wc -l | tr -d ' ')"
assert_json_eq "세 렌더러의 esc 정의가 동일하다" "$espec" '1'
assert_json_eq "esc 정의가 세 파일에 모두 있다" \
  "$(grep -l '^def esc:' "$ROOT/scripts/render-main.jq" "$ROOT/scripts/render-thread.jq" "$ROOT/scripts/render-simple.jq" | wc -l | tr -d ' ')" '3'

# --- 주입 방어: 스레드 ---
# 스레드 답글은 PR **제목**과 작성자·라벨까지 싣는다. 본체가 싣지 않는
# 필드들이므로 여기서 따로 막아야 한다.
inj="$(jq '.prs[0].title = "<!channel> 긴급"
           | .prs[0].author = "<@U123>"
           | .prs[0].labels = ["<!here>"]
           | .changes.migrations = ["<!everyone>.sql"]' \
  "$CTX" | jq -f "$TJ" --arg thread_ts "1.1")"
assert_json_eq "스레드의 PR 제목 <!channel> 이 이스케이프된다" \
  "$(printf '%s' "$inj" | jq '.text | test("&lt;!channel&gt;")')" 'true'
assert_json_eq "스레드에 원본 제어열이 남지 않는다" \
  "$(printf '%s' "$inj" | jq '.text | test("<!channel>|<@U123>|<!here>|<!everyone>")')" 'false'
assert_json_eq "스레드의 우리 PR 링크는 살아 있다" \
  "$(printf '%s' "$inj" | jq '.text | test("\\|#95>")')" 'true'

# --- 주입 방어: 간소 ---
inj2="$(jq '.actor = "<!channel>evil" | .apps = "<@U9>" | .image_tag = "<!here>"' \
  "$CTX" | jq -f "$SJ" --arg phase start)"
# mrkdwn 으로 파싱되는 텍스트(`{type:"mrkdwn", text:...}`)에만 원본 제어열이
# 없어야 한다. `image_url`/`alt_text` 는 mrkdwn 이 아니므로(위 render-simple.jq
# 주석 참고) 검사 범위에서 의도적으로 제외한다 — render-main.jq 와 동일 취급.
assert_json_eq "간소 형식의 mrkdwn 텍스트에 원본 제어열이 남지 않는다" \
  "$(printf '%s' "$inj2" | jq '[.. | objects | select(.type == "mrkdwn") | .text | select(test("<!channel>|<@U9>|<!here>"))] | length')" '0'
assert_json_eq "간소 형식의 image_url/alt_text 는 mrkdwn 이 아니므로 원본 값을 보존한다" \
  "$(printf '%s' "$inj2" | jq '(.attachments[0].blocks[] | select(.type=="context") | .elements[0]) as $img
     | ($img.image_url | test("<!channel>evil")) and ($img.alt_text == "<!channel>evil")')" 'true'
assert_json_eq "간소 형식의 Actions 링크는 살아 있다" \
  "$(printf '%s' "$inj2" | jq '[.. | strings | select(test("\\|Actions>"))] | length | . > 0')" 'true'

# --- 누락 필드 내구성 ---
assert_json_eq "labels 키 부재에도 스레드가 유효" \
  "$(jq 'del(.prs[0].labels)' "$CTX" | jq -f "$TJ" --arg thread_ts "1.1" | jq 'has("text")')" 'true'
assert_json_eq "api_files 키 부재에도 스레드가 유효" \
  "$(jq 'del(.changes.api_files)' "$CTX" | jq -f "$TJ" --arg thread_ts "1.1" | jq '.text | test("\\*API 표면\\*  없음")')" 'true'
assert_json_eq "image_tag 키 부재에도 간소 형식이 유효" \
  "$(jq 'del(.image_tag)' "$CTX" | jq -f "$SJ" --arg phase start | jq 'has("channel")')" 'true'

# 간소 형식도 빈 argocd_url 에서 끊긴 링크를 만들지 않는다 (render-main 과 동일 규칙).
noargo2="$(jq '.argocd_url = ""' "$CTX" | jq -f "$SJ" --arg phase start)"
assert_json_eq "간소 형식의 빈 argocd_url 은 평문으로" \
  "$(printf '%s' "$noargo2" | jq '[.. | strings | select(test("ArgoCD\\(링크 없음\\)"))] | length | . > 0')" 'true'
assert_json_eq "간소 형식에 깨진 링크가 생기지 않는다" \
  "$(printf '%s' "$noargo2" | jq '[.. | strings | select(test("<\\|ArgoCD>|https:///"))] | length')" '0'

# base == head (같은 커밋 재배포)를 사람이 읽을 수 있게 명시한다.
redep="$(jq '.range.base = "aaa" | .range.head = "aaa"' "$CTX" | jq -f "$SJ" --arg phase result)"
assert_json_eq "같은 커밋 재배포는 '재배포' 로 표기된다" \
  "$(printf '%s' "$redep" | jq '[.. | strings | select(test("재배포 — 새 커밋 없음"))] | length | . > 0')" 'true'
newdep="$(jq '.range.base = "aaa" | .range.head = "bbb"' "$CTX" | jq -f "$SJ" --arg phase result)"
assert_json_eq "다른 커밋이면 재배포 표기가 없다" \
  "$(printf '%s' "$newdep" | jq '[.. | strings | select(test("재배포"))] | length')" '0'

# --- 빈 image_tag 는 빈 코드스팬이 아니라 '-' 로 (I1, render-thread.jq) ---
noimg_th="$(jq '.image_tag = ""' "$CTX" | jq -f "$TJ" --arg thread_ts "1.1")"
assert_json_eq "스레드의 빈 image_tag 는 '-' 로 렌더된다" \
  "$(printf '%s' "$noimg_th" | jq '.text | test("이미지 태그\\*  `-`")')" 'true'

assert_json_eq "thread 골든" "$th" "$(cat "$ROOT/tests/golden/payload_thread.json")"
assert_json_eq "simple start 골든" "$st" "$(cat "$ROOT/tests/golden/payload_simple_start.json")"
