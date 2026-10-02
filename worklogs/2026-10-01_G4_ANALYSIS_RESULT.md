# G4 분석 job·draft·확정 수직 슬라이스 결과

상태: 완료 — 누적 21/50 implemented-local

## 구현 결과

- 사용자 경로 6개와 worker callback 1개를 구현했다: 분석 job 생성·조회·재시도, safe draft 목록·수정, batch 확정, 분석 결과 수신.
- 일반 경로는 사용자 JWT/RLS와 본인 고정 narrow RPC만 사용한다. raw prediction, lease token, 내부 오류 코드, object key는 사용자 DTO에서 제외했다.
- callback은 raw-body HMAC, 5분 timestamp 창, 엄격한 결과 cardinality·bbox·속성·canonical cutout path를 검사한다.
- `lib/supabase-internal.js` 한 곳만 `SUPABASE_SECRET_KEY`와 `AI_CALLBACK_HMAC_SECRET`을 읽으며 설정 누락 시 fail-closed한다.
- 완료 callback replay는 mutable job·Storage보다 먼저 판정한다. 새 결과의 cutout은 bytes 검사 뒤 `storage.objects.id + updated_at` fence를 transaction에서 재확인한다.
- draft 확정은 exact version key set, idempotency key, asset readiness를 잠근 transaction에서 검사하고 `note`를 `garments.memo`로 저장한다.

## DB·계약 변경

- additive migration: `backend/supabase/migrations/202610010001_analysis.sql`.
- authenticated RPC 5개와 service_role-only RPC 3개를 추가했다.
- authenticated의 raw `garment_drafts` SELECT와 legacy confirm RPC 실행 권한을 회수했다.
- OpenAPI·coverage registry·API/DB 설계·standalone 문서 스냅샷을 누적 21/50으로 동기화했다.

## 검토 반영

읽기 전용 병렬 검토에서 발견한 세 release blocker를 모두 반영했다.

1. 동일 callback replay가 Storage 재검사 때문에 실패할 수 있던 문제를 preflight RPC로 해결했다.
2. 검증한 cutout과 확정한 Storage row가 분리되던 TOCTOU를 object identity/version fence와 row lock으로 차단했다.
3. API `retryable` 계산을 DB retry 오류 allowlist와 일치시켰다.

## 로컬 검증

- `npm test`: 68/68 통과.
- `npm run test:schema`: 7 migrations와 6 SQL assertion 파일 통과.
- `npm run coverage:contract`: 50 operations, 21 implemented-local, registry 21, 22 tables 기준 통과.
- `npm run seed:validate`: 네트워크·DB·SQL 출력 없이 통과.
- `npm run smoke:preview`: dry-run 통과, 네트워크 미사용.
- canonical/copy 문서 SHA-256 manifest 동기화와 `git diff --check` 통과.

## 의도적으로 남긴 미검증 범위

- 원격 migration 적용, hosted Auth/PostgREST/Storage, 실제 AI worker, callback secret 주입, Vercel Preview E2E는 수행하지 않았다.
- hosted Storage의 overwrite·metadata timestamp 동작은 실제 프로젝트에서 확인해야 한다.
- 비밀값을 생성·수정·출력하지 않았고 원격 DB·배포를 변경하지 않았다.
