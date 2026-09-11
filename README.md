# neo-pkg-hub

machbase-neo 패키지 메타데이터 허브.

`packages.yaml`에 등록된 각 패키지의 GitHub 메타데이터(저장소 정보 + 릴리스)를 매일 00:00 UTC에 자동 수집하여 `packages.json`으로 발행합니다. neo-web 등 클라이언트는 이 정적 파일을 raw URL로 조회하고, 문서는 각 항목의 `docs` URL로 직접 가져옵니다.

각 패키지는 **버전별 최소 서버 버전(minServer)** 을 담은 `versions[]` 이력을 가집니다(이슈 machbase/neo#1369). `packages.json`은 이 이력의 **비파괴 누산기**이며, 발행 전 검증 게이트(형식/완전성/monotonic)를 통과해야 합니다. 자세한 내용은 [버전 이력 & minServer](#버전-이력--minserver-versions) 참고.

## 구조

```
.
├── packages.yaml              # 패키지 목록 (수동 관리)
├── packages.json              # 출시 패키지만 — neo-web이 읽는 카탈로그 (비파괴 누산기, 자동 갱신)
├── packages-all.json          # ⚠️ deprecated — 전체 + experiment 플래그, neo-web v8.5.10~v8.7.0 전용 (같은 스키마, 항목 없으면 [])
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
    experiment: false                            # 필수: true면 packages.json(카탈로그)에서 제외
```

다음 sync 실행 시 자동으로 `packages.json`이 갱신됩니다. `packages.yaml`을 main에 push하면 cron을 기다리지 않고 즉시 sync가 돕니다.

> ⚠️ 등록 대상 저장소는 **public이어야 합니다.** `packages.json`은 인증 없는 브라우저가 직접 fetch하는 정적 파일이고, sync가 쓰는 Actions `GITHUB_TOKEN`은 이 저장소에만 스코프되므로 private 저장소는 조회 자체가 404가 됩니다. `docs`/`icon` raw URL도 동일하게 404가 되고, 릴리스 asset도 받을 수 없어 설치가 실패합니다. 아직 공개할 수 없는 패키지는 등록을 미루세요 — `experiment: true`는 public 저장소를 카탈로그에서 가리는 수단이지, private 저장소를 등록하는 수단이 아닙니다. 이미 등록된 저장소가 나중에 private으로 바뀐 경우의 동작은 [저장소를 읽을 수 없을 때](#저장소를-읽을-수-없을-때)를 참고하세요.

## 필드

- **docs**: 저장소 내 문서 파일 경로. 지정 시 `https://raw.githubusercontent.com/{full_name}/{default_branch}/{path}` 형태로 변환되어 출력됩니다. 미지정 시 `null`.
- **icon**: 각 패키지 저장소 루트에 `icon.svg` 또는 `icon.png`를 두면 자동 감지됩니다 (sync 시 HEAD 요청으로 `svg` → `png` 순 확인). 둘 다 없으면 `null`. 다른 경로/파일명을 쓰려면 `icon` 필드에 전체 URL로 override.
- **version / released_at**: GitHub `releases/latest` API에서 `tag_name`과 `published_at`을 가져와 채웁니다. 릴리스가 없으면 `null`.
- **homepage**: GitHub 저장소 메타데이터의 `homepage` 값.
- **experiment**: **전 패키지 필수, boolean.** `true`면 `packages.json`에 싣지 않아 neo-web 카탈로그에 나타나지 않습니다 (deprecated인 `packages-all.json`에는 실림). `false`면 두 파일 모두에 실립니다 (이슈 machbase/neo#1438). 자세한 내용은 [experiment 게이트](#experiment-게이트) 참고.

클라이언트는 `icon`/`docs`가 `null`이거나 로드 실패 시 fallback 처리하세요.

## experiment 게이트

검증이 끝나지 않은 패키지가 hub 등록과 동시에 모든 사용자에게 노출되는 것을 막기 위한 장치입니다. **hub가 하는 일은 `experiment: true` 패키지를 `packages.json`에 싣지 않는 것 하나입니다.**

> ⚠️ **`packages-all.json`은 deprecated입니다.** 이 파일을 읽는 neo-web은 **v8.5.10 ~ v8.7.0**뿐이고, v8.7.0 다음 릴리스부터는 `packages.json`만 읽습니다. 새 클라이언트는 이 파일을 쓰지 마세요. 해당 버전 서버를 지원하는 동안만 발행을 유지하며, 제거 전에 확인할 것은 [`packages-all.json` (deprecated)](#packages-alljson-deprecated)에 있습니다.

### 버전별로 읽는 파일

neo-web은 machbase-neo와 같은 버전 번호로 함께 릴리스됩니다.

| neo-web (= machbase-neo) | 읽는 파일 | `experiment: true` 패키지 |
| --- | --- | --- |
| v8.5.9 이하 | `packages.json` | 카탈로그에 없음 |
| v8.5.10 ~ v8.7.0 | `packages-all.json` (실패하면 `packages.json`) | 서버 experiment 모드 ON일 때만 표시. 이미 설치된 패키지는 OFF여도 표시하되 설치·업데이트는 막음 |
| v8.7.0 다음 릴리스부터 | `packages.json` | 카탈로그에 없음. 서버 `/public/`에 아카이브나 설치본이 있으면 그것으로 카드 표시 |

v8.7.0 다음 릴리스부터는 experiment 플래그를 보지 않습니다. 서버 experiment 모드가 App Store에 주는 영향은 버전 메뉴의 커스텀 버전 입력란 하나뿐입니다.

### 왜 `packages.json`에서 빼는가

클라이언트는 받은 파일을 그대로 렌더링하므로, 한 파일에 `experiment` 필드만 넣는 방식은 그 필드를 모르거나 무시하는 클라이언트에 대해 **fail-open**입니다. `packages.json`에 **엔트리를 넣지 않는 것만이 실제로 숨기는 유일한 수단**이고, 이 원칙은 `packages-all.json`을 제거한 뒤에도 그대로입니다.

`packages.json`은 해당 패키지가 없어도 **항상 `[]`로 발행됩니다.** 구버전 neo-web은 non-ok 응답을 에러로 처리해 카탈로그 전체가 비고, 새 neo-web도 hub 카드를 전부 잃고 오프라인으로 표시됩니다.

### 미출시 패키지를 테스트하려면

v8.7.0 다음 릴리스부터는 `experiment: true` 패키지가 **서버 experiment 모드와 무관하게** 카탈로그에 나오지 않습니다. 테스터에게 배포하려면 패키지 아카이브(GitHub `Download ZIP` 또는 codeload tarball — `.zip` / `.tar` / `.tar.gz` / `.tgz`)를 테스트 서버의 `/public/`에 두세요. neo-web은 서버의 아카이브를 스캔해 루트 `package.json`으로 카드를 만들고, hub와 무관하게 설치·업데이트할 수 있게 합니다. 인터넷이 닿지 않는 서버에 배포하는 방법도 같습니다.

v8.5.10 ~ v8.7.0 서버라면 서버를 experiment 모드로 켜면 카탈로그에 나타납니다.

### `packages-all.json` (deprecated)

neo-web v8.5.10 ~ v8.7.0만 읽는 파일입니다. 모든 패키지를 각 엔트리의 `experiment` 플래그와 함께 싣고(일반 패키지는 `packages.json`과 중복), 클라이언트가 로컬에서 거릅니다. 참고용이며 이후 릴리스에는 없는 로직입니다:

```ts
const all = await fetchPkgHubList(PKG_HUB_ALL_URL);
const visible = all.filter((p) => !p.experiment || experimentOn || p.installed_frontend);
```

`installed_frontend` 예외는 experiment 모드에서 설치한 패키지가 모드를 끄는 순간 목록에서 사라져 uninstall 경로까지 없어지는 것을 막기 위한 것이고, 그렇게 남은 카드에서는 uninstall·stop만 허용하고 설치·업데이트는 억제합니다. 이후 릴리스의 neo-web은 설치본을 서버의 `/public/`에서 직접 읽어 카드를 만들기 때문에 이 예외가 필요 없습니다.

두 파일을 병합하는 클라이언트는 없어야 합니다. 어느 neo-web이든 파일을 **하나만** 읽기 때문에, `raw.githubusercontent`가 두 파일을 따로 캐시(`max-age=300`)해도 전환 중인 패키지가 중복되거나 사라지는 일이 없습니다.

**제거 조건**: v8.5.10 ~ v8.7.0 서버를 더 이상 지원하지 않을 때.

**제거 전에 알아둘 것**

- **구버전 서버는 깨지지 않습니다.** v8.5.10 ~ v8.7.0 neo-web은 `packages-all.json`을 먼저 요청하고 실패하면 `packages.json`으로 넘어갑니다 (v8.5.10·v8.7.0 코드로 확인). 파일이 없어도 카탈로그는 유지되고, 카탈로그를 열 때마다 404가 하나 더 생기며, experiment 모드에서도 미출시 패키지가 보이지 않게 될 뿐입니다.
- **experiment 패키지의 버전 이력이 사라집니다.** `sync.sh`의 누산기는 이전 이력을 `packages-all.json` → `packages.json` 순으로 읽는데, experiment 패키지는 `packages.json`에 없으므로 **그 `versions[]` 이력은 `packages-all.json`에만 있습니다.** 파일을 그냥 없애면 이력이 남을 곳이 없어져, 해당 패키지가 출시되는 시점의 최신 릴리스부터 이력이 다시 쌓입니다. 보존하려면 제거 전에 누산기를 다른 저장소로 옮기세요.
- **`experiment` 필드는 제거 대상이 아닙니다.** 패키지를 `packages.json`에서 빼는 역할은 파일이 하나로 줄어도 그대로 필요합니다.

**절차**: ① 이력 보존 방법 결정 → ② `scripts/sync.sh`에서 `ALL_JSON` 발행과 누산기의 `packages-all.json` 읽기 제거 → ③ 저장소에서 `packages-all.json` 삭제 → ④ 이 절과 위 버전 표의 v8.5.10 ~ v8.7.0 행 삭제.

### 원천과 검증

**`packages.yaml`이 유일한 원천입니다.** 발행 파일 두 개 모두 sync가 매번 전량 재생성하는 산출물이라, 여기에 직접 `experiment`를 써넣거나 엔트리를 옮기면 **다음 sync에서 조용히 되돌아갑니다** — `minServer`의 수동 백필이 carry-forward되는 것과 다르니 혼동하지 마세요.

패키지가 experiment를 졸업하면 `packages.yaml`에서 `experiment: false`로 바꾸기만 하면 됩니다. sync가 `packages.json`에도 엔트리를 내보내기 시작하며, `versions[]` 이력과 `icon`은 accumulator가 두 파일을 함께 읽으므로 플래그를 어느 방향으로 뒤집어도 유실되지 않습니다. 반대로 `true`로 되돌리면 `packages.json`에서만 빠집니다.

CI 게이트 (`sync.yml`의 `validate-yaml` job, PR·push·cron 모두에서 실행):

- **키 필수**: 키를 빠뜨리면 실패. 키 오타(`experment:`)가 "누락"으로 드러나 잡히도록 하는 장치입니다.
- **boolean 필수**: `yes` / `"false"` / `1` / 빈 값 모두 실패. 전부 조용히 falsy로 처리되어 미검증 패키지를 노출시킬 수 있기 때문입니다.

주의할 점:

- **접근 제어가 아닙니다.** 어느 파일에 싣느냐로 카탈로그에서 빠질 뿐, `packages-all.json`은 누구나 받을 수 있고 이름을 아는 사용자는 API나 아카이브로 직접 설치할 수 있습니다.
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
https://raw.githubusercontent.com/<owner>/neo-pkg-hub/main/packages.json       # 카탈로그 (출시 패키지)
https://raw.githubusercontent.com/<owner>/neo-pkg-hub/main/packages-all.json   # ⚠️ deprecated — neo-web v8.5.10~v8.7.0 전용
```

두 파일은 **엔트리 스키마가 동일**하므로 같은 파서를 재사용하면 됩니다. 새 클라이언트는 `packages.json` **하나만** 사용하세요 — 미출시 패키지를 걸러내는 일은 hub가 이미 했습니다. `packages-all.json`은 deprecated이며 [제거 예정](#packages-alljson-deprecated)입니다. 어떤 경우에도 두 파일을 병합하지 마세요. 캐시 만료 시점이 어긋나 전환 중인 패키지가 중복되거나 사라집니다.

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
