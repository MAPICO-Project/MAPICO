# 프로필 조회 API 첫 수직 슬라이스 결과 보고

상태: 완료 — 로컬 구현·mock 검증. hosted Supabase 통합은 미검증.

## 계획 대비 결과

- 계획된 50개 operation 중 첫 제품 API인 `GET/HEAD /api/v1/me`를 구현했다.
- bearer 토큰을 Supabase Auth `/auth/v1/user`로 검증하고, 확인된 사용자 ID·사용자 JWT·publishable key로 PostgREST를 호출해 기존 RLS를 유지한다.
- service-role 키 없이 Profile 허용 필드만 반환한다. 토큰, Auth metadata, `training_consent`, `created_at`, preference `user_id`, 상위 오류 본문과 예외 메시지는 노출하지 않는다.
- GET/HEAD 외 메서드는 외부 호출 전에 405로 거절한다. 인증 형식 오류도 외부 호출 전에 401로 거절한다.
- OpenAPI는 getMe만 `implemented-local`, 나머지 49개 operation은 `planned`로 유지했다.

## 변경 파일

- `backend/api/v1/me.js`: 의존성 주입 가능한 얇은 Vercel handler.
- `backend/lib/profile.js`: 설정·bearer 검사, Auth/REST 호출, 오류 매핑, Profile allowlist 투영.
- `backend/test/me.test.mjs`: 인증·RLS 전달·실패 폐쇄·정보 비노출·HEAD·데이터 무결성 mock 테스트.
- `deliverables/backend/openapi.yaml`, `API_DESIGN.md`: getMe의 로컬 구현 상태와 503 의존성 오류·인증 흐름 기록.
- `backend/docs/`: 공식 export 스크립트로 OpenAPI/API/DB/ERD 사본과 manifest 동기화.
- `backend/README.md`, 구현 상태·세션 인계·본 계획/결과 문서 갱신.
- SQL·migration·원격 설정은 변경하지 않았다.

## 검증

- `npm test`: 20/20 통과. 최초 적용 직후 16/18은 테스트 helper가 명시적 `authorization: undefined`를 기본 토큰으로 치환한 문제였고 helper 수정 후 모두 통과했다. 제품 코드 실패가 아니었다.
- `npm run test:schema`: OpenAPI 36 paths 검증, migration 3개 실행, product/security SQL assertions, embedded PostgreSQL 통과.
- OpenAPI 구조 검사: 총 50 operation 중 `implemented-local` 1개(getMe), `planned` 49개. updateMe/deleteMe는 planned 유지.
- export 해시: openapi/API_DESIGN/DB_DESIGN/ERD 정본과 `backend/docs` 사본 및 manifest가 모두 일치.
- Opus: `claude-opus-5-5`, first-party, 오류 없음. service-role 없이 사용자 JWT/RLS로 구현 가능하다고 판정하고 503 계약 누락·오류 envelope·DTO allowlist를 지적했다.
- Sonnet 최종 리뷰: `claude-sonnet-5`, first-party, 오류 없음. 신규 3개 파일에 수정 필수 보안·정확성 결함이 없다고 판정했다.

## 미검증·후속 작업

- 실제 hosted Supabase의 Auth 상태 코드, RLS, PostgREST embed/정렬, numeric JSON 직렬화, 프로필 생성 trigger는 검증하지 않았다.
- 원격 schema가 아직 적용되지 않았으므로 현재 배포에서 `/api/v1/me` 성공을 주장하지 않는다.
- Vercel의 실제 중첩 함수 라우팅과 새 배포도 검증하지 않았다.
- 프론트와 API가 다른 origin이면 Authorization preflight를 위한 CORS 정책이 추가로 필요하다. 현재 `vercel.json`에는 CORS가 없다.
- write API는 현재 authenticated 역할에 SELECT만 허용한 DB 경계와 충돌하므로, PATCH `/me`를 구현하기 전에 narrow RPC 또는 신뢰된 BFF 쓰기 권한 방식을 별도 보안 설계해야 한다.
- 다음 안전한 로컬 수직 슬라이스 후보는 기존 RLS를 재사용할 수 있는 읽기 API다. 원격 적용·배포·실데이터 검증은 계속 사용자 실습 경계다.
