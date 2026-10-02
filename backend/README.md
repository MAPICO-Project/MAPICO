# MyFit:Core · 마피코 백엔드

MAFICO 모노레포의 `backend/` 영역입니다. 저장소: https://github.com/MAFICO-Project/mafico (비공개).
모바일 웹 우선. 현재 구현은 배포/연결 검증 단계이며 제품 API 전체 구현이 아닙니다.

## 실제 구현
| 경로 | 동작 |
|---|---|
| / | 배포 안내 |
| /api/health | HTTP 런타임 200, 제품 준비 완료 아님 |
| /api/readiness | 제품 통합 미완료이므로 503 |
| /api/catalog | 정적 5스타일 샘플, DB 아님 |
| /api/aesthetics, /api/v1/aesthetics | Supabase 공개 추구미 카탈로그 읽기; 공통 안전 envelope 적용 |
| /api/v1/tpo-presets | deprecated TPO 공개 카탈로그 읽기; 제품 활성 사용은 미결 |
| /api/v1/me | GET/HEAD 내 프로필 조회와 PATCH 표시명·시간대 변경 |
| /api/v1/me/aesthetics | PUT 선호 추구미 1~3개 원자 교체 |
| /api/v1/me/onboarding | PUT 인지 분기·튜토리얼·완료 상태 저장 |
| /api/v1/garments | GET/HEAD 옷장 keyset 목록, category filter, 검증 자산 signed URL |
| /api/v1/garments/{garmentId} | GET/HEAD 상세, PATCH optimistic update, DELETE 멱등 soft-delete |
| /api/v1/garment-batches | POST 배치·source asset 예약과 signed upload 발급 |
| /api/v1/garment-batches/{batchId} | GET/HEAD 본인 배치 상태 조회 |
| /api/v1/garment-batches/{batchId}/upload-url | POST 미업로드 배치의 signed URL 재발급 |
| /api/v1/garment-batches/{batchId}/complete-upload | POST 실제 객체 검증과 uploaded 상태 전이 |
| /api/v1/garment-batches/{batchId}/analysis-jobs | POST 멱등 분석 job 생성 |
| /api/v1/analysis-jobs/{jobId} | GET/HEAD 안전한 분석 상태 조회 |
| /api/v1/analysis-jobs/{jobId}/retry | POST 실패한 분석 job 재시도 |
| /api/v1/garment-batches/{batchId}/drafts | GET/HEAD raw 예측 제외 draft 조회 |
| /api/v1/garment-drafts/{draftId} | PATCH optimistic 사용자 보정 |
| /api/v1/garment-batches/{batchId}/confirm | POST version 고정 원자 확정 |
| /api/internal/analysis-jobs/{jobId}/result | POST raw-body HMAC worker callback |
| /api/v1/weather/current | GET/HEAD 현재 예보 slot과 fresh/stale cache 조회 |
| /api/v1/recommendations | POST 날씨·추구미 기반 결정론 추천 생성 |
| /api/v1/recommendations/{recommendationId} | GET/HEAD 저장된 추천 안전 projection |
| /api/v1/recommendations/{recommendationId}/accept | POST 추천 outfit을 private worn OOTD로 채택 |
| /api/v1/saved-outfits, /api/v1/saved-outfits/{savedOutfitId} | 보관 코디 목록·생성·조회·수정·삭제 |
| /api/v1/ootd, /api/v1/ootd/{ootdId} | OOTD 목록·수동 생성·조회·수정·삭제 |
| /api/v1/closet/statistics | 실제 착용 기준 통계 |
| /api/v1/feed 및 하위 media/like 경로 | 피드·공유 미디어·좋아요·내 아카이브 |
| /api/v1/mimic-jobs, /api/v1/mimic-jobs/{jobId} | 따라입기 작업 생성·안전한 결과 조회 |
| /api/internal/mimic-jobs/{jobId}/result | domain-separated raw-body HMAC worker callback |

현재 G1~G8의 제품 API 49개가 로컬 구현됐습니다. docs/openapi.yaml v0.3의 50개 operation 중 49개가 `implemented-local`이고 `requestAccountDeletion` 1개만 `planned`입니다. 실제 hosted Supabase 통합이나 배포 완료를 뜻하지 않습니다.

옷장 읽기는 사용자 JWT/RLS로 활성 의류와 검증된 cutout/source asset을 조회하고, 같은 JWT로 5분 Storage signed URL을 발급합니다. URL 형식에는 bucket/object 경로가 포함될 수 있으나 DB의 raw object key와 내부 AI 속성은 별도 필드로 반환하지 않습니다. 수정·삭제는 `202609300001_closet.sql`의 본인 고정 narrow RPC를 사용하며 실제 Storage 객체 cleanup worker와 hosted signing은 미검증입니다.

G3 등록은 `202609300002_ingestion.sql`에서 idempotency row lock과 본인 고정 RPC로 batch/source asset/object key를 원자 생성합니다. Storage INSERT는 아직 미검증인 본인 source asset의 정확한 경로에만 허용하고 overwrite 권한은 주지 않습니다. 완료 요청은 ranged GET으로 MIME·크기·magic bytes를 검사하며 DB가 `storage.objects` owner·size·MIME를 다시 확인합니다. 로컬 Storage는 stub이고 실제 signed-upload URL, Range 응답, 정책 적용 시점은 hosted 미검증입니다.

