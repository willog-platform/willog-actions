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

# run_step <스텝 이름> — 실제 러너와 같은 레이아웃에서 실행한다.
#   체크아웃 루트를 임시 디렉토리로 만들고 `.willog-actions` 가 이 repo 를
#   가리키게 한다. 실제 워크플로도 그 경로로 스크립트를 참조한다.
#   stdout: GITHUB_OUTPUT 내용,  stderr: 스텝의 로그
run_step() {
  local name="$1"; shift
  local body out work rc
  body="$(mktemp)"; out="$(mktemp)"; work="$(mktemp -d)"
  ln -s "$ROOT" "$work/.willog-actions"
  extract_step "$name" > "$body"
  ( cd "$work" && GITHUB_OUTPUT="$out" bash "$body" ) >&2
  # 추출된 스텝의 종료코드를 그대로 되돌린다. 정리(`rm -rf`)가 마지막 문장이면
  # 그 종료코드가 함수 반환값을 덮어써 스텝이 실패해도 항상 0으로 보인다 —
  # "본문 실패는 job을 실패시킨다" 같은 성질은 이 값을 보고 판정하므로 필수.
  rc=$?
  cat "$out"
  rm -rf "$body" "$out" "$work"
  return "$rc"
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
  # RANGE_JSON 은 F1(유령 릴리즈 방지) 가드가 추가되며 `Choose channel` 의
  # 필수 env 가 됐다. 이 진리표는 phase/status/environment/채널 조합을
  # 검사하는 것이 목적이므로 commits:1 (비어 있지 않은 범위) 로 고정한다 —
  # commits:0 케이스는 별도 "유령 릴리즈 방지" 어서션이 전담한다.
  PHASE="$1" STATUS="$2" ENVIRONMENT="$3" DEV_CH=Cdev REL_CH="$4" \
    RANGE_JSON='{"base":"a","head":"b","commits":1,"truncated":false}' \
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
     RANGE_JSON='{"base":"a","head":"b","commits":1,"truncated":false}' \
     run_step "Choose channel" 2>&1 >/dev/null)"
case "$e" in
  *'::warning::'*) _pass "릴리즈 채널 미지정은 ::warning:: 으로 알린다" ;;
  *)               _fail "릴리즈 채널 미지정은 ::warning:: 으로 알린다" ;;
esac
e="$(PHASE=result STATUS=success ENVIRONMENT=prod DEV_CH=Cdev REL_CH=Crel \
     RANGE_JSON='{"base":"a","head":"b","commits":1,"truncated":false}' \
     run_step "Choose channel" 2>&1 >/dev/null)"
case "$e" in
  *'::warning::'*) _fail "릴리즈 채널이 지정됐는데 경고가 났다 (경고 피로)" ;;
  *)               _pass "릴리즈 채널 지정 시에는 경고가 없다" ;;
esac

# --- release_envs : 릴리즈 노트 대상 환경을 호출 측이 고른다 ---
# 기본값(stage,prod)은 위 진리표가 담당한다. 여기서는 명시 지정이 판정을 바꾸는지,
# 형식(공백·빈 값)에 얼마나 관대한지 본다.
chr() {
  RELEASE_ENVS="$1" PHASE=result STATUS=success ENVIRONMENT="$2" DEV_CH=Cdev REL_CH=Crel \
    RANGE_JSON='{"base":"a","head":"b","commits":1,"truncated":false}' \
    run_step "Choose channel" 2>/dev/null | tr '\n' ' ' | jq -Rc .
}
assert_json_eq "release_envs=dev,stage,prod → dev 도 릴리즈 채널" \
  "$(chr 'dev,stage,prod' dev)" '"release=true id=Crel "'
assert_json_eq "release_envs=stage,prod (명시) → dev 는 여전히 간소" \
  "$(chr 'stage,prod' dev)" '"release=false id=Cdev "'
assert_json_eq "release_envs=stage → prod 는 릴리즈 노트 대상이 아니다" \
  "$(chr 'stage' prod)" '"release=false id=Cdev "'
assert_json_eq "release_envs 공백 포함 'dev, stage' 도 허용" \
  "$(chr 'dev, stage' dev)" '"release=true id=Crel "'
assert_json_eq "release_envs 빈 값 → 기본값(stage,prod) 으로 동작" \
  "$(chr '' stage)" '"release=true id=Crel "'
assert_json_eq "release_envs 빈 값 → dev 는 간소" \
  "$(chr '' dev)" '"release=false id=Cdev "'
