out="$(jq -f "$ROOT/scripts/summarize.jq" "$ROOT/tests/fixtures/prs_raw.json")"
assert_json_eq "PR 요약 골든 일치" "$out" "$(cat "$ROOT/tests/golden/prs_summarized.json")"

# 빈 배열 안전
assert_json_eq "빈 입력" "$(printf '[]' | jq -f "$ROOT/scripts/summarize.jq")" '[]'

# fetch-prs.sh: 번호 배열이 비면 gh 호출 없이 빈 배열
S="$ROOT/scripts/fetch-prs.sh"
assert_json_eq "빈 번호 배열" "$(GH=/nonexistent/gh bash "$S" o/r '[]' 2>/dev/null)" '[]'
assert_fail "numbers 누락 시 실패" bash "$S" o/r

# --- fetch-prs.sh 의 실제 핵심 동작: 다중 집계 + 한 건 실패 ---
# 가짜 gh: 인자 중 첫 숫자를 PR 번호로 보고, 2번만 실패시킨다.
FB="$(mktemp -d)/gh"
cat > "$FB" <<'FAKE'
#!/usr/bin/env bash
n=""
for a in "$@"; do case "$a" in ''|*[!0-9]*) ;; *) n="$a"; break ;; esac; done
if [ "$n" = "2" ]; then exit 1; fi
printf '{"number":%s,"title":"t%s","url":"u%s","author":{"login":"a"},"labels":[],"body":null}\n' "$n" "$n" "$n"
FAKE
chmod +x "$FB"

out="$(GH="$FB" bash "$S" o/r '[1,2,3]' 2>/dev/null)"
assert_json_eq "다중 PR 집계는 3건 전부 남는다" \
  "$(printf '%s' "$out" | jq 'length')" '3'
assert_json_eq "조회 실패 PR 은 자리표시자로 남는다 (조용히 빠지지 않는다)" \
  "$(printf '%s' "$out" | jq -c '.[] | select(.number==2) | {number, title, labels}')" \
  '{"number":2,"title":"(PR 조회 실패)","labels":[]}'
err="$(GH="$FB" bash "$S" o/r '[1,2,3]' 2>&1 >/dev/null || true)"
case "$err" in
  *'::warning::'*) _pass "조회 실패는 ::warning:: 으로 알린다" ;;
  *)               _fail "조회 실패는 ::warning:: 으로 알린다" ;;
esac

# --- 픽스처에 없는 프로덕션 형태 (골든 4건이 덮지 못하는 곳) ---
J="$ROOT/scripts/summarize.jq"
one() { printf '%s' "$1" | jq -c -f "$J"; }
mk()  { jq -n --arg b "$1" '[{number:1,title:"x",url:"u",author:{login:"a"},labels:[],body:$b}]'; }

IMG='<img src="https://github.com/user-attachments/assets/abc" width="600">'
assert_json_eq "HTML img 태그 1개 → image_count 1 (이중계상 없음)" \
  "$(one "$(mk "$IMG")" | jq '.[0].image_count')" '1'
assert_json_eq "HTML img 태그 2개 → image_count 2" \
  "$(one "$(mk "$IMG
$IMG")" | jq '.[0].image_count')" '2'

assert_json_eq "제목이 'fix:' 뿐이면 빈 문자열이 아니라 원제목으로 폴백" \
  "$(one '[{"number":1,"title":"fix:","url":"u","author":{"login":"a"},"labels":[],"body":null}]' \
     | jq -c '.[0].summary')" '"fix:"'

assert_json_eq "labels 의 name 이 없거나 null 이어도 문자열 배열 유지" \
  "$(one '[{"number":1,"title":"x","url":"u","author":{"login":"a"},"labels":[{"name":"ok"},{"name":null},{}],"body":null}]' \
     | jq -c '.[0].labels')" '["ok","",""]'
