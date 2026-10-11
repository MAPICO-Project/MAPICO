# 마피코 DB 설계 v0.4

기준: 2026-09-28 최신 기능 표 및 회의. **SQL 스키마 작성 및 로컬 검증 완료, 제품 API/원격 Supabase 적용 완료를 뜻하지 않는다.**

## 적용 경로

워크스페이스 기준 `backend/supabase/migrations/202609270001_core.sql`부터 파일명 순서대로 `202610100003_reco_weather_stats.sql`까지 17개를 적용한다. 독립 backend 저장소에서는 `supabase/migrations/`이다. public 테이블은 28개다(2026-10-10에 `feed_post_items`·`garment_embeddings`·`storage_cleanup_queue` 추가). 원격 DB에는 아직 push하지 않았다. 기존 migration은 수정하지 않고 G1~G8 변경, 날씨 최신행 동률 회귀 보정, 2026-10-09 유저플로우 정렬(G9)·옷 카테고리 6종 정리, 2026-10-10 결정 반영(G10: [`202610100001_feed_links_mimic.sql`](../supabase/migrations/202610100001_feed_links_mimic.sql), [`202610100002_ootd_multi_account.sql`](../supabase/migrations/202610100002_ootd_multi_account.sql), [`202610100003_reco_weather_stats.sql`](../supabase/migrations/202610100003_reco_weather_stats.sql))을 additive migration으로 추가했다.

## 도메인 데이터 사전

| 테이블 | 목적·주요 필드 | 접근 |
|---|---|---|
| profiles | auth.users와 1:1, display_name, timezone, knows_aesthetic, tutorial_seen, onboarding_completed, avatar_object_key?(profile-media 경로), ai_notice_accepted_at?(외부 AI 전송 고지 동의 시각), training_consent(기본 false)·training_consent_updated_at? | 본인(쓰기는 RPC) |
| aesthetics | 5종 카탈로그(code·표시명·정의·버전). 현 seed(feminine/y2k/minimal/grunge/casual)는 이전 임시값이며 최종 명칭 확정 후 별도 migration | 활성 카탈로그 공개 |
| user_aesthetic_preferences | 유저별 추구미 role(main/sub, 정본) + weight(합 1, main ≥ sub). main 정확히 1·sub 0~2 | 본인 |
| tpo_presets | 이전 TPO 카탈로그, 삭제하지 않음 | 활성 카탈로그 공개 |
| garment_batches | 업로드·분석·검토 단위 | 본인 |
| garment_assets | closet-private 원본/누끼 경로·검증시각 | 본인 |
| analysis_jobs | 분석 상태·재시도·lease | 본인 제한 필드/서버 |
| garment_drafts | AI 원본 예측 + 사용자 수정값 + version | 본인 |
| garments | 확정 의류, category, 선택 memo(1,000자), 내부 속성 | 본인 |
| garment_aesthetic_scores | 모델 버전별 추구미 점수 | 본인 |
| weather_snapshots | 발표·유효·수집 시간, 격자, 공급자, payload | 서버 |
| recommendation_requests | 사용자·대상 날짜·날씨·조건·상태, selected_aesthetic_id?(홈 Chip 선택, FK aesthetics) | 본인 |
| outfit_recommendations | AI 추천 순위·설명·근거 | 본인 |
| outfit_items | 추천별 의류·slot | 본인 |
| saved_outfits | 날짜 없는 보관함, title(100자), note, source_recommendation_id?, version | 본인 |
| saved_outfit_items | 코디 구성 garment_id, position, 동일 소유자 복합 FK | 본인 |
| ootd_entries | worn_on(하루 여러 건, 유일 제약 없음), outfit_id?, saved_outfit_id?, item_snapshot, note, rating, weather_snapshot_id?, wear_status, photo_object_key?(선택 사진 1장, ootd-private 경로) | 본인, 비공개 유지 |
| feed_posts | caption(2,000자), aesthetic_id?, weather_code?(clear·cloudy·rain·snow·wind·unknown), temperature_c?, visibility, source_ootd_id? | 공개 게시물 또는 본인; source_ootd_id 제외 |
| feed_post_items | 포스트↔작성자 옷 연결 1~10개: post_id, position, garment_id?(원본 하드 삭제 시 NULL), 연결 시점 스냅샷(category·color_hex·pattern·추구미 점수). 복합 FK `(user_id, garment_id)`, 커밋 시점 1개 이상 보장(deferred trigger) | 서버 전용(공개는 `linked_items`의 id·position·category만) |
| feed_media | 공유용 복사본, feed-private 경로, 검증시각, 순서 | 서버 전용 |
| post_likes | user_id + post_id 유일; 좋아요 아카이브 | 본인 + 현재 열람 가능한 게시물만 |
| mimic_requests | post_id, queued/running/succeeded/no_match/failed, result, model_version | 본인 상태만; raw result/모델 버전 서버 전용 |
| mimic_source_items | job별 source snapshot. 2026-10-10부터 `post_item_id`·`category`를 추가했고 media 컬럼은 nullable(구 이미지 기반 결과 호환) | 서버 전용 |
| mimic_candidate_items | job별 본인 garment·cutout·Storage version snapshot | 서버 전용 |
| garment_embeddings | 옷당 1벡터·model_version. 따라입기 매칭 점수에 혼합하며 채우는 worker는 아직 없음. 계정 삭제 시 CASCADE | 서버 전용 |
| storage_cleanup_queue | 삭제 후 지울 Storage 객체 경로 대기열(user_id 없음). 소비 worker 미구현 | 서버 전용 |
| media_uploads | 프로필 이미지·OOTD 사진 업로드: purpose(avatar/ootd_photo), bucket, object_key, MIME·크기, verified_at, attached_at, deleted_at | 본인 조회, 쓰기는 RPC |
| idempotency_keys | 중복 요청·응답 기록·만료 | 서버 |

