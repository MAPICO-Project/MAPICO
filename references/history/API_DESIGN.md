# 마피코 API 설계 v0.2 — 이전 범위

> 2026-09-28: 프로젝트명은 마피코로 확정. 이 문서의 M0.5는 이전 축소 설계안이며 최신 전체 PRD를 충족하지 않습니다. `PRD_DELTA_2026-09-28.md`를 먼저 읽으세요. 현재 HTTP 임시 배포는 아래 API의 구현체가 아닙니다.

작성일: 2026-09-27. 실행 가능한 서버가 아니라 구현·검토용 계약이다. 정본은 `api/openapi.yaml`이며, 이전 `API_DESIGN_DRAFT_2026-09-27.md`는 이력으로 남긴다.

## 적용 범위와 변경점

M0.5의 프로필, 추구미 선택, 원샷 의류 등록, 분석 결과 수정·확정, 옷장, 날씨, 추천, 비공개 OOTD를 다룬다. 전체 23개 경로·27개 operation이다. 소셜 로그인은 Supabase Auth SDK가 수행하며 별도의 비밀번호 저장 API를 만들지 않는다.

기존 초안에서 모호했던 추천 세트와 개별 코디 ID를 분리했다. 추천 확정에는 `outfit_id`가 필수다. 추구미 선호는 전달된 PRD대로 **1~3개**다. 전체 카탈로그를 5개로 줄인다는 회의 방향은 반영하되, 이름이 전달되지 않은 5개 추구미를 임의로 생성하지 않는다. 카탈로그 등록 전 선택 UI는 빈 상태를 안내한다.

TPO는 선택적이다. 요청에서 생략하면 프로필 기본값을 사용하고, 기본값도 없으면 TPO 점수 계산을 제외한다. 명시적 `null`은 프로필 값과 무관하게 제외한다. 이때 응답 `scores.tpo=null`이며 다른 점수의 가중치를 재정규화한다. TPO별 추가 지도학습은 초기 계약의 전제 조건이 아니다.

피드·스크랩·댓글·Mimic·swap·수동 코디/OOTD 생성·공개 OOTD·캘린더 자동 분석·정시 사전 추천은 후속 단계이며 현재 OpenAPI에서 제거했다. OOTD는 추천 코디 확정으로 생성한다. 샘플 피드는 FE fixture로 시연 가능하다. 삭제된 이전 경로가 구현되어 있다고 가정하지 않는다.

## 공통 계약

- Base path: `/api/v1`. 서버는 Vercel BFF이며 DB/Auth/Storage는 Supabase다.
- 사용자 API: `Authorization: Bearer <Supabase access token>`. 서명·issuer·audience·만료를 검증하고 사용자 ID는 검증된 `sub`에서만 가져온다.
- 카탈로그 GET만 익명 접근을 허용한다. 내부 callback은 별도 HMAC 인증을 사용한다.
- 다른 사용자의 자원은 404로 응답한다. 클라이언트가 보내는 `user_id`, 임의 저장소 경로를 소유권 근거로 사용하지 않는다.
- 날짜는 ISO `YYYY-MM-DD`, 시각은 RFC3339 UTC offset 포함. OOTD 날짜 해석에는 프로필 IANA timezone을 사용한다.
- 생성·확정·재시도·삭제 명령에는 `Idempotency-Key`가 필수다. 사용자+operation+키로 24시간 저장하고 canonical request hash를 비교한다. 같은 body는 최초 HTTP status/body를 재생, 다른 body는 409, 처리 중이면 409 `REQUEST_IN_PROGRESS`다. 재생된 응답의 signed URL이 만료되었으면 별도 재발급 API로 갱신한다.
- draft/garment/OOTD 수정은 `expected_version`을 받는다. 버전 불일치면 409이며 최신 조회 후 수정한다. 여러 필드 변경은 한 번에 저장한다.
- 페이지는 keyset cursor, 기본20·최대100개다. 날짜/카테고리 필터가 바뀌면 cursor를 폐기한다. cursor는 서명되거나 서버 검증되는 불투명 토큰이다.
- 모든 오류는 `error.code/message/retryable/request_id/details` 형식이다. 클라이언트는 영문 `code`로 분기하고 한국어 message를 그대로 파싱하지 않는다.

| HTTP | 의미 | 대표 code |
|---|---|---|
| 400 | JSON/쿼리 형식 오류 | INVALID_REQUEST |
| 401 | 토큰/서명 없음·만료·실패 | UNAUTHENTICATED |
| 404 | 없음 또는 접근 불가 | RESOURCE_NOT_FOUND |
| 409 | 상태·버전·멱등 충돌 | VERSION_CONFLICT, IDEMPOTENCY_CONFLICT, REQUEST_IN_PROGRESS, STALE_ATTEMPT, OOTD_ALREADY_EXISTS |
| 413 | 업로드 크기 제한 | IMAGE_TOO_LARGE |
| 422 | 필드/도메인 조건 위반 | VALIDATION_FAILED, INVALID_IMAGE, AESTHETICS_REQUIRED |
| 429 | 요청 제한 | RATE_LIMITED (`Retry-After` 초) |
| 503 | 의존 서비스 사용 불가 | WEATHER_UNAVAILABLE, STORAGE_UNAVAILABLE |

