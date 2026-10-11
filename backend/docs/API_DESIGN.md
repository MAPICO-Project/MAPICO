# MAFICO(마피코) API 설계 v0.4

최신 정리 PRD `../product/PRD.md`와 변경표를 반영한 **모바일 웹 우선 설계 계약**이다. `openapi.yaml`은 39개 경로·53개 operation을 포함하며 53개 모두 `x-implementation-status: implemented-local`이다(2026-10-10 결정 반영으로 `DELETE /me`와 `GET /ootd/calendar`가 구현됨, 구현 현황은 `node backend/scripts/report-coverage.mjs`). v0.4는 2026-10-10 설계 보드 결정([DECISIONS](../records/decisions/DECISIONS.md), PM 협의 안건: [링크](../worklogs/2026-10-10_PM_협의안건.md))을 반영했다. health/readiness와 로컬 검증을 hosted 통합 완료로 해석하지 않는다.

## 계약 기준과 변경점

- `/api/v1`, Supabase JWT. 카카오 OAuth 로그인·로그아웃은 Supabase Auth SDK 경유하며 별도의 비밀번호 API를 만들지 않는다.
- 추구미는 **5종(개수 확정)** 중 메인 1개 + 보조 0~2개를 고른다. `role`(main/sub)이 정본이고 weight는 선택 입력(전부/전무, 생략 시 1/n, main ≥ sub)이다. 최종 5종의 명칭·정의는 팀 선정 대기이며, 종전 페미닌/Y2K/미니멀/그런지/캐주얼은 이전 제안·구현 seed 이력이다. 사진 탐색 분기의 점수 산식은 아직 미결이다. 추천의 Chip/메인/보조 가중(0.6/0.25/0.15)은 우리 쪽 임시 기준이다(PM 협의).
- TPO는 2026-10-10 제외 확정(PM 협의)이다. 조회 API·테이블은 deprecated로 남기며 v0.3 제안은 입력 생략/null만 허용하고 예전 프로필 기본값을 몰래 적용하지 않는다. `/tpo-presets`는 이전 호환 후보로 deprecated 처리했다. 팀 결정 후 별도 계약 변경한다.
- 코디 보관, 날짜별 착용 기록, 공유 게시물을 분리했다. 추천 채택 외에 직접 고른 옷으로 OOTD를 생성할 수 있다.
- 좋아요가 아카이브 역할을 한다. 독립 스크랩 API는 추가하지 않았다.
- 옷 카테고리(`GarmentCategory`)는 유저플로우 6종 outerwear·top·bottom·shoes·bag·accessory다(2026-10-09, dress·other 제거). AI callback의 `attributes.category`는 1~40자 라벨을 받되 6종 밖이면 draft `category=null`로 저장하고, 사용자가 draft PATCH로 6종 중 하나를 고르기 전까지 confirm은 422다. 추천의 옷장 충분 기준은 카테고리 무관 2벌 이상이다(2026-10-10, 아래 G5 절).
- 색상·추구미 예측은 내부 데이터로 보존하되 옷 상세/편집 DTO는 카테고리·하위분류·비고 중심으로 제한했다.

### 구현된 첫 수직 슬라이스: GET/HEAD `/me`

Bearer 토큰을 Supabase Auth `/auth/v1/user`로 확인한 뒤, 같은 사용자 JWT와 publishable key를 PostgREST에 전달해 기존 RLS로 `profiles`와 추구미 선호를 조회한다. service-role 키는 사용하지 않는다. 응답은 `Profile` 허용 필드만 재구성하며 토큰·Auth metadata·내부 DB 열·상위 오류 본문을 노출하지 않는다.