assert_json_eq "release_envs 부분 문자열 'development' 은 dev 와 다르다" \
  "$(chr 'development,stage' dev)" '"release=false id=Cdev "'
# release_envs 에 있어도 phase/status 게이트는 그대로다
assert_json_eq "release_envs=dev 라도 start 는 간소" \
  "$(RELEASE_ENVS=dev PHASE=start STATUS=success ENVIRONMENT=dev DEV_CH=Cdev REL_CH=Crel \
     RANGE_JSON='{"base":"a","head":"b","commits":1,"truncated":false}' \
     run_step "Choose channel" 2>/dev/null | tr '\n' ' ' | jq -Rc .)" '"release=false id=Cdev "'

# --- env: 블록과 run: 본문의 변수 참조가 일치하는가 (정적 검사) ---
# 하네스가 변수를 직접 주입하는 구조상, YAML 의 env: 매핑이 깨져도 런타임
# 테스트는 통과한다. 참조되는데 env: 에 없는 변수를 정적으로 잡아낸다.
missing="$(python3 - "$WF" <<'PY'
import re, sys, pathlib, yaml
wf = yaml.safe_load(pathlib.Path(sys.argv[1]).read_text())
# 러너가 제공하는 변수와 셸 빌트인은 제외한다.
PROVIDED = {
    "GITHUB_OUTPUT", "GITHUB_ENV", "GITHUB_PATH", "GITHUB_STEP_SUMMARY",
    "GITHUB_SHA", "GITHUB_REF", "GITHUB_WORKSPACE", "GITHUB_REPOSITORY",
    "HOME", "PATH", "PWD", "IFS", "RUNNER_TEMP", "RUNNER_OS",
}
bad = []
for job in (wf.get("jobs") or {}).values():
    for st in (job.get("steps") or []):
        run = st.get("run")
        if not run:
            continue
        declared = set((st.get("env") or {}).keys())
        # 본문에서 대입되는 지역 변수도 제외한다. 줄 시작뿐 아니라
        # `case ... in dev) HOST=... ;;` 처럼 case 분기 라벨(`)`) 바로
        # 뒤에서 대입되는 관용구도 지역 변수로 인정한다 — 그렇지 않으면
        # 이 파일의 기존 `Resolve ArgoCD URL`/`Build simple context` 스텝의
        # HOST·LABEL 이 오탐으로 잡힌다.
        local = set(re.findall(r'(?:^|\))\s*([A-Z_][A-Z0-9_]*)=', run, re.M))
        local |= set(re.findall(r'\bfor\s+([A-Za-z_][A-Za-z0-9_]*)\s+in\b', run))
        used = set(re.findall(r'\$\{?([A-Z_][A-Z0-9_]*)\}?', run))
        for v in sorted(used - declared - local - PROVIDED):
            bad.append("%s: %s" % (st.get("name", "?"), v))
print("\n".join(bad))
PY
)"
if [ -z "$missing" ]; then
  _pass "run: 본문이 참조하는 모든 변수가 env: 에 선언되어 있다"
else
  _fail "env: 에 없는 변수를 참조한다 — ${missing}"
fi

# --- ${{ }} 표현식이 실존하는 대상을 가리키는가 (정적 검사) ---
# 키 이름 대조(위 검사)로는 `${{ inputs.enviroment }}` 처럼 **오른쪽**이 틀린
# 경우를 못 잡는다. 그것이 이 검사군을 만든 동기였던 결함이므로 따로 막는다.
badref="$(python3 - "$WF" <<'PY'
import re, sys, pathlib, yaml
wf = yaml.safe_load(pathlib.Path(sys.argv[1]).read_text())
# 주의: YAML 1.1 은 `on` 을 불리언 True 로 읽는다. PyYAML 도 그렇게 한다.
on = wf.get("on") if wf.get("on") is not None else wf.get(True)
wc = (on or {}).get("workflow_call") or {}
inputs  = set((wc.get("inputs")  or {}).keys())
secrets = set((wc.get("secrets") or {}).keys())
jobs = list((wf.get("jobs") or {}).values())
step_ids = {st["id"] for j in jobs for st in (j.get("steps") or []) if st.get("id")}
bad = []
# YAML 로 파싱된 문자열 값만 훑는다 — 원본 텍스트 전체를 훑으면 주석에 적힌
# 예시(가령 이 검사군의 동기가 된 `${{ inputs.y }}` 같은 설명용 오탐 리터럴)까지
# 실제 표현식으로 오인한다. 주석은 파싱 단계에서 이미 사라지므로 이 방법이 아니면
# "실제로 평가되는 표현식"과 "사람이 읽는 설명"을 구분할 수 없다.
def strings(node):
    if isinstance(node, str):
        yield node
    elif isinstance(node, dict):
        for v in node.values():
            yield from strings(v)
    elif isinstance(node, list):
        for v in node:
            yield from strings(v)
