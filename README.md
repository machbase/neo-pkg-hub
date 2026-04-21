# neo-pkg-hub

machbase-neo 패키지 메타데이터 및 README 허브.

`packages.yaml`에 등록된 각 패키지의 GitHub 메타데이터를 매일 00:00 UTC에 자동 수집하여 `packages.json`으로 발행합니다. neo-web 등 클라이언트는 이 정적 파일을 raw URL로 조회하고, README는 `packages.json`의 `full_name`과 `default_branch`를 조합해 원본 저장소에서 직접 가져옵니다.

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
  - name: neo-cat
    organization: machbase
    repo: neo-cat
```

다음 sync 실행 시 자동으로 `packages.json`이 갱신됩니다.

## 출력 스키마

`packages.json`:

```json
[
  {
    "name": "neo-cat",
    "description": "machbase neo's watchcat",
    "github": {
      "organization": "machbase",
      "repo": "neo-cat",
      "full_name": "machbase/neo-cat",
      "html_url": "https://github.com/machbase/neo-cat",
      "default_branch": "main",
      "language": "TypeScript",
      "license": "Apache-2.0",
      "stargazers_count": 0,
      "forks_count": 0
    },
    "pushed_at": "2025-02-25T00:04:43Z"
  }
]
```

## 클라이언트 접근

메타데이터:

```
https://raw.githubusercontent.com/<owner>/neo-pkg-hub/main/packages.json
```

README는 `packages.json`의 각 항목에서 URL을 조합:

```
https://raw.githubusercontent.com/{github.full_name}/{github.default_branch}/README.md
```

예) `https://raw.githubusercontent.com/machbase/neo-cat/main/README.md`

## Sync 실행

- **자동**: 매일 00:00 UTC (09:00 KST)
- **수동**: GitHub Actions → `sync packages` → Run workflow
- **로컬**: `yq`, `jq` 설치 후 `bash scripts/sync.sh` (필요 시 `GITHUB_TOKEN` 환경변수 설정)
