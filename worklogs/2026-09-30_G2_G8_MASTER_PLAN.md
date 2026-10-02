# G2~G8 백엔드 구현·전체 회귀 마스터 계획

상태: 로컬 구현·검토·회귀 완료 — G2~G8 완료, OpenAPI 49/50 `implemented-local`

## 1. 목표와 정확한 범위

- 완료 기준: OpenAPI 50개 중 49개 `implemented-local`, 1개 `planned`.
- 이번 범위: G2~G8의 43개 operation을 순차 구현해 누적 49/50을 달성했다.
- 범위 밖 잔여: `requestAccountDeletion` 1개는 로드맵상 G9다. G2~G8 완료 뒤에도 자동 완료 처리하지 않고 별도 계획 대상으로 남긴다.
- 각 G는 독립 bounded goal로 `계획 → 읽기 전용 검토 → 구현 → 테스트 → 기록 → 다음 G` 순서를 지킨다.
- 기존 backend 수정·미추적 변경은 사용자 작업으로 보존하며 reset/checkout/clean/commit하지 않는다.

## 2. 공통 안전·완료 기준

1. 원격 Supabase SQL 적용, Vercel 배포, GitHub 변경, 외부 계정 설정, 비밀값 생성·수정·출력을 하지 않는다.
2. DB 변경은 새 additive migration으로만 작성하며 기존 migration은 수정하지 않는다.
3. 브라우저 요청은 사용자 JWT/RLS를 기본으로 한다. service role이 필요한 내부 작업은 명시적 server-only 경계와 주입 가능한 gateway로 분리하고 비밀값을 코드·fixture·로그에 넣지 않는다.
4. body/query/path allowlist, 크기·개수·UUID·cursor·version/idempotency 검증을 upstream 전에 수행한다.
5. fixture·fallback·실제 AI/Storage/날씨 결과를 응답과 문서에서 구분한다. mock 성공만으로 operation을 `implemented-local`로 올리지 않는다.
6. handler, 실제 로컬 실행 경로 또는 안전한 adapter, contract fixture, 단위 테스트, SQL/RLS 증거, coverage registry, OpenAPI 상태가 모두 있어야 `implemented-local`로 센다.
7. 각 G 종료 시 `npm test`, `npm run test:schema`, `npm run coverage:contract`, `npm run seed:validate`, `npm run smoke:preview`, `git diff --check`를 실행한다.
8. hosted Auth/PostgREST/Storage, 실제 외부 API·AI worker, Preview E2E는 별도 `미검증`으로 유지한다.

## 3. 실행 순서

### G2 — 옷장 읽기·기본 변경 (+4, 누적 10/50) — 로컬 완료

- operation: `listGarments`, `getGarment`, `updateGarment`, `deleteGarment`.
- 중심 테이블: `garments`, `garment_assets`, `garment_aesthetic_scores`.
- 구현: cursor/page 계약, 공개 가능한 asset projection, soft-delete 제외, category/memo 수정, optimistic version, 소유자 고정 update/delete RPC.
- 핵심 테스트: 타인 소유 차단, 삭제 행 비노출, 내부 object key·모델 점수 비노출, stale version 충돌, 목록/상세 DTO 일치.

### G3 — 등록·Storage 기반 (+4, 누적 14/50) — 로컬 완료

- operation: `createGarmentBatch`, `getGarmentBatch`, `refreshUploadUrl`, `completeGarmentUpload`.
- 중심 테이블: `garment_batches`, `garment_assets`, `idempotency_keys`, Storage adapter.
- 구현: 서버 생성 object key, MIME/크기/개수 제한, idempotency, signed-upload gateway, 업로드 검증 완료 전 분석 차단.
- 핵심 테스트: 경로 조작·다른 사용자 batch·중복 완료·만료 URL·잘못된 metadata 차단. 실제 Storage 서명·객체 HEAD는 hosted 미검증으로 유지.

### G4 — AI 등록 job·draft·확정 (+7, 누적 21/50) — 로컬 완료

- operation: `createAnalysisJob`, `getAnalysisJob`, `retryAnalysisJob`, `listGarmentDrafts`, `updateGarmentDraft`, `confirmGarmentBatch`, `receiveAnalysisResult`.
- 중심 테이블: `analysis_jobs`, `garment_drafts`, `garments`, `garment_assets`, `garment_aesthetic_scores`.
- 구현: 상태 전이·재시도·lease/attempt, worker callback 인증 경계, AI 원본과 사용자 수정 분리, version 충돌, batch 원자 확정.
- 핵심 테스트: 중복 callback 멱등성, stale attempt 거절, 타인 job 차단, fixture/model version 구분, 2~6벌 draft→수정→확정 로컬 흐름.

### G5 — 날씨·추천 기반 (+4, 누적 25/50) — 로컬 완료

- operation: `getCurrentWeather`, `createRecommendation`, `getRecommendation`, `acceptRecommendation`.
- 중심 테이블: `weather_snapshots`, `recommendation_requests`, `outfit_recommendations`, `outfit_items`, `ootd_entries`.
- 구현: 날씨 provider gateway와 snapshot, 추천 요청 idempotency·상태, 소유 의류 검증, 설명 source(`template`/`llm`) 구분, 채택 RPC.
- 핵심 테스트: provider/AI 실패 fallback, 미래·과거 snapshot 오용 차단, 삭제 의류 제외, 타 사용자 결과 비노출, 중복 채택 안전성.