for s in strings(wf):
    for expr in re.findall(r'\$\{\{([^}]*)\}\}', s):
        e = expr.strip()
        m = re.match(r'^inputs\.([A-Za-z_][A-Za-z0-9_]*)$', e)
        if m and m.group(1) not in inputs:
            bad.append("없는 input: " + m.group(1)); continue
        m = re.match(r'^secrets\.([A-Za-z_][A-Za-z0-9_]*)$', e)
        if m and m.group(1) not in secrets:
            bad.append("없는 secret: " + m.group(1)); continue
        m = re.match(r'^steps\.([A-Za-z_][A-Za-z0-9_-]*)\.outputs\.', e)
        if m and m.group(1) not in step_ids:
            bad.append("없는 step id: " + m.group(1)); continue
        # github.* 는 이 워크플로가 쓰기로 한 속성만 허용한다. GitHub 컨텍스트
        # 전체를 알 수는 없으므로 화이트리스트가 유일한 정적 방어다. 오타
        # (`github.actorr`)는 Actions 가 조용히 빈 문자열로 만들고, 그 실패는
        # 배포 로그에도 안 남는다.
        GITHUB_OK = {"actor", "repository", "run_id", "token", "job_workflow_sha", "sha", "ref_name"}
        m = re.match(r'^github\.([A-Za-z_][A-Za-z0-9_]*)$', e)
        if m and m.group(1) not in GITHUB_OK:
            bad.append("허용되지 않은 github 속성: " + m.group(1)); continue
        # jobs.X.outputs.Y — X 는 선언된 job, Y 는 그 job 의 output 이어야 한다.
        m = re.match(r'^jobs\.([A-Za-z_][A-Za-z0-9_-]*)\.outputs\.([A-Za-z_][A-Za-z0-9_-]*)$', e)
        if m:
            jid, key = m.group(1), m.group(2)
            jd = (wf.get("jobs") or {}).get(jid)
            if jd is None:
                bad.append("없는 job id: " + jid)
            elif key not in ((jd.get("outputs") or {})):
                bad.append("job %s 에 없는 output: %s" % (jid, key))
            continue
print("\n".join(sorted(set(bad))))
PY
)"
if [ -z "$badref" ]; then
  _pass "모든 \${{ }} 표현식이 실존하는 input·secret·step 을 가리킨다"
else
  _fail "실존하지 않는 대상을 가리키는 표현식 — ${badref}"
fi

# --- gh CLI 가 암묵적으로 소비하는 변수는 이름 대조로 보호되지 않는다 ---
# GH_TOKEN 은 `$GH_TOKEN` 으로 본문에서 참조되지 않고 gh CLI 가 환경에서 읽는다.
# 그래서 위 두 검사 어느 쪽도 이 키의 삭제를 잡지 못한다. 명시적으로 못 박는다.
assert_json_eq "release_ctx 가 GH_TOKEN 을 선언한다 (gh CLI 가 암묵 소비)" \
  "$(python3 - "$WF" <<'PY'
import sys, pathlib, yaml
wf = yaml.safe_load(pathlib.Path(sys.argv[1]).read_text())
for j in (wf.get("jobs") or {}).values():
    for st in (j.get("steps") or []):
        if st.get("id") == "release_ctx":
            print("true" if "GH_TOKEN" in (st.get("env") or {}) else "false"); raise SystemExit
print("false")
PY
)" 'true'

