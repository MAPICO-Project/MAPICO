# D0 로컬 기반 구현 결과

상태: 완료 — 원격 배포·DB·비밀값을 변경하지 않고 공통 HTTP/Auth/CORS 기반, `getMe` 재사용 구조, smoke dry-run, 계약 fixture, coverage 자동검사를 구현·검증했다.

## 완료 범위

- 공통 오류 envelope와 request-id 생성기를 `lib/errors.js`로 분리했다.
- Bearer 토큰 형식·길이 검증을 `lib/auth.js`로 분리했다. JWT claim은 신뢰하지 않고 Supabase `/auth/v1/user`가 사용자를 확인한다.
- 사용자 JWT와 publishable key만 전달하는 RLS용 Supabase client를 `lib/supabase-user.js`로 분리했다. secret/service-role 키를 읽지 않는다.
- `CORS_ALLOWED_ORIGINS`의 완전 일치 allowlist, `Vary`, OPTIONS 204, 노출 헤더를 `lib/cors.js`와 `lib/route.js`에 구현했다. `*`, `null`, 부분 도메인, credential cookie는 허용하지 않는다.
- `/api/v1/me`를 공통 route/client 위에 올리고 기존 응답·오류·HEAD 동작을 유지했다.
- `test/fixtures/`에 `fixture-*` 계약 샘플을 추가하고 실제 데이터/추론과 구분했다.
- `npm run coverage:contract`가 OpenAPI 50 operation, migration 22 table, 구현·계약 테스트·RLS 증거를 자동 검사한다.
- `npm run smoke:preview`는 기본적으로 네트워크를 사용하지 않는다. 실제 검증은 `--execute`와 환경변수 토큰을 명시해야 하며 URL·토큰·응답 본문을 출력하지 않는다.
- `profiles`와 `user_aesthetic_preferences`의 교차 사용자 RLS 차단을 embedded PostgreSQL 보안 테스트에 추가했다.

현재 자동 보고 기준은 구현 1/50 operation, 계획 49/50, 구현 operation이 참조하는 테이블 2/22다. 나머지를 완료한 것으로 표시하지 않는다.

## 검증

- `npm test`: 29/29 통과. 기존 20개에서 CORS·route·fixture 9개를 추가했다.
- `npm run coverage:contract`: OpenAPI 50, public table 22, registry 정합성 `valid=true`.
- `npm run smoke:preview`: `network_used=false` dry-run 통과.
- `npm run test:schema`: OpenAPI 36 paths, migration 3개, `product.sql`, `security.sql`, embedded PostgreSQL 통과.
- `git diff --check`: 통과.
- hosted Supabase Auth/Storage와 실제 Vercel Preview는 검증하지 않았다.

## Claude 검토와 반영

- Opus 설계 검토: `claude-opus-5-5`, first-party, 오류 없음, session `901fc388-b9b9-4842-b980-51d4a6126f4b`, list 기준 USD 1.0166888. 공통 모듈 경계, 정확한 CORS allowlist, 사용자 JWT/RLS 유지, fixture와 coverage 주의사항을 채택했다.
- Sonnet 최종 리뷰: `claude-sonnet-5`, first-party, 오류 없음, session `a1a3274b-1328-402d-8235-a263424aa9c5`, list 기준 USD 1.2195404. MUST-fix 없음. RLS 증거 과장과 405 CORS 일관성 지적을 반영했다.
- 첫 Opus 호출은 결과를 반환하지 않은 채 남아 정확한 비용을 관측하지 못했고, 해당 로컬 CLI process만 중단한 뒤 범위를 좁힌 호출로 재실행했다. 파일·원격 변경은 없었다.
- Sonnet의 로컬 Bash 실행 일부는 restricted 권한으로 거절됐지만, Astra가 같은 명령을 직접 실행해 결과를 검증했다.

## 남은 경계

- 사용자 작업: 개발 Supabase 대상·migration 적용, Preview 배포 방식·환경변수·고정 URL·CORS origin, 테스트 사용자/JWT 준비.
- 에이전트 후속: A0-3 계정/온보딩 narrow write/RPC 설계와 A0-7 재현 가능한 seed/fixture 설계. 이번 결과가 원격 D0 완료를 의미하지 않는다.

