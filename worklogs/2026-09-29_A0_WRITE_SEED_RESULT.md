# A0-3·A0-7 쓰기 RPC·개발 seed 결과

상태: 완료 — 원격 DB·배포·비밀값 변경 없이 계정/온보딩 narrow RPC와 비실행 fixture seed 계약을 로컬 구현·검증했다.

## 구현 결과

- 새 additive migration: `202609290001_account_onboarding.sql`.
- `profiles`에 nullable `knows_aesthetic`, non-null `tutorial_seen`을 추가하고 기존 `onboarding_completed`를 계약의 `completed`로 사용한다.
- `update_my_profile`: 사용자 ID 입력 없이 `auth.uid()`만 사용한다. presence flag로 PATCH 생략과 표시명 `null` 초기화를 구분하고 IANA timezone을 검증한다.
- `replace_my_aesthetic_preferences`: 1~3개, 정확한 JSON key, UUID, weight 범위, 중복, 합 `1±0.0001`, 활성 taxonomy를 검증한다. profile row lock 후 delete+insert를 한 transaction에서 수행한다.
- `save_my_onboarding_state`: nullable `knows_aesthetic`와 필수 boolean 두 개를 자기 profile에 저장한다. 미결인 완료 선행조건은 만들지 않았다.
- 세 함수 모두 `security definer set search_path=''`, `auth.uid()` 필수, authenticated 전용 execute다. 관련 table direct write revoke는 유지한다.
- 세 RPC는 `void`이며 향후 BFF가 같은 사용자 JWT/RLS로 계약 응답을 재조회한다. HTTP handler가 없어 OpenAPI는 1 implemented/49 planned를 유지한다.
- `avatar_asset_id`는 Storage 수명주기 확정 전 미지원이며 향후 handler가 422 `UNSUPPORTED_FIELD`로 거절하도록 계약에 명시했다.
- `fixtures/dev-seed.fixture.json`은 최종 taxonomy가 아닌 5개 `fixture_style_*`, synthetic profile, metadata-only 이미지 허용정보만 담는다.
- `npm run seed:validate`는 비밀/토큰/URL/path 변형, taxonomy 오인, weight/참조/권한 metadata를 검사하며 네트워크·DB·SQL을 사용하지 않는다.

## 검증 결과

- 기준선: unit 29/29, schema, coverage 통과.
- 구현 후 unit: 31/31 통과.
- schema: OpenAPI 36 paths, migration 4개, `account_writes.sql`·`product.sql`·`security.sql`, embedded PostgreSQL 통과.
- seed validator: taxonomy 5, profile 1, image metadata 1, `network_used=false`, `database_used=false`, `sql_emitted=false`.
- coverage: OpenAPI 50·ERD 22, 구현 1·계획 49 유지, `valid=true`.
- Mermaid: 총 11개 블록 브라우저 parser 통과.
- 정본 `deliverables/backend`과 `backend/docs` export hash 동기화.
- hosted Supabase Auth/PostgREST/RLS, 병렬 session, 실제 Preview는 미검증이다.

## 리뷰와 예외 기록

- Opus 직접 검토는 Claude CLI session limit(429, 자정까지)로 비용 USD 0에 종료됐다. 결과 model metadata는 없었다.
- 같은 quota에서 Sonnet 중복 호출은 하지 않았다.
- 대체 읽기 전용 설계·최종 감사는 내장 `legacy_audit` 작업자가 수행했다. 실제 모델 ID와 비용은 노출되지 않아 미측정으로 기록한다.
- 최종 감사의 HIGH/MUST finding은 없었다. medium finding 중 void RPC/API 응답 차이, avatar 미지원 입력, path/url 변형 탐지를 문서·계약·validator에 반영했다.
- UUID cast와 hosted 동시성은 로컬 검증 범위에서 안전 경계를 확인했으나, 실제 PostgREST 병렬 통합 테스트가 남는다.

## 다음 단계

- 에이전트: G1에서 `PATCH /me`, `PUT /me/aesthetics`, `PUT /me/onboarding` handler·body validation·RPC 오류 mapping·안전 재조회를 구현한다. 공개 catalog 읽기 operation도 공통 route로 올린다.
- 사용자: 개발 Supabase 대상에 migration 4개를 순서대로 적용하고, Preview 환경변수·CORS origin·테스트 Auth 사용자를 준비한다. 원격 적용 전 project ref와 기존 schema를 확인한다.

