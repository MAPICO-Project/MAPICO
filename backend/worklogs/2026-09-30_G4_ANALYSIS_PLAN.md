# G4 분석 job·draft·확정 수직 슬라이스 계획

상태: 구현·검증 완료

## 1. bounded goal

- 대상은 `createAnalysisJob`, `getAnalysisJob`, `retryAnalysisJob`, `listGarmentDrafts`, `updateGarmentDraft`, `confirmGarmentBatch`, `receiveAnalysisResult` 7개 operation이다.
- G1~G3 변경과 14/50 기준선을 보존하고 누적 21/50 `implemented-local`을 목표로 한다.
- 원격 DB·배포·실제 비밀값은 변경하지 않는다. worker/Storage/hosted callback은 로컬 계약과 분리해 기록한다.

## 2. 사용자 경로

1. batch/job 생성·retry·draft patch·confirm은 `auth.uid()` 고정 narrow RPC와 사용자 JWT를 사용한다. direct table write는 계속 금지한다.
2. create는 `uploaded` batch와 verified source를 row lock으로 확인하고 단 하나의 queued job을 만들며 batch를 `processing`으로 바꾼다. idempotency replay는 동일 job을 반환한다.
3. retry는 본인 failed job, `attempt < max_attempts`, 미확정 batch만 같은 job을 queued로 되돌린다. 실제 claim 때만 attempt가 증가한다.
4. job DTO는 lease token·lease expiry·raw result를 제외하고 retryable/error allowlist만 만든다.
5. draft DTO는 raw prediction 전체를 반환하지 않고 predicted category/subcategory, 현재 category/subcategory/note, confidence, signed cutout, version만 구성한다.
6. draft patch는 정확한 presence flag와 optimistic version을 사용하며 predicted 원본은 보존하고 `user_overrides`만 변경한다.
7. confirm은 draft id/version 집합과 idempotency key를 한 transaction에서 검증하고 garments 생성, 선택 draft confirmed, 나머지 rejected, batch confirmed를 원자 처리한다. 성공 후 사용자 JWT/RLS로 safe garment DTO를 다시 읽는다.

## 3. worker callback 경계

1. `/internal/.../result`는 body parser를 끄고 제한된 raw JSON bytes를 읽어 `HMAC-SHA256(timestamp+'.'+raw_body)`를 timing-safe 비교한다. timestamp는 ±300초, signature는 고정 길이 hex, body/path job id는 일치해야 한다.
2. worker에게 DB credential을 주지 않는다. HMAC 검증을 마친 BFF만 격리된 internal Supabase gateway를 사용하며, 사용자 API/lib는 service-role/secret credential을 읽지 않는다. 실제 비밀값은 생성·수정·출력하지 않는다.
3. internal gateway는 정확한 allowlist RPC/Storage path만 허용한다. callback cutout path는 해당 job user/batch prefix와 정확히 결합하고 객체 존재·MIME·크기·magic bytes를 검사한다.
4. service-only callback RPC는 event id/payload hash를 `idempotency_keys`에 기록해 동일 replay는 `applied=false`, 동일 event의 다른 payload는 409로 처리한다. running attempt/lease/token/expiry를 row lock으로 확인한다.
5. succeeded는 items 1~6/errors 0, partial_failed는 items 1~6/errors 1+, failed는 items 0/errors 1+로 검증한다. item_index/client_item_key/object path 중복과 bbox 순서를 거절한다.
6. callback transaction은 검증된 cutout assets, drafts, terminal job 결과, batch review/failed를 함께 반영한다. 사용자 경로에는 raw model result·model version·worker errors를 직접 노출하지 않는다.

## 4. 예상 변경과 검증

- additive migration: 사용자 RPC, callback service-only RPC, 정확한 revoke/grant, SQL assertions.
- `lib/analysis.js`, 격리된 internal gateway/HMAC 처리, 6개 사용자 route와 1개 internal route.
- unit fixture, callback replay/stale lease/tamper/cross-owner/raw 비노출 테스트, OpenAPI·coverage·canonical/copy 문서·manifest·결과 기록.
- 각 단계 종료 시 unit, schema/SQL, coverage, seed, smoke dry-run, diff-check를 실행한다.

## 5. 검토 질문

- isolated service credential 경계가 기존 사용자 JWT/RLS 원칙과 비밀값 비노출을 실제로 유지하는지 확인한다.
- raw-body HMAC, replay event, stale lease, terminal overwrite, Storage 검증 사이에 우회나 TOCTOU가 있는지 확인한다.
- 기존 `claim_analysis_job`/`finish_analysis_job`과 새 callback RPC가 충돌하거나 attempt 의미를 깨지 않는지 확인한다.
- confirm idempotency·partial_failed 정책과 raw prediction/user override 병합이 OpenAPI DTO와 일치하는지 확인한다.

## 6. 완료 기준

- 7개 operation에 실제 handler, DB/Storage 경계, contract fixture, 단위·SQL/RLS 증거가 있다.
- mock-only worker 성공을 hosted 완료로 표현하지 않으며 실제 secret이 없는 로컬 기본 실행은 fail-closed한다.
- 21/50 coverage와 전체 G4 회귀가 통과한다.

## 7. 검토 반영

- 읽기 전용 병렬 검토에서 durable callback replay, Storage object identity/version fence, retryable allowlist 일치가 release blocker로 확인됐다.
- 완료 event는 `inspect_analysis_callback`이 mutable job·Storage 조회 전에 replay를 반환한다.
- cutout은 `storage.objects.id + updated_at` fence를 받은 뒤 bytes를 검사하고, 적용 transaction에서 같은 row를 잠가 owner·MIME·size·identity·version을 다시 비교한다.
- API `retryable`은 DB retry RPC와 같은 오류 allowlist를 사용한다.
- 실제 hosted Storage overwrite/metadata 동작, AI worker와 secret 주입은 로컬 완료 범위가 아니며 미검증으로 유지한다.