# --- Build release context ---
# migration_glob 이 비었거나 공백뿐이면 **gh 호출 전에** 크게 실패해야 한다.
# `migration_glob` 가드가 gh **호출 전에** 발동하는지 직접 측정한다.
# 에러 문안 부분문자열에 의존하면 문안 변경 시 조용히 가드가 사라진다.
for glob in '' '   '; do
  ghlog="$(mktemp)"; ghdir="$(mktemp -d)"
  printf '#!/usr/bin/env bash\nprintf "called\\n" >> "%s"\nexit 1\n' "$ghlog" > "$ghdir/gh"
  chmod +x "$ghdir/gh"
  e="$(PATH="$ghdir:$PATH" MIGRATION_GLOB="$glob" ENVIRONMENT=prod SERVICE_NAME=svc REPO=o/r RUN_ID=1 \
       ACTOR=a IMAGE_TAG=t APPS=api ARGOCD_URL=https://a CHANNEL=C1 \
       RANGE_JSON='{"base":"a","head":"b","commits":1,"truncated":false}' \
       MAX_COMMITS=100 API_GLOB= API_EXCLUDE= VERSION_BUMP=auto GH_TOKEN=x \
       run_step "Build release context" 2>&1 >/dev/null || true)"
  case "$e" in
    *'::error::'*) _pass "migration_glob='${glob}' 은 ::error:: 로 거부된다" ;;
    *)             _fail "migration_glob='${glob}' 이 거부되지 않았다" ;;
  esac
  assert_json_eq "migration_glob='${glob}' 에서 gh 호출 0회 (실측)" \
    "$(wc -l < "$ghlog" | tr -d ' ' | jq -R 'tonumber')" '0'
  rm -rf "$ghlog" "$ghdir"
done

# --- 항목 7: Build simple context / Send simple notification ---
# 이 두 스텝은 Phase 0 (dev 배포·시작 알림·모든 실패)의 1단계이고, 다른
# run: 본문은 전부 이 파일에서 스텝 레벨로 검증되는데 이 둘만 빠져 있었다.
sc_ctx() {
  SERVICE_NAME=svc ENVIRONMENT=prod REPO=o/r RUN_ID=1 ACTOR=barry \
    DEPLOY_STATUS=success IMAGE_TAG=abc123 APPS=api ARGOCD_URL=https://a CHANNEL=C1 \
    RANGE_JSON='{"base":"a","head":"b","commits":1,"truncated":false}' \
    run_step "Build simple context" 2>/dev/null
}
o="$(sc_ctx)"
# `wc -l` 은 줄바꿈 문자 수를 센다. `$( )` 명령치환은 후행 개행을 지우므로
# `printf '%s\n'` 로 하나 되돌려 붙여야 "내용이 있는 한 줄" 이 0으로
# 잘못 세지 않는다.
assert_json_eq "Build simple context 의 \$GITHUB_OUTPUT 은 정확히 한 줄" \
  "$(printf '%s\n' "$o" | wc -l | tr -d ' ')" '1'
assert_json_eq "출력이 json= 접두사로 시작한다" \
  "$(printf '%s' "$o" | cut -c1-5 | jq -Rc .)" '"json="'
CTXJSON="${o#json=}"
assert_json_eq "environment prod → env_label Production" \
  "$(printf '%s' "$CTXJSON" | jq '.env_label')" '"Production"'
assert_json_eq "channel·range·image_tag 가 그대로 전달된다" \
  "$(printf '%s' "$CTXJSON" | jq -c '{channel, image_tag, range}')" \
  '{"channel":"C1","image_tag":"abc123","range":{"base":"a","head":"b","commits":1,"truncated":false}}'

# **보안 동기 불변식 (변이에서 살아남음):** `simple_ctx` 의 `jq -n` 에서 `-c`
# 를 지워도 스위트가 green 이었다 — 주석은 이것이 출력 인젝션 방어에
# "필수" 라고 못 박는데, 그 성질을 지키는 회귀 테스트가 없었다. `-c` 가
# 없으면 jq 가 여러 줄로 예쁘게 출력하고, 그 여러 줄 값이 그대로
# `$GITHUB_OUTPUT` 에 `json=...` 으로 쓰이면 GitHub 의 줄 단위 파서가 깨져
# 임의의 output 이 주입될 수 있다. "정확히 한 줄" 어서션(위)이 이 불변식을
# 직접 지킨다 — `-c` 가 사라지면 이 어서션이 깨진다(아래에서 실측 증명).

