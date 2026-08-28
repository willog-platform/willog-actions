#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"
. ./helpers.sh

for t in test_*.sh; do
  [ -f "$t" ] || continue
  printf '\n== %s\n' "$t"
  . "./$t"
done

printf '\n실패 %s건\n' "$FAILURES"
[ "$FAILURES" -eq 0 ]
