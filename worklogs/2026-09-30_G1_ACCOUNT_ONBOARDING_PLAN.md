# G1 계정·온보딩 HTTP 수직 슬라이스 계획

상태: 완료 — 결과는 `2026-09-30_G1_ACCOUNT_ONBOARDING_RESULT.md`

## bounded goal

기존 D0/A0 변경을 보존하고 원격 DB·배포·비밀값을 건드리지 않은 채 다음 5개 OpenAPI operation을 로컬 HTTP 수직 슬라이스로 구현·검증한다.

- `PATCH /api/v1/me` (`updateMe`)
- `PUT /api/v1/me/aesthetics` (`replaceAestheticPreferences`)
- `PUT /api/v1/me/onboarding` (`saveOnboardingState`)
- `GET/HEAD /api/v1/aesthetics` (`listAesthetics`)
- `GET/HEAD /api/v1/tpo-presets` (`listTpoPresets`, deprecated 계약 유지)

## 구현 계약

1. 쓰기 요청은 기존 Bearer 검증과 사용자 JWT/RLS Supabase client만 사용하고 service role을 사용하지 않는다.
2. JSON body는 `application/json`, 16 KiB 이하 최상위 plain object와 operation별 정확한 key allowlist를 검사한다. 파싱·media type 오류는 400, 알 수 없는 key·빈 patch·타입·범위·중복·가중치 합은 422로 upstream 호출 전에 거절한다.
3. `avatar_asset_id`가 존재하면 Storage 수명주기 전이므로 다른 값과 무관하게 422 `UNSUPPORTED_FIELD`로 거절한다.
4. RPC는 `update_my_profile`, `replace_my_aesthetic_preferences`, `save_my_onboarding_state`만 POST 호출한다. profile patch는 presence flag를 포함한 인자 4개를 항상 보내고, 선호 UUID는 소문자 정규화한 새 객체만 보낸다. void 성공은 200/204를 모두 허용한다.
5. RPC 성공 후 같은 사용자 JWT/RLS로 operation별 허용 필드만 재조회한다. 쓰기 후 0행·잘못된 행은 내부 오류, 재조회 upstream 실패는 안전한 503으로 처리한다. RPC와 재조회가 단일 transaction은 아니며 동시 쓰기의 최신 결과가 보일 수 있다.
6. 알려진 `22023`+메시지는 422, `P0002`+`profile_not_found`는 404, 인증 실패는 401, rate limit은 429, `PGRST202`·`42883`·권한/기타 upstream 장애는 안전한 503으로 매핑하고 upstream 본문을 응답에 노출하지 않는다.
7. 공개 catalog는 인증 헤더를 무시하고 publishable key의 익명 읽기만 사용하며 공통 request-id/CORS/error envelope를 적용한다. aesthetics는 활성 행을 `{id, code, display_name, active}`로 투영하고, deprecated TPO는 알려진 5개 code의 정적 description을 합쳐 반환한다. 기존 `/api/aesthetics` 경로는 같은 DTO로 호환 유지한다.
8. 성공 응답과 오류 fixture, handler/클라이언트 단위 테스트, coverage registry, OpenAPI 구현 상태·503·request-id 설명, backend README를 함께 갱신한다. 정본 OpenAPI 변경 후 `backend/docs` 사본과 export manifest를 동기화한다.

## 구현 전 검토 결과

- 2026-09-30 Claude CLI 읽기 전용 검토 완료: `canonicalModel=claude-opus-5-5`, `provider=firstParty`, `is_error=false`, web 요청·하위 agent 없음.
- 관측 비용: CLI list 기준 USD 0.5944344. 실제 청구액과 동일하다고 단정하지 않는다.
- HIGH 4건을 위 구현 계약에 반영했다: SQLSTATE+메시지 allowlist, void 200/204 처리, OpenAPI 503/request-id 보완, PATCH presence 인자 고정.
- 기존 migration에서 `profiles` 전체 SELECT와 public catalog SELECT가 authenticated/anon에 부여돼 새 profile 컬럼 재조회가 가능함을 로컬 SQL로 확인했다.

## 완료 기준

- 신규·기존 unit test 전체 통과.
- `npm run test:schema`, `npm run coverage:contract`, `npm run seed:validate`, `git diff --check` 통과.
- coverage가 50 operation 중 G1의 6개 누적 구현(`getMe` 포함), registry/contract/RLS 증거와 일치.
- 원격 Supabase·Vercel·비밀값을 사용하지 않았음을 결과 문서에 명시.
- 실제 hosted Auth/PostgREST/RLS와 Preview smoke는 미검증으로 남긴다.

## 금지 범위

- 기존 migration 수정, 원격 SQL 적용, 배포, 외부 계정 변경, `.env`·`.vercel`·비밀값 열람/출력.
- 미결 제품 정책(TPO 활성 사용, 완료 선행조건, 최종 taxonomy 명칭) 임의 확정.
- 기존 수정·미추적 파일 reset/checkout/clean 또는 사용자 변경 덮어쓰기.
