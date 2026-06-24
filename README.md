# neo-pkg-hub

machbase-neo 패키지 메타데이터 허브.

`packages.yaml`에 등록된 각 패키지의 GitHub 메타데이터(저장소 정보 + 릴리스)를 매일 00:00 UTC에 자동 수집하여 `packages.json`으로 발행합니다. neo-web 등 클라이언트는 이 정적 파일을 raw URL로 조회하고, 문서는 각 항목의 `docs` URL로 직접 가져옵니다.

각 패키지는 **버전별 최소 서버 버전(minServer)** 을 담은 `versions[]` 이력을 가집니다(이슈 machbase/neo#1369). `packages.json`은 이 이력의 **비파괴 누산기**이며, 발행 전 검증 게이트(형식/완전성/monotonic)를 통과해야 합니다. 자세한 내용은 [버전 이력 & minServer](#버전-이력--minserver-versions) 참고.

## 구조

```
.
├── packages.yaml              # 패키지 목록 (수동 관리)
├── packages.json              # 전체 메타데이터 + 버전 이력 (비파괴 누산기, 자동 갱신)
├── package.json               # validator 의존성 (semver)
├── scripts/
│   ├── sync.sh                # sync 로직 (bash + curl + jq + yq)
│   └── lib/validate.js        # packages.json 검증 게이트 (node + semver)
└── .github/workflows/
    └── sync.yml               # 자정 UTC 자동 sync → validate → commit
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
```

다음 sync 실행 시 자동으로 `packages.json`이 갱신됩니다.

## 필드

- **docs**: 저장소 내 문서 파일 경로. 지정 시 `https://raw.githubusercontent.com/{full_name}/{default_branch}/{path}` 형태로 변환되어 출력됩니다. 미지정 시 `null`.
- **icon**: 각 패키지 저장소 루트에 `icon.svg` 또는 `icon.png`를 두면 자동 감지됩니다 (sync 시 HEAD 요청으로 `svg` → `png` 순 확인). 둘 다 없으면 `null`. 다른 경로/파일명을 쓰려면 `icon` 필드에 전체 URL로 override.
- **version / released_at**: GitHub `releases/latest` API에서 `tag_name`과 `published_at`을 가져와 채웁니다. 릴리스가 없으면 `null`.
- **homepage**: GitHub 저장소 메타데이터의 `homepage` 값.

클라이언트는 `icon`/`docs`가 `null`이거나 로드 실패 시 fallback 처리하세요.

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

**검증 게이트** (`scripts/lib/validate.js`, sync 후 commit 전 실행):

- **형식**: 모든 `version`/`minServer`가 유효 semver.
- **완전성**: 모든 행에 `minServer` 존재 — 기본 경고, `STRICT_MIN_SERVER=1`이면 하드 실패(모든 패키지가 `minServerVersion`을 갖추면 strict로 전환).
- **monotonic**: 패키지 내에서 버전이 높을수록 `minServer`가 낮아지지 않음.
- comparator는 neo-web 런타임과 동일한 `semver`(prerelease 포함)를 사용합니다.

로컬 검증: `npm install && npm run validate` (또는 `node scripts/lib/validate.js packages.json`).

## 클라이언트 접근

메타데이터:

```
https://raw.githubusercontent.com/<owner>/neo-pkg-hub/main/packages.json
```

각 패키지의 문서/아이콘은 `packages.json`의 `docs`, `icon` URL을 그대로 사용하면 됩니다.

## Sync 실행

- **자동**: 매일 00:00 UTC (09:00 KST) — sync → `validate.js`(실패 시 push 안 함) → commit
- **수동**: GitHub Actions → `sync packages` → Run workflow
- **로컬**: `yq`, `jq`, `node` 설치 후 `npm install && bash scripts/sync.sh && npm run validate` (필요 시 `GITHUB_TOKEN` 환경변수 설정)