## 외부 API 목록

| Method | Path | 주요 입력 → 응답 |
|---|---|---|
| GET/PATCH | `/me` | 프로필 및 기본 TPO → Profile |
| GET | `/aesthetics` | 활성 카탈로그 → AestheticList |
| GET | `/tpo-presets` | 선택 가능한 TPO → TpoList |
| PUT | `/me/aesthetics` | 고유 aesthetic_id 1~3개, 양의 가중치 합1 → Preferences |
| POST | `/garment-batches` | MIME·크기 → BatchCreated·signed upload |
| GET | `/garment-batches/{batchId}` | → Batch |
| POST | `/garment-batches/{batchId}/upload-url` | 만료 재발급 → SignedUpload |
| POST | `/garment-batches/{batchId}/complete-upload` | 실제 객체 확인 → Batch |
| POST | `/garment-batches/{batchId}/analysis-jobs` | → 202 AnalysisJob |
| GET | `/analysis-jobs/{jobId}` | → AnalysisJob |
| POST | `/analysis-jobs/{jobId}/retry` | 실패 작업 재큐잉 → 202 AnalysisJob |
| GET | `/garment-batches/{batchId}/drafts` | → DraftList (최대6개) |
| PATCH | `/garment-drafts/{draftId}` | version·수정 속성 → GarmentDraft |
| POST | `/garment-batches/{batchId}/confirm` | draft_ids·draft_versions → 201 ConfirmResult |
| GET | `/garments` | category·cursor·limit → GarmentPage |
| GET/PATCH/DELETE | `/garments/{garmentId}` | 상세/수정/삭제예약 → Garment 또는202 |
| GET | `/weather/current` | lat·lon → WeatherSnapshot |
| POST | `/recommendations` | 위치·선택 TPO·요청 개수 → 201 RecommendationSet |
| GET | `/recommendations/{recommendationId}` | 추천 세트 → RecommendationSet |
| POST | `/recommendations/{recommendationId}/accept` | outfit_id·worn_on → 201 Ootd |
| GET | `/ootd` | 기간 조회 → OotdPage |
| PATCH/DELETE | `/ootd/{ootdId}` | 메모·평점/기록삭제 → Ootd /204 |

## 업로드·분석·확정

클라이언트는 BFF에서 받은 `upload.url/method/headers`를 그대로 사용해 private Storage에 직접 업로드한다. 20MiB는 MVP 설계 기본값이며 이미지 MIME은 JPEG/PNG/WebP만 허용한다. 서버는 파일 확장자를 신뢰하지 않고 파일 바이트·실제 크기·디코딩 가능 여부를 검사한다. 객체 키는 서버가 사용자와 배치에 묶어 생성하고 upsert를 허용하지 않는다. 만료된 업로드 URL은 아직 업로드 전인 배치에서만 갱신한다.

`complete-upload`가 객체를 검증한 뒤에만 분석을 요청할 수 있다. `analysis_jobs` 자체를 내구성 있는 DB 큐로 사용하고, 배치 상태와 Job 생성을 동일 DB 트랜잭션으로 처리한다. dispatcher가 claim RPC로 lease를 얻어 외부 AI를 호출한다. 커밋 후 외부 호출이 실패하면 lease 만료 후 다시 claim하므로 메모리 작업 유실에 의존하지 않는다.

분석은 `queued → running → succeeded / partial_failed / failed`다. 최초 claim 전 `attempt=0`, claim/reclaim할 때 attempt가 증가한다. failed 재시도는 동일 job을 queued로 돌리고 다음 claim에서 새 lease를 발급한다. M0.5의 partial_failed는 `retryable=false`다. 성공 결과를 검토·확정하거나 새 배치로 재촬영한다. 부분 재시도는 사용자 수정값을 보존하는 증분 결과 저장이 준비된 후 확장한다.

draft는 예측 원본 `predicted_attributes`와 사용자 편집 `current_attributes`를 분리한다. callback이 나중에 도착해도 사용자 수정값을 덮어쓰지 않는다. 확정은 1~6개 draft 소유권·버전을 모두 확인하고 garments 생성, draft 상태, batch 상태를 한 트랜잭션에서 처리한다. 미선택 draft는 rejected다. partial 결과를 확정하면 그 배치는 더 이상 재분석하지 않는다.

## 내부 Worker callback

`POST /internal/analysis-jobs/{jobId}/result`는 사용자 JWT 대신 `X-Worker-Timestamp`, `X-Worker-Signature`를 검증한다. 서명은 `HMAC-SHA256(secret, timestamp + '.' + raw_request_body)`의 hex이며 허용 시각 편차는 ±300초다. 서명 비교는 constant time으로 한다. body의 job_id가 path와 같아야 하며 body 전체에 서명하므로 경로 바꿔치기도 거부한다.