GET·HEAD·PATCH·DELETE를 지원하며 HEAD도 동일한 인증·조회 과정을 거치고 본문만 생략한다. 그 밖의 메서드는 405와 `Allow` 헤더를 반환한다. PATCH는 정확한 body allowlist와 16 KiB 제한을 적용하고 구 필드 `avatar_asset_id`를 422 `UNSUPPORTED_FIELD`로 거절한다. 프로필 이미지는 `avatar_upload_id`(검증된 본인 업로드, null이면 제거)로 바꾸고 응답 `avatar`는 5분 signed URL 또는 null이다. PATCH는 `ai_notice_accepted`(true만 허용, 철회 불가, 첫 동의 시각 유지)와 `training_consent`(boolean, 기본 false)도 받으며 프로필 필드와 한 트랜잭션(`update_my_profile_settings`)에 저장한다. `GET /me`가 두 값을 돌려준다. 학습 동의는 저장·조회만 하고 학습에는 아직 쓰지 않는다. 설정 누락·Auth/DB 장애는 503, 잘못된 토큰은 401, 프로필 없음은 404, validation은 422, rate limit은 429로 실패 폐쇄한다. 로컬 mock 테스트만 통과한 상태이며 실제 hosted Supabase Auth·RLS·PostgREST embed는 미검증이다.

`PUT /me/aesthetics`와 `PUT /me/onboarding`은 사용자 JWT로 narrow RPC를 호출하고 `void` 성공 뒤 같은 JWT/RLS로 허용 필드만 재조회한다. 알려진 SQLSTATE와 메시지만 404/422로 매핑하며 알 수 없는 upstream 오류 본문은 노출하지 않고 503으로 닫는다. RPC와 재조회는 단일 transaction이 아니므로 동시 쓰기 시 재조회 시점의 최신 상태가 응답될 수 있다.

`GET/HEAD /aesthetics`와 deprecated `GET/HEAD /tpo-presets`는 요청 Authorization을 사용하지 않고 publishable key로 활성 행을 익명 조회한다. 전자는 `{id,code,display_name,active}`, 후자는 알려진 5개 code의 `{code,display_name,description}`만 반환한다. TPO handler 구현은 최신 홈에서의 활성 사용 결정을 의미하지 않는다.

### 사용자 고정 narrow RPC와 HTTP 경계

additive migration `202609290001_account_onboarding.sql`은 `auth.uid()`로 대상을 고정한 `update_my_profile`, `replace_my_aesthetic_preferences`, `save_my_onboarding_state` RPC를 추가한다. 모두 `security definer`, 빈 `search_path`, authenticated 전용 execute를 사용하며 관련 테이블 직접 쓰기는 계속 금지한다. 표시명 `null` 초기화와 patch 생략을 별도 presence flag로 구분하고, 선호 교체는 1~3개·중복 없음·활성 카탈로그·가중치 합을 검사한 뒤 profile row lock 안에서 원자 교체한다.

세 RPC는 내부 DB row 전체를 반환하지 않는 `void` 함수다. BFF는 성공 후 같은 사용자 JWT/RLS로 안전한 projection을 재조회해 OpenAPI의 `Profile`, `Preferences`, `OnboardingState` 응답을 구성하며, 재조회 실패를 성공 응답으로 꾸미지 않는다. body validation·오류 mapping은 로컬 구현됐고 hosted PostgREST RPC 검증은 남아 있다.

### 회원 탈퇴 `DELETE /me` (2026-10-10)

Idempotency-Key 필수. ① 사용자 JWT 확인 ② 서버 키로 `purge_account_data` 실행(데이터 전부 삭제) ③ Supabase Auth Admin API로 auth 사용자 삭제 → 202 `{id, status:'deletion_pending'}`. 데이터 삭제가 실패하면 auth 사용자는 지우지 않는다. Admin 호출 실패는 503 `ACCOUNT_DELETION_INCOMPLETE`(retryable)이며 같은 요청을 재시도한다. 이미 삭제된 auth 사용자(404)는 성공으로 본다. Storage 객체 경로는 `storage_cleanup_queue`에 넣으며 이를 처리하는 worker는 아직 없다.

