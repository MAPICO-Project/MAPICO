# G5 날씨·추천 수직 슬라이스 결과

상태: 완료 — 누적 25/50 implemented-local

## 구현 결과

- 현재 시간대 날씨, 추천 생성·조회·채택 4개 operation을 구현했다.
- 날씨는 한국 지원영역을 privacy-preserving grid로 축약하고 동일 current slot에서 10분 fresh, provider 실패 시 3시간 stale까지만 사용한다.
- provider fetch마다 새 immutable snapshot을 만들므로 과거 추천의 날씨 근거가 변경되지 않는다.
- 추천 생성은 provider 전에 authenticated reservation과 2분 lease token으로 idempotency를 선점하며 실패 후 lease 만료 시 같은 key로 재개한다.
- deterministic engine은 활성 의류, 날씨, 사용자 추구미 weight와 garment aesthetic score를 사용한다. 자유 형식 LLM은 사용하지 않고 검증된 fact 기반 template 설명만 저장한다.
- 추천 finalize와 채택은 garment/asset을 안정된 순서로 잠그고 soft-delete·검증 상태를 다시 확인한다. legacy `accept_outfit` 실행권은 회수했다.

## DB·계약 변경

- additive migration: `backend/supabase/migrations/202610010002_recommendations.sql`.
- server-only weather 조회·저장과 recommendation finalize RPC, authenticated reservation·accept RPC를 추가했다.
- recommendation 생성 당시 `weather_was_stale`, engine/rules version, DB에서 읽은 preference snapshot을 고정한다.
- OpenAPI·coverage·API/DB 설계·standalone snapshot을 25/50으로 동기화했다.

## 검토 반영

읽기 전용 병렬 검토에서 지적된 cache 시간 경계, stale usage 보존, service-role confused deputy, provider 전 idempotency, legacy accept 우회, OOTD DTO, aesthetic 미사용, pending 복구, snapshot 불변성, soft-delete TOCTOU, 동일 날짜 replay, immutable refetch 문제를 모두 반영했다.

## 로컬 검증

- `npm test`: 77/77 통과.
- `npm run test:schema`: 8 migrations와 7 SQL assertion 파일 통과.
- `npm run coverage:contract`: 50 operations, 25 implemented-local, registry 25, 22 tables 기준 통과.
- seed validation, preview smoke dry-run, 문서 hash 동기화, `git diff --check` 통과.

## 미검증 범위

- 원격 migration, hosted RLS/RPC, 실제 날씨 provider quota·schema·발표 주기, Preview 동시 요청·timezone 자정 E2E는 수행하지 않았다.
- `WEATHER_PROVIDER_BASE_URL`, `WEATHER_PROVIDER_API_KEY`, server-only Supabase secret의 실제 값은 생성·수정·출력하지 않았다.