# --- Send simple notification ---
fake_curl_once() {
  local resp="$1" dir
  dir="$(mktemp -d)"
  { printf '#!/usr/bin/env bash\n'
    printf 'printf %%s %s\n' "'$resp'"
  } > "$dir/curl"
  chmod +x "$dir/curl"
  printf '%s' "$dir"
}
SIMPLE_CTX='{"channel":"C1","service_name":"svc","environment":"dev","env_label":"Development","repo":"o/r","run_id":"1","actor":"barry","deploy_status":"","image_tag":"","apps":"api","argocd_url":"https://a","range":{"base":"a","head":"b","commits":1,"truncated":false}}'
send_simple_with() {
  local d; d="$(fake_curl_once "$1")"
  PATH="$d:$PATH" TOKEN=x PHASE=start CTX="$SIMPLE_CTX" run_step "Send simple notification" 2>/dev/null
  rm -rf "$d"
}
send_simple_rc() {
  local d; d="$(fake_curl_once "$1")"
  ( PATH="$d:$PATH" TOKEN=x PHASE=start CTX="$SIMPLE_CTX" run_step "Send simple notification" >/dev/null 2>&1 )
  local rc=$?; rm -rf "$d"; return $rc
}
o="$(send_simple_with '{"ok":true,"ts":"1.1"}')"
assert_json_eq "성공 시 sent=true 가 출력된다" \
  "$(printf '%s' "$o" | jq -Rsc 'split("\n") | map(select(startswith("sent=")))')" '["sent=true"]'
if send_simple_rc '{"ok":false,"error":"channel_not_found"}'; then
  _fail "Slack 응답 ok:false 인데 job 이 성공했다"
else
  _pass "Slack 응답 ok:false 는 job 을 실패시킨다"
fi
o2="$(send_simple_with '{"ok":false,"error":"channel_not_found"}')"
assert_json_eq "실패 시 sent= 출력이 없다" \
  "$(printf '%s' "$o2" | jq -Rsc 'split("\n") | map(select(startswith("sent=")))')" '[]'

# --- 항목 7 불변식 증명: -c 를 지운 스크래치 워크플로에서는 위 '정확히 한 줄' 이 깨진다 ---
NOC_WF="$(mktemp -d)/deploy-notify-noc.yml"
python3 - "$WF" "$NOC_WF" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
target = "          CTX=\"$(jq -n -c \\\n"
idx = text.find("Build simple context")
# simple_ctx 스텝 안의 `jq -n -c` 하나만 `-c` 제거 (다른 스텝은 그대로 둔다).
seg = text[idx: idx + 2000]
patched = seg.replace("jq -n -c \\", "jq -n \\", 1)
assert patched != seg, "패치 대상을 찾지 못했다"
text = text[:idx] + patched + text[idx + 2000:]
open(dst, "w").write(text)
PY
WF_SAVED="$WF"
WF="$NOC_WF"
o_noc="$(sc_ctx)"
LINES_NOC="$(printf '%s\n' "$o_noc" | wc -l | tr -d ' ')"
WF="$WF_SAVED"
printf '  [증명] -c 제거 스크래치의 Build simple context 출력 줄 수: %s (1 이 아니어야 어서션이 이 불변식을 지킴을 증명)\n' "$LINES_NOC"
if [ "$LINES_NOC" != "1" ]; then
  _pass "증명: -c 를 지우면 \$GITHUB_OUTPUT 이 한 줄이 아니게 된다 (불변식이 실제로 보호됨)"
else
  _fail "증명 실패: -c 를 지웠는데도 한 줄로 남았다"
fi

# --- Send release note ---
# 가짜 curl 을 PATH 앞에 두고 Slack 응답을 통제한다.
fake_curl() {
  local main="$1" thread="$2" dir
  dir="$(mktemp -d)"
  { printf '#!/usr/bin/env bash\n'
    printf 'if [ -f "%s/called" ]; then printf %%s %s; else : > "%s/called"; printf %%s %s; fi\n' \
      "$dir" "'$thread'" "$dir" "'$main'"
  } > "$dir/curl"
  chmod +x "$dir/curl"
  printf '%s' "$dir"
}
send_with() {
  local d; d="$(fake_curl "$1" "$2")"
  PATH="$d:$PATH" TOKEN=x CTX="$(cat "$ROOT/tests/fixtures/context_prod.json")" \
    run_step "Send release note" 2>/dev/null
  rm -rf "$d"
}
send_rc() {
  local d; d="$(fake_curl "$1" "$2")"
  ( PATH="$d:$PATH" TOKEN=x CTX="$(cat "$ROOT/tests/fixtures/context_prod.json")" \
    run_step "Send release note" >/dev/null 2>&1 )
  local rc=$?; rm -rf "$d"; return $rc
}

