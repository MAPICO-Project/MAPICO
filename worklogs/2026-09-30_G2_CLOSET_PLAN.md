# G2 옷장 API 세부 계획

상태: 완료 — 결과는 `2026-09-30_G2_CLOSET_RESULT.md`

## bounded goal

- `GET /api/v1/garments` (`listGarments`)
- `GET /api/v1/garments/{garmentId}` (`getGarment`)
- `PATCH /api/v1/garments/{garmentId}` (`updateGarment`)
- `DELETE /api/v1/garments/{garmentId}` (`deleteGarment`)
- 완료 시 OpenAPI 누적 10/50 `implemented-local`.

## 읽기 경로

1. 기존 Bearer 검증 후 사용자 JWT/RLS로만 `garments`를 조회한다. `user_id`는 Auth 결과로 고정하고 `deleted_at is null`을 명시한다.
2. 목록은 `created_at DESC, id DESC`, 기본 20·최대 100의 keyset cursor와 `limit+1` 조회를 사용한다. cursor에는 version, PostgREST가 반환한 원형 timestamp, 마지막 `id`, category filter를 base64url JSON으로 담고 정확한 shape·길이를 검사한다. timestamp를 JS Date로 재직렬화하지 않는다.
3. category는 정본 8종만 허용한다. 알 수 없는 query key, 배열형 query, 잘못된 limit/cursor는 upstream 전에 400/422로 닫는다.
4. 의류 row는 `id, asset_id, category, attributes, memo, version, created_at, updated_at`만 조회한다. 응답 `attributes`는 `category` 컬럼, `attributes.subcategory`, `memo→note`로 새로 만들며 raw jsonb, 내부 `user_id`, `source_draft_id`, 색상·모델 점수는 응답하지 않는다. category 수정 시 컬럼과 jsonb의 category를 함께 갱신한다.
5. `image`는 `garments.asset_id`가 가리키는 `kind=cutout`, `original_image`는 그 asset의 batch에 있는 유일한 `kind=source`로 매핑한다. `verified_at != null`, `deleted_at is null`, `bucket_id=closet-private`인 자산만 signed URL 후보로 인정한다.
6. 사용자 JWT로 최대 200개 경로를 chunk한 Storage bulk signed URL을 5분 TTL로 발급하고 `{url, expires_at}`만 투영한다. signed URL 형식상 bucket/object 경로가 URL에 포함될 수 있음을 숨기지 않는다. 자산 부재·미검증·삭제·항목별 not-found는 해당 필드만 null, 요청 전체 5xx/형식 오류는 안전한 503으로 처리한다.

## 쓰기 경로와 additive migration

1. `update_my_garment`: `auth.uid()` 고정, 활성 본인 의류만 row lock, `expected_version` 확인, category/subcategory/memo presence flag를 적용하고 version을 1 증가시킨다.
2. category는 8종, subcategory는 nullable 80자, memo는 nullable 1,000자로 제한한다. NUL과 알 수 없는 key를 BFF/SQL 양쪽에서 거절한다.
3. `delete_my_garment`: `auth.uid()` 고정, SQL이 직접 garment ID의 request hash를 만들고 `Idempotency-Key` 형식을 재검증한다. 유효한 기존 replay를 garment 존재 검사보다 먼저 확인한다. 만료 행은 교체하고 동일 key/다른 대상은 409, 성공 status/body는 24시간 저장한다.
4. 삭제는 관련 batch row를 잠가 같은 batch의 동시 삭제를 직렬화한 뒤 garment `deleted_at`과 version을 갱신한다. cutout은 더 이상 참조하는 활성 garment가 없을 때, source는 batch에 활성 garment가 없을 때 각각 asset `deleted_at`을 표시한다. DB row는 FK 이력 보존을 위해 물리 삭제하지 않는다.
5. 두 RPC는 `security definer set search_path=''`, authenticated execute만 허용하고 table direct write revoke를 유지한다.
6. RPC 성공 후 update는 같은 JWT/RLS로 다시 읽는다. delete는 안전한 `{id,status:"deletion_pending"}`만 반환한다. 실제 Storage 객체 삭제 worker는 G3/후속 hosted 통합 전 미검증이다.

## 오류 매핑

- body/query/path 형식: 400 `INVALID_REQUEST_BODY` 또는 422 `VALIDATION_ERROR`.
- 본인 활성 row 없음: 404 `GARMENT_NOT_FOUND`.
- expected version 불일치: 409 `VERSION_CONFLICT`.
- idempotency key 누락/형식: 400/422, 동일 key의 다른 대상: 409 `IDEMPOTENCY_CONFLICT`. 단일 transaction RPC라 외부에서 관찰 가능한 진행 중 상태는 만들지 않는다.
- Storage signing/schema/upstream 장애: 안전한 503. upstream detail·object key 비노출.

## 증거와 완료 기준

- 새 migration과 `garment_writes.sql`: 본인 고정, 직접 write 거절, optimistic version, null/생략, cross-owner, soft delete, idempotency replay/conflict, orphan asset 표시 검증.
- handler/서비스/Storage signing client 단위 테스트: cursor/filter, DTO allowlist, signed URL, path/body/header 검증, RPC 인자·오류, HEAD/OPTIONS/405.
- synthetic success/error fixture, coverage registry, OpenAPI 상태·503, README/API/DB 설계와 export hash 갱신.
- 전체 unit, schema/embedded PostgreSQL, coverage, seed, smoke dry-run, diff-check 통과.
- 원격 DB·Storage·Preview·비밀값은 사용하지 않는다.

## 구현 전 검토 기록

- Claude CLI 읽기 전용 검토 완료: `canonicalModel=claude-opus-5-5`, `provider=firstParty`, `is_error=false`, web/하위 agent 없음.
- 관측 비용: CLI list 기준 USD 0.6477452. 실제 청구액과 같다고 단정하지 않는다.
- 직접 RPC 호출을 전제로 SQL이 최종 allowlist·소유권·idempotency를 검증하고 정확한 signature로 PUBLIC/anon execute를 revoke한다.
- OpenAPI의 subcategory `maxLength: 80`, 네 operation의 503, DELETE 202와 오류 코드 설명을 구현과 함께 동기화한다.
