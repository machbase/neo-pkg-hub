# neo-pkg-hub

machbase-neo 패키지 메타데이터 허브.

`packages.yaml`에 등록된 각 패키지의 GitHub 메타데이터(저장소 정보 + 릴리스)를 매일 00:00 UTC에 자동 수집하여 `packages.json`으로 발행합니다. neo-web 등 클라이언트는 이 정적 파일을 raw URL로 조회하고, 문서는 각 항목의 `docs` URL로 직접 가져옵니다.

각 패키지는 **버전별 최소 서버 버전(minServer)** 을 담은 `versions[]` 이력을 가집니다(이슈 machbase/neo#1369). `packages.json`은 이 이력의 **비파괴 누산기**이며, 발행 전 검증 게이트(형식/완전성/monotonic)를 통과해야 합니다. 자세한 내용은 [버전 이력 & minServer](#버전-이력--minserver-versions) 참고.

## 구조

```
.
├── packages.yaml              # 패키지 목록 (수동 관리)
├── packages.json              # 일반 패키지만 — 레거시 뷰 (비파괴 누산기, 자동 갱신)
├── packages-all.json          # 전체 + experiment 플래그 (같은 스키마, 항목 없으면 [])
├── package.json               # validator 의존성 (semver)
├── scripts/
│   ├── sync.sh                # sync 로직 (bash + curl + jq + yq)
│   └── lib/validate.js        # packages.json 검증 게이트 (node + semver)
└── .github/workflows/
    └── sync.yml               # packages.yaml 검증 → sync → validate → commit
```

## 패키지 추가

`packages.yaml`에 항목 추가 후 PR/커밋:

```yaml
packages:
  - name: neo-pkg-replication
    organization: machbase
    repo: neo-pkg-replication
    docs: neo-pkg-replication/docs/index.en.md   # 선택: 문서 경로 (저장소 루트 기준)
    icon: https://example.com/custom.png         # 선택: 아이콘 URL override
    experiment: false                            # 필수: 카탈로그 노출 게이트
```

다음 sync 실행 시 자동으로 `packages.json`이 갱신됩니다. `packages.yaml`을 main에 push하면 cron을 기다리지 않고 즉시 sync가 돕니다.

> ⚠️ 등록 대상 저장소는 **public이어야 합니다.** `packages.json`은 인증 없는 브라우저가 직접 fetch하는 정적 파일이고, sync가 쓰는 Actions `GITHUB_TOKEN`은 이 저장소에만 스코프되므로 private 저장소는 조회 자체가 404가 됩니다. `docs`/`icon` raw URL도 동일하게 404가 되고, 릴리스 asset도 받을 수 없어 설치가 실패합니다. 아직 공개할 수 없는 패키지는 등록을 미루세요 — `experiment: true`는 public 저장소를 카탈로그에서 가리는 수단이지, private 저장소를 등록하는 수단이 아닙니다. 이미 등록된 저장소가 나중에 private으로 바뀐 경우의 동작은 [저장소를 읽을 수 없을 때](#저장소를-읽을-수-없을-때)를 참고하세요.

## 필드

- **docs**: 저장소 내 문서 파일 경로. 지정 시 `https://raw.githubusercontent.com/{full_name}/{default_branch}/{path}` 형태로 변환되어 출력됩니다. 미지정 시 `null`.
- **icon**: 각 패키지 저장소 루트에 `icon.svg` 또는 `icon.png`를 두면 자동 감지됩니다 (sync 시 HEAD 요청으로 `svg` → `png` 순 확인). 둘 다 없으면 `null`. 다른 경로/파일명을 쓰려면 `icon` 필드에 전체 URL로 override.
- **version / released_at**: GitHub `releases/latest` API에서 `tag_name`과 `published_at`을 가져와 채웁니다. 릴리스가 없으면 `null`.
- **homepage**: GitHub 저장소 메타데이터의 `homepage` 값.
- **experiment**: **전 패키지 필수, boolean.** `true`면 neo 서버 experiment 모드가 켜진 사용자에게만 neo-web 카탈로그에 노출됩니다. `false`면 항상 노출 (이슈 machbase/neo#1438). 자세한 내용은 [experiment 게이트](#experiment-게이트) 참고.

클라이언트는 `icon`/`docs`가 `null`이거나 로드 실패 시 fallback 처리하세요.

## experiment 게이트

검증이 끝나지 않은 패키지가 hub 등록과 동시에 모든 사용자에게 노출되는 것을 막기 위한 장치입니다.

| 패키지 `experiment` | 서버 experiment 모드 | 카탈로그 노출 |
| --- | --- | --- |
| `true` | ON | 표시 |
| `true` | OFF | 숨김 (단, 이미 설치된 패키지는 표시) |
| `false` | ON / OFF | 표시 |

### 왜 파일을 두 개 내는가

| 파일 | 내용 | 소비자 |
| --- | --- | --- |
| `packages.json` | `experiment: false` 패키지만 — **레거시 뷰** | 구버전 neo-web |
| `packages-all.json` | **전체** (각 엔트리에 `experiment` 플래그) | experiment 지원 neo-web |

일반 패키지는 **두 파일에 중복 존재**합니다. 그 중복이 의도된 설계이고, 두 가지를 얻습니다.

**1. 레거시 안전성.** 한 파일에 `experiment` 필드만 넣는 방식은 구버전 neo-web에 대해 **fail-open**입니다. 클라이언트는 받은 파일을 그대로 렌더링하므로 모르는 필드로는 아무것도 숨길 수 없습니다. 구버전은 `packages.json`만 fetch하므로 **거기에 엔트리를 넣지 않는 것만이 실제로 숨기는 유일한 수단**입니다.

**2. 원자성.** 현재 neo-web은 `packages-all.json` **하나만** 읽으므로 독립적으로 캐시된 두 응답을 맞춰볼 일이 없습니다. 데이터를 "일반은 여기, experiment는 저기"로 쪼개면, 전환 중인 패키지가 `raw.githubusercontent`의 `max-age=300` 동안 양쪽에 다 있거나 양쪽에 다 없는 상태가 되어 카드가 중복되거나 사라집니다.

```ts
const all = await fetchPkgHubList(PKG_HUB_ALL_URL);
const visible = all.filter((p) => !p.experiment || experimentOn || p.installed_frontend);
```

`installed_frontend` 예외가 필요한 이유는, 그게 없으면 experiment 모드에서 설치한 패키지가 모드를 끄는 순간 목록에서 사라져 **uninstall 경로까지 없어지기** 때문입니다. 다만 이렇게 유예 노출된 카드는 uninstall·stop만 허용하고 **설치 버튼과 업데이트 배지는 억제**해야 합니다 — 재검증하려고 회수한 패키지의 미검증 신규 버전을 일반 사용자에게 권하게 되기 때문입니다.

두 파일 모두 해당 패키지가 없어도 **항상 `[]`로 발행됩니다.** neo-web이 non-ok 응답을 에러로 처리하므로 파일이 없으면 카탈로그 전체가 깨집니다.

### 원천과 검증

**`packages.yaml`이 유일한 원천입니다.** 발행 파일 두 개 모두 sync가 매번 전량 재생성하는 산출물이라, 여기에 직접 `experiment`를 써넣거나 엔트리를 옮기면 **다음 sync에서 조용히 되돌아갑니다** — `minServer`의 수동 백필이 carry-forward되는 것과 다르니 혼동하지 마세요.

패키지가 experiment를 졸업하면 `packages.yaml`에서 `experiment: false`로 바꾸기만 하면 됩니다. sync가 `packages.json`에도 엔트리를 내보내기 시작하며, `versions[]` 이력과 `icon`은 accumulator가 두 파일을 함께 읽으므로 플래그를 어느 방향으로 뒤집어도 유실되지 않습니다. 반대로 `true`로 되돌리면 `packages.json`에서만 빠집니다.

CI 게이트 (`sync.yml`의 `validate-yaml` job, PR·push·cron 모두에서 실행):

- **키 필수**: 키를 빠뜨리면 실패. 키 오타(`experment:`)가 "누락"으로 드러나 잡히도록 하는 장치입니다.
- **boolean 필수**: `yes` / `"false"` / `1` / 빈 값 모두 실패. 전부 조용히 falsy로 처리되어 미검증 패키지를 노출시킬 수 있기 때문입니다.

주의할 점:

- **접근 제어가 아닙니다.** neo-web 클라이언트 측 필터일 뿐이라 이름을 아는 사용자는 API로 직접 설치할 수 있습니다.
- **긴급 차단 수단이 아닙니다.** 발행 후에도 `raw.githubusercontent.com`의 `max-age=300` 때문에 최대 5분 지연됩니다.
- `experiment: true` 패키지는 아직 릴리스가 없을 수 있으므로, validator의 빈 `versions[]` 검사가 error 대신 warn으로 완화됩니다 (비-experiment 패키지는 그대로 hard error).

## 출력 스키마

`packages.json`:

```json
[
  {
    "name": "neo-pkg-replication",
    "description": "Data replication tool",
    "version": "1.0.0",
    "icon": "https://raw.githubusercontent.com/machbase/neo-pkg-replication/main/icon.png",
    "docs": "https://raw.githubusercontent.com/machbase/neo-pkg-replication/main/docs/index.en.md",
    "homepage": "http://docs.machbase.com",
    "experiment": false,
    "github": {
      "organization": "machbase",
      "repo": "neo-pkg-replication",
      "full_name": "machbase/neo-pkg-replication",
      "html_url": "https://github.com/machbase/neo-pkg-replication",
      "default_branch": "main",
      "language": "HTML",
      "license": null,
      "stargazers_count": 1,
      "forks_count": 0
    },
    "released_at": "2026-05-28T04:36:20Z",
    "versions": [
      { "version": "1.0.4", "minServer": "8.5.4", "released_at": "2026-05-28T04:36:20Z" },
      { "version": "1.0.0", "minServer": "8.5.0", "released_at": "2026-04-28T02:10:13Z" }
    ]
  }
]
```

> 최상위 `version`/`released_at`은 `versions[0]`(최신)의 **미러**입니다 — `versions[]`를 모르는 구버전 클라이언트 하위호환용. 이 미러는 절대 제거하지 마세요(제거 시 구 neo-web에서 설치가 release 태그 대신 HEAD로 빠짐).

## 버전 이력 & minServer (versions[])

각 패키지 엔트리의 `versions[]`는 **최신 우선** 정렬된 버전 이력입니다. 행 스키마:

| 필드 | 설명 |
| --- | --- |
| `version` | 릴리스 태그명 (`1.0.4`, `v1.0.9` 등) |
| `minServer` | 이 버전이 요구하는 **최소 machbase-neo 서버 버전** (leading `v` 없는 plain semver, 예 `8.5.4`) |
| `released_at` | 릴리스 시각 (ISO8601) |

**minServer 출처 / 관리**

- **자동(latest)**: 새 릴리스 발견 시 `sync.sh`가 그 **릴리스 태그 시점의 `package.json`** `minServerVersion`을 읽어 채웁니다 (`GET /repos/.../contents/package.json?ref=<tag>`). 패키지에 `minServerVersion`이 없으면 비워두며 validator가 경고/실패로 표시 → 수동 백필.
- **비파괴 누산**: `sync.sh`는 기존 `packages.json`을 읽어 **새 버전만 prepend**하고 기존 행은 그대로 carry-forward합니다. 한 번 확정된 `minServer`는 daily sync로 덮어쓰이지 않습니다.
- **수동 백필**: 시스템 도입 이전 과거 릴리스의 `minServer`는 `packages.json`을 직접 편집해 채웁니다.

**보장 범위**

sync는 매 실행마다 각 저장소의 `releases/latest` **하나만** 관찰하고, 관찰한 것을 비파괴 누적합니다. 따라서 아래는 기록되지 않습니다.

- 한 sync 주기(24h) 안에 두 번 이상 릴리스한 경우, 마지막 것을 제외한 나머지
- 저장소가 private이거나 `packages.yaml`에서 빠져 있는 동안 나온 릴리스

hub는 누락된 버전을 소급 복원하지 않습니다. **이력의 연속성은 각 패키지 저장소의 책임입니다** — 릴리스는 sync 주기당 하나로, 저장소는 public으로 유지하세요. 다만 누락은 "들어오지 않은" 것이지 "지워진" 것이 아닙니다. 한 번 발행된 행은 그대로 남습니다.

**검증 게이트** (`scripts/lib/validate.js`, sync 후 commit 전 실행):

- **형식**: 모든 `version`/`minServer`가 유효 semver.
- **완전성**: 모든 행에 `minServer` 존재 — 기본 경고, `STRICT_MIN_SERVER=1`이면 하드 실패(모든 패키지가 `minServerVersion`을 갖추면 strict로 전환).
- **monotonic**: 패키지 내에서 버전이 높을수록 `minServer`가 낮아지지 않음.
- comparator는 neo-web 런타임과 동일한 `semver`(prerelease 포함)를 사용합니다.

로컬 검증: `npm install && npm run validate` (또는 `node scripts/lib/validate.js packages.json`).

## 클라이언트 접근

메타데이터:

```
https://raw.githubusercontent.com/<owner>/neo-pkg-hub/main/packages.json       # 레거시 뷰
https://raw.githubusercontent.com/<owner>/neo-pkg-hub/main/packages-all.json   # 전체
```

두 파일은 **엔트리 스키마가 동일**하므로 같은 파서를 재사용하면 됩니다. experiment 게이트를 지원하는 클라이언트는 `packages-all.json` **하나만** 받아 로컬에서 필터하세요 — 두 파일을 병합하면 캐시 만료 시점이 어긋나 전환 중인 패키지가 중복되거나 사라집니다. 게이트를 지원하지 않는 클라이언트는 `packages.json`만 사용하세요.

각 패키지의 문서/아이콘은 각 엔트리의 `docs`, `icon` URL을 그대로 사용하면 됩니다.

## Sync 실행

- **자동(정기)**: 매일 00:00 UTC (09:00 KST) — `validate-yaml` → sync → `validate.js`(실패 시 push 안 함) → commit
- **자동(즉시)**: `packages.yaml`이 main에 push되면 바로 실행. 봇 커밋은 `packages.json`만 건드리고 `[skip ci]`가 붙으므로 루프하지 않음
- **PR**: `packages.yaml`을 변경하는 PR은 `validate-yaml`만 실행 (packages.json 재생성·push 없음)
- **수동**: GitHub Actions → `sync packages` → Run workflow
- **로컬**: `yq`, `jq`, `node` 설치 후 `npm install && bash scripts/sync.sh && npm run validate` (필요 시 `GITHUB_TOKEN` 환경변수 설정)

## 저장소를 읽을 수 없을 때

등록된 저장소가 private으로 바뀌거나, 삭제·이름 변경되거나, GitHub 장애가 재시도(3회)를 넘겨 지속되면 sync는 **그 패키지의 갱신만 건너뛰고 직전 엔트리를 그대로 다시 발행**합니다. 나머지 패키지는 정상 갱신됩니다. 하나가 막혀 전체 발행이 멈추는 일은 없습니다.

- **hub는 스스로 항목을 지우지 않습니다.** 카탈로그에서 실제로 내리려면 `packages.yaml`에서 항목을 제거하세요.
- 404(private/삭제)와 5xx(장애)를 **구분하지 않습니다.** 어느 쪽이든 동작이 "이전 값 유지"로 같기 때문입니다.
- `experiment` 플래그만은 `packages.yaml` 값으로 다시 적용됩니다 — 저장소를 못 읽어도 게이트의 source of truth는 yaml입니다.
- 한 번도 발행된 적 없는 패키지(신규 등록 시 오타, 처음부터 private)는 되살릴 엔트리가 없으므로 그냥 빠집니다.
- skip이 하나라도 있으면 `sync.sh`는 `exit 2`로 끝나고, 워크플로는 **발행·commit·push를 모두 마친 뒤 마지막에 job을 실패**시킵니다. 조치할 때까지 매일 red가 뜹니다.

이 동안 카탈로그에는 카드가 남지만 icon·docs·릴리스 asset이 전부 404라 **깨진 카드**로 보입니다. 의도된 trade-off입니다 — 일시 장애를 삭제로 오판해 멀쩡한 패키지를 카탈로그에서 지우는 것보다 낫습니다.
