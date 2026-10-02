# G1 계정·온보딩 HTTP 수직 슬라이스 결과

상태: 완료 — 원격 DB·배포·비밀값 변경 없이 5개 G1 operation을 로컬 구현·검증했다.

## 구현 결과

- `PATCH /api/v1/me`: 표시명·시간대 strict allowlist, 명시적 null/presence flag, `avatar_asset_id` 422 거절, RPC 성공 뒤 Profile 재조회.
- `PUT /api/v1/me/aesthetics`: 1~3개, 정확한 중첩 key, UUID 소문자 정규화·중복, weight 범위·합 검증, 원자 교체 RPC 뒤 선호 재조회.
- `PUT /api/v1/me/onboarding`: nullable `knows_aesthetic`와 필수 boolean 두 개를 정확히 검증하고 RPC 뒤 API 이름으로 재투영.
- `GET/HEAD /api/v1/aesthetics`: publishable key 익명 읽기, 활성 행과 공개 DTO만 반환. 기존 `/api/aesthetics`도 같은 handler로 유지.
- `GET/HEAD /api/v1/tpo-presets`: deprecated 호환 읽기. 알려진 5개 code에만 정적 설명을 결합하며 활성 제품 사용을 확정하지 않음.
- JSON은 `application/json`, 16 KiB 이하 plain object만 허용한다. body 파싱 오류는 400, validation과 미지원 필드는 422다.
- RPC는 고정된 세 함수만 POST할 수 있고 `void` 200/204를 성공으로 처리한다. 알려진 SQLSTATE+메시지만 404/422로 매핑하며 그 밖의 본문은 노출하지 않고 503으로 닫는다.
- 사용자 쓰기는 Supabase Auth 검증과 동일 JWT/RLS만 사용한다. service role은 런타임에서 사용하지 않는다.

## 검토 반영

- 구현 전 Claude CLI Opus 읽기 전용 검토 1회 완료.
- 실행 증거: `canonicalModel=claude-opus-5-5`, `provider=firstParty`, `is_error=false`, web 요청 0, 하위 agent 0.
- CLI list 기준 비용 USD 0.5944344를 관측했으며 실제 청구액과 같다고 단정하지 않는다.
- HIGH 4건(SQLSTATE 매핑, void 200/204, OpenAPI 503/request-id, presence 인자)을 구현·계약·테스트에 반영했다.

## 검증 결과

- `npm test`: 41/41 통과.
- `npm run test:schema`: OpenAPI 36 paths, migration 4개, `account_writes.sql`·`product.sql`·`security.sql`, embedded PostgreSQL 통과.
- `npm run coverage:contract`: OpenAPI 50, implemented-local 6, planned 44, registry/contract/RLS 증거 6, ERD 22, `valid=true`.
- `npm run seed:validate`: taxonomy 5, profile 1, image metadata 1, network/DB/SQL 사용 없음.
- `npm run smoke:preview`: dry-run 통과, `network_used=false`.
- `git diff --check`: 통과.
- 정본 `deliverables/backend`과 `backend/docs`의 OpenAPI·API 설계 해시 일치. export manifest 갱신.

## 검증 경계와 잔여 위험

- hosted Supabase Auth/PostgREST/RLS, 실제 Vercel Preview, Kakao Auth, 실제 JWT, 병렬 요청은 미검증이다.
- RPC commit과 응답 재조회는 한 transaction이 아니다. 같은 사용자의 동시 쓰기가 있으면 재조회 시점 최신 상태가 보일 수 있다.
- RPC 타임아웃 시 commit 여부를 로컬에서 판별할 수 없다. 세 쓰기는 동일 입력 재시도가 가능한 형태지만 실제 hosted 장애 주입 검증이 남는다.
- TPO read는 계약 호환용이며 최신 홈에서의 활성 사용을 확정하지 않는다. 최종 taxonomy 5종 명칭도 여전히 미정이다.
- 기존 backend 수정·미추적 변경은 reset/clean/commit 없이 보존했다.

## 다음 단계

- 사용자 준비 후 G1 실제 E2E: migration 4개가 적용된 개발 Supabase와 테스트 JWT로 계정→선호/온보딩 저장→재조회, 공개 catalog, Preview CORS를 공동 검증한다.
- 에이전트 다음 bounded goal 후보는 로드맵의 G2 옷장 읽기(`list/get/update/deleteGarment` 중 읽기 우선)다. 원격 환경 준비 여부와 독립적으로 로컬 계약부터 진행할 수 있다.