G4 분석은 `202610010001_analysis.sql`의 사용자 고정 RPC와 service-only callback RPC를 사용합니다. 일반 경로는 사용자 JWT/RLS와 safe projection만 사용하고, 격리된 `lib/supabase-internal.js`만 `SUPABASE_SECRET_KEY`와 `AI_CALLBACK_HMAC_SECRET`을 읽습니다. callback은 raw-body HMAC, event replay, lease, canonical Storage 경로와 객체 metadata를 검증합니다. 실제 AI worker·hosted callback·secret 주입은 미검증입니다.

G5 날씨·추천은 10분 fresh/3시간 stale current-slot cache, provider 전 2분 reservation lease, 불변 snapshot, 날씨·사용자 추구미 기반 deterministic engine을 사용합니다. 자유 형식 LLM은 사용하지 않고 검증된 fact에서 template 설명만 렌더링합니다. 실제 provider·hosted 동시성·timezone 자정 E2E는 미검증입니다.

G6~G8은 보관 코디·OOTD·통계, 피드·공유 미디어·좋아요, 따라입기 비동기 작업을 구현합니다. 따라입기는 공개·검증된 피드 미디어와 본인 활성 의류를 생성 시 snapshot으로 고정하고, callback replay를 lease보다 먼저 판정합니다. 공개 응답의 source key는 내부 media UUID 대신 `source-N`으로 비식별화합니다. 실제 worker와 hosted Storage/Auth 동시성은 미검증입니다.

계정·온보딩 write operation은 strict body allowlist를 거쳐 `202609290001_account_onboarding.sql`의 사용자 고정 narrow RPC를 호출합니다. RPC의 `void` 성공 후 같은 사용자 JWT/RLS로 안전한 응답을 재조회합니다. `avatar_asset_id`는 Storage 수명주기 계약 전까지 422 `UNSUPPORTED_FIELD`로 거절합니다. RPC와 재조회는 단일 transaction이 아니므로 동시 쓰기가 있으면 재조회 시점의 최신 상태가 보일 수 있습니다.

## 실행/검증
```sh
npm ci --ignore-scripts
npm test
npm run test:schema
npm run coverage:contract
npm run smoke:preview
npm run seed:validate
```

Node 22. 서버 런타임 외부 의존성 없음. SQL 검증의 Auth/Storage와 `/me` 테스트의 upstream 응답은 스텁/mock이며 실제 Supabase 검증이 아닙니다.

`coverage:contract`는 OpenAPI 50개 operation과 migration의 24개 public 테이블을 직접 읽어 구현·계약 테스트·RLS 증거 상태를 보고합니다. `smoke:preview`는 기본적으로 네트워크를 사용하지 않는 dry-run입니다. 실제 Preview 검증은 사용자가 배포 URL을 확인한 뒤 `MAFICO_SMOKE_TOKEN`을 환경변수로만 제공하고 다음처럼 명시적으로 실행합니다. 토큰과 응답 본문은 출력하지 않습니다.

```sh
node scripts/smoke-preview.mjs --execute --base-url https://example-preview.vercel.app
```

Frontend origin은 `CORS_ALLOWED_ORIGINS`에 쉼표로 구분한 완전한 origin을 등록합니다. 와일드카드·`null`·부분 일치는 허용하지 않고, Bearer 인증을 사용하므로 credential cookie는 허용하지 않습니다. 예시 값과 실제 비밀값은 커밋하지 않습니다.

FE·AI 계약 샘플은 `test/fixtures/`에 있으며 `fixture-*` 식별자로 실제 사용자 데이터·실제 AI 결과와 구분합니다. 이 파일들은 런타임 코드에서 import하지 않습니다.

개발 seed 계약은 `fixtures/dev-seed.fixture.json`과 `npm run seed:validate`로 검사합니다. 다섯 taxonomy 항목은 최종 명칭이 아닌 `fixture_style_01`~`05` placeholder이며, 프로필·이미지는 실제 사용자나 파일이 아닌 metadata-only fixture입니다. 이 명령은 SQL을 만들거나 DB·네트워크에 연결하지 않습니다. 실제 개발 Supabase의 Auth 사용자는 Dashboard/Admin API로 별도 생성하고, 최종 taxonomy는 팀 승인 후 별도 migration으로 반영합니다.

## 배포
Vercel Node Functions, public/ 정적 안내. 일반 API는 `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`, `CORS_ALLOWED_ORIGINS`를 사용합니다. G4 callback과 G5 server-owned 저장에는 `SUPABASE_SECRET_KEY`가 필요하며, G4는 `AI_CALLBACK_HMAC_SECRET`, G5 실제 날씨 연동은 `WEATHER_PROVIDER_BASE_URL`, `WEATHER_PROVIDER_API_KEY`를 추가로 사용합니다. 이 값은 브라우저·fixture·로그에 두지 않습니다.

현재 Vercel 프리뷰: https://backend-cbv0u73ct-iscream.vercel.app
Supabase REST가 프로젝트에 응답하는 것은 확인했으나 스키마는 아직 원격 적용하지 않았습니다. 정확한 DB 연결 대상 확인 후 마이그레이션합니다.

## 구성
api/ HTTP 핸들러 · lib/ 공통 HTTP/Auth/CORS/Supabase 처리 · test/ 단위 테스트와 계약 fixture · fixtures/ 비실행 개발 seed 계약 · coverage/ 구현 증거 registry · supabase/ migrations/tests · docs/ 계약 스냅샷 · scripts/ 로컬 스키마·coverage·smoke·seed 검증.

.gitignore의 .env/.vercel/비밀 txt를 유지하세요. Vercel은 모노레포 전체가 아니라 `backend`를 Root Directory로 설정합니다.
