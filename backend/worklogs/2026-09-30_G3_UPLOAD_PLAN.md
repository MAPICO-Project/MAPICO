# G3 배치·업로드 수직 슬라이스 계획

상태: 완료

## 1. bounded goal

- 대상 operation은 `createGarmentBatch`, `getGarmentBatch`, `refreshUploadUrl`, `completeGarmentUpload` 4개다.
- 기존 변경과 G1·G2 기준선을 보존하며 누적 coverage를 14/50 `implemented-local`로 올린다.
- 원격 Supabase, 배포, 실제 환경변수와 비밀값은 변경하지 않는다. hosted Storage 동작은 로컬 계약·SQL 검증과 구분해 기록한다.

## 2. 구현 경계

1. `create_my_garment_batch` SECURITY DEFINER RPC가 인증 사용자와 idempotency key를 검증하고 batch/source asset/object key를 한 트랜잭션에서 생성한다. object key는 `user_id/batch_id/source.ext` 규칙으로 서버가 결정하며 클라이언트 값을 받지 않는다.
2. Storage에는 `closet-private`의 아직 미검증인 본인 등록 source asset과 정확히 일치하는 object만 INSERT할 수 있는 정책을 추가한다. 일반 bucket 열람·UPDATE·DELETE·upsert는 허용하지 않는다.
3. BFF는 사용자 JWT로 Supabase Storage의 signed-upload URL을 생성한다. URL은 HTTPS·동일 프로젝트 host·정확한 bucket/object path인지 검사하며 2시간 만료 계약을 응답에 명시한다.
4. batch 조회와 URL 재발급은 RLS로 보이는 본인 batch/source asset 한 건만 허용한다. 재발급은 `awaiting_upload`, 미검증, 미삭제 상태에서만 가능하다.
5. 업로드 완료는 인증된 ranged GET(`bytes=0-65535`)으로 magic bytes와 최소 구조를 검사한다. 206이면 `Content-Range` total이 선언 크기와 같아야 하며, range를 무시한 200 응답은 64 KiB 뒤 중단한다.
6. 검증 성공 후 `complete_my_garment_upload` RPC가 row lock 아래 `storage.objects`의 owner·size·MIME도 독립적으로 재검증하고 asset `verified_at`과 batch `uploaded`를 원자적으로 갱신한다. 동일 idempotency key replay와 이미 완료된 동일 batch replay는 성공시키고 다른 요청 재사용은 409로 거절한다.
7. object가 없으면 retry 가능한 409로 상태를 유지한다. 존재하지만 크기·MIME·magic bytes가 틀리면 RPC가 batch를 `failed`로 종결하며 object 정리는 후속 worker 범위로 남긴다. 응답과 로그에는 bearer token, signed token, 내부 object body를 포함하지 않는다.
8. signed URL은 프로젝트 HTTPS host, 정확히 인코딩된 upload/sign 경로, 단일 `token` query만 허용한다. upsert를 사용하지 않고 URL/token을 idempotency row에 저장하지 않는다.

## 3. 예상 변경

- additive migration 1개: RPC 2개, Storage INSERT policy, 정확한 권한, 검증용 SQL assertions.
- `lib/supabase-user.js`: 허용 RPC와 signed-upload/object-download adapter. service-role credential은 읽지 않는다.
- `lib/garment-batches.js`와 라우트 3개: 엄격한 body/path/header 검증, DTO projection, 상태 전이.
- unit/fixture/contract/RLS 테스트, OpenAPI 4개 operation 상태·503 계약, canonical/copy 문서와 manifest, coverage registry, 결과 worklog.

## 4. 검토 질문

- 등록 asset에 정확히 결합된 Storage INSERT 정책이 signed-upload 생성에 필요한 최소 권한인지, 우회 업로드가 상태 무결성을 깨지 않는지 확인한다.
- create와 complete idempotency의 replay·만료·동시성·request hash가 충분한지 확인한다.
- 원격 Storage HEAD를 신뢰하지 않고 실제 bytes를 제한적으로 읽어 MIME/크기/시그니처를 검증하는 방식의 누락을 찾는다.
- URL/path/token, 타 사용자 batch, 검증 전 asset, 잘못된 metadata가 외부로 노출되거나 상태를 전진시키는 경로를 찾는다.

## 5. 완료 기준

- 4개 operation에 실경로, handler, RPC/Storage adapter, 성공·오류 테스트, 계약 fixture, SQL/RLS 증거가 모두 있다.
- G3 단위·스키마·coverage·seed·preview dry-run·diff-check가 통과한다.
- hosted Storage 서명/업로드/검증은 실제 환경 미검증으로 남기고 mock-only 성공을 hosted 완료로 표현하지 않는다.

## 6. 읽기 전용 검토 기록

- 실제 모델: `canonicalModel=claude-opus-5-5`, `provider=firstParty`, `is_error=false`, web 요청 0, 하위 agent 0.
- session: `dee79fb3-1893-491e-a4bc-969f1a8bcfba`, list 기준 비용 USD 1.3931388.
- 반영한 MUST: BFF 검증 우회 방지를 위한 DB 재검증, 미검증 source 전용 SELECT, asset/batch에 정확히 결합된 INSERT, signed URL 엄격 검증과 무-upsert, range/terminal-invalid 처리.
- 반영한 SHOULD: 충돌 안전 idempotency, DB 내부 canonical hash, replay 규칙, open batch 상한, 신규 파일까지 포함하는 service-role 문자열 감사.