옷 카테고리는 유저플로우 6종 `outerwear`(아우터)·`top`(상의)·`bottom`(하의)·`shoes`(신발)·`bag`(가방)·`accessory`(액세서리)다(2026-10-09 사용자 결정, `202610090002`). `dress`·`other`는 제거했고 다른 값으로 옮기는 규칙은 정하지 않았다: 확정 옷이나 OOTD 스냅샷에 dress/other가 있으면 migration이 실패하고, 미확정 draft는 category를 비우고 AI 라벨을 `raw_prediction.ai_category`로만 남긴다. AI가 6종 밖 라벨을 주면 draft category는 null이고 사용자가 6종 중 하나를 고르기 전까지 확정(`invalid_category`)되지 않는다. 모자는 accessory 하위 세부분류로 처리할 수 있으나 하위 코드 목록은 팀 합의 전 고정하지 않는다. 기존 내부 색상/추구미 데이터는 유지하되 최신 CLO-005 화면 DTO에서는 제외한다.

## 코디 / 착장 / 게시물 분리

- **보관함**: 실제 착용과 무관한 재사용 조합. 아이템 변경은 보관함만 갱신한다.
- **OOTD**: 특정 날짜 기록. 추천 없이 수동 생성 가능하도록 outfit_id NOT NULL을 해제했다. 두 원본 링크는 동시에 지정할 수 없고, 수동 조합은 둘 다 null일 수 있다. 기록 당시 아이템 스냅샷은 보관함 편집과 독립적이다.
- **게시물**: OOTD를 자동 공개하지 않는다. 별도 게시 행위로 공개 데이터와 검증된 공유 이미지 복사본을 만든다.
- **따라입기**: 게시물에서 요청 생성 → AI 결과 → 본인 옷으로 검증된 후보를 보관함에 저장. JSON 결과의 타인 의류 ID를 그대로 저장하지 않는다.

## 확정되지 않은 정책과 보수적 기본값