| 삭제 대상 | 비고 |
|---|---|
| 프로필·추구미 선호 | |
| 옷장 | 배치·자산·분석 작업·초안·의류·추구미 점수·임베딩 |
| 추천 | 요청·코디·아이템 |
| OOTD·코디 보관함 | |
| 피드 게시물 | 미디어·연결 아이템, 내 게시물에 남이 누른 좋아요 포함 |
| 내가 누른 좋아요 | |
| 따라입기 | 내 요청과 내 게시물을 대상으로 한 남의 요청 |
| 업로드 기록·멱등 키 | |
| Storage 객체 | 경로만 `storage_cleanup_queue`에 적재, 실제 삭제는 미구현 |

최근 재인증 요구는 없다. hosted Auth Admin 응답과 `storage.objects` 권한은 미검증이다.

### 외부 AI 전송 고지

`ai_notice_accepted`가 false인 사용자가 분석 작업을 만들거나 재시도하면 403 `AI_NOTICE_REQUIRED`(retryable=false)를 반환한다. 클라이언트는 고지 화면 뒤 `PATCH /me {ai_notice_accepted:true}`를 하고 다시 요청한다. 따라입기·추천 설명은 검사 대상이 아니다.

### G9 업로드: 프로필 이미지·OOTD 선택 사진

`POST /media-uploads`(purpose `avatar`|`ootd_photo`, Idempotency-Key)가 서버 경로의 signed PUT URL을 주고, `POST /media-uploads/{uploadId}/complete-upload`가 G3와 같은 방식(ranged GET MIME·magic bytes + RPC의 storage.objects owner·metadata 재검증)으로 검증한다. 검증된 업로드는 `PATCH /me`의 `avatar_upload_id`, `POST`·`PATCH /ootd`의 `photo_upload_id`로 기존 RPC와 같은 transaction에서 한 번만 붙는다. 다른 용도·미검증·이미 붙은 업로드는 409 `MEDIA_UPLOAD_CONFLICT`, 없는 업로드는 404 `MEDIA_UPLOAD_NOT_FOUND`, 24시간 내 미완료 10개 초과는 409 `TOO_MANY_OPEN_UPLOADS`다. 버킷은 비공개 `profile-media`·`ootd-private`이며 읽기는 사용자 JWT로 서명한다. 다른 사용자에게 프로필 이미지를 보여주는 경로(피드 작성자 아바타)와 교체된 객체 정리는 아직 없다.

## 주요 API 묶음

| 영역 | 경로 및 동작 | PRD |
|---|---|---|
| 프로필·온보딩 | `/me` 조회/수정(프로필 이미지 포함)/탈퇴, `/me/aesthetics` 메인·보조 교체, `/me/onboarding` 상태 저장 | MYP, OnBoarding |
| 업로드 | `/media-uploads` 생성, `/{uploadId}/complete-upload` 검증 | MYP 프로필 이미지, STC OOTD 사진 |
| 등록 | 배치 생성·signed URL·업로드 검증·Job 생성/조회·실패 재시도·draft 편집/확정 | CLO-002~004 |
| 옷장 | `/garments` 조회, `/garments/{id}` 상세/수정/삭제 | CLO-001/005 |
| 추천 | `/recommendations` 생성, 결과 조회, 선택 outfit의 accept | HOM-004/005 |
| 보관함 | `/saved-outfits` 목록/생성, 개별 조회/수정/삭제 | STC-005 |
| 캘린더 | `/ootd` 목록/수동 생성, `/ootd/calendar` 월별 대표+건수, 개별 상세/수정/삭제 | STC-001~004 |
| 통계 | `/closet/statistics` 실제 착용 횟수·30일 미착용·`top_aesthetic` | STC-006 |
| 공유 | `/feed` 탐색/작성, 개별 조회/수정/철회, 공유 이미지 업로드/검증 | FED-001/002 |
| 좋아요 | `/feed/{postId}/like` PUT/DELETE, `/me/likes`, `/me/posts` | FED-003, MYP-003/005 |
| 따라입기 | `/mimic-jobs` 생성, `/{jobId}` 결과 폴링 | FED-004/005 |

