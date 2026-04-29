# neo-pkg-hub

machbase-neo 패키지 메타데이터 허브.

`packages.yaml`에 등록된 각 패키지의 GitHub 메타데이터(저장소 정보 + 최신 릴리스)를 매일 00:00 UTC에 자동 수집하여 `packages.json`으로 발행합니다. neo-web 등 클라이언트는 이 정적 파일을 raw URL로 조회하고, 문서는 각 항목의 `docs` URL로 직접 가져옵니다.

## 구조

```
.
├── packages.yaml              # 패키지 목록 (수동 관리)
├── packages.json              # 전체 메타데이터 (자동 생성)
├── scripts/
│   └── sync.sh                # sync 로직 (bash + curl + jq + yq)
└── .github/workflows/
    └── sync.yml               # 자정 UTC 자동 sync + 수동 트리거
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
    "released_at": "2026-04-28T02:10:13Z"
  }
]
```

## 클라이언트 접근

메타데이터:

```
https://raw.githubusercontent.com/<owner>/neo-pkg-hub/main/packages.json
```

각 패키지의 문서/아이콘은 `packages.json`의 `docs`, `icon` URL을 그대로 사용하면 됩니다.

## Sync 실행

- **자동**: 매일 00:00 UTC (09:00 KST)
- **수동**: GitHub Actions → `sync packages` → Run workflow
- **로컬**: `yq`, `jq` 설치 후 `bash scripts/sync.sh` (필요 시 `GITHUB_TOKEN` 환경변수 설정)
