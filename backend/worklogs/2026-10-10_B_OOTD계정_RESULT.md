# 2026-10-10 트랙 B — OOTD 여러 건·고지/학습 동의·회원 탈퇴 RESULT

근거: [DECISIONS 2026-10-10](../records/decisions/DECISIONS.md), [결정 반영 계획](2026-10-10_결정반영_PLAN.md). 커밋·원격 DB 명령 없음.

## 1. 하루 OOTD 여러 건
- **무엇을**: migration `202610100002_ootd_multi_account.sql`이 `ootd_entries (user_id, worn_on)` 유일 제약을 컬럼 기준 카탈로그 조회로 제거하고, 목록 인덱스를 `(user_id, worn_on desc, created_at desc, id desc)`로 바꿨다. `create_my_ootd`는 날짜 충돌 검사를 없애고 worn만 받는다(생략 시 worn, planned면 `invalid_ootd`). `update_my_ootd`는 기록이 있는 날짜로 옮길 수 있고 wear_status는 worn만 보낼 수 있다(이전 planned→worn 전환용). `accept_my_recommendation`은 같은 날 다른 outfit이면 한 건 추가, 같은 날 같은 outfit을 다시 채택하면 기존 기록 반환(더블탭 방지). 새 RPC `get_my_ootd_calendar(from,to)`와 `GET /ootd/calendar`(최대 62일)를 추가했다.
- **정렬·대표 기준**: 목록 `worn_on DESC, created_at DESC, id DESC`(cursor v2에 created_at 포함, v1 cursor는 400). 캘린더 대표 = 그날 사진 있는 기록 중 가장 최근, 사진이 없으면 가장 최근 기록. 건수 = 그날 기록 수(상태 무관).
- **통계**: `get_my_closet_statistics`는 (기록, 의류) 단위로 세므로 같은 날 2건이면 2회. planned 기존 행은 제외. 트랙 C가 이 함수를 다시 정의했으며 C 판에서도 SQL 테스트 통과(g1=3회).
- **왜**: 결정 "하루 여러 건, 착용만, 캘린더는 대표 사진+건수, 오늘 입기는 충돌 없이 추가".

## 2. 외부 AI 전송 고지·학습 동의
- **무엇을**: `profiles.ai_notice_accepted_at`(필수 고지 동의 시각), `training_consent_updated_at` 추가. 학습 동의는 기존 `training_consent`(기본 false) 재사용. `PATCH /me`에 `ai_notice_accepted`(true만, 철회 불가·첫 시각 유지)와 `training_consent`(boolean)를 받고 새 RPC `update_my_profile_settings`로 프로필 필드와 한 트랜잭션에 저장. `GET /me`에 두 값 노출. `create_my_analysis_job`·`retry_my_analysis_job`이 고지 미동의면 `ai_notice_required` → **403 `AI_NOTICE_REQUIRED`**(retryable=false, "외부 AI 분석 전송 고지에 동의해야 사진을 분석할 수 있습니다.").
- **왜**: 결정 "가입 시 외부 AI 전송 고지(필수) + 사진 학습 사용 동의(선택, 기본 꺼짐), 마이페이지에서 변경". 학습 동의는 저장·조회만.

## 3. 회원 탈퇴 `DELETE /me`
- **무엇을**: ① 사용자 JWT 확인 ② 서버 키로 `purge_account_data(p_user_id)`(service_role 전용) ③ Supabase Auth Admin API `DELETE /auth/v1/admin/users/{id}`(404=이미 삭제→성공) → 202 `{id, status:'deletion_pending'}`. 서버 키 호출은 불변식대로 `lib/supabase-internal.js`에 `purgeAccountData`·`deleteAuthUser` 두 메서드로 추가(fetch 주입으로 테스트). Idempotency-Key 필수.
- **삭제 범위**: 프로필·추구미·옷장(배치·자산·분석 작업·초안·의류·추구미 점수·임베딩)·추천(요청·코디·아이템)·OOTD·보관함·피드 게시물(미디어·연결 아이템)·내가 누른 좋아요·내 게시물에 남이 누른 좋아요·따라입기(내 요청 + 내 게시물 대상 남의 요청)·업로드 기록·멱등 키. Storage 객체 경로(DB 행 4종 + 소유자 접두사의 고아 객체)는 새 `storage_cleanup_queue`에 넣는다(user_id 없음, 처리 worker 미구현 — 기존 옷 삭제 "자산 정리 예약"과 같은 수준).
- **삭제 순서**: NO ACTION FK(outfit_items→garments 등)는 cascade 문마다 검사되어 프로필 1건 삭제로는 실패한다. 자식 먼저 명시 순서로 지우고 마지막에 프로필을 지운다. 트랙 A의 `feed_post_items`는 게시물 CASCADE로 지워져 따로 처리하지 않았다.
- **멱등·재시도**: purge는 프로필이 없으면 `profile_deleted=false`, 대기열 `on conflict do nothing`. 데이터 삭제가 실패하면 auth 사용자를 지우지 않는다. Admin 실패는 503 `ACCOUNT_DELETION_INCOMPLETE`(retryable) → 같은 요청 재시도. 프로필 행을 FOR UPDATE로 잡아 동시 쓰기는 FK 실패로 끝난다.

