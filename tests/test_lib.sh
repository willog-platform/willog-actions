# lib.sh 를 서브셸에서 source 해 이 프로세스를 오염시키지 않는다.
L="$ROOT/scripts/lib.sh"

iod() { ( . "$L"; int_or_default "$@" ) 2>/dev/null; }

assert_json_eq "정상 정수 통과"        "$(iod X 50 100 | jq -R .)"   '"50"'
assert_json_eq "선행 0 정규화"          "$(iod X 007 100 | jq -R .)"  '"7"'
# 8진수 함정: bash 산술은 선행 0 을 8진수로 읽는다. 007 은 우연히 유효한
# 8진수라 통과하므로, 8·9 가 든 값으로 반드시 검사해야 한다.
assert_json_eq "008 → 8 (8진수 오해 없이)" "$(iod X 008 100 | jq -R .)"  '"8"'
assert_json_eq "009 → 9"                   "$(iod X 009 100 | jq -R .)"  '"9"'
assert_json_eq "089 → 89"                  "$(iod X 089 100 | jq -R .)"  '"89"'
assert_json_eq "빈 값 → 기본값"         "$(iod X '' 100 | jq -R .)"   '"100"'
assert_json_eq "비숫자 → 기본값"        "$(iod X abc 100 | jq -R .)"  '"100"'
assert_json_eq "0 → 기본값"             "$(iod X 0 100 | jq -R .)"    '"100"'
assert_json_eq "00 → 기본값"            "$(iod X 00 100 | jq -R .)"   '"100"'
assert_json_eq "000 → 기본값"           "$(iod X 000 100 | jq -R .)"  '"100"'
assert_json_eq "음수 → 기본값"          "$(iod X -5 100 | jq -R .)"   '"100"'
assert_json_eq "공백 포함 → 기본값"     "$(iod X ' 5 ' 100 | jq -R .)" '"100"'

# 경고는 stderr 로만 가고 stdout(캡처값)을 오염시키지 않는다.
err="$( ( . "$L"; int_or_default X abc 100 ) 2>&1 >/dev/null || true )"
case "$err" in
  *'::warning::'*) _pass "잘못된 값은 ::warning:: 으로 알린다" ;;
  *)               _fail "잘못된 값은 ::warning:: 으로 알린다" ;;
esac

# bash 원시 에러가 새어나가면 로깅 계약이 깨진다.
err="$( ( . "$L"; int_or_default X 008 100 ) 2>&1 >/dev/null || true )"
case "$err" in
  *'value too great for base'*) _fail "008 에서 bash 8진수 원시 에러 누출" ;;
  *)                            _pass "008 에서 원시 에러 누출 없음" ;;
esac

# require: 값을 되돌려주고, 빈 값이면 죽는다.
assert_json_eq "require 는 값을 되돌려준다" \
  "$( ( . "$L"; require NAME hello ) | jq -R . )" '"hello"'
assert_fail "require 는 빈 값에서 죽는다" bash -c '. "'"$L"'"; require NAME ""'
