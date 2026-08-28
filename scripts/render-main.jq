# 컨텍스트 JSON → chat.postMessage 본문
# 목업은 스펙 §3.2 참조.

def md($t): { type: "mrkdwn", text: $t };
def repo_url: "https://github.com/" + .repo;

# ── Slack mrkdwn 이스케이프 ────────────────────────────────────────
# 신뢰할 수 없는 자유 텍스트(PR 요약·작성자·파일명·이미지 태그 등)를
# mrkdwn 블록에 넣기 전에 반드시 통과시킨다.
# Slack 은 `<!channel>`·`<!here>`·`<@U123>` 을 mrkdwn 안 어디에 있든 **실제
# 멘션으로 해석**한다 — 이 파일이 의도적 `<!here>` 를 넣는 것과 동일한 기제다.
# 이스케이프하지 않으면 PR 제목에 `<!channel>` 을 쓴 사람이 채널 전체 핑을
# 발생시킬 수 있고, 스펙 §3.1의 "`<!channel>` 은 쓰지 않는다" 결정이 우회된다.
# `&` 를 **먼저** 치환해야 뒤 치환이 만든 `&lt;` 의 `&` 가 이중 이스케이프되지 않는다.
# 우리가 직접 조립하는 `<url|text>` 링크와 `.mention` 리터럴에는 적용하지 않는다.
def esc: (. // "") | gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;");

# Slack 의 section.text mrkdwn 은 3000자, fields 각 항목은 2000자 상한이 있고
# 넘기면 chat.postMessage 가 `invalid_blocks` 로 거부한다 — 알림이 아예 안 간다.
# `## Summary` 첫 줄은 사람이 쓰는 자유 텍스트라 한 줄이 수백 자가 될 수 있으므로
# 항목 단위로 잘라 상한에 닿지 않게 한다.
# jq 의 `length` 는 유니코드 코드포인트 단위이므로 한국어도 안전하게 잘린다.
def clip($n): if (. | length) > $n then (.[:$n] + "…") else . end;

# 모든 필드 값에 1800자 백스톱을 둔다. 아래 개별 fold 로 이미 충분히 짧아지지만,
# 접기 개수 계산이 틀려도 상한에 닿지 않게 하는 마지막 방어선이다.
def field($label; $value): md("*" + $label + "*\n" + ($value | clip(1800)));

# 목록을 접는다. `$n` 개까지 보이고 나머지는 "그 외 N건" 으로 갈음한다.
def fold($items; $n; $sep):
  if ($items | length) <= $n then ($items | join($sep))
  else (($items[:$n] | join($sep)) + $sep + "그 외 " + (($items | length) - $n | tostring) + "건")
  end;

def version_text:
  if .version.previous == null
  then "`" + (.version.next | esc) + "`"
  else (.version.previous | esc) + " → `" + (.version.next | esc) + "`"
  end;

# 상단 요약: 상위 5건까지, 초과분은 접는다.
def summary_lines:
  (.prs | map("• " + (.summary | esc | clip(200)))) as $all
  | if ($all | length) == 0 then "• 커밋 직접 반영 (PR 없음)"
    elif ($all | length) <= 5 then ($all | join("\n"))
    else (($all[:5] | join("\n")) + "\n• 그 외 " + (($all | length) - 5 | tostring) + "건")
    end;

def warning_line:
  [ (if (.changes.migrations | length) > 0
     then "*DB 마이그레이션 " + (.changes.migrations | length | tostring) + "건*" else empty end),
    (if .changes.api_touched then "*API 표면 변경 (확인 필요)*" else empty end) ]
  | if length == 0 then null else "⚠️  " + join(" · ") end;

# PR 링크는 전량 나열하면 상한을 넘는다 (실측: PR 30건 → 2174자 > 2000).
# 12건까지 보이고 접는다. 전체 목록은 스레드 답글에 있다.
def pr_field:
  if (.prs | length) == 0 then "없음"
  else fold((.prs | sort_by(.number) | map("<" + .url + "|#" + (.number|tostring) + ">")); 12; " · ")
  end;

def attach_field:
  ((.prs | map(.image_count) | add) // 0) as $n
  | (.prs | map(select(.image_count > 0))) as $withImages
  | if $n == 0 then "없음"
    else "스크린샷 " + ($n|tostring) + "장 → " +
         (if ($withImages | length) == 1
          then "<" + $withImages[0].url + "|PR에서 보기>"
          else "각 PR에서 보기" end)
    end;

def migration_field:
  # Flyway 는 `V33__excursion_history.sql` → `V33`.
  # Node(MikroORM) 는 `Migration20250101120000.ts` 처럼 `__` 가 없으므로
  # 확장자만 떼어 `Migration20250101120000` 으로 보인다.
  # (실측: telemetry-api·member-api 의 마이그레이션이 이 형태다.)
  # 파일명은 git 경로에서 오므로 이스케이프한다.
  # 전량 나열하면 상한을 넘는다 (실측: Node 형식 30건 → 2520자 > 2000).
  # 10건까지 보이고 접는다. 전체 목록은 스레드 답글에 있다.
  if (.changes.migrations | length) == 0 then "없음"
  else fold((.changes.migrations
             | map(sub("__.*$"; "") | sub("\\.(sql|ts|js)$"; "") | esc)); 10; " · ")
  end;

def links_field:
  "<" + repo_url + "/actions/runs/" + .run_id + "|Actions>" +
  # argocd_url 이 비면 링크를 만들지 않는다. `<|ArgoCD>` 는 깨진 mrkdwn 이고
  # `https:///...` 는 끊긴 링크다 — 둘 다 이유 없이 노출되면 안 된다.
  (if ((.argocd_url // "") == "") then " · ArgoCD(링크 없음)"
   else " · <" + .argocd_url + "|ArgoCD>" end) +
  (if .environment == "prod"
   then " · <" + repo_url + "/releases/tag/" + .version.next + "|Release>"
   else "" end);

def truncation_note:
  if .range.truncated
  then "\n\n_커밋 " + (.range.commits|tostring) + "개 중 상한까지만 조회했습니다. 일부 PR이 누락될 수 있습니다._"
  else "" end;

# `.mention` 은 우리가 넣는 리터럴이므로 이스케이프하지 않는다.
# `// ""` 가 필요한 이유: 키가 아예 없으면 `null + " "` 가 `" "` 로 평가되어
# 헤더 앞에 군더더기 공백이 붙는다 (jq 는 null 을 + 의 항등원으로 취급).
def mention_prefix:
  if ((.mention // "") == "") then "" else (.mention + " ") end;

{
    channel: .channel,
    text: ("🚀 [" + (.service_name | esc) + "] " + (.version.next | esc) + " · " + (.env_label | esc) + " 배포 완료"),
    attachments: [ {
      color: "#36a64f",
      fallback: ("🚀 [" + (.service_name | esc) + "] " + (.version.next | esc) + " · " + (.env_label | esc) + " 배포 완료"),
      blocks: (
        [ { type: "section", text: md(
              mention_prefix +
              "🚀  *[ <" + repo_url + "|" + (.service_name | esc) + "> ]  " +
              "`" + (.version.next | esc) + "`  ·  " + (.env_label | esc) + " 배포 완료*") },
          { type: "divider" },
          { type: "section", text: md(("*이번 배포 내용*\n" + summary_lines + truncation_note) | clip(2800)) } ]
        + ( (warning_line) as $w
            | if $w == null then [] else [ { type: "section", text: md($w) } ] end )
        + [ { type: "divider" },
            # 필드는 항상 6개다. 정보가 없을 때도 "없음" 으로 자리를 지킨다.
            # Slack 의 fields 는 2열로 배치되므로 6개면 3행 고정이 되고, 같은
            # 메시지를 반복해서 훑는 사람이 필드 위치를 기억할 수 있다.
            # 조건부인 것은 상단의 `⚠️` 줄 하나뿐이고, 그것이 조건부여야 하는
            # 이유(평소 없으니 떴을 때 읽힌다)가 정보성 필드에는 적용되지 않는다.
            { type: "section", fields: (
                [ field("🌐  환경"; (.env_label | esc)),
                  field("📦  버전"; version_text),
                  field("📋  포함 PR (" + (.prs|length|tostring) + "건)"; pr_field),
                  field("🖼️  첨부"; attach_field),
                  field("🗄️  마이그레이션"; migration_field),
                  field("🔗  링크"; links_field) ] ) },
            { type: "context", elements: [
                { type: "image", image_url: ("https://github.com/" + .actor + ".png"), alt_text: .actor },
                md("*" + (.actor | esc) + "* 님이 배포  ·  `" + (.image_tag | esc) + "`") ] } ]
      )
    } ]
  }