G2 옷장 읽기는 사용자 JWT/RLS로 활성 의류를 keyset 조회하고 검증된 cutout과 같은 batch의 source asset만 사용자 JWT로 5분 signed URL로 바꾼다. 응답 attributes는 `category` 컬럼, `attributes.subcategory`, `memo→note` allowlist로 새로 구성한다. signed URL 자체에는 Storage bucket/object 경로가 포함될 수 있으나 raw DB 경로와 내부 AI 속성을 별도 필드로 노출하지 않는다. 수정·삭제는 본인 고정 narrow RPC, optimistic version, SQL idempotency replay, soft-delete·asset cleanup marker를 사용한다. 실제 hosted Storage signing과 객체 cleanup worker는 미검증이다.

G3 등록은 body와 idempotency key를 엄격히 검증한 뒤 본인 고정 RPC가 batch, source asset, 서버 생성 object key를 한 transaction에서 만든다. signed upload는 등록된 본인 source 경로에만 INSERT 가능한 Storage RLS로 제한하고 upsert를 사용하지 않는다. 완료 요청은 최대 64 KiB ranged GET으로 MIME·크기·JPEG/PNG/WebP magic bytes를 확인하며, RPC가 `storage.objects` owner·size·MIME를 독립적으로 재검증한다. object 부재는 retry 가능한 409, 존재하지만 invalid인 객체는 422와 terminal `failed`로 처리한다. hosted Storage의 URL·Range·RLS 동작은 미검증이다.

G4 분석은 사용자 JWT/RLS 기반 job 생성·조회·재시도, raw 예측을 제외한 draft 조회·수정, exact version 집합을 요구하는 원자 확정을 구현한다. worker callback은 body parser를 끈 raw bytes에 `timestamp.raw_body` HMAC을 검증하고, 서버 전용 gateway 한 곳만 Supabase secret을 읽는다. callback event replay를 lease 검사보다 먼저 판정하며 Storage prefix·소유자·MIME·크기·magic bytes를 재검증한 뒤 service-only RPC가 job·draft·asset·batch를 한 transaction에서 전이한다. 실제 worker, hosted Storage와 secret 주입은 미검증이다.

G5 날씨·추천은 한국 지원영역의 시간당 current slot, 10분 fresh/3시간 stale cache를 사용한다. provider 호출 전에 사용자 고정 reservation과 2분 lease로 idempotency를 선점하며, 실패 후 lease가 만료되면 같은 key가 새 token으로 안전하게 재개한다. 추천 rule engine은 활성 의류, 날씨, 저장된 추구미 가중치를 결정론적으로 사용하고 설명은 검증된 fact 기반 template만 렌더링한다. 추천 생성 당시 stale 여부와 불변 weather snapshot을 보존하며 채택은 path-bound recommendation/outfit, 활성 의류, 날짜 충돌을 원자 검증한다. 실제 provider와 hosted 동시 요청은 미검증이다.

추천 요청(2026-10-10, 일부 PM 협의)은 `aesthetic_id`(uuid|null, 생략=메인)를 받는다. 사용자 선호(메인·보조)에 없으면 422다. 가중치는 선택한 Chip 0.6, 그 외 메인 0.25, 보조 0.15다. 응답은 `selected_aesthetic_id`를 돌려준다. 옷장 충분 기준은 카테고리 무관 2벌 이상이다. 2벌 미만이면 추천 0개와 `insufficient_wardrobe`, 하의가 없어도 있는 옷으로 조합한다. 3개 미만이면 만들어진 만큼 반환하고 `shortfall_reasons`(`insufficient_wardrobe`, `missing_category:<카테고리>`, `requested_count_not_reached`)와 이를 파생한 `missing_categories` 배열을 담는다. 구 코드 `missing_complete_base_outfit`은 새로 만들지 않는다. 날씨는 `GET /weather/current?region_code=seoul`과 추천 `location: { region_code }`로 시·도 17개를 직접 고를 수 있다(위치 거절 대비, 대표 좌표는 근사값). lat/lon과 region_code는 정확히 하나만 보내며 아니면 422다. TPO는 제외 확정이며 null만 허용한다.

