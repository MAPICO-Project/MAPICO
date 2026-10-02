# G2 옷장 API 결과

상태: 완료 — 원격 DB·Storage·배포·비밀값 변경 없이 옷장 4개 operation을 로컬 구현·검증했다.

## 구현

- `listGarments`: category filter, 기본 20/최대 100, `created_at DESC,id DESC` limit+1 keyset cursor.
- `getGarment`: 본인 활성 의류 단건 조회.
- `updateGarment`: exact body allowlist, optimistic version, category/subcategory/note presence flag, narrow RPC 뒤 동일 JWT/RLS 재조회.
- `deleteGarment`: SQL 재검증 Idempotency-Key, 24시간 replay, batch lock, garment soft-delete, orphan cutout/source asset cleanup marker, 202 projection.
- `image`: garment cutout, `original_image`: 같은 batch의 source. 검증·비삭제 asset만 사용자 JWT로 5분 bulk signed URL 발급.
- DB raw attributes에서 `category` 컬럼, `attributes.subcategory`, `memo→note`만 새 DTO로 투영하고 AI 내부 속성과 raw object key는 별도 필드로 노출하지 않음.
- 자산 부재·항목별 not-found는 nullable image, Storage 요청 전체 실패·형식 오류는 안전한 503.

## DB·권한

- additive migration `202609300001_closet.sql` 추가. 기존 migration 수정 없음.
- `update_my_garment`, `delete_my_garment`는 `security definer set search_path=''`, `auth.uid()` 고정, authenticated 전용 execute.
- 직접 table write revoke 유지. SQL이 category/길이/idempotency를 재검증해 BFF 우회 직접 RPC도 같은 경계를 적용.
- `garment_writes.sql`에서 cross-owner, direct write, version conflict, idempotency replay/conflict, soft-delete, batch asset cleanup marker 검증.

## 검토

- Claude CLI Opus 읽기 전용 검토 1회 완료.
- 실행 증거: `canonicalModel=claude-opus-5-5`, `provider=firstParty`, `is_error=false`, web/하위 agent 0.
- CLI list 기준 관측 비용 USD 0.6477452. 실제 청구액과 같다고 단정하지 않음.
- HIGH 6건을 계획·SQL·HTTP·계약에 반영: RPC 권한/직접 호출, nullable asset 실패 구분, signed URL 경로 설명, DTO/DB 매핑, idempotency 순서·만료, batch 동시성.

## 검증

- `npm test`: 49/49 통과.
- `npm run test:schema`: OpenAPI 36 paths, migration 5개, SQL assertion 4개, embedded PostgreSQL 통과.
- `npm run coverage:contract`: 50 total, 10 implemented-local, 40 planned, registry/contract/RLS 10, ERD 22, `valid=true`.
- seed validator, Preview smoke dry-run(`network_used=false`), `git diff --check` 통과.
- 정본/사본 OpenAPI·API/DB 설계 hash 일치, export manifest 갱신.

## 미검증·다음

- hosted Supabase PostgREST/RLS/Storage bulk signing과 signed URL 실제 읽기, 병렬 delete, 실제 Storage cleanup worker는 미검증.
- signed URL 형식에는 bucket/object 경로가 포함될 수 있다. 만료 토큰 외 raw DB 경로 필드는 반환하지 않는다.
- 다음 bounded goal은 G3 배치 생성·조회·upload URL 재발급·업로드 완료 검증 4개 operation이다.