- `wear_status=unconfirmed`는 기존 기록을 실제 착용으로 오인하지 않기 위한 중립 기본값. `planned/worn`은 기술 제안이며 사용자 UX 확정이 아니다. 착용 통계는 worn만 집계한다.
- 하루 1기록 유일 제약은 `202610100002`에서 제거했다(하루 여러 건, PM 협의). 목록 인덱스는 `(user_id, worn_on desc, created_at desc, id desc)`다. 새 기록은 `worn`만 허용하고 기존 `planned`·`unconfirmed` 행은 조회만 한다.
- 별점 1~5는 nullable. 예정 착장 별점/미래 worn 제한, 날짜 변경 규칙은 API 정책 확정 전 미구현.
- 1~3 추구미/대표 순위/무드보드 점수 산정은 아직 DB 자동 계산 안 함. seed 명칭은 이전 임시 카탈로그이며 최종 명칭은 미정; 학습 정의·벡터 차원도 미확정.
- TPO 칩 제거를 TPO 내부 데이터 삭제로 단정하지 않으며 자동 기본값 적용은 별도 결정.
- 피드 최초 스키마는 추구미 1개 태그. 여러 개 선택 확정 시 연결 테이블 필요.
- OOTD 과거/미래 날짜에 오늘 날씨를 붙이지 않는다. 서버가 대상 시점의 snapshot을 선택하며 미확보는 null. 내부 weather_snapshot_id는 외부 응답에서 안전한 요약으로 변환한다.

## 권한·트랜잭션

신규 테이블은 RLS를 활성화하고 브라우저 직접 쓰기를 허용하지 않는다. BFF는 JWT 검증 후 본인 user_id를 주입해야 한다. service_role은 RLS를 우회하므로 단순 키 연결만으로 안전해지지 않는다.

계정·온보딩 쓰기는 authenticated 사용자가 직접 table write하지 않고 `update_my_profile`, `replace_my_aesthetic_preferences`, `save_my_onboarding_state` RPC만 실행한다. 함수는 `auth.uid()`가 없는 호출을 거절하고 다른 사용자 ID를 입력으로 받지 않는다. 선호 교체는 profile row를 잠가 같은 사용자의 동시 교체를 직렬화하며 검증·삭제·삽입이 한 transaction에서 끝난다. `avatar_asset_id`는 Storage 수명주기 미확정으로 제외했다.

세 RPC는 내부 열 노출을 피하려고 `void`를 반환한다. BFF는 RPC 성공 후 같은 사용자 JWT/RLS로 허용 필드만 다시 조회해 API 응답을 만든다. profile row lock의 단일 DB transaction 직렬화는 로컬 검증했지만, 실제 hosted PostgREST의 병렬 요청 순서와 재조회 실패 동작은 통합 테스트 전이다.

G2 의류 수정·삭제도 `update_my_garment`, `delete_my_garment` RPC로 제한한다. 수정은 version row lock과 category/subcategory/memo presence flag를 사용한다. 삭제는 `deleteGarment` scope의 idempotency replay를 garment 존재 확인보다 먼저 처리하고 batch row lock 뒤 garment를 soft-delete한다. cutout은 더 이상 참조되지 않을 때, source는 batch의 활성 garment가 없을 때 asset cleanup marker를 남긴다. DB 행은 이력 FK 때문에 물리 삭제하지 않으며 실제 Storage 객체 cleanup은 후속 worker가 필요하다.

G3 등록은 `create_my_garment_batch`, `complete_my_garment_upload` RPC를 authenticated에만 허용한다. 생성 RPC는 canonical request hash와 idempotency row lock, 사용자별 awaiting_upload 상한을 적용하고 서버가 object key를 만든다. Storage INSERT/검증 SELECT 정책은 본인·source·미검증·미삭제·awaiting_upload·정확한 object key를 모두 만족해야 한다. 완료 RPC는 batch/asset row lock과 `storage.objects` owner·metadata를 재검증하여 `awaiting_upload→uploaded` 또는 invalid object의 `failed` 전이를 원자 처리한다. UPDATE·DELETE Storage 정책과 upsert는 허용하지 않는다.

