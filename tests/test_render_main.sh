J="$ROOT/scripts/render-main.jq"

out="$(jq -f "$J" "$ROOT/tests/fixtures/context_prod.json")"

# 구조 계약
assert_json_eq "채널" "$(printf '%s' "$out" | jq '.channel')" '"C0RELEASE"'
assert_json_eq "색상 초록" "$(printf '%s' "$out" | jq '.attachments[0].color')" '"#36a64f"'
assert_json_eq "요약 항목 2개" \
  "$(printf '%s' "$out" | jq '[.attachments[0].blocks[] | select(.type=="section") | .text.text? // empty | select(test("•"))] | length')" '1'
assert_json_eq "경고 줄 존재" \
  "$(printf '%s' "$out" | jq '[.attachments[0].blocks[] | .text?.text? // empty | select(test("마이그레이션 2건"))] | length')" '1'
assert_json_eq "API 문안은 확인 필요" \
  "$(printf '%s' "$out" | jq '[.attachments[0].blocks[] | .text?.text? // empty | select(test("API 표면 변경 \\(확인 필요\\)"))] | length')" '1'
assert_json_eq "멘션 포함" \
  "$(printf '%s' "$out" | jq '[.attachments[0].blocks[] | .text?.text? // empty | select(test("<!here>"))] | length | . > 0')" 'true'

# 인젝션 회귀: 따옴표가 살아남고 페이로드는 유효 JSON
assert_json_eq "따옴표 보존" \
  "$(printf '%s' "$out" | jq '[.. | strings | select(test("NPE .경계. 수정"))] | length | . > 0')" 'true'

# 최소 케이스: 경고 줄과 멘션이 없고, PR 0건이어도 유효
min="$(jq -f "$J" "$ROOT/tests/fixtures/context_minimal.json")"
# `⚠️` 는 경고 줄에만 쓰이므로 이것이 경고 줄 부재의 정확한 검사다.
# ("마이그레이션" 문자열 검사는 필드 라벨까지 잡아 부정확했다.)
assert_json_eq "변경 없으면 ⚠️ 경고 줄 자체가 없다" \
  "$(printf '%s' "$min" | jq '[.. | strings | select(test("⚠️"))] | length')" '0'
assert_json_eq "변경 없어도 마이그레이션 필드는 '없음' 으로 자리를 지킨다" \
  "$(printf '%s' "$min" | jq -c '[.attachments[0].blocks[] | .fields? // [] | .[] | .text | select(test("마이그레이션"))]')" \
  '["*🗄️  마이그레이션*\n없음"]'
assert_json_eq "필드는 항상 6개 (2열 3행 고정)" \
  "$(printf '%s' "$min" | jq '[.attachments[0].blocks[] | .fields? // empty] | add | length')" '6'
assert_json_eq "멘션 없음" \
  "$(printf '%s' "$min" | jq '[.. | strings | select(test("<!here>"))] | length')" '0'
assert_json_eq "최소 케이스도 유효 JSON" "$(printf '%s' "$min" | jq 'has("channel")')" 'true'

# 아주 긴 요약이 Slack block 상한을 넘기지 않는다.
# (넘기면 chat.postMessage 가 invalid_blocks 로 거부해 알림이 아예 안 간다.)
long="$(jq -n --arg s "$(printf 'x%.0s' $(seq 1 500))" \
  '{service_name:"s",environment:"prod",env_label:"Production",repo:"o/r",run_id:"1",
    actor:"a",deploy_status:"success",image_tag:"t",apps:"api",argocd_url:"https://a",
    channel:"C1",mention:"",
    range:{base:"a",head:"b",commits:1,truncated:false},
    version:{previous:null,next:"v1.0.0",bump:"initial"},
    prs:[{number:1,title:"t",summary:$s,author:"a",labels:[],url:"u",image_count:0}],
    changes:{migrations:[],api_touched:false,api_files:[]}}' | jq -f "$J")"
assert_json_eq "긴 요약은 잘린다" \
  "$(printf '%s' "$long" | jq '[.attachments[0].blocks[] | .text?.text? // empty | select(test("xxx"))] | map(length) | max | . < 400')" 'true'
assert_json_eq "모든 section text 가 3000자 이하" \
  "$(printf '%s' "$long" | jq '[.. | objects | select(.type=="mrkdwn") | .text | length] | max | . <= 3000')" 'true'

# Node 스타일 마이그레이션 파일명도 다듬어진다.
node="$(jq '.changes.migrations = ["Migration20250101120000.ts","V33__a.sql"]' \
  "$ROOT/tests/fixtures/context_prod.json" | jq -f "$J")"
assert_json_eq "Flyway 와 Node 파일명 모두 다듬어진다" \
  "$(printf '%s' "$node" | jq -c '[.attachments[0].blocks[] | .fields? // [] | .[] | .text | select(test("마이그레이션"))] | .[0]')" \
  '"*🗄️  마이그레이션*\nMigration20250101120000 · V33"'

# --- Slack mrkdwn 주입 방어 ---
# PR 제목·요약에 `<!channel>` 을 넣으면 Slack 이 실제 채널 전체 핑으로 해석한다
# (이 파일이 의도적 `<!here>` 를 넣는 것과 같은 기제). 스펙 §3.1은 `<!channel>` 을
# 쓰지 않기로 정했으므로, PR 텍스트로 그것을 주입하는 경로를 막아야 한다.
inj="$(jq '.prs[0].summary = "<!channel> <@U123456> 긴급 <https://evil|링크> & 앰퍼샌드"' \
  "$ROOT/tests/fixtures/context_prod.json" | jq -f "$J")"
