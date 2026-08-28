#!/usr/bin/env bash
# 모든 스크립트의 공통 기반. stdout은 JSON 전용이므로 로그는 전부 stderr.
set -euo pipefail

die()  { printf '::error::%s\n'   "$*" >&2; exit 1; }
warn() { printf '::warning::%s\n' "$*" >&2; }
note() { printf '::notice::%s\n'  "$*" >&2; }

# require <이름> <값> — 비어 있으면 죽고, 아니면 값을 되돌려준다.
require() {
  local name="$1" val="${2-}"
  [ -n "$val" ] || die "required input missing: ${name}"
  printf '%s' "$val"
}
