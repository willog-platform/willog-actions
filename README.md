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

## 사용법

각 서비스 repo의 `.github/workflows/deploy.yaml` 에서 기존 `notify-start` /
`notify-result` job을 아래로 대체한다.

호출 측 repo의 `permissions` 는 **끌어올리지 않는다.** 워크플로 최상위에서
`contents: write` 를 열면 `build-and-push`(서드파티 빌드 툴 실행)·`create-manifest`·
`argocd-sync` 까지 쓰기 가능한 토큰을 받는데, 이 job들은 그 권한을 쓰지 않는다.
재사용 워크플로 호출은 **호출하는 job 레벨**에서 `permissions:` 를 선언할 수
있으므로, 아래처럼 알림을 보내는 두 job에만 준다. **job 레벨에 `permissions:` 를
쓰면 적지 않은 스코프는 전부 `none` 이 된다** — `pull-requests: read` 를
빠뜨리면 커밋→PR 조회가 403 으로 죽어 릴리즈 노트가 0통 나간다(2026-09-02
rule-engine 첫 stage 배포에서 실제 발생). 아래 세 줄을 그대로 쓴다. 이렇게 하면 피해 범위가
그 두 job으로 좁아지고, "알림 job은 배포를 막지 않는다"는 경계(위 설계 원칙)가
호출 측 파일만 봐도 보인다 — 최상위에 있으면 그 경계가 다른 job들과 뒤섞여
안 보인다.

```yaml
jobs:
  notify-start:
    permissions:
      contents: write        # deployed/{env}·v* 태그 push
      pull-requests: read    # 커밋→PR 역산·PR 본문 조회. 빠지면 403 으로 릴리즈 노트 0통
      id-token: write
    uses: willog-platform/willog-actions/.github/workflows/deploy-notify.yml@v1
    with:
      phase: start
      service_name: rule-engine        # ← 아래 "service_name" 절을 반드시 읽을 것
      environment: ${{ inputs.environment }}
      apps: ${{ inputs.apps }}
      dev_channel_id: C02NXP88NP8
    secrets:
      SLACK_NOTIFICATION_TOKEN: ${{ secrets.SLACK_NOTIFICATION_TOKEN }}
      ARGOCD_SERVER_DEV:        ${{ secrets.ARGOCD_SERVER_DEV }}
      ARGOCD_SERVER_STAGE:      ${{ secrets.ARGOCD_SERVER_STAGE }}
      ARGOCD_SERVER_PROD:       ${{ secrets.ARGOCD_SERVER_PROD }}

  notify-result:
    permissions:
      contents: write        # deployed/{env}·v* 태그 push
      pull-requests: read    # 커밋→PR 역산·PR 본문 조회. 빠지면 403 으로 릴리즈 노트 0통
      id-token: write
    needs: [prepare, argocd-sync]
    if: always()
    uses: willog-platform/willog-actions/.github/workflows/deploy-notify.yml@v1
    with:
      phase: result
      service_name: rule-engine
      environment: ${{ inputs.environment }}
      apps: ${{ inputs.apps }}
      image_tag: ${{ needs.prepare.outputs.image_tag }}
      deploy_status: ${{ needs.argocd-sync.result }}
      dev_channel_id: C02NXP88NP8
      release_channel_dev:   C0XXXXXXXXX        # #deploy_summary_dev
      release_channel_stage: C0YYYYYYYYY        # #deploy_summary_stage
      release_channel_prod:  C0ZZZZZZZZZ        # #deploy_summary_prod
      release_envs: dev,stage,prod              # 생략 시 stage,prod
      migration_glob: 'src/main/resources/db/migration/V*.sql'
      api_path_glob: 'src/main/kotlin/**/*Controller.kt'
    secrets:
      # ⚠️ 이 주석을 그대로 복사하지 말 것. 위 notify-start 의 secrets 4줄을
      #    똑같이 적어야 한다. `secrets:` 아래가 비면 SLACK_NOTIFICATION_TOKEN
      #    (required) 이 전달되지 않아 호출이 실패한다.
      SLACK_NOTIFICATION_TOKEN: ${{ secrets.SLACK_NOTIFICATION_TOKEN }}
      ARGOCD_SERVER_DEV:        ${{ secrets.ARGOCD_SERVER_DEV }}
      ARGOCD_SERVER_STAGE:      ${{ secrets.ARGOCD_SERVER_STAGE }}
      ARGOCD_SERVER_PROD:       ${{ secrets.ARGOCD_SERVER_PROD }}
```

### service_name — 짐작하면 링크가 죽는다