o="$(send_with '{"ok":true,"ts":"123.456"}' '{"ok":true,"ts":"9"}')"
assert_json_eq "본문 성공 시 thread_ts 가 설정된다" \
  "$(printf '%s' "$o" | jq -Rsc 'split("\n") | map(select(startswith("thread_ts=")))')" \
  '["thread_ts=123.456"]'

# `ts` 가 없는 `ok:true` 응답. `jq -r '.ts'` 였다면 문자열 "null" 을 내
# thread_ts=null 로 GITHUB_OUTPUT 에 쓰이고, 그것은 비어 있지 않아 Task 11의
# 마커 태그 게이트(`thread_ts != ''`)를 통과해 버린다 — 전송이 확인되지
# 않았는데 태그가 이동하는 자기치유 붕괴. `.ts // empty` 는 이 응답에서
# thread_ts 를 전혀 내지 않고 job 을 실패시켜야 한다.
o="$(send_with '{"ok":true}' '{"ok":true,"ts":"9"}')"
assert_json_eq "ts 없는 ok:true 에서 thread_ts 가 설정되지 않는다 (null 로 새지 않는다)" \
  "$(printf '%s' "$o" | jq -Rsc 'split("\n") | map(select(startswith("thread_ts=")))')" '[]'
if send_rc '{"ok":true}' '{"ok":true,"ts":"9"}'; then
  _fail "ts 없는 ok:true 인데 job 이 성공했다"
else
  _pass "ts 없는 ok:true 는 job 을 실패시킨다"
fi

o="$(send_with '{"ok":false,"error":"invalid_blocks"}' '{"ok":true,"ts":"9"}')"
assert_json_eq "본문 실패 시 thread_ts 가 설정되지 않는다" \
  "$(printf '%s' "$o" | jq -Rsc 'split("\n") | map(select(startswith("thread_ts=")))')" '[]'
if send_rc '{"ok":false,"error":"invalid_blocks"}' '{"ok":true,"ts":"9"}'; then
  _fail "본문 실패인데 job 이 성공했다"
else
  _pass "본문 실패는 job 을 실패시킨다"
fi

# 스레드 실패는 job 을 실패시키지 않고 thread_ts 를 보존한다 —
# Task 11 이 이 값으로 마커 태그 이동을 게이트하므로 이 성질이 자기치유의 핵심이다.
o="$(send_with '{"ok":true,"ts":"123.456"}' '{"ok":false,"error":"x"}')"
assert_json_eq "스레드 실패에도 thread_ts 는 보존된다" \
  "$(printf '%s' "$o" | jq -Rsc 'split("\n") | map(select(startswith("thread_ts=")))')" \
  '["thread_ts=123.456"]'
if send_rc '{"ok":true,"ts":"123.456"}' '{"ok":false,"error":"x"}'; then
  _pass "스레드 실패는 job 을 실패시키지 않는다"
else
  _fail "스레드 실패가 job 을 실패시켰다"
fi

# --- Move deployed marker tag : 진리표 (자기치유의 핵심) ---
# 이 태스크가 "가장 중요한 성질"이라 부른 것에 회귀 보호가 없었다.
# 실제 git repo + bare 리모트를 만들어 태그가 실제로 이동했는지 측정한다.
# marker_case <RELEASE> <SENT> — 추출된 스텝 본문을 실제 repo 에서 돌리고
# **bare 리모트에 태그가 실제로 갔는지**를 측정한다(로컬 태그가 아니다).
# 스텝 레벨 `if:`(always()/outcome/phase/status)는 추출 하네스가 우회하므로
# 이 함수로는 검증되지 않는다 — 그 게이팅은 리뷰에서 손으로 확인해야 한다.
marker_case() {
  local release="$1" sent="$2" sent_simple="${3-}"
  local up wk moved
  up="$(mktemp -d)"; wk="$(mktemp -d)"
  git init -q --bare "$up/o.git"
  git init -q -b main "$wk"
  git -C "$wk" config user.email t@t.io; git -C "$wk" config user.name t
  echo a > "$wk/a"; git -C "$wk" add -A; git -C "$wk" commit -q -m a
  git -C "$wk" remote add origin "$up/o.git"
  git -C "$wk" push -q origin main
  # 스텝 본문을 이 repo 안에서 실행한다 (git 작업이므로 cwd 가 중요하다).
  local body out
  body="$(mktemp)"; out="$(mktemp)"
  extract_step "Move deployed marker tag" > "$body"
  ( cd "$wk" && ENVIRONMENT=prod RELEASE="$release" SENT="$sent" \
      SENT_SIMPLE="$sent_simple" GITHUB_OUTPUT="$out" bash "$body" ) >/dev/null 2>&1 || true
  if git -C "$up/o.git" rev-parse --verify --quiet 'refs/tags/deployed/prod' >/dev/null; then
    moved=true
  else
    moved=false
  fi
  rm -rf "$up" "$wk" "$body" "$out"
  printf '%s' "$moved"
}

