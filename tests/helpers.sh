#!/usr/bin/env bash
# bash 3.2 호환. 연관배열·mapfile 사용 금지.
FAILURES=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

_pass() { printf '  ok   %s\n' "$1"; }
_fail() { printf '  FAIL %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

# assert_json_eq <설명> <실제JSON> <기대JSON>
assert_json_eq() {
  local desc="$1" actual="$2" expected="$3"
  local a b
  a="$(printf '%s' "$actual"   | jq -S -c . 2>/dev/null)" || { _fail "$desc (실제가 JSON이 아님)"; return; }
  b="$(printf '%s' "$expected" | jq -S -c . 2>/dev/null)" || { _fail "$desc (기대가 JSON이 아님)"; return; }
  if [ "$a" = "$b" ]; then _pass "$desc"; else
    _fail "$desc"
    printf '    기대: %s\n    실제: %s\n' "$b" "$a"
  fi
}

# assert_fail <설명> <명령...> — 0이 아닌 종료코드를 기대한다.
assert_fail() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then _fail "$desc (성공해버렸음)"; else _pass "$desc"; fi
}

# make_repo — 커밋 3개가 있는 임시 git repo를 만들고 경로를 stdout으로.
make_repo() {
  local d
  d="$(mktemp -d)"
  git -C "$d" init -q -b main
  git -C "$d" config user.email t@t.io
  git -C "$d" config user.name  t
  local i
  for i in 1 2 3; do
    printf 'x%s\n' "$i" > "$d/f${i}.txt"
    git -C "$d" add -A
    git -C "$d" commit -q -m "commit ${i}"
  done
  printf '%s' "$d"
}

# fake_gh <응답디렉토리> — 인자를 슬러그로 바꿔 <디렉토리>/<슬러그>.json 을 출력하는
# 가짜 gh 를 만들고 그 경로를 stdout으로. 파일이 없으면 빈 배열.
fake_gh() {
  local respdir="$1" bin
  [ -n "$respdir" ] || { printf 'fake_gh: 응답 디렉토리 인자가 필요합니다\n' >&2; return 1; }
  bin="$(mktemp -d)/gh"
  # 응답 디렉토리를 스크립트에 굽는다. 호출 측이 FAKE_GH_DIR 을 따로
  # 넘기지 않아도 되고, 넘기면 그것이 우선한다.
  {
    printf '#!/usr/bin/env bash\n'
    printf 'DIR="${FAKE_GH_DIR:-%s}"\n' "$respdir"
    cat <<'FAKE'
slug="$(printf '%s' "$*" | tr -cs 'A-Za-z0-9' '_')"
f="${DIR}/${slug}.json"
if [ -f "$f" ]; then cat "$f"; else printf '[]
'; fi
FAKE
  } > "$bin"
  chmod +x "$bin"
  printf '%s' "$bin"
}