`service_name` 은 **그 repo의 기존 `env.SERVICE_NAME` 과 정확히 같아야 한다.**
Slack 메시지의 ArgoCD 링크가 `applications/argocd/{service_name}-{environment}`
로 만들어지기 때문이다(기존 워크플로도 같은 규칙을 썼다). 값이 다르면 알림은
정상적으로 가지만 **ArgoCD 링크만 조용히 죽는다.**

값의 형태는 repo마다 통일되어 있지 않다. 짧은 이름으로 짐작하면 틀린다.

| repo | `service_name` |
|---|---|
| `willog-rule-engine` | `rule-engine` |
| `willog-vision-api` | `willog-vision-api` ← 전체 이름. `values.yaml` 의 project·imagePrefix 와 묶여 있다 |
| `willog-telemetry-api` | `telemetry-api` |
| `willog-member-api` | `member-api` |

확인 방법: `grep SERVICE_NAME .github/workflows/deploy.yaml`

### repo별 glob

| repo | `migration_glob` | `api_path_glob` |
|---|---|---|
| `willog-rule-engine` | `src/main/resources/db/migration/V*.sql` | `src/main/kotlin/**/*Controller.kt` |
| `willog-vision-api` | `infra/database/src/main/resources/db/migration/V*.sql` | `apps/*/src/main/kotlin/**/*Controller.kt` |
| `willog-telemetry-api` | `libs/database/src/*/migrations/Migration*.ts` | `apps/*/src/**/*.controller.ts` |
| `willog-member-api` | `libs/database/src/*/migrations/Migration*.ts` | `apps/*/src/**/*.controller.ts` |
| `willog-vision-web` | `none` ← 마이그레이션 없음(프론트엔드) | (미지정) |

`migration_glob` 은 릴리즈 경로에서 필수다. 기본값을 두지 않는 이유는, 지정을
잊었을 때 마이그레이션이 있는데 없다고 조용히 보고하는 것이 최악이기 때문이다. 그래서
마이그레이션이 **정말로 없는** repo 는 `none` 이라고 **명시**한다 — 빈 값(설정을
잊음)과 `none`(없다고 선언함)은 다르게 다뤄지고, 후자만 통과한다.
새 repo를 붙일 때는 위 표를 짐작으로 채우지 말고 실측한다:

```bash
git ls-files | grep -E 'migration'      # 마이그레이션 실물 위치 확인
git ls-files | grep -E 'Controller|controller'
```

(실제로 이 표의 Node 두 행이 한 번 틀렸다. `apps/cli/src/migration/` 은
마이그레이션 **실행 커맨드**만 담고 마이그레이션 파일은 0개다.)

### input 전체 명세

| input | 타입 | 필수 | 기본값 | 설명 |
|---|---|---|---|---|
| `phase` | string | ✓ | — | `start` \| `result` |
| `service_name` | string | ✓ | — | 위 절 참고. 기존 `env.SERVICE_NAME` 과 일치시킨다 |
| `environment` | string | ✓ | — | `dev` \| `stage` \| `prod` |
| `dev_channel_id` | string | ✓ | — | 개발용 Slack 채널. 시작·실패·dev 배포가 여기로 간다 |
| `apps` | string | | `""` | 빌드 대상 (표시용) |
| `image_tag` | string | `result` 시 | `""` | 배포된 이미지 태그 |
| `deploy_status` | string | `result` 시 | `""` | `success` \| `failure` \| `cancelled` |
| `release_channel_id` | string | | `""` | 환경별 채널을 쓰지 않는 환경의 릴리즈 노트 채널(공용 폴백). **환경별 값과 둘 다 비우면 릴리즈 노트가 dev 채널로 간다** |
| `release_channel_dev` / `_stage` / `_prod` | string | | `""` | 환경별 릴리즈 노트 채널. 해당 환경에서 `release_channel_id` 를 **이긴다**. 비운 환경만 공용 값으로 떨어진다 |
| `release_envs` | string | | `stage,prod` | 릴리즈 노트 형식을 쓰는 환경(쉼표 구분). dev 배포도 릴리즈 채널에 보이게 하려면 `dev,stage,prod`. prod 의 v* 태그·Release 는 목록과 무관하게 prod 에서만 |
| `migration_glob` | string | 릴리즈 경로 필수 | `""` | 위 표 참고. 릴리즈 경로에서 빈 값이면 크게 실패한다. 마이그레이션이 없는 repo(프론트엔드 등)는 `none` 으로 명시 |
| `api_path_glob` | string | | `""` | 컨트롤러 경로. 미지정 시 API 표면 감지를 건너뛴다 |
| `api_exclude_glob` | string | | `**/*.spec.ts,**/*Test.kt,**/test/**` | API 감지에서 제외할 경로 |
| `version_bump` | string | | `auto` | `auto` \| `patch` \| `minor` \| `major`. `auto` 는 PR 라벨에서 산출 |
| `max_commits` | string | | `100` | PR 역산 시 순회할 커밋 상한 |

