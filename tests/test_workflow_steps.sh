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