assert_json_eq "릴리즈 경로 + 전송 확인 → 마커 이동" \
  "$(marker_case true 123.456 | jq -R .)" '"true"'
assert_json_eq "릴리즈 경로 + 전송 미확인 → 마커 이동 안 함 (자기치유)" \
  "$(marker_case true '' | jq -R .)" '"false"'
assert_json_eq "간소 경로(dev) + 전송 확인 → 마커 이동" \
  "$(marker_case false '' true | jq -R .)" '"true"'
assert_json_eq "간소 경로 + 릴리즈 값이 섞여도 간소 확인만 본다" \
  "$(marker_case false 123.456 true | jq -R .)" '"true"'

# **빈 RELEASE 는 "간소 경로"가 아니라 "알 수 없음"이다.**
# `always()` 가 붙은 뒤 range·channel 이 실패하면 RELEASE 가 빈 값이 되는데,
# 그때 마커가 이동하면 알림 0통으로 커밋 범위가 영구 유실된다.
# (`always()` 이전에는 Actions 가 스텝을 건너뛰어 암묵적으로 보호했다.)
assert_json_eq "RELEASE 가 빈 값(channel 미실행)이면 마커 이동 안 함" \
  "$(marker_case '' '' | jq -R .)" '"false"'
assert_json_eq "RELEASE 빈 값 + SENT 있음이어도 마커 이동 안 함" \
  "$(marker_case '' 123.456 | jq -R .)" '"false"'

# 간소 경로도 전송 확인을 요구한다 — 릴리즈 경로만 보호하면 거울상 구멍이 남는다.
assert_json_eq "간소 경로 + 전송 미확인 → 마커 이동 안 함" \
  "$(marker_case false '' '' | jq -R .)" '"false"'
assert_json_eq "간소 경로 + 전송 확인 → 마커 이동" \
  "$(marker_case false '' true | jq -R .)" '"true"'

# --- Create version tag and release : 기존 태그면 warn+skip, 중복 Release 없음 ---
release_case() {
  local pretag="$1" ghlog wk body out
  ghlog="$(mktemp)"; wk="$(mktemp -d)"
  local ghdir; ghdir="$(mktemp -d)"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' "$ghlog" > "$ghdir/gh"
  chmod +x "$ghdir/gh"
  git init -q --bare "$wk/o.git"; git init -q -b main "$wk/w"
  git -C "$wk/w" config user.email t@t.io; git -C "$wk/w" config user.name t
  echo a > "$wk/w/a"; git -C "$wk/w" add -A; git -C "$wk/w" commit -q -m a
  git -C "$wk/w" remote add origin "$wk/o.git"; git -C "$wk/w" push -q origin main
  [ -n "$pretag" ] && git -C "$wk/w" tag "$pretag"
  body="$(mktemp)"; out="$(mktemp)"
  extract_step "Create version tag and release (prod only)" > "$body"
  ( cd "$wk/w" && PATH="$ghdir:$PATH" GH_TOKEN=x VERSION=v1.0.0 \
      CTX="$(cat "$ROOT/tests/fixtures/context_prod.json")" \
      GITHUB_OUTPUT="$out" bash "$body" ) >/dev/null 2>&1 || true
  grep -c 'release create' "$ghlog" | tr -d ' '
  rm -rf "$ghlog" "$ghdir" "$wk" "$body" "$out"
}
assert_json_eq "태그가 없으면 Release 를 1회 만든다" \
  "$(release_case '' | jq -R 'tonumber')" '1'
assert_json_eq "태그가 이미 있으면 Release 를 만들지 않는다 (중복 방지)" \
  "$(release_case v1.0.0 | jq -R 'tonumber')" '0'