assert_json_eq "요약의 <!channel> 은 이스케이프된다" \
  "$(printf '%s' "$inj" | jq '[.. | strings | select(test("&lt;!channel&gt;"))] | length | . > 0')" 'true'
assert_json_eq "이스케이프 후 원본 <!channel> 은 남지 않는다" \
  "$(printf '%s' "$inj" | jq '[.. | strings | select(test("<!channel>"))] | length')" '0'
assert_json_eq "<@U123456> 멘션도 이스케이프된다" \
  "$(printf '%s' "$inj" | jq '[.. | strings | select(test("<@U123456>"))] | length')" '0'
assert_json_eq "앰퍼샌드가 이중 이스케이프되지 않는다" \
  "$(printf '%s' "$inj" | jq '[.. | strings | select(test("&amp;amp;"))] | length')" '0'
# 의도적 멘션은 살아 있어야 한다.
assert_json_eq "의도적 <!here> 는 그대로 유지된다" \
  "$(printf '%s' "$inj" | jq '[.. | strings | select(test("<!here>"))] | length | . > 0')" 'true'
# 우리가 조립한 링크는 이스케이프되지 않아야 한다.
assert_json_eq "우리가 만든 <url|text> 링크는 살아 있다" \
  "$(printf '%s' "$inj" | jq '[.. | strings | select(test("\\|Actions>"))] | length | . > 0')" 'true'

# --- 상한 회귀: 실측으로 초과가 확인된 두 필드 ---
# PR 30건 → pr_field 2174자, Node 형식 마이그레이션 30건 → migration_field 2520자.
# 둘 다 2000자 상한을 넘겨 chat.postMessage 가 페이로드 전체를 거부했다.
big="$(jq '.prs = [range(30) | {number:(.+1000), title:"t", summary:"s", author:"a",
                               labels:[], url:("https://github.com/o/r/pull/" + ((.+1000)|tostring)),
                               image_count:0}]
          | .changes.migrations = [range(30) | "Migration2025010112" + (.|tostring)
                                               + "_add_some_reasonably_long_table_name.ts"]' \
  "$ROOT/tests/fixtures/context_prod.json" | jq -f "$J")"
assert_json_eq "PR 30건·마이그레이션 30건에서도 모든 필드가 2000자 이하" \
  "$(printf '%s' "$big" | jq '[.attachments[0].blocks[] | .fields? // empty | .[] | .text | length] | max | . <= 2000')" 'true'
assert_json_eq "모든 section text 도 3000자 이하" \
  "$(printf '%s' "$big" | jq '[.. | objects | select(.type=="mrkdwn") | .text | length] | max | . <= 3000')" 'true'
assert_json_eq "PR 필드는 12건까지 보이고 접힌다" \
  "$(printf '%s' "$big" | jq '[.attachments[0].blocks[] | .fields? // [] | .[] | .text | select(test("포함 PR"))] | .[0] | test("그 외 18건")')" 'true'
assert_json_eq "마이그레이션 필드는 10건까지 보이고 접힌다" \
  "$(printf '%s' "$big" | jq '[.attachments[0].blocks[] | .fields? // [] | .[] | .text | select(test("마이그레이션"))] | .[0] | test("그 외 20건")')" 'true'

# mention 키가 아예 없어도 군더더기 공백이 붙지 않는다.
nom="$(jq 'del(.mention)' "$ROOT/tests/fixtures/context_prod.json" | jq -f "$J")"
assert_json_eq "mention 키 부재 시 선행 공백 없음" \
  "$(printf '%s' "$nom" | jq '.attachments[0].blocks[0].text.text | test("^🚀")')" 'true'

# --- 빈 argocd_url 은 끊긴 링크를 만들지 않는다 ---
# 예전 워크플로는 시크릿 누락 시 `https:///applications/...` 를 내보냈고
# 그것이 그대로 Slack 에 끊긴 링크로 노출됐다.
noargo="$(jq '.argocd_url = ""' "$ROOT/tests/fixtures/context_prod.json" | jq -f "$J")"
assert_json_eq "빈 argocd_url 은 링크 없는 평문으로" \
  "$(printf '%s' "$noargo" | jq '[.attachments[0].blocks[] | .fields? // [] | .[] | .text | select(test("링크"))] | .[0] | test("ArgoCD\\(링크 없음\\)")')" 'true'
assert_json_eq "빈 argocd_url 에서 깨진 mrkdwn 링크가 생기지 않는다" \
  "$(printf '%s' "$noargo" | jq '[.. | strings | select(test("<\\|ArgoCD>|https:///"))] | length')" '0'
assert_json_eq "Actions 링크는 그대로 유지된다" \
  "$(printf '%s' "$noargo" | jq '[.. | strings | select(test("\\|Actions>"))] | length | . > 0')" 'true'

# 골든 회귀
assert_json_eq "prod 골든" "$out" "$(cat "$ROOT/tests/golden/payload_prod.json")"
assert_json_eq "minimal 골든" "$min" "$(cat "$ROOT/tests/golden/payload_minimal.json")"
