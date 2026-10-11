# 2026-10-11 hosted 1차 실측 결과

기준: [기준표](2026-10-11_hosted_1차실측_기준.md). 도구: `backend/tools/hosted-e2e.mjs`(핸들러 in-process + 원격 Supabase, `--json <파일>`로 요약 저장).

- 무엇을: migration 17개가 push된 원격 Supabase에 `api/**` 핸들러를 로컬 Node로 붙여 H1~H6을 실측했다(최종 5회차 기준, 총 56.0초).
- 왜: 로컬(PGlite·스텁) 통과가 hosted Auth·RLS·Storage·Admin API 동작을 보장하지 않기 때문이다.
- 검증: H1·H2·H5·H6 통과. H3·H4는 결함으로 막힌 단계를 **도구 안 우회(shim·테스트 사용자 범위 SQL)**로 넘겨 끝까지 진행했다. 우회 위에서 통과한 항목은 "통과(우회)"로 적었고, 그 단계는 hosted에서 그대로는 실패한다.
- 미검증: Vercel 배포 환경, 실제 AI worker, 앱 실기기, Storage 정리 worker(없음), 동시 요청.
- 제품 코드·migration은 고치지 않았다. 코디네이터 공유 번호(#1·#2·#5·#6·#7·#9)는 "알려진 결함 #n"으로 표시했고, 새로 찾은 것은 N1~N6이다.

## 항목별 결과

| ID | 결과 | 시간 | 내용 |
|---|---|---|---|
| H1 스키마 | 통과 | 1.4s | migration 17개(로컬과 버전 일치), public 테이블 28개, RLS 28/28, 버킷 4개 모두 비공개, 함수 이름 중복 0·`begin_my_recommendation` 1개(인자 9개) |
| H2 인증 | 통과 | 2.3s | Admin API 생성 200×2, 비밀번호 로그인 200×2, `GET /me` 200(프로필 자동 생성), 비로그인·위조 토큰 401 |
| H3-1·2 고지 | 통과 | | 미동의 분석 403 `AI_NOTICE_REQUIRED` → `PATCH /me` 200(동의 시각 저장, training_consent=false) |
| H3-3 추구미 | 통과 | | 5종 조회, 메인1+보조1 저장(weight 0.5/0.5) |
| H3-4 업로드 | **부분** | | 배치 201·서명 URL PUT 200·complete 200은 통과. **업로드 전 complete → 503(기대 409 `UPLOAD_NOT_FOUND`), `upload-url` 재발급 → 503** (N1) |
| H3-5 분석·콜백 | **실패** | | HMAC 콜백 503: 알려진 결함 #7(`get_analysis_cutout_fence` text=uuid, 42883). 서버 키 업로드 cutout은 owner_id null 3/3 → #7을 고쳐도 #2로 막힘. 잘못된 서명 401은 통과. `GET /analysis-jobs/{id}` 503 `DATABASE_SCHEMA_NOT_READY`(알려진 결함 #5 `max_attempts`). drafts 서명 이미지 0/3(N2). 이후는 `apply_analysis_result` 쓰기를 테스트 사용자 범위 SQL로 재현해 진행 |
| H3-5 6종 밖 라벨 | 통과(우회) | | `dress` → draft category null (BFF 변환 규칙과 같은 값으로 재현) |
| H3-6 수정·확정 | 통과 | | null 상태 confirm 422 → draft PATCH(shoes) 200 → confirm 201(3벌), 옷장 3벌·이미지 3(S2 shim) |
| H3-7 날씨·추천 | **실패** → 통과(우회) | | KMA 응답은 정상(28.3℃)인데 `GET /weather/current` 503: 알려진 결함 #9(DB가 `valid_at`을 `+00:00` 형식으로 돌려줌). S1 shim 후 날씨 200, 추천 201·Chip=보조·`requested_count_not_reached`(3벌이라 1조합), 선호 밖 Chip 422 |
| H3-8 채택 | 통과(우회) | | 201 OOTD |
| H3-9 OOTD 사진 | **실패** → 통과(우회) | | `POST /media-uploads` 503: Storage가 서명 업로드 발급 시 insert RLS를 metadata 없이 검사해 정책이 거부(N3). 사용자 JWT 직접 업로드도 같은 이유로 거부. 서버 키 업로드+owner SQL 후 complete 200, 같은 날 두 번째 OOTD 201·photo 있음 |
| H3-10 캘린더 | 통과(우회) | | 오늘 count=2, 대표=사진 있는 기록, 사진 서명 URL |
| H3-11 보관함 | 통과 | | 201 (`source_recommendation_id`는 추천 요청 id가 아니라 **outfit id**여야 함, N5) |
| H3-12 피드 | **부분** | | 0개 422·생성 201(linked 2) 통과. 미디어 서명 업로드 503(N3) → 우회 후 complete 200·공개 전환 200 |
| H3-13 통계 | **부분** | | 200, 착용 횟수 반영(같은 날 2건=2회). `top_aesthetic=null`: 확정 흐름에 `garment_aesthetic_scores`를 쓰는 경로가 없음(N4). 점수 행을 직접 넣으면 top_aesthetic=메인으로 정상 집계 |
| H4-1 격리 | 통과(1건 제외) | | B→A garment·drafts·batch·OOTD·reco API 404, PostgREST 직접 select 0행(drafts는 403), Storage 직접 GET·서명 400(대조군 A 본인 200). job 조회만 503(#5, 노출 없음) |
| H4-2 공개 피드 | **실패**(목록) / 통과(상세) | | `GET /feed` 결과 status 없음(500): 알려진 결함 #5(`feed_posts.deleted_at` grant)+#6(오류 전파). 상세는 200, `linked_items` 키 `id,position,category`만, A 옷 id·경로 노출 0 |
| H4-3 좋아요 | 통과 | | PUT 204×2(멱등), `/me/likes` 1건, like_count 1 |
| H4-4 따라입기 | 통과 | | B 옷 2벌(우회 콜백) 확정 후 202 succeeded, 전체·아이템 grade=medium, 숫자 점수 키 없음(`coverage` 비율만 있음) |
| H4-5 결과 보관 | 통과 | | 201 |
| H5 탈퇴 | 통과 | 4.5s | A·B 202, user_id·job·post·batch 열이 있는 public 24개 테이블 모두 0행, 정리 대기열 9건(Storage 객체 9개), auth.users 0·Admin GET 404, 남은 토큰 `GET /me` 401 |
| H6 정리 | 통과 | 4.3s | Storage 9개 삭제(Storage API), 대기열 9행 삭제. 별도 확인: `mafico-e2e-*` 사용자 0, 고아 프로필 0, 고아 객체 0, 대기열 0, 테스트 점수 행 0. 1~4회차도 같은 정리로 0 확인 |

소요: H3 27.1s, H4 16.2s(우회 SQL 포함). 날씨 캐시 행(`weather_snapshots`, 사용자 무관 공용 캐시)은 남겼다.

## 원인과 수정 제안 (Advisor 결정용)

| 번호 | 원인(파일:줄) | 제안 |
|---|---|---|
| #7 | `202610010001_analysis.sql:223`, `202610090002_garment_categories_six.sql:231` `obj.owner_id is distinct from j.user_id` — hosted `storage.objects.owner_id`는 text(`owner`는 uuid) | 새 migration에서 `obj.owner_id is distinct from j.user_id::text`로 두 함수 재정의(`202609300002_ingestion.sql:113`처럼) |
| #2 | 서버 키 업로드 객체는 owner_id null인데 펜스가 owner=사용자를 요구 | worker가 사용자 owner를 만들 방법이 없다. 펜스를 "경로 접두 + owner null 또는 사용자"로 완화하거나, BFF가 cutout용 서명 업로드 URL을 사용자 대신 발급 |
| #5 | `lib/analysis.js:45`가 `max_attempts` 조회(grant `202609270001_core.sql:150`에 없음), `lib/feed.js` 목록 필터 `deleted_at`(grant `202609280001_product.sql:90`에 없음) | grant 추가 또는 select/filter 변경 |
| #9 | `lib/weather.js:291` `row.valid_at !== slot` 문자열 비교 | `Date.parse` 비교 |
| N1 | hosted Storage는 없는 객체에 404가 아니라 **400 `NoSuchKey`**를 준다. `lib/supabase-user.js:268`, `lib/supabase-internal.js:157`이 404만 missing으로 본다 | 400 + 본문 `error=NoSuchKey`(또는 `statusCode:"404"`)도 missing 처리. 영향: 업로드 전 complete 409→503, **`upload-url` 재발급은 항상 503** |
| N2 | Storage sign 응답 `signedURL`이 `/object/sign/...`(앞에 `/storage/v1` 없음). `lib/analysis.js:93`, `lib/garments.js:128`, `lib/media.js:54`, `lib/feed.js:108`이 `/storage/v1/object/sign/`만 허용해 이미지가 모두 null(피드는 503 가능) | `createSignedUpload`(`supabase-user.js:244`)처럼 `/object/`로 시작하면 `/storage/v1`을 붙이는 공통 함수 |
| N3 | `user_media_upload`(`202610090001_userflow_alignment.sql:358-360`, `g9_can_upload_media` 346행)와 `feed_media_upload`(`202610010004_feed.sql:307-309`, `g7_can_upload_feed_media` 291행)가 `metadata->>'size'`를 요구하는데, Storage는 서명 업로드 발급·직접 업로드 시 metadata 없이 insert RLS를 검사 → 프로필 이미지·OOTD 사진·피드 이미지 업로드가 전부 막힘 | insert 정책에서 size·mime 조건을 빼고(경로·행 존재만), 크기·MIME은 지금처럼 complete RPC에서 재검증. closet 정책(`202609300002_ingestion.sql:132`)과 같은 방식 |
| N4 | `garment_aesthetic_scores`에 쓰는 코드·RPC가 없다(확정 RPC가 draft의 aesthetic_scores를 옮기지 않음) → 통계 `top_aesthetic`·추천 추구미 가중·따라입기 추구미 점수가 항상 기본값 | 확정 시 draft `raw_prediction.aesthetic_scores`를 저장하거나, 제품 결정으로 null을 정상 상태로 명시 |
| N5 | `saved_outfits.source_recommendation_id` FK는 `outfit_recommendations(id)`(코디 id). OpenAPI 설명 없음 | 계약에 "추천 코디(outfit) id"라고 명시 또는 필드명 정리 |
| N6 | `claim_analysis_job`은 전역에서 가장 오래된 job을 점유하고 만료 job을 일괄 실패 처리 | 실측 중 다른 사용자 대기 job 1건이 있어 도구는 RPC 대신 자기 job만 SQL로 점유했다. 운영 worker는 문제없으나 공용 개발 DB에서 테스트 시 주의 |

## 도구 메모

- 우회는 모두 도구 안에서만 한다: S1(weather 응답 `valid_at` 정규화), S2(sign 응답 경로 접두 보정), 테스트 사용자 객체 owner SQL 보정, `apply_analysis_result` 쓰기 SQL 재현. 수정이 push되면 우회 없이 통과해야 하며, 통과 시 해당 shim이 켜지지 않는다(S1·S2는 첫 실패 뒤에만 켜짐).
- 출력·JSON에는 키·JWT·서명 URL이 없다(JSON에서 `eyJ`·`sb_`·`token=` 검색 0건).
- 실측 중 고친 도구 버그: feed_media 정렬 열(`created_at` 없음 → `position`), 가짜 날씨 `issued_at`(slot보다 늦으면 DB가 거부), 보관함 `source_recommendation_id` 값.

## 2차 실행 (결함 수정 후, 2026-10-11)
- 무엇을: migration `202610110001_hosted_fixes.sql`을 원격에 push하고(원격 18개) `WEATHER_PROVIDER=kma`로 `hosted-e2e.mjs`를 재실행했다. 수정 내역: [hosted 결함 수정](2026-10-11_hosted결함수정_RESULT.md).
- 결과: **H1~H6 전부 통과**(총 49.6초). 서버 키로 올린 cutout(owner 없음)도 콜백 200, 날씨·추천·피드 목록·이미지 서명 URL·OOTD 사진 업로드 정상. 남은 데이터 0(공용 날씨 캐시 제외).
- 도구 수정: H1-1이 migration 개수를 17로 고정해 실패 → 원격·로컬 목록 일치로 변경.
- 미검증: Vercel 배포 환경(보호·환경변수), 실제 AI worker, 앱 에뮬레이터 실측(사용자 예정). `claim_analysis_job` 전역 점유(#4)는 남아 있다.