### G6 — 보관함·OOTD·통계 (+11, 누적 36/50) — 로컬 완료

- operation: `listSavedOutfits`, `createSavedOutfit`, `getSavedOutfit`, `updateSavedOutfit`, `deleteSavedOutfit`, `listOotdEntries`, `createManualOotd`, `getOotd`, `updateOotdEntry`, `deleteOotdEntry`, `getClosetStatistics`.
- 중심 테이블: `saved_outfits`, `saved_outfit_items`, `ootd_entries`, `garments`, `weather_snapshots`.
- 구현: 조합 소유권·중복 검증과 원자 저장, optimistic version, OOTD item snapshot, 원본 링크 최대 하나, `wear_status=worn` 통계만 집계.
- 핵심 테스트: 보관함 변경 후 과거 OOTD 불변, 하루 중복 정책 유지, cross-owner FK 차단, 삭제 참조 충돌, planned/unconfirmed 통계 제외.

### G7 — 피드·미디어·좋아요 (+11, 누적 47/50) — 로컬 완료

- operation: `listFeed`, `createFeedPost`, `getFeedPost`, `updateFeedPost`, `deleteFeedPost`, `createFeedMediaUpload`, `completeFeedMedia`, `likeFeedPost`, `unlikeFeedPost`, `listLikedPosts`, `listMyPosts`.
- 중심 테이블: `feed_posts`, `feed_media`, `post_likes`, `ootd_entries`, `idempotency_keys`, feed Storage adapter.
- 구현: 공개 전용 projection, 비공개/삭제 가시성, OOTD 원본 비노출, 공유용 media 복사·검증, 좋아요 멱등성, cursor pagination.
- 핵심 테스트: 타인 OOTD/closet path 유출 차단, 비공개 전환 후 archive 숨김, signed URL 전 검증, 삭제 게시물·중복 좋아요·타인 media 조작 차단.

### G8 — 따라입기 (+2, 누적 49/50) — 로컬 완료

- operation: `createMimicJob`, `getMimicJob`.
- 중심 테이블: `mimic_requests`, `feed_posts`, `garments`, `saved_outfits`, `saved_outfit_items`.
- 구현: 접근 가능한 게시물만 요청, 비동기 상태/재시도 경계, raw AI result 비노출, 본인 소유 의류 재검증 후 saved-outfit handoff.
- 핵심 테스트: 게시물 비공개·삭제 전환, no-match/failure, 타인 의류 ID 주입 차단, safe model version 외 내부 metadata 비노출, 게시자 탈퇴 cascade 회귀.

## 4. 검토·통합 전략

- G2/G3, G4, G5/G6, G7/G8의 네 architecture 묶음으로 읽기 전용 고난도 검토를 수행하고 실제 model metadata·관측 비용을 기록한다.
- 구현 파일은 root 단일 작성자로 유지한다. 별도 agent나 CLI가 파일을 수정하지 않게 하고 검토 결과만 회수한다.
- 공통 모듈(auth/error/CORS/Supabase client)은 필요한 최소 변경만 하며 매 G마다 기존 G1 회귀를 먼저 확인한다.
- OpenAPI 정본 `deliverables/backend/openapi.yaml`과 `backend/docs` 사본은 각 G 종료 시 해시를 동기화한다.

## 5. 전체 회귀·최종 보고

G8 완료 기준 전체 감사 결과는 다음과 같다.

- OpenAPI 50개 중 정확히 49개 `implemented-local`, G9 `requestAccountDeletion`만 `planned`다.
- 전체 unit test 98/98 통과.
- 독립 `npm run test:schema` 통과.
- `npm run coverage:contract` 49/50, valid=true.
- `npm run seed:validate`, `npm run smoke:preview -- --dry-run`, diff-check 통과.
- 원격 Supabase DB·Storage·배포·비밀값은 변경하지 않았다.
- hosted Auth/PostgREST/Storage, 실제 외부 provider·AI worker와 Preview E2E는 여전히 미검증이며 로컬 완료와 구분한다.

## 6. 중단하지 않고 진행하되 완료로 속이지 않는 조건

- 제품 결정이 없어도 보수적 기존 계약으로 진행하되, 계약 자체가 모순되거나 데이터 손실 위험이 있으면 해당 G를 checkpoint하고 독립적인 다음 작업을 계속한다.
- 실제 원격 자격증명·외부 계정·팀 결정만이 필요한 항목은 로컬 adapter와 테스트까지 완료하고 `hosted 미검증`으로 남긴다.
- 테스트가 실패한 상태, mock-only 경로, 문서/coverage 불일치는 완료로 집계하지 않는다.
- 매 단계 결과를 `worklogs/2026-09-30_G{n}_*_RESULT.md`에 남겨 아침에 현재 위치와 재개 지점을 바로 확인할 수 있게 한다.
