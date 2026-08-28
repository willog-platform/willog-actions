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

# int_or_default <이름> <값> <기본값> — 양의 정수가 아니면 경고하고 기본값을 쓴다.
# 설정 오타 하나로 알림이 죽지 않게 하되, 조용히 넘어가지도 않는다.
# `[ "$x" -gt "$y" ]` 에 비숫자를 넣으면 bash 원시 에러가 stderr 로 새어나가
# `::warning::` 로깅 계약을 깨고, 실패한 test 가 if 에 먹혀 안전 신호가
# 조용히 꺼진다. 그 경로를 원천 차단한다.
int_or_default() {
  local name="$1" val="${2-}" def="$3" num
  case "$val" in
    ''|*[!0-9]*) ;;   # 비숫자·빈 값 → 아래 경고 경로
    *)
      # `10#` 을 반드시 붙인다. bash 산술은 선행 0 을 8진수 접두사로 읽으므로
      # `008`·`009`·`089` 에서 "value too great for base" 치명적 원시 에러를
      # 내고 stdout 에 아무것도 남기지 않는다 — 이 헬퍼가 막으려는 결함과
      # 정확히 같은 부류다. (`007` 은 우연히 유효한 8진수여서 통과한다.)
      # 산술 정규화 자체는 필요하다: `case` 패턴만으로는 "00"·"000" 같은
      # 0의 다른 표기를 전부 거를 수 없고, 선행 0("089"→89)도 정리해준다.
      num=$((10#$val))
      if [ "$num" -gt 0 ]; then printf '%s' "$num"; return 0; fi
      ;;
  esac
  warn "${name} 값이 양의 정수가 아님: '${val}' — 기본값 ${def} 사용"
  printf '%s' "$def"
}
