# 컨텍스트 JSON + --arg thread_ts → 스레드 답글
# 상단을 짧게 유지하는 대가로 기술 상세는 전부 여기 온다.
# 본체가 목록을 접는 대신 여기에 전량이 있으므로 fold 는 쓰지 않는다.
# 이 답글은 blocks 없는 plain `text` 라 Slack 상한이 40,000자로 훨씬 넉넉하다.

# Slack mrkdwn 이스케이프. **render-main.jq 의 정의와 한 글자도 달라서는 안 된다.**
# (같은 파일에 두는 대신 복제한 이유: jq 모듈(`include` + `-L`)을 쓰면 워크플로와
#  테스트의 모든 호출 지점에 `-L` 을 붙여야 하고, 빠뜨리면 컴파일 에러가 난다.
#  한 줄 정의를 복제하고 **세 파일의 정의가 동일한지 검사하는 테스트**를 두는
#  쪽이 배관이 적고 어긋남을 잡아낸다. tests/test_render_aux.sh 참고.)
# Slack 은 `<!channel>`·`<@U123>` 을 mrkdwn 어디에 있든 실제 멘션으로 해석하므로,
# 신뢰할 수 없는 PR 텍스트를 그대로 넣으면 채널 전체 핑을 주입할 수 있다.
# `&` 를 먼저 치환해야 뒤 치환이 만든 `&lt;` 가 이중 이스케이프되지 않는다.
def esc: (. // "") | gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;");

def pr_lines:
  if (.prs | length) == 0 then "_PR 없음 (커밋 직접 반영)_"
  else (.prs | sort_by(-.number) | map(
      ("<" + .url + "|#" + (.number|tostring) + ">  " + (.title | esc)
       + "  ·  @" + (.author | esc)
       + (if ((.labels // []) | length) > 0
          then "  ·  [" + ((.labels | map(esc)) | join(", ")) + "]"
          else "" end))
    ) | join("\n"))
  end;

def migration_lines:
  if ((.changes.migrations // []) | length) == 0 then "없음"
  else (.changes.migrations | map(esc) | join(", ")) end;

def api_lines:
  if ((.changes.api_files // []) | length) == 0 then "없음"
  else (.changes.api_files | map(esc) | join(", ")) end;

{
  channel: .channel,
  thread_ts: $thread_ts,
  text: ( "*PR 상세*\n" + pr_lines
        + "\n\n*마이그레이션*  " + migration_lines
        + "\n*API 표면*  " + api_lines
        + "\n*커밋 범위*  `" + (.range.base | esc) + ".." + (.range.head | esc) + "`  ("
          + (.range.commits|tostring) + " commits"
          + (if .range.truncated then ", 절단됨" else "" end) + ")"
        # 빈 image_tag 는 빈 코드스팬이 아니라 `-` 로 (render-main.jq·render-simple.jq 와 동일 규칙).
        + "\n*이미지 태그*  `" +
          (if ((.image_tag // "") == "") then "-" else (.image_tag | esc) end) + "`" )
}