payload는 `event_id`, `job_id`, `attempt`, `lease_token`, terminal status, model_versions, items, errors다. 현재 running job의 유효 lease token/attempt와 일치할 때만 결과를 반영한다. 이미 처리한 동일 event/payload는 `applied=false`로 200을 반환한다. 같은 event의 다른 payload, 만료 lease, 이전 attempt는409다. 동일 event replay 확인은 terminal 상태 검사보다 먼저 수행한다.

각 item은 고유 client_item_key, 정규화 bbox, 허용 prefix 내 mask_object_key, 예측 attrs/confidence를 포함한다. bbox는 x_min<x_max·y_min<y_max, 파일은 존재 및 소유권 확인이 필요하다. succeeded는1~6개 items·errors0, partial은1~6개 items·errors1개 이상, failed는items0·errors1개 이상이다. Worker는 service role key를 받지 않고 제한된 업로드/다운로드 권한만 받는다. 실제 Worker claim·lease 갱신 transport는 별도 내부 구현 작업이다.

## 추천·OOTD

추천 세트 ID는 `recommendation_requests.id`, 각 코디 ID는 `outfit_recommendations.id`다. accept에는 세트 URL과 `outfit_id`가 모두 필요하며 서버에서 관계를 검증한다. 보유 옷이 부족하면 3개를 억지로 만들지 않는다. 1~2개만 가능하면 그 개수와 shortfall_reasons를 반환하고, 0개면 같은 201 응답에서 `status=insufficient_wardrobe`, `outfits=[]`를 반환한다. 추천 요청은 저장되었으므로 201이다.

추천 결과는 날씨·추구미·TPO·조화도 점수와 구조화 근거, engine/rules version을 포함한다. LLM 실패 시 근거 템플릿 설명으로 대체한다. accept는 현재 소유한 활성 의류·만료 여부·`worn_on=target_date`를 다시 확인한다. 같은 사용자·날짜에 OOTD는 하나다. 동일 명령은 멱등 재생하고, 같은 날짜·같은 outfit이면 기존 기록을 반환한다. 다른 코디로 기록을 추가하려 하면409로 기존 기록을 보호한다. 다른 선택으로 바꾸려면 기존 OOTD를 삭제 후 새로 기록한다. 이 UX는 MVP 기본안이며 다회 착장 기능이 필요하면 DB unique 및 API를 함께 변경한다.

현재 weather endpoint는 기상청 **단기 예보의 현재 시간대 데이터**를 사용한다. `issued_at`은 발표 시각, `valid_at`은 예보 대상 시각, `fetched_at`은 수집 시각이다. 이를 observed_at으로 표현하지 않는다. 미세먼지는 별도 제공자가 준비되지 않으면 null이며 추천 판단에 사용하지 않는다. 원시 위경도 대신 필요한 격자·시간대만 날씨 스냅샷에 저장한다.

## DB 매핑과 구현 경계

| API 도메인 | DB |
|---|---|
| Profile/Preferences | profiles, aesthetics, user_aesthetic_preferences, tpo_presets |
| Batch/Job/Draft | garment_batches, analysis_jobs, garment_drafts, garment_assets |
| Closet | garments (예측 provenance는 draft 참조) |
| Weather | weather_snapshots |
| RecommendationSet/Outfit | recommendation_requests, outfit_recommendations, outfit_items |
| OOTD | ootd_entries → outfit_recommendations / outfit_items 참조 |

응답은 DB row 그대로가 아닌 BFF projection이다. signed image URL·만료시각·JSON attrs 조립은 BFF 책임이다. DB draft의 `raw_prediction`/`user_overrides`는 API `predicted_attributes`/`current_attributes`로 변환하고 `item_index`는 안정 item key로 표현한다. Worker callback의 mask 경로는 검증한 `asset_id`로 바꿔 finish RPC에 전달한다. 멱등 ledger, callback dedupe, queue lease, 권한 검증은 SQL만 배포한다고 완성되지 않으며 BFF/Worker 구현과 통합 테스트가 필요하다.

## 구현 완료 검증 기준

1. 타인 자원 조회/수정/이미지 URL 발급이 모두 거부된다.
2. 동일 confirm/accept/분석 요청을 동시에 재전송해도 결과가 한 번 생성된다.
3. 이전 lease callback이 최신 결과를 바꾸지 않으며 동일 event replay는200이다.
4. 사용자 수정값이 예측값과 함께 보존되고 partial_failed 재시도는 거부된다.
5. 부족한 옷장·날씨 장애·LLM 장애에 정의된 응답이 나온다.
6. TPO 생략/null/명시값과 outfit 소속/만료/삭제 조건을 검증한다.

OpenAPI 파싱·참조 검증은 계약 파일의 정합성 검사일 뿐 위 서버 동작 검증의 대체가 아니다.
