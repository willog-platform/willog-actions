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

# --- 항목 8: image_count 도 HTML 주석을 걷어내야 한다 (summary_section 과 동일) ---
# 코멘트아웃된 이미지는 실제로 보이지 않으므로 "첨부 있음" 으로 잘못 보고되면
# 안 된다. 마크다운 이미지·<img> 태그·맨몸 URL 세 형태 모두 검사한다.
assert_json_eq "주석 안 마크다운 이미지는 image_count 0" \
  "$(one "$(mk '<!-- ![shot](https://github.com/user-attachments/assets/abc) -->')" | jq '.[0].image_count')" '0'
assert_json_eq "주석 안 <img> 태그는 image_count 0" \
  "$(one "$(mk "<!-- $IMG -->")" | jq '.[0].image_count')" '0'
assert_json_eq "주석 밖 이미지와 주석 안 이미지가 섞이면 주석 안만 제외" \
  "$(one "$(mk "$IMG
<!-- $IMG -->")" | jq '.[0].image_count')" '1'

assert_json_eq "제목이 'fix:' 뿐이면 빈 문자열이 아니라 원제목으로 폴백" \
  "$(one '[{"number":1,"title":"fix:","url":"u","author":{"login":"a"},"labels":[],"body":null}]' \
     | jq -c '.[0].summary')" '"fix:"'

assert_json_eq "labels 의 name 이 없거나 null 이어도 문자열 배열 유지" \
  "$(one '[{"number":1,"title":"x","url":"u","author":{"login":"a"},"labels":[{"name":"ok"},{"name":null},{}],"body":null}]' \
     | jq -c '.[0].labels')" '["ok","",""]'

# --- I7: 마크다운 링크는 Slack mrkdwn 링크 문법이 아니다 ---
# `[text](url)` 는 실제 PR 템플릿(templates/pull_request_template.md)의
# Summary 예시 형태다. Slack mrkdwn 은 이 문법을 모르므로 그대로 내보내면
# 대괄호·URL 이 그대로 노출된다. summarize.jq 는 링크 텍스트만 남기고 URL 은
# 버린다 (render-main.jq 의 `esc` 는 나중에 `<`·`>` 를 이스케이프하므로,
# 여기서 <url|text> 형태를 만들면 그 단계에서 다시 깨진다 — 그래서 여기서
# 텍스트만 남기고 끝낸다).
assert_json_eq "마크다운 링크 [text](url) 는 텍스트만 남고 URL 은 버려진다" \
  "$(one '[{"number":1,"title":"x","url":"u","author":{"login":"a"},"labels":[],"body":"## Summary\n- [[Jira](https://willog.atlassian.net/browse/CP-2)] 이탈 히스토리 기록 API 신설\n"}]' \
     | jq '.[0].summary')" '"[Jira] 이탈 히스토리 기록 API 신설"'
assert_json_eq "요약에 마크다운 링크의 URL 문자열이 남지 않는다" \
  "$(one '[{"number":1,"title":"x","url":"u","author":{"login":"a"},"labels":[],"body":"## Summary\n- [[Jira](https://willog.atlassian.net/browse/CP-2)] 이탈 히스토리 기록 API 신설\n"}]' \
     | jq '.[0].summary | test("willog.atlassian.net")')" 'false'

# --- I7: 템플릿의 플레이스홀더 줄은 주석 안에 있어 요약으로 나가지 않는다 ---
TPL="$ROOT/templates/pull_request_template.md"
assert_json_eq "플레이스홀더 예시 줄이 주석 밖에 살아 있지 않다" \
  "$(python3 -c "import re;print(1 if re.search(r'(?m)^-\\s*\\[\\[Jira\\]\\(https://willog\\.atlassian\\.net/browse/TICKET\\)\\]', open('$TPL').read()) else 0)")" '0'
tpl_out="$(python3 -c "
import json
print(json.dumps([{'number':1,'title':'fix: something','url':'u','author':{'login':'a'},'labels':[],'body':open('$TPL').read()}]))
" | jq -f "$J")"
assert_json_eq "빈(플레이스홀더뿐인) 템플릿은 제목 폴백으로 떨어진다" \
  "$(printf '%s' "$tpl_out" | jq '.[0].summary')" '"something"'
assert_json_eq "빈 템플릿 요약에 플레이스홀더 문구가 남지 않는다" \
  "$(printf '%s' "$tpl_out" | jq '.[0].summary | test("여기에 무엇이 달라지는지")')" 'false'
