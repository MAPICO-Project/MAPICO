# G3 배치·업로드 수직 슬라이스 결과

상태: 완료

## 결과

- `createGarmentBatch`, `getGarmentBatch`, `refreshUploadUrl`, `completeGarmentUpload` 4개를 `implemented-local`로 전환했다. 누적 coverage는 14/50이며 36개가 planned다.
- `202609300002_ingestion.sql`에 충돌 안전 idempotency, awaiting_upload 상한, 서버 생성 object key, batch/source asset 원자 생성, upload 완료 재검증과 terminal invalid 전이를 추가했다.
- Storage INSERT/SELECT는 본인·등록 source·미검증·미삭제·awaiting_upload·정확한 경로에만 허용한다. UPDATE/DELETE/upsert 권한은 추가하지 않았다.
- HTTP 경로는 사용자 JWT만 사용한다. signed URL은 프로젝트 HTTPS host·정확한 upload/sign 경로·단일 token query를 검사하고 Content-Type을 고정한다.
- 완료 경로는 64 KiB ranged GET, 응답 MIME, Content-Range total, JPEG/PNG/WebP magic bytes를 검사한다. RPC도 `storage.objects` owner·size·MIME를 다시 검사한다.
- object 부재는 retry 가능한 409로 유지하고, 존재하지만 invalid인 객체는 422와 batch `failed`로 종결한다. token·URL·object body는 idempotency row에 저장하지 않는다.

## 검토 반영

- Claude CLI 읽기 전용 검토: `canonicalModel=claude-opus-5-5`, `provider=firstParty`, `is_error=false`, session `dee79fb3-1893-491e-a4bc-969f1a8bcfba`, web/하위 agent 0, list 기준 USD 1.3931388.
- DB 재검증, 미검증 source 전용 SELECT, 정확한 INSERT policy, URL allowlist, 무-upsert, Range 검사, invalid terminal 처리, 충돌 안전 idempotency, open batch 상한을 반영했다.

## 검증

- unit: 56/56 통과.
- OpenAPI: 36 paths 검증 통과.
- additive migrations: 6개 실행 통과.
- SQL assertions: `account_writes`, `garment_writes`, `ingestion`, `product`, `security` 통과.
- coverage: 14 implemented-local / 36 planned, contract/RLS evidence 14, 22 tables, `valid=true`.
- seed validator 통과, preview smoke dry-run `network_used=false`, `git diff --check` 통과.
- canonical/copy hash 일치:
  - openapi `8acbe663e74894d2e5999ee20a2cfd5bb64c968840682209ac87bf38561ec264`
  - API design `486e28046de4d226d0e2f5aa5b4d78bce436b711cbb7e2e1b0c4baf546315a4f`
  - DB design `3820403f9fd3510845f79b02089e0068addcbc4d296b6554a0e723eb96b3e883`

## 미검증 경계

- 실제 Supabase Storage의 signed-upload URL 응답 형식, 2시간 유효기간, INSERT RLS 적용 시점, overwrite 충돌, Range/Content-Range 응답은 원격 환경에서 실행하지 않았다.
- PGlite의 Auth/Storage는 stub이다. 실제 object cleanup worker와 분석 worker의 재디코딩 검증도 후속 hosted/worker 범위다.
- 원격 DB·배포·실제 환경변수·비밀값은 변경하거나 출력하지 않았다.
