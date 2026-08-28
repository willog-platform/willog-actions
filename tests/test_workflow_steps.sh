WF="$ROOT/.github/workflows/deploy-notify.yml"

# extract_step <스텝 이름> — 해당 스텝의 run: 본문을 stdout 으로 낸다.
extract_step() {
  python3 - "$1" "$WF" <<'PY'
import re, sys, pathlib, textwrap
name, path = sys.argv[1], sys.argv[2]
y = pathlib.Path(path).read_text()
# 스텝 경계는 같은 들여쓰기의 `- name:` 이다.
for st in re.split(r'\n(?=      - name: )', y):
    if st.lstrip().startswith('- name: ' + name):
        m = re.search(r'\n\s+run: \|\n(.*)$', st, re.S)
        if m:
            sys.stdout.write(textwrap.dedent(m.group(1)))
            sys.exit(0)
sys.exit('step not found: ' + name)
PY
}

# run_step <스텝 이름> — GITHUB_OUTPUT 을 임시파일로 두고 실행한다.
#   stdout: GITHUB_OUTPUT 내용,  stderr: 스텝의 로그(경고 등)
run_step() {
  local name="$1"; shift
  local body out
  body="$(mktemp)"; out="$(mktemp)"
  extract_step "$name" > "$body"
  GITHUB_OUTPUT="$out" bash "$body" >&2
  cat "$out"
  rm -f "$body" "$out"
}

# --- Resolve ArgoCD URL ---
o="$(ENVIRONMENT=prod SERVICE=svc SRV_DEV= SRV_STAGE= SRV_PROD=argocd.example      run_step "Resolve ArgoCD URL" 2>/dev/null)"
assert_json_eq "시크릿 있으면 URL 을 만든다" \
  "$(printf '%s' "$o" | grep -c '^url=https://argocd.example/' | jq -R 'tonumber')" '1'

o="$(ENVIRONMENT=prod SERVICE=svc SRV_DEV= SRV_STAGE= SRV_PROD=      run_step "Resolve ArgoCD URL" 2>/dev/null)"
assert_json_eq "시크릿 없으면 url 이 빈 값이다" \
  "$(printf '%s' "$o" | jq -Rsc 'split("\n") | map(select(startswith("url=")))')" '["url="]'
assert_json_eq "그때 https:/// 같은 반쪽 URL 을 내보내지 않는다" \
  "$(printf '%s' "$o" | grep -c 'https:///' | jq -R 'tonumber')" '0'

e="$(ENVIRONMENT=prod SERVICE=svc SRV_DEV= SRV_STAGE= SRV_PROD=      run_step "Resolve ArgoCD URL" 2>&1 >/dev/null)"
case "$e" in
  *'::warning::'*) _pass "시크릿 없으면 ::warning:: 으로 알린다" ;;
  *)               _fail "시크릿 없으면 ::warning:: 으로 알린다" ;;
esac

o="$(ENVIRONMENT=typo SERVICE=svc SRV_DEV=a SRV_STAGE=b SRV_PROD=c      run_step "Resolve ArgoCD URL" 2>/dev/null)"
assert_json_eq "environment 오타에서도 빈 url" \
  "$(printf '%s' "$o" | jq -Rsc 'split("\n") | map(select(startswith("url=")))')" '["url="]'

# 워크플로 커맨드 주입 방어: 개행이 든 environment 로 가짜 명령을 심을 수 없다.
# 검사 기준은 **줄 시작**이다. Actions 러너는 stdout 을 줄 단위로 훑어 줄
# **맨 앞**의 `::command::` 만 해석하므로, 개행이 제거된 뒤 같은 줄 안에
# 문자열로 남는 `::error::...` 는 무해하다. 부분문자열 검사는 그 무해한
# 경우까지 실패로 잡는다 — 검사 대상이 아니라 검사 기준이 틀린 것이다.
e="$(ENVIRONMENT="$(printf 'x\n::error::INJECTED')" SERVICE=svc SRV_DEV= SRV_STAGE= SRV_PROD= \
     run_step "Resolve ArgoCD URL" 2>&1 >/dev/null)"
if printf '%s\n' "$e" | grep -q '^::error::'; then
  _fail "개행이 든 environment 로 워크플로 커맨드를 주입할 수 있다"
else
  _pass "개행이 든 environment 로 워크플로 커맨드를 주입할 수 없다"
fi
# 개행이 살아 있으면 로그가 여러 줄로 쪼개진다. 줄 수 자체를 못 박는다.
assert_json_eq "경고가 여러 줄로 쪼개지지 않는다" \
  "$(printf '%s\n' "$e" | grep -c '^::' | jq -R 'tonumber')" '1'

# --- Choose channel : 진리표 핵심 셀 ---
ch() {
  PHASE="$1" STATUS="$2" ENVIRONMENT="$3" DEV_CH=Cdev REL_CH="$4" \
    run_step "Choose channel" 2>/dev/null | tr '\n' ' '
}
assert_json_eq "prod+result+success → 릴리즈 채널" \
  "$(ch result success prod Crel | jq -Rc .)" '"release=true id=Crel "'
assert_json_eq "stage+result+success → 릴리즈 채널" \
  "$(ch result success stage Crel | jq -Rc .)" '"release=true id=Crel "'
assert_json_eq "dev+result+success → dev 채널·간소" \
  "$(ch result success dev Crel | jq -Rc .)" '"release=false id=Cdev "'
assert_json_eq "prod+result+failure → dev 채널·간소" \
  "$(ch result failure prod Crel | jq -Rc .)" '"release=false id=Cdev "'
assert_json_eq "prod+start → dev 채널·간소" \
  "$(ch start success prod Crel | jq -Rc .)" '"release=false id=Cdev "'
assert_json_eq "릴리즈 채널 미지정 → 형식은 유지, 채널만 dev" \
  "$(ch result success prod '' | jq -Rc .)" '"release=true id=Cdev "'

e="$(PHASE=result STATUS=success ENVIRONMENT=prod DEV_CH=Cdev REL_CH= \
     run_step "Choose channel" 2>&1 >/dev/null)"
case "$e" in
  *'::warning::'*) _pass "릴리즈 채널 미지정은 ::warning:: 으로 알린다" ;;
  *)               _fail "릴리즈 채널 미지정은 ::warning:: 으로 알린다" ;;
esac
e="$(PHASE=result STATUS=success ENVIRONMENT=prod DEV_CH=Cdev REL_CH=Crel \
     run_step "Choose channel" 2>&1 >/dev/null)"
case "$e" in
  *'::warning::'*) _fail "릴리즈 채널이 지정됐는데 경고가 났다 (경고 피로)" ;;
  *)               _pass "릴리즈 채널 지정 시에는 경고가 없다" ;;
esac
