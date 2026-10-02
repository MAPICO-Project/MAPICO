# MAFICO 팀 저장소 사용 안내

## 저장소 받기

```sh
git clone https://github.com/MAFICO-Project/mafico.git
cd mafico
```

저장소는 비공개입니다. 팀원은 GitHub 조직 또는 저장소 collaborator 권한이 필요합니다.

## 파트별 위치

| 파트 | 작업 경로 | 먼저 읽을 문서 |
|---|---|---|
| Backend | `backend/` | `backend/README.md` |
| Frontend | `apps/` | `apps/README.md` |
| AI | `ai/` | `ai/README.md` |
| Product/Design | `deliverables/` | `deliverables/README.md` |
| API 탐색 | `apps/api-docs/` | `apps/api-docs/README.md` |

파트 폴더에 별도 `.git`을 만들지 않습니다.

## 브랜치와 PR

```sh
git switch main
git pull --ff-only
git switch -c backend/example-task
```

브랜치 예시는 `backend/*`, `frontend/*`, `ai/*`, `docs/*`입니다. 커밋은 담당 경로 중심으로 만들고 GitHub에 push한 뒤 Pull Request를 엽니다. API 계약을 변경하는 PR은 OpenAPI, 구현, 테스트, 관련 문서를 같이 수정합니다.

## 백엔드 검증

```sh
cd backend
npm ci --ignore-scripts
npm test
npm run test:schema
npm run coverage:contract
npm run seed:validate
```

현재 OpenAPI에는 50개 제품 operation이 있고 49개가 로컬 구현됐습니다. `requestAccountDeletion`은 계획 상태입니다. 로컬 테스트 통과는 hosted Supabase·Vercel·AI worker 검증 완료를 의미하지 않습니다.

## Swagger API 문서

```sh
cd apps/api-docs
npm run sync:check
npm start
```

브라우저에서 `http://127.0.0.1:4173`을 엽니다. 실제 토큰은 화면 공유·녹화 중 입력하지 않고, 쓰기 API의 Try it out은 개발 환경에서만 사용합니다.

## 비밀값

- 실제 값은 `.env`와 배포 플랫폼 Secret에만 둡니다.
- `.env.example`에는 변수 이름만 기록합니다.
- Supabase secret/service-role, 사용자 JWT, AI callback secret, 날씨 key를 Git·이슈·채팅에 올리지 않습니다.
- 사용자 이미지, 원본 데이터, 모델 가중치와 생성 산출물을 커밋하지 않습니다.

## 배포 설정

- Backend Vercel Root Directory: `backend`
- Frontend Vercel Root Directory: 실제 앱 디렉터리
- API Docs 정적 Root Directory: `apps/api-docs`
- Supabase project, migration, Auth redirect, Storage, 환경변수는 Git 저장소 이름 변경과 별도로 확인합니다.

## 팀 결정이 필요한 항목

- 최종 추구미 5종 이름·정의와 운영 seed
- 계정 탈퇴 후 공개 게시물·Storage·AI 파생 데이터의 보존/파기 정책
- TPO 활성 여부, 하루 OOTD 수, OOTD 사진 정책
- AI worker와 날씨 provider의 실제 배포 책임자
- 프론트엔드 기술 스택과 API client 생성 방식