# 위 두 어서션만으로는 기존-태그 검사의 유무를 구별하지 못한다 — 검사를 지워도
# `git tag -a` 가 기존 태그에서 어차피 중단되어 `release create` 에 도달하지
# 않으므로 호출 수는 0으로 같다. **판별 성질은 종료코드다.**
# 검사가 있으면 warn + exit 0 (재실행이 job 을 붉게 만들지 않는다),
# 없으면 git 이 exit 128 로 죽는다.
release_rc() {
  local pretag="$1" ghdir wk body rc
  ghdir="$(mktemp -d)"; printf '#!/usr/bin/env bash\nexit 0\n' > "$ghdir/gh"; chmod +x "$ghdir/gh"
  wk="$(mktemp -d)"
  git init -q --bare "$wk/o.git"; git init -q -b main "$wk/w"
  git -C "$wk/w" config user.email t@t.io; git -C "$wk/w" config user.name t
  echo a > "$wk/w/a"; git -C "$wk/w" add -A; git -C "$wk/w" commit -q -m a
  git -C "$wk/w" remote add origin "$wk/o.git"; git -C "$wk/w" push -q origin main
  [ -n "$pretag" ] && git -C "$wk/w" tag "$pretag"
  body="$(mktemp)"
  extract_step "Create version tag and release (prod only)" > "$body"
  ( cd "$wk/w" && PATH="$ghdir:$PATH" GH_TOKEN=x VERSION=v1.0.0 \
      CTX="$(cat "$ROOT/tests/fixtures/context_prod.json")" \
      GITHUB_OUTPUT=/dev/null bash "$body" ) >/dev/null 2>&1
  rc=$?
  rm -rf "$ghdir" "$wk" "$body"
  printf '%s' "$rc"
}
assert_json_eq "기존 태그에서 warn 후 정상 종료한다 (재실행이 job 을 붉게 하지 않음)" \
  "$(release_rc v1.0.0 | jq -R 'tonumber')" '0'
assert_json_eq "태그가 없을 때도 정상 종료한다" \
  "$(release_rc '' | jq -R 'tonumber')" '0'

# --- 빈 커밋 범위(같은 커밋 재배포)는 릴리즈 경로를 타지 않는다 ---
# 타면 next-version 이 새 버전을 계산해 내용이 빈 릴리즈와 <!here> 핑을 만든다.
assert_json_eq "커밋 0건이면 release=false (유령 릴리즈 방지)" \
  "$(PHASE=result STATUS=success ENVIRONMENT=prod DEV_CH=Cdev REL_CH=Crel \
     RANGE_JSON='{"base":"a","head":"a","commits":0,"truncated":false}' \
     run_step "Choose channel" 2>/dev/null | tr '\n' ' ' | jq -Rc .)" \
  '"release=false id=Cdev "'
assert_json_eq "커밋 1건 이상이면 release=true 유지" \
  "$(PHASE=result STATUS=success ENVIRONMENT=prod DEV_CH=Cdev REL_CH=Crel \
     RANGE_JSON='{"base":"a","head":"b","commits":1,"truncated":false}' \
     run_step "Choose channel" 2>/dev/null | tr '\n' ' ' | jq -Rc .)" \
  '"release=true id=Crel "'

# 읽을 수 없는 범위는 릴리즈 경로를 **켜 둔 채** 통과해서는 안 된다 (fail-safe).
ch_range() {
  PHASE=result STATUS=success ENVIRONMENT=prod DEV_CH=Cdev REL_CH=Crel \
    RANGE_JSON="$1" run_step "Choose channel" 2>/dev/null | tr '\n' ' ' | jq -Rc .
}
assert_json_eq "commits 키가 없으면 release=false (fail-safe)" \
  "$(ch_range '{"base":"a","head":"b"}')" '"release=false id=Cdev "'
assert_json_eq "commits 가 null 이면 release=false" \
  "$(ch_range '{"base":"a","head":"b","commits":null}')" '"release=false id=Cdev "'
assert_json_eq "RANGE_JSON 이 비면 release=false" \
  "$(ch_range '')" '"release=false id=Cdev "'
assert_json_eq "commits 가 \"00\" 이면 release=false (선행 0 은 신뢰하지 않는다)" \
  "$(ch_range '{"base":"a","head":"b","commits":"00"}')" '"release=false id=Cdev "'

e="$(PHASE=result STATUS=success ENVIRONMENT=prod DEV_CH=Cdev REL_CH=Crel \
     RANGE_JSON='{"base":"a","head":"b"}' \
     run_step "Choose channel" 2>&1 >/dev/null || true)"
case "$e" in
  *'::warning::'*) _pass "읽을 수 없는 범위는 ::warning:: 으로 알린다" ;;
  *)               _fail "읽을 수 없는 범위는 ::warning:: 으로 알린다" ;;
esac