정확한 필드·응답·오류는 같은 폴더 `openapi.yaml`을 따른다. 생성 명령에는 `Idempotency-Key`, 편집에는 `expected_version`이 필요한 경로가 명시돼 있다. 피드 편집은 현재 DB에 version이 없어 마지막 변경 우선이라는 임시 계약이며, 동시 편집 보호가 필요하면 DB version을 추가해야 한다.

## 코디 보관과 OOTD

보관함에는 날짜 없는 `title`, `note`, `garment_ids`, 선택적 `source_recommendation_id`를 저장한다. 의류 ID는 중복 없는 배열이며 모두 본인의 활성 의류여야 한다. 원자적으로 본체와 아이템을 저장한다. 보관함을 수정해도 과거 OOTD가 바뀌지 않는다.

수동 OOTD는 `worn_on`, `garment_ids`가 필수이며 `wear_status`는 생략하면 `worn`이고 `worn`만 보낼 수 있다(`planned`는 422). 선택 사진은 기록당 1장이며 `photo_upload_id`로 붙이고 응답 `photo`(signed URL|null)로 읽는다. `saved_outfit_id` 또는 `outfit_id`는 선택 출처이며 둘을 동시에 넣을 수 없다. DB의 item snapshot은 서버가 확정한 시점의 카테고리/옷 ID를 보존한다. 착용(`worn`)만 새로 쓴다. 예전 기록의 `planned`·`unconfirmed`는 조회만 허용하고 통계에서 제외한다. 미래 날짜에 `worn`을 입력하거나 `planned`에 별점을 입력하면 422를 반환하는 제안이다.

2026-10-10 결정(PM 협의: 플로우는 날짜당 1건처럼 표현)으로 **하루 여러 건**을 허용한다(날짜 유일 제약 해제). `/ootd` 목록 정렬은 `worn_on DESC, created_at DESC, id DESC`이며 cursor는 v2(created_at 포함, v1 cursor는 400)다. 추천 채택은 같은 날 다른 outfit이면 한 건 추가하고, 같은 날 같은 outfit을 다시 채택하면 기존 기록을 반환한다(더블탭 방지). `GET /ootd/calendar?from&to`(최대 62일)는 날짜별 대표 기록과 건수를 준다. 대표는 그날 사진 있는 기록 중 가장 최근, 사진이 없으면 가장 최근 기록이고 건수는 상태 무관 기록 수다. 사진은 서명 URL로만 나간다. 통계는 (기록, 의류) 단위로 세므로 같은 날 2건이면 2회다. 날짜 변경은 기록이 있는 날로도 가능하다. 날짜 변경과 기록 삭제는 이미 공유한 피드 게시물을 자동 변경하지 않는다. 사용자가 게시물 철회를 별도로 수행한다.

날씨는 임의 JSON을 받지 않는다. `weather_snapshot_id`의 날짜·지역을 서버가 검증한다. 과거 날씨 데이터가 없거나 미래 예보 범위를 벗어나면 null로 남기고 오늘 날씨를 대입하지 않는다. 현재 상세 위치를 공유 피드에 노출하지 않는다.

