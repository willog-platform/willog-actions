# 컨텍스트 JSON + --arg phase (start|result) → 간소 페이로드
# dev 환경 전체, 모든 phase:start, 모든 실패에 쓴다.

def md($t): { type: "mrkdwn", text: $t };
def repo_url: "https://github.com/" + .repo;

# Slack mrkdwn 이스케이프. **render-main.jq 의 정의와 한 글자도 달라서는 안 된다.**
# (같은 파일에 두는 대신 복제한 이유: jq 모듈(`include` + `-L`)을 쓰면 워크플로와
#  테스트의 모든 호출 지점에 `-L` 을 붙여야 하고, 빠뜨리면 컴파일 에러가 난다.
#  한 줄 정의를 복제하고 **세 파일의 정의가 동일한지 검사하는 테스트**를 두는
#  쪽이 배관이 적고 어긋남을 잡아낸다. tests/test_render_aux.sh 참고.)
# Slack 은 `<!channel>`·`<@U123>` 을 mrkdwn 어디에 있든 실제 멘션으로 해석하므로,
# 신뢰할 수 없는 PR 텍스트를 그대로 넣으면 채널 전체 핑을 주입할 수 있다.
# `&` 를 먼저 치환해야 뒤 치환이 만든 `&lt;` 가 이중 이스케이프되지 않는다.
def esc: (. // "") | gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;");


def state:
  if $phase == "start" then "start"
  elif .deploy_status == "success" then "success"
  elif .deploy_status == "cancelled" then "cancelled"
  else "failure" end;

def color:
  if state == "start" then "#1e90ff"
  elif state == "success" then "#36a64f"
  elif state == "cancelled" then "#808080"
  else "#dc3545" end;

def headline:
  if state == "start" then "🚀  배포 시작"
  elif state == "success" then "✅  배포 성공"
  elif state == "cancelled" then "⏹️  배포 취소"
  else "❌  배포 실패" end;

def footer:
  if state == "start" then "*" + (.actor | esc) + "* 님이 배포를 시작했습니다"
  elif state == "success" then "배포가 정상적으로 완료되었습니다 🎉"
  # cancelled 는 failure 와 다른 상태다 (예: argocd-sync 의 660s 타임아웃으로
  # 인한 취소). "오류가 발생했습니다" 는 사실과 다르므로 별도 문안을 쓴다.
  elif state == "cancelled" then "배포가 취소되었습니다 ⏹️ 오류는 아닙니다"
  else "배포 중 오류가 발생했습니다 🔥 로그를 확인하세요" end;

# 최상단 `text` 는 두지 않는다. Slack 은 최상단 `text` 를 attachment 카드 **위에**
# 한 줄로 더 출력하므로, 카드 첫 블록의 헤드라인과 합쳐 "🚀 배포 시작" 이 한
# 메시지에 두 번 보인다 (2026-09-03 #cicd 제보). 푸시·사이드바 미리보기 문안은
# attachment 의 `fallback` 이 그대로 담당하므로 알림 품질 손실은 없다.
{
  channel: .channel,
  attachments: [ {
    color: color,
    fallback: (headline + " [" + (.service_name | esc) + "] " + (.env_label | esc)),
    blocks: [
      { type: "section", text: md(
          headline + "  *[ <" + repo_url + "|" + (.service_name | esc) + "> ]  " +
          "<" + repo_url + "/actions/runs/" + .run_id + "|Actions>" +
          # 빈 argocd_url 은 링크 없는 평문으로 (render-main.jq 와 동일 규칙).
          (if ((.argocd_url // "") == "") then "  ·  ArgoCD(링크 없음)"
           else "  ·  <" + .argocd_url + "|ArgoCD>" end) + "*") },
      { type: "divider" },
      { type: "section", fields: [
          md("*🌐  환경*\n`" + (.environment | esc) + "`"),
          md("*🎯  apps*\n`" + (.apps | esc) + "`"),
          md("*📦  이미지*\n`" + (if ((.image_tag // "") == "") then "-" else (.image_tag | esc) end) + "`"),
          # base == head 면 같은 커밋 재배포다. 해시 두 개를 눈으로 비교하게
          # 하지 않고 명시한다 — 운영자가 "새로 나간 것이 있나"를 즉시 알아야 한다.
          md("*🔀  범위*\n`" + (.range.base | esc) + ".." + (.range.head | esc) + "`"
             + (if .range.base == .range.head then "\n_재배포 — 새 커밋 없음_" else "" end)) ] },
      { type: "context", elements: [
          # `image_url` 과 `alt_text` 는 이스케이프하지 않는다. 둘 다 mrkdwn 이
          # 아니다 — `alt_text` 는 접근성 문자열이라 Slack 이 멘션으로 파싱하지
          # 않고(Task 7 리뷰에서 확인), URL 에 HTML 엔티티를 넣는 것은 의미상
          # 틀렸다(URL 은 퍼센트 인코딩 대상이다). 게다가 GitHub 로그인에는
          # `<`·`>`·`&` 가 들어갈 수 없다. 아래 `md(footer)` 의 `.actor` 는
          # mrkdwn 이므로 그쪽에서 이스케이프한다. render-main.jq 와 동일하게 둔다.
          { type: "image", image_url: ("https://github.com/" + .actor + ".png"), alt_text: .actor },
          md(footer) ] }
    ]
  } ]
}