G4는 `create_my_analysis_job`, `retry_my_analysis_job`, `list_my_garment_drafts`, `update_my_garment_draft`, `confirm_my_garment_batch`를 authenticated에만 허용한다. `garment_drafts` raw 행의 직접 조회 권한과 기존 확정 RPC 실행 권한은 회수하고 safe projection 및 사용자 override만 노출한다. `apply_analysis_result`는 service_role 전용이며 callback event replay를 먼저 판정한 뒤 running lease·attempt·token, canonical cutout 경로와 Storage owner/metadata, item cardinality를 검사하고 terminal job·draft·asset·batch를 원자 전이한다. 실제 service credential 주입과 hosted Storage 동작은 미검증이다.

G5는 authenticated `begin_my_recommendation`, `accept_my_recommendation`과 service-only weather/recommendation RPC를 분리한다. reservation은 profile timezone에서 target date를 계산하고 2분 lease token으로 provider 이전 idempotency를 보호한다. finalize는 불변 weather snapshot의 grid·slot·age·stale 분류, DB 선호 snapshot, rank·score·중복 outfit, 정렬 잠근 활성 garment/asset을 다시 검증한다. 채택은 legacy accept 권한을 회수하고 idempotency row→날짜 advisory lock→기존 OOTD→추천·outfit→garment/asset 순으로 잠근다.

G6 보관함/아이템, OOTD 원본 링크, 게시물 원본 링크는 `(user_id,id)` 복합 FK로 교차 소유자 연결을 차단한다. 저장·수정 RPC는 아이템 수/중복/soft-delete 여부와 version을 확인하고 한 transaction에서 처리한다. OOTD snapshot은 이후 보관함 변경과 독립적이며 통계는 `worn`만 집계한다.

G7 피드 projection은 공개 게시물 또는 본인 글만 허용하며 다른 사용자의 OOTD ID·옷장 경로·원본 사진을 반환하지 않는다. `feed_media`는 서버 전용이고 `feed-private`은 등록된 본인 초안 경로에만 업로드를 허용한다. BFF는 객체 identity/version fence와 실파일을 검증한 뒤 짧은 signed URL을 반환한다. 비공개 전환 전 URL은 만료 전까지 유효할 수 있다.

G8 따라입기는 공개·검증된 source media와 요청자 소유 활성 garment/cutout의 identity/version을 생성 시 snapshot으로 고정한다. user advisory lock, user/post open-job 재사용, 사용자별 open 3개 제한, 2시간 deadline, 최대 3회 lease attempt와 7일 terminal retention을 적용한다. authenticated는 create/get narrow RPC만 실행하고 raw result·snapshot·lease는 조회하지 못한다. callback은 service role 전용이며 결과 조회 때 원본 공개성과 의류 가용성을 다시 투영한다.

G9(2026-10-09 유저플로우 정렬)는 PM 확인이 필요 없는 4건만 반영했다. ① 추구미 `role`: 기존 행은 가중치 최댓값(동률이면 aesthetic_id 순)을 main으로 backfill했다. main 부분 unique index가 즉시, 지연 제약 트리거 `aesthetic_roles_valid`가 커밋 시 "main 1·sub ≤2·sub weight ≤ main"을 보장한다. `replace_my_aesthetic_preferences(jsonb)`는 같은 시그니처로 교체해 role 필수, weight 전부/전무(생략 시 1/n)를 검사한다. ② `feed_posts.weather_code`와 `create_my_feed_post`에 `wind` 추가. ③④ `media_uploads` + 비공개 버킷 `ootd-private`·`profile-media`: `create_my_media_upload`가 서버 경로 `{user}/{purpose}/{id}.{ext}`를 만들고, Storage INSERT는 그 대기 행과 MIME·크기가 맞을 때만, SELECT는 본인 미삭제 업로드만 허용한다. `complete_my_media_upload`가 storage.objects owner·metadata를 검증한다. 검증된 업로드는 `update_my_profile_with_avatar`, `create_my_ootd_with_photo`, `update_my_ootd_with_photo`가 기존 RPC와 같은 transaction에서 한 번만(attached_at) 붙인다. `(user_id, object_key)` 복합 FK와 경로 purpose check로 다른 사용자·다른 용도 경로를 막는다. 교체·제거된 객체는 owner만 읽을 수 있게 남고 Storage 정리 worker는 없다.

