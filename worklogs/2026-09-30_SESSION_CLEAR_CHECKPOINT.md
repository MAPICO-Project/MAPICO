# 세션 clear 체크포인트 — 2026-09-30

상태: 안전하게 재개 가능. 진행 중인 파일 작성자·CLI process·원격 작업 없음.

## 완료된 로컬 범위

- 엄격한 MVP: 정본 ERD 22테이블, OpenAPI 50 operation 유지.
- HTTP 기반: 공통 오류/request-id, Bearer Auth, 사용자 JWT/RLS Supabase client, 정확 일치 CORS/OPTIONS.
- 구현 product operation: `getMe` 1/50. 나머지 49개는 계획 상태이며 RPC 기반을 HTTP 완료로 계산하지 않는다.
- 계정/온보딩 DB 기반: `202609290001_account_onboarding.sql`의 narrow RPC 3개와 로컬 권한/원자성 테스트.
- 개발 도구: Preview smoke dry-run, operation/table coverage, fixture 계약, metadata-only dev seed validator.
- 문서: API/DB/ERD/OpenAPI 정본과 `backend/docs` 사본 hash 동기화.

## 2026-09-30 clear 직전 재검증

- `npm test`: 31/31 통과.
- `npm run test:schema`: OpenAPI 36 paths, migration 4개, SQL assertion 3개 묶음, embedded PostgreSQL 통과.
- `npm run coverage:contract`: OpenAPI 50, ERD 22, implemented 1/planned 49, `valid=true`.
- `npm run seed:validate`: taxonomy 5, profile 1, image metadata 1, network/DB/SQL 사용 없음.
- `git diff --check`: 통과.
- hosted Supabase, 실제 Vercel Preview, Kakao Auth, 병렬 PostgREST는 미검증.

## 저장소 주의

- `backend/`는 독립 Git 저장소이며 현재 완료 작업이 수정·untracked 상태로 남아 있다. 커밋 요청을 받지 않았으므로 커밋하지 않았다.
- 다음 세션에서 `git reset`, `checkout`, clean, 대량 삭제를 하지 않는다. 현재 변경은 사용자 작업으로 보존한다.
- 비밀값·`.env`·`.vercel`은 읽거나 출력·커밋하지 않는다.
- 원격 DB 적용과 배포는 사용자 실습 경계다.

## 사용자 진행 대기

1. 개발 Supabase project ref와 기존 schema 확인.
2. migration 4개를 순서대로 적용.
3. 개발 Auth 테스트 사용자 생성.
4. Vercel의 `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`, `CORS_ALLOWED_ORIGINS` 등록.
5. 고정 Preview URL, Frontend origin, 최종 taxonomy 5종 정의 확정.

값 자체가 아니라 완료 여부와 비밀값 없는 식별 정보만 공유한다.

## 다음 에이전트 goal

G1 계정·온보딩 HTTP 수직 슬라이스:

- `PATCH /api/v1/me` (`updateMe`)
- `PUT /api/v1/me/aesthetics` (`replaceAestheticPreferences`)
- `PUT /api/v1/me/onboarding` (`saveOnboardingState`)
- 공개 catalog의 `listAesthetics`, 필요 시 deprecated `listTpoPresets`
- body allowlist, RPC 오류 mapping, 성공 후 같은 JWT/RLS 재조회, fixture/coverage/OpenAPI 상태 갱신
- `avatar_asset_id`는 Storage 수명주기 전 422 `UNSUPPORTED_FIELD`

Claude CLI는 이전 9월 29일 자정 전 session limit 기록이 있다. 현재 날짜는 9월 30일이므로 새 goal에서 한 번만 상태를 확인하고, 실패를 반복하지 않는다. Astra 통합·단일 작성자 규칙과 원격 무변경 경계를 유지한다.

## 재개 명령문

> `AGENTS.md`, `worklogs/SESSION_HANDOFF.md`, `worklogs/2026-09-30_SESSION_CLEAR_CHECKPOINT.md`, `worklogs/2026-09-29_A0_WRITE_SEED_RESULT.md`를 읽고 이어서 진행해주세요. 먼저 backend의 기존 변경을 보존하고 검증 기준선을 확인한 뒤, G1 계정·온보딩 HTTP 수직 슬라이스를 bounded goal로 계획→검토→구현→테스트→기록 순서로 진행하세요. 원격 DB·배포·비밀값은 변경하지 마세요.

