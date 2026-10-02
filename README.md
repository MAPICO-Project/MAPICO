# MAFICO · 마피코

옷장 등록, 날씨·추구미 기반 코디 추천, OOTD, 소셜 피드와 Styling Mimic을 제공하는 모바일 웹 프로젝트입니다.

이 저장소는 백엔드·프론트엔드·AI·제품 문서를 함께 관리하는 모노레포입니다. 각 파트는 담당 폴더에서 작업하고, 파트 간 계약 변경은 같은 Pull Request에서 함께 검토합니다.

## 저장소 구조

| 경로 | 담당 범위 | 현재 상태 |
|---|---|---|
| [`backend/`](backend/) | HTTP API, Supabase SQL/RLS/Storage, 계약 테스트, Vercel 설정 | OpenAPI 50개 중 49개 로컬 구현 |
| [`apps/`](apps/) | 프론트엔드 앱과 UI 프리뷰 | `frontend-preview`는 fixture 기반 임시 UI |
| [`apps/api-docs/`](apps/api-docs/) | 팀 공유 Swagger UI | OpenAPI 정본과 hash 동기화 |
| [`ai/`](ai/) | 분석·따라입기 워커와 모델 연동 | 계약 정리 단계, 실제 워커 미배포 |
| [`deliverables/`](deliverables/) | PRD, API/DB/디자인 공식 산출물 | 제품·기술 정본 |
| [`records/`](records/) | 회의와 확정 결정 | 변경 이력 보존 |
| [`worklogs/`](worklogs/) | 작업 계획·검증·결과 | 실행 근거 |
| [`references/`](references/) | 과거 문서와 참고자료 | 현재 정본으로 사용하지 않음 |

모델 가중치, 원본 데이터, 생성 산출물은 Git에 올리지 않습니다. `models/`, `data/`, `artifacts/`에는 추적용 `.gitkeep`만 둡니다.

## 빠른 시작

백엔드 검증:

```sh
cd backend
npm ci --ignore-scripts
npm test
npm run test:schema
npm run coverage:contract
npm run seed:validate
```

프론트엔드 프리뷰:

```sh
cd apps/frontend-preview
npm install
npm test
```

파트별 상세 설정은 [백엔드 README](backend/README.md), [프론트엔드 안내](apps/README.md), [AI 안내](ai/README.md)를 따릅니다.

API 문서는 `apps/api-docs`에서 `npm start` 후 Swagger UI로 확인할 수 있습니다. 정본 변경 후에는 `npm run sync`와 `npm run sync:check`을 실행합니다.

## 협업 규칙

1. `main`에서 담당 작업 브랜치를 만듭니다. 예: `backend/g9-account-deletion`, `frontend/onboarding`, `ai/analysis-worker`.
2. 커밋은 담당 폴더를 중심으로 작게 나눕니다. Git은 폴더별로 push하는 것이 아니라 브랜치와 커밋을 push합니다.
3. API 또는 DB 계약이 바뀌면 `deliverables/backend/`, `backend/docs/`, 구현과 테스트를 같은 PR에서 갱신합니다.
4. PR에는 실행한 테스트, 미검증 항목, 환경 설정 변경 여부를 적습니다.
5. `.env`, `.vercel`, Supabase 연결 자료, 토큰, 사용자 데이터, 이미지와 모델 가중치는 커밋하지 않습니다.

자세한 에이전트·문서 규칙은 [AGENTS.md](AGENTS.md)를 참고합니다.
팀원 최초 설정과 PR 절차는 [팀 저장소 사용 안내](docs/TEAM_ONBOARDING.md)에 정리되어 있습니다.

## 현재 검증 상태

- 백엔드 단위 테스트: 98/98 통과
- OpenAPI: 36 paths, 50 operations
- 로컬 구현: 49 operations, 계정 삭제 1 operation 계획 상태
- DB: 12 migrations, 24 public tables, 10 SQL assertion 묶음
- 미검증: hosted Supabase Auth/Storage/RLS, 실제 Vercel 환경, AI 워커, 날씨 provider

임시 UI: https://mafico-preview.vercel.app

## 배포 경계

- 백엔드 Vercel 프로젝트의 Root Directory는 `backend`로 설정합니다.
- 프론트엔드는 해당 앱 디렉터리를 별도 Root Directory로 설정합니다.
- Supabase 원격 DB와 비밀값은 저장소 구조 변경으로 자동 이전되지 않습니다.
- 환경변수 이름만 예제 파일에 기록하고 실제 값은 각 배포 환경의 Secret 설정에 둡니다.

GitHub 저장소: https://github.com/MAFICO-Project/mafico