G10(2026-10-10): ① `feed_post_items`로 포스트에 옷 1~10개를 연결하고(`create_my_feed_post`·`update_my_feed_post`에 `p_garment_ids`, 구 시그니처 drop, 기존 OOTD 출처 포스트는 백필), `create_my_mimic_job`이 연결 아이템과 내 옷장을 SQL에서 동기 매칭한다(헬퍼 `g10_*`, 등급 임계값 정본은 `g10_mimic_grade`; `claim_mimic_job`은 항상 null, 열린 구 작업은 실패 처리). `on delete set null (garment_id)`는 PG15+ 문법이라 원격 push 전 PG 버전을 확인해야 한다. ② `get_my_ootd_calendar`, 추천 채택(`accept_my_recommendation`)의 같은 날 추가 규칙, `update_my_profile_settings`, `g10b_require_ai_notice`(고지 미동의 시 분석 생성·재시도 거절). ③ `begin_my_recommendation`은 9인자(`p_selected_aesthetic_id`) 하나만 둔다. `get_my_closet_statistics`는 같은 시그니처로 교체해 `aesthetic_totals`·`top_aesthetic`(착용 기록 건마다 옷의 추구미 점수 합산)을 낸다.

탈퇴는 service_role 전용 `purge_account_data(p_user_id)`가 자식부터 명시 순서로 지우고 마지막에 프로필을 지운다(NO ACTION FK는 cascade 문마다 검사되어 프로필 한 건 삭제로는 실패하기 때문). 이어 BFF가 Auth Admin API로 auth 사용자를 지운다. Storage 객체 경로는 `storage_cleanup_queue`에 넣으며 DB cascade로는 객체가 지워지지 않는다. 실제 객체 삭제 worker와 hosted 권한은 미검증이다.

기존 `accept_outfit` RPC는 수동 OOTD의 nullable outfit_id를 null-safe 비교하도록 교체했다. 날짜 충돌 시 수동 기록을 추천 채택 성공으로 잘못 반환하지 않는다.

## 검증과 남은 작업

`npm run test:schema`가 migration 17개와 account/closet/ingestion/analysis/recommendation/outfit/feed/mimic/security/userflow_alignment·feed_links_mimic·ootd_multi_account·reco_weather_stats SQL assertions를 PGlite에서 실행한다. owner/RLS, 멱등성, Storage fence, queue lease, callback replay, visibility, safe projection을 로컬 검증한다.

`fixtures/dev-seed.fixture.json`은 최종 taxonomy나 실제 사용자가 아닌 disposable-local 전용 metadata 계약이다. `npm run seed:validate`가 `fixture-*` 표시, 5개 placeholder, preference 합, 이미지 사용 허용 metadata, 자격증명 형태 부재를 검사하며 SQL·DB·네트워크를 사용하지 않는다. 실제 개발 Supabase Auth 사용자와 최종 taxonomy는 사용자·팀 승인 후 별도로 준비한다.

PGlite에서 Auth/Storage는 테스트 스텁이다. 실제 Supabase Auth/Storage, 동시 요청, 서명 URL, 탈퇴 정리, 제품 endpoint, pgvector 검색은 통합 검증 전이다. 기존 OpenAPI v0.2 검사 통과와 최신 v0.3 요구사항 충족은 별개다.

읽기 전용 설계 검토를 수행했다. 피드 열 권한을 이용하는 좋아요 RLS 오류를 테스트로 수정했고, 게시자 탈퇴를 타인 따라입기 FK가 막지 않도록 CASCADE로 변경했으며 raw 모델 결과 직접 조회를 차단했다. 수동 OOTD는 원본 링크가 없어도 유효하므로 '원본 정확히 하나 필수' 제안은 채택하지 않고 '최대 하나'로 제한했다. 게시자 계정 삭제 시 타인의 연결된 따라입기 행 정리까지 테스트했다.
