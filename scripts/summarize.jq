# raw PR 배열 → 요약된 PR 배열
# 입력: [{number,title,url,author:{login},labels:[{name}],body}]
# 출력: [{number,title,summary,author,labels,url,image_count}]

def strip_comments:
  gsub("<!--(?:.|\n)*?-->"; "");

def conventional_strip:
  sub("^(feat|fix|chore|refactor|docs|test|perf|build|ci|style|revert)(\\([^)]*\\))?!?:\\s*"; "");

# --- I7: 마크다운 링크 `[text](url)` → 링크 텍스트만 남긴다 (URL 은 버린다) ---
# Slack mrkdwn 에는 `[text](url)` 문법이 없다(`<url|text>` 만 있다). PR
# 템플릿의 `- [[Jira](.../TICKET)] ...` 처럼 요약 첫 줄에 마크다운 링크가
# 들어오면, 이스케이프 없이 그대로 내보내면 대괄호가 그대로 노출되고,
# `esc`(render-main.jq)를 거치면 대괄호는 살아 있고 URL의 `/`·`.` 만 무해하게
# 남는다 — 어느 쪽도 링크로 동작하지 않는다.
#
# **URL 을 살려 `<url|text>` 로 만들지 않는 이유:** URL 은 PR 본문에서 온
# 신뢰할 수 없는 자유 텍스트다. render-main.jq 의 `esc` 는 "우리가 조립한
# `<url|text>` 는 신뢰하고 이스케이프하지 않는다"는 성질에 의존하므로, 여기서
# 만든 `<url|text>` 를 그대로 통과시키려면 render 단계에서도 이 텍스트를
# "신뢰한다"고 표시해야 한다 — 임의의 외부 URL을 개발팀+비개발 부서가 보는
# 채널에서 클릭 가능하게 만드는 신뢰 확장이다. PR 링크 자체는 이미 본문의
# 다른 필드(`포함 PR`)에 있으므로, 굳이 확장하지 않고 **텍스트만 남기고 URL은
# 버리는 쪽**을 택한다. (대안: render 단계에서 esc 이후에 이 변환을 하고
# 링크를 살리는 것. 그러나 위 신뢰 확장 판단 때문에 채택하지 않았다.)
#
# 이 변환은 summarize.jq(추출 단계)에서 끝내야 한다 — render-main.jq 의 `esc`
# 는 `<`·`>` 를 이스케이프하므로, 만약 여기서 `<url|text>` 형태를 만들어
# 넘긴다면 esc 가 그것을 `&lt;url|text&gt;` 로 다시 깨뜨린다. 텍스트만 남기는
# 이 접근은 결과에 `<`·`>` 가 없으므로 그 문제 자체가 생기지 않는다.
def strip_md_links:
  gsub("\\[(?<label>[^\\]]*)\\]\\([^)]*\\)"; "\(.label)");

# body 에서 "## Summary" 섹션의 첫 유효 줄. 없으면 null.
def summary_section:
  ((. // "") | strip_comments | split("\n")) as $lines
  | ($lines | map(test("^##\\s*Summary\\s*$")) | index(true)) as $i
  | if $i == null then null
    else
      ($lines[($i + 1):]) as $rest
      | ($rest | map(test("^##\\s")) | index(true)) as $j
      | (if $j == null then $rest else $rest[:$j] end)
      | map(sub("^\\s*[-*]\\s*"; "") | sub("^\\s+"; "") | sub("\\s+$"; ""))
      | map(select(length > 0))
      | (.[0] // null)
    end;

# 마크다운 이미지 + <img> 태그 + 맨몸 user-attachments URL 의 합.
# 마크다운 이미지를 먼저 제거해 이중계상을 막는다.
# `strip_comments` 를 먼저 거친다 — summary_section 은 이미 그렇게 하는데
# 여기서 빠뜨리면, 주석으로 지워진(예: 리뷰 중 임시로 코멘트아웃한) 이미지가
# 여전히 image_count 에 잡혀 "첨부" 필드가 실제로 보이지 않는 스크린샷을
# 있다고 보고한다.
def image_count:
  (. // "" | strip_comments) as $b
  | ([$b | scan("!\\[[^\\]]*\\]\\([^)]*\\)")] | length) as $md
  | ($b | gsub("!\\[[^\\]]*\\]\\([^)]*\\)"; "")) as $r1
  | ([$r1 | scan("<img[\\s>]")] | length) as $tags
  # <img> 태그도 센 다음 제거한다. src 가 user-attachments URL 인
  # `<img src="..." width="600">` 는 실무에서 매우 흔한 형태인데
  # (마크다운 이미지 문법에 width 지정이 없다), 제거하지 않으면
  # $tags 와 $bare 에서 이중 계상된다.
  | ($r1 | gsub("<img[^>]*>"; "")) as $r2
  | ([$r2 | scan("https://github\\.com/user-attachments/assets/[A-Za-z0-9._-]+")] | length) as $bare
  | $md + $tags + $bare;

# 빈 문자열은 jq 의 `//` 가 "있는 값"으로 취급하므로 직접 null 로 바꿔야
# 다음 폴백이 걸린다. `fix:` 처럼 접두사만 있는 제목이 여기 해당한다.
def nonempty: if . == "" then null else . end;

map({
  number: .number,
  title:  .title,
  # 3단 폴백: Summary 섹션 → 접두사 제거한 제목 → 원제목.
  # 마지막 단계가 없으면 제목이 `fix:` 뿐일 때 요약이 빈 줄로 나간다.
  # PR 템플릿이 없는 repo 에서는 이 폴백 경로가 주 경로다.
  summary: (((.body | summary_section)
            // ((.title | conventional_strip) | nonempty)
            // .title) | strip_md_links),
  author: (.author.login // "unknown"),
  # `.name` 이 없거나 null 인 라벨도 문자열 배열 계약을 깨지 않는다.
  labels: ((.labels // []) | map(.name // "")),
  url: .url,
  image_count: (.body | image_count)
})