(2026-10-11) OOTD 목록·상세·캘린더·추천 채택 응답은 `weather`(저장 당시 날씨 요약: `weather_code`·`temperature_c`·`feels_like_c`·`precipitation_type`·`precipitation_probability`·`valid_at`, 없으면 null)를 함께 준다. `weather_code`는 강수형태에서 파생(rain·mixed→rain, snow→snow, none→clear, 그 외 unknown)하며 하늘상태는 수집하지 않는다. 날씨 제공자는 서버 환경변수 `WEATHER_PROVIDER`로 고른다: `adapter`(기본, 정규화 JSON HTTPS 어댑터) 또는 `kma`(기상청 data.go.kr 초단기실황 + 단기예보 POP 직접 호출, `WEATHER_PROVIDER_API_KEY`=serviceKey, `WEATHER_PROVIDER_BASE_URL` 생략 시 `https://apis.data.go.kr/1360000/VilageFcstInfoService_2.0`).

## 피드와 개인정보 경계

1. 사용자가 OOTD 또는 갤러리에서 공유 게시물 초안을 만든다. 본인 옷장 아이템 1~10개를 `garment_ids`로 연결해야 하며(`source_ootd_id`만 주면 그 OOTD의 쓸 수 있는 옷을 자동 연결, 없으면 409) 0개·중복·11개 이상은 422, 남의 옷은 404 `GARMENT_NOT_FOUND`, 삭제·미검증 옷은 409다. `FeedPostCreate.visibility`는 private만 허용한다. 연결 없는 구 포스트는 숨김·삭제는 되나 다시 공개할 수 없다(409 `FEED_CONFLICT`). 미디어 검증 후 별도 PATCH로 공개한다.
2. 공유 전용 `feed-private` 객체를 업로드하고 서버가 실파일을 검증한다. 원본 옷장 경로를 공개 URL로 바꾸지 않는다.
3. 사용자가 명시적으로 public 전환한다. 검증된 미디어가 1개 이상이어야 한다.
4. 읽을 때마다 공개/소유자 권한을 확인하고 짧은 signed URL을 발급한다. 비공개·삭제 시 새 발급은 즉시 중단된다. 기존 signed URL은 만료까지 접근 가능할 수 있으므로 만료시간 정책이 필요하다.

피드 DTO는 caption/공유 이미지/태그/작성자 표시 정보와 `linked_items`(`{id(연결 행 ID), position, category}`)만 제공한다. source OOTD ID, 작성자의 개인 의류 ID, 옷장 이미지, 색·패턴, 원본 경로, 내부 임베딩은 노출하지 않는다. 연결 시점 스냅샷을 저장하므로 원본 옷을 지워도 게시물은 유지된다. 연결 아이템의 공개용 사진은 구현하지 않았다(필요하면 작성자가 따로 올리는 방식, PM 협의). 현재 피드 DB는 추구미 태그 1개이며 다중 태그 여부는 제품 확인 대상이다. 온도 필터는 `[min,max)`로 제안하고 날씨 코드는 유저플로우 필터(맑음·흐림·비·눈·바람)에 맞춰 clear/cloudy/rain/snow/wind/unknown이다. 사용자 입력 날씨 태그를 관측 사실로 간주하지 않는다.

좋아요는 `(user_id, post_id)` 유일키로 PUT/DELETE 멱등 처리한다. 아카이브는 현재 볼 수 있는 포스트만 반환한다. 비공개/삭제 포스트의 좋아요가 보인다는 이유로 원문을 우회 조회할 수 없어야 한다.

## 따라입기와 AI

따라입기(2026-10-10 재설계)는 포스트에 연결된 아이템 ↔ 내 옷장을 서버가 동기로 매칭한다(대표 이미지 재분석 폐기). `POST /mimic-jobs`는 202와 Job ID를 유지하되 바로 succeeded/no_match가 되며 `GET /mimic-jobs/{jobId}`로 읽는다. 매처 rule-v1은 같은 카테고리만 후보로 하고 색·패턴·추구미로 점수를 내며(근거 데이터 없는 기준값), 내 옷장 아이템은 한 번만 배정한다. 임베딩(`garment_embeddings`)이 양쪽에 있으면 점수에 섞는다(현재 채우는 worker 없음).