## 검증
- `npm --prefix backend test`: **129 pass / 0 fail**(새 `test/ootd-account.test.mjs` 8개 포함).
- `npm --prefix backend run test:schema`: OpenAPI 39 paths 검증, migration 17개, SQL 테스트 15개 전부 통과(트랙 A·C migration 포함 상태).
- 새 SQL `supabase/tests/ootd_multi_account.sql`: 같은 날 2건(+이동으로 3건) 저장, planned 거절, 캘린더 건수·대표(사진 우선), 추천 채택 같은 날 추가/같은 outfit 재채택 반환, 건별 통계, 고지 미동의 시 분석 생성·재시도 거절(상태 무변경), 탈퇴 후 `user_id` 컬럼이 있는 모든 public 테이블(카탈로그 자동 탐색)에서 0행, 내 게시물의 남의 좋아요·따라입기 0, 상대 사용자 데이터 보존, 대기열 7개 경로, 재실행 no-op, auth.users 삭제.
- 기존 테스트 수정: `outfits_ootd.sql`(planned 생성→worn, 날짜 충돌→추가, g3 통계 5회), `recommendations.sql`(같은 날 다른 outfit 채택=2건; initplan 평가 순서 때문에 결과를 먼저 저장), `analysis.sql`(고지 동의 1줄), `me/account/common/userflow/fixture` 테스트의 Profile 필드·RPC 이름·`Allow` 헤더.

## 미검증 (hosted에서만 확인 가능)
- Supabase Auth Admin API 실제 응답 코드, 서버 키 권한, auth 사용자 삭제 시 `storage.objects.owner` 등 플랫폼 FK 영향.
- hosted에서 `purge_account_data`(postgres 소유 security definer)의 `storage.objects` 읽기 권한.
- Storage 정리 worker(대기열 소비)는 없다. 탈퇴 후 객체는 대기열 처리 전까지 남는다(DB 접근 경로는 모두 끊김).
- 최근 재인증 요구 없음. auth 사용자까지 삭제된 뒤 재시도는 401.
- 따라입기(트랙 A)·추천 설명 LLM은 고지 검사 대상에 넣지 않았다(분석 작업 생성·재시도만).

## 다른 담당에 넘길 것 / 문서 반영할 내용
- **공유 파일 변경**: `lib/errors.js`(AI_NOTICE_REQUIRED, ACCOUNT_DELETION_INCOMPLETE), `lib/supabase-user.js`(RPC 허용목록 2개, 오류 매핑 3개), `lib/supabase-internal.js`(메서드 2개 추가), `docs/openapi.yaml`(Profile·ProfilePatch·DELETE /me·/ootd·/ootd/calendar·분석 403·accept 설명·info 문구), `coverage/implementation.json`(requestAccountDeletion·getOotdCalendar), `test/fixtures/get-me·g1-account`.
- **Advisor**: `scripts/report-coverage.mjs`의 `operations.size === 52 && tables.size === 25` 고정값이 현재 53/28이라 `valid:false`(오류 목록은 비어 있음). swagger-ui 사본 동기화·info의 operation 수 재계산(작성 시점 53개).
- **API_DESIGN**: `/ootd` 정렬·cursor v2, `GET /ootd/calendar` 계약과 대표 기준, POST/PATCH wear_status=worn만, accept 같은 날 추가 규칙, PATCH /me 동의 필드, DELETE /me 단계·응답·재시도, 403 AI_NOTICE_REQUIRED.
- **DB_DESIGN/ERD**: `ootd_entries` 날짜 유일 제약 제거·새 인덱스, `profiles.ai_notice_accepted_at`·`training_consent_updated_at`, 새 테이블 `storage_cleanup_queue`(현재 public 28개에 포함), RPC `update_my_profile_settings`·`get_my_ootd_calendar`·`purge_account_data`·`g10b_require_ai_notice`.
- **PRD/README 미결 목록**: "하루 OOTD 수", "탈퇴 시 데이터 처리"는 2026-10-10 결정으로 해소(하루 여러 건은 PM 협의 표시 유지). CLAUDE.md 작업 규칙 3의 미결 예시에서도 두 항목 정리 필요.
- **데모 앱**: 가입 직후 고지 화면 → `PATCH /me {ai_notice_accepted:true, training_consent:false}` 후 옷 분석 요청. 캘린더는 `GET /ootd/calendar`, 날짜 상세는 `GET /ootd?from=d&to=d`.
- 포스트는 생성 시점 OOTD 아이템 스냅샷을 쓴다. 이후 OOTD를 수정해도 이미 만든 포스트에는 반영되지 않는다.
- 고지 미동의 사용자가 분석을 요청하면 403 `AI_NOTICE_REQUIRED` → 프론트는 고지 화면으로 보낸 뒤 `PATCH /me {ai_notice_accepted:true}` 후 재요청해야 한다.
- (교차 검토 반영) 캘린더 RPC는 Storage 키 대신 `has_photo`만 준다. 서버가 대표 기록 키를 사용자 RLS로 읽어 서명 URL만 응답한다. `GET /ootd`·`/ootd/{id}`도 응답엔 서명 URL만 있다. 단 본인 `ootd_entries.photo_object_key`는 테이블 RLS로 본인이 직접 읽을 수 있다(본인 객체·본인만 읽기 정책). 완전히 숨기려면 열 권한 회수 + 서버 키 읽기로 바꿔야 한다.
- coverage: `getClosetStatistics`를 `statistics.test.mjs`·`reco_weather_stats.sql`·점수/추구미 테이블로 갱신. `createRecommendation`에 `user_aesthetic_preferences`·`garment_aesthetic_scores`를 넣으면 rls_test 한 파일이 모든 테이블을 언급해야 하는 규칙에 걸려(`recommendations.sql`엔 없음) 넣지 않았다 — C가 `recommendations.sql`에 두 테이블 검증을 추가하면 넣을 수 있다.
- `fixtures/dev-seed.fixture.json`은 바꾸지 않았다(검증기가 프로필 키를 제한하는지 확인 후 동의 필드 추가 여부 결정).
