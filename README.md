# willog-actions

`willog-platform` 공용 GitHub Actions 재사용 워크플로.

## deploy-notify.yml

배포 시작·결과를 Slack에 알린다. `stage`·`prod` 결과 알림은 배포에 포함된 PR을
커밋 범위에서 역산한 릴리즈 노트 형식으로, `dev`·시작·실패는 간소 형식으로 보낸다.

도입 방법과 input 명세는 아래 "사용법" 참고.

## 설계 원칙

- `*.sh` 는 I/O만, `*.jq` 는 순수 변환만. 이 분리로 로직 전량을 push 없이 테스트한다.
- 스크립트 stdout은 JSON 전용. 로그는 stderr로 `::notice::`/`::warning::`/`::error::`.
- Slack 페이로드는 전량 `jq -n --arg`. 셸 문자열 보간 금지.
- bash 3.2 호환 (로컬 macOS 검증 가능해야 한다).
- **알림 job은 배포 job의 `needs` 에 넣지 않는다.** 이 성질이 `@v1` 이동 태그를 안전하게 만든다.

## 테스트

    bash tests/run.sh
