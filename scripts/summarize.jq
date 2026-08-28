# raw PR 배열 → 요약된 PR 배열
# 입력: [{number,title,url,author:{login},labels:[{name}],body}]
# 출력: [{number,title,summary,author,labels,url,image_count}]

def strip_comments:
  gsub("<!--(?:.|\n)*?-->"; "");

def conventional_strip:
  sub("^(feat|fix|chore|refactor|docs|test|perf|build|ci|style|revert)(\\([^)]*\\))?!?:\\s*"; "");

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
def image_count:
  (. // "") as $b
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
  summary: ((.body | summary_section)
            // ((.title | conventional_strip) | nonempty)
            // .title),
  author: (.author.login // "unknown"),
  # `.name` 이 없거나 null 인 라벨도 문자열 배열 계약을 깨지 않는다.
  labels: ((.labels // []) | map(.name // "")),
  url: .url,
  image_count: (.body | image_count)
})