응답에는 숫자 similarity를 내지 않고 등급만 낸다. 아이템별 `grade`는 high(내부 점수 0.75 이상)·medium(0.5 이상)·low, 매칭 없음은 null이다. 전체 `grade`는 연결 아이템 전체 점수 평균(미매칭 0)에 같은 기준을 적용하며 succeeded에서만 있다. 전체 등급 산정 방식(맞은 옷 수 기준 여부)은 PM 협의 대상이다. 매치에는 `post_item_id`(= 상세 `linked_items[].id`)와 `category`가 있어 상세와 짝지을 수 있다. 일부만 매칭돼도 succeeded가 될 수 있으며 coverage로 범위를 알린다. no_match는 추가 등록 CTA로 이어진다. 연결 없는 구 포스트로 요청하면 409 `MIMIC_CONFLICT`다. 대표 이미지 재분석 경로는 비활성이며 callback은 휴면이다.

매칭 결과 저장은 부수효과가 아니다. 사용자가 확인한 의류 ID로 `/saved-outfits`를 별도 호출한다. 생성/조회 모두 원본 포스트의 현재 가시성을 재검사하며, 삭제·비공개 원본은404를 반환한다. DB의 mimic result JSON은 일반 클라이언트 직접 조회를 막고 BFF가 허용된 projection만 반환한다. 구 callback은 `mimic.v1` domain-separated raw-body HMAC, event replay-before-lease, exact result schema와 snapshot fence를 검증한다. 공개 source key는 내부 media UUID 대신 `source-N`으로 비식별화한다. 실제 worker 실행과 hosted secret 주입은 미검증이다.

## DB 대비 구현 공백

| 계약 | 현재 SQL와의 관계 |
|---|---|
| 보관함·수동 OOTD·피드·좋아요·mimic | 로컬 HTTP·RPC·RLS 구현 완료, hosted Auth/Storage/worker E2E 미검증 |
| 의류 note/subcategory | API note는 신규 garments.memo 컬럼에 매핑; subcategory는 attributes의 허용 키로 저장하는 제안. 수정 allowlist 필요 |
| 온보딩 인지 분기·튜토리얼 상태 | additive 필드·narrow RPC·HTTP handler 로컬 완료. hosted 검증 필요 |
| 프로필 이미지 | G9 `media_uploads`·`avatar_upload_id` 로컬 완료. 타인에게 보이는 작성자 아바타·객체 정리 미구현 |
| 피드 작성자 표시 정보·like_count | service-only 안전 projection 구현, hosted 동시성 검증 필요 |
| 착장샷 | OOTD 선택 사진 1장은 G9 로컬 완료(ootd-private). 교체·삭제된 객체 Storage 정리 worker 필요 |
| 탈퇴 | `DELETE /me` 로컬 구현(데이터 전부 삭제 + auth 사용자 삭제). Storage 정리 worker·재인증·hosted Admin API 검증 필요 |
| 5시/7시 추천 | 팀 결정 전 온디맨드만 설계 |

Supabase 연결만으로 이 계약이 실행되지는 않는다. 마이그레이션 적용 뒤 사용자 JWT 검증, RLS 회귀검증, BFF 구현, Storage 검증과 삭제 worker, AI 연동을 순서대로 구현해야 한다.

## 검토와 검증

읽기 전용 설계 검토를 수행했다. 지적한 보관함 변경에 따른 과거 기록 오염, planned/worn 구분, 공유 전용 projection, 삭제 게시물 아카이브, 비동기 mimic의 다섯 항목을 계약에 반영했다. 이 검토가 원격 배포 검증을 의미하지는 않는다.

OpenAPI 3.1은 로컬 Swagger Parser 검증을 통과했다. 모든 `$ref`가 해결되는 계약 구조 검증이며 실제 HTTP endpoint 테스트는 아니다. DB 실행 검증 결과는 DB 설계/작업 요약을 별도로 참조한다.