secrets

| secret | 필수 | 용도 |
|---|---|---|
| `SLACK_NOTIFICATION_TOKEN` | ✓ | 봇 토큰 (`chat:write`) |
| `ARGOCD_SERVER_DEV` / `_STAGE` / `_PROD` | | ArgoCD 링크용 **호스트명**. 없으면 링크를 생략하고 경고한다 |

`ARGOCD_TOKEN_*` 은 전달하지 않는다 — 알림은 URL만 필요하고 ArgoCD API를
호출하지 않는다.

### 선행 작업

0. **이 repo(`willog-actions`)의 가시성 결정이 먼저다.** `Checkout willog-actions`
   스텝(`deploy-notify.yml`)에는 `token:` 이 없어 **호출 측 repo 에 스코프된
   `github.token`** 을 쓴다. 이 토큰은 `willog-actions` 가 **private** 이면
   그 repo를 읽지 못한다. 아래 1번의 Access 설정은 reusable workflow *호출*
   권한만 다루고 `actions/checkout` 권한과는 별개다. 셋 중 하나를 택한다:
   - `willog-actions` 를 **public** 으로 둔다 (가장 단순), 또는
   - 스크립트를 `actions/checkout` 대신 **composite action** 으로 소비한다
     (private repo의 *action* 참조는 위 Access 설정으로 커버된다), 또는
   - `contents: read` 권한이 있는 토큰을 별도로 발급해 넘긴다.

   고르지 않고 넘어가면, `willog-actions` 가 private일 경우 **첫 dev 배포부터
   알림이 0통** 나가고 `Repository not found` 에러가 남는다 — 경로 오타처럼
   보이지만 원인은 가시성이다. 이 결정은 보류 중이며 사람이 확정해야 한다.
1. **이 repo의 Settings → Actions → General → Access** 를
   `Accessible from repositories in the willog-platform organization` 으로 설정.
   빠뜨리면 호출 측이 `workflow was not found` 로 실패하는데, 메시지가 경로
   오타로 오독된다. **확인 방법:** 서비스 repo 하나에서 `@v1` 대신
   `@<현재 sha>` 로 고정한 dev 배포를 1회 디스패치하고, 그 잡 로그에
   `workflow was not found` 가 나오지 않는지 확인한다.
2. **릴리즈 전용 Slack 채널을 만들고 알림 봇을 초대**한 뒤 채널 ID를 확보해
   `release_channel_{dev,stage,prod}` 에 넣는다(환경을 한 채널로 모을 때는
   `release_channel_id` 하나만 써도 된다). 환경을 채널로 가를 때는 **채널마다
   따로 초대**해야 한다 — 한 채널에만 초대하고 나머지를 빠뜨리면 그 환경의
   릴리즈 노트만 `not_in_channel` 로 실패한다. 초대할 앱은 조직에서 기존 배포 알림을
   보내던 그 Slack 앱(봇) **`Willog Notification`** 이며(`#cicd` 의 발신자,
   `SLACK_NOTIFICATION_TOKEN` 의 주인), `chat:write` 스코프가 있어야 한다. 봇 초대를
   빠뜨리면 `not_in_channel` 로 **첫 릴리즈 노트부터** 실패한다. 이 단계를
   건너뛰면 릴리즈 노트가 **조용히 dev 채널로** 간다.
3. `bash scripts/bootstrap-labels.sh willog-platform/<repo>` 로 라벨 생성.
   `breaking`/`feature`/`fix` 는 semver 증가를 결정한다 — **없으면 모든 릴리즈가
   patch 증가가 되어 버전이 무의미해진다.** 재실행해도 안전하다(`--force`).
   중간 repo 에서 실패하면 그 뒤 repo 는 처리되지 않으므로, 원인을 고친 뒤
   **같은 목록으로 다시 실행**한다.
4. `templates/pull_request_template.md` 를 각 repo `.github/` 에 복사.
   템플릿이 없으면 요약이 PR 제목 폴백으로만 동작한다(정상 동작이지만
   비개발 독자에게 전달되는 정보가 줄어든다).
5. 호출 repo의 `notify-start`/`notify-result` 두 job에 위 "사용법" 예시와 같이
   `permissions:` (`contents: write`, `id-token: write`) 를 **job 레벨로** 추가한다.
   워크플로 최상위 `permissions` 는 올리지 않는다 — 두 알림 job이 이제 자기
   권한을 완전히 선언하므로, 호출 측 파일에 이미 있는 repo 고유
   `permissions` 항목(예: 다른 job이 쓰는 별도 스코프)을 최상위에서 병합하다가
   지우는 실수를 겪지 않는다.
