# 2026-10-11 hosted 결함 수정 RESULT

근거: `2026-10-11_데모앱_PLAN.md` 계약 문제 #1~#9, `2026-10-11_hosted_1차실측_RESULT.md` N1~N5. 새 migration `supabase/migrations/202610110001_hosted_fixes.sql` 하나(기존 migration 무수정). 원격 DB push·커밋 안 함.

## 검증
- `npm --prefix backend test` 142/142 통과(새 `test/hosted-fixes.test.mjs` 12건 포함)
- `npm --prefix backend run test:schema` 통과: migration 18개 + SQL 테스트 16개(새 `supabase/tests/hosted_fixes.sql`), 컬럼 grant 정적 검사 29개 select 통과
- `swagger-ui sync` 후 `sync:check` 통과, `report-coverage` valid:true
- 미검증: hosted Supabase·실제 KMA 응답·실제 worker에서의 재실측(push 후 `tools/hosted-e2e.mjs` 재실행 필요)

## 항목별
| # | 원인 | 수정 | 검증 |
|---|---|---|---|
| 1 CORS | preflight Allow-Headers가 `Authorization, Content-Type`뿐 | `Idempotency-Key` 추가(lib가 읽는 브라우저 헤더 전부. `x-worker-*`는 서버 간 callback 전용이라 제외) | common 테스트 갱신 + lib의 `req.headers` 읽기를 정적 수집해 Allow-Headers 포함 여부 검사 |
| 2·7 cutout owner | hosted `owner_id`는 text → `uuid` 비교 42883. 서버 키 업로드는 owner NULL | `get_analysis_cutout_fence`·`apply_analysis_result`·`create_my_mimic_job` 재정의: owner NULL 허용, 있으면 `owner_id = user_id::text` | SQL: NULL owner 통과, 다른 owner 거부, 다른 사용자 경로 거부, apply 성공 |
| 3 날씨 제공자 | 정규화 JSON 어댑터만 지원 | `WEATHER_PROVIDER=kma`: 초단기실황(T1H·REH·PTY·WSD) + 단기예보 POP, 위경도→기상청 격자(LCC) 변환, region_code 대표좌표 그대로 사용. 기본값 `adapter`(기존 유지). resultCode≠00·XML 오류는 실패 처리, 키는 응답에 없음 | 요청 파라미터(base_date/time, nx/ny)·저장 payload·오류 봉투 테스트 |
| 5 column grant | `analysis_jobs.max_attempts`, `feed_posts.deleted_at` grant 누락 | 두 열 grant. 전수 조사는 `validate-schema.mjs`가 lib의 user-JWT select·filter·order 열을 정적 수집해 `has_column_privilege('authenticated',…)`로 검사(이번에 빠진 열은 이 둘뿐) | grant를 지우면 검사가 실패함을 확인 |
| 6 feed 오류 전파 | `listResponse`가 `{error}` 객체를 응답으로 반환 → 500 | `rows.error` 반환. 같은 패턴 전수 확인: `recommendations.js` 추천 생성의 `garmentsResult`도 같은 버그라 수정 | 403 → 503 `DATABASE_SCHEMA_NOT_READY` 테스트 |
| 9 시각 문자열 비교 | `valid_at !== slot`(`+00:00` vs `.000Z`) | `sameInstant`(시각 값 비교). lib 전수 확인: 그 밖의 비교는 같은 출처끼리이거나 날짜(YYYY-MM-DD) 비교. 피드 커서가 `toISOString()`으로 마이크로초를 잘라 경계 행이 반복·누락되던 문제도 DB 문자열 유지로 수정 | `+00:00` 캐시 적중·저장 후 반환, 마이크로초 커서 테스트 |
| 8 OOTD 저장 당시 날씨 | 응답에 snapshot id만 | 새 RPC `get_my_ootd_weather`(본인 OOTD가 참조하는 스냅샷만, 격자 제외). OOTD 목록·상세·캘린더·추천 채택 응답에 `weather` 요약(`weather_code` 등). OpenAPI `OotdWeatherSummary` | SQL(타 사용자 0건, 원본 테이블 비공개)·단위 테스트 |
| 스텁 | PGlite 스텁 owner_id uuid | `validate-schema.mjs`·`generate-erd.mjs`에서 text. ERD.md 재생성(migration 수 18) | 스텁 타입 SQL 단언 |
| N1 | Storage가 없는 객체에 400 `NoSuchKey` | `storageObjectMissing`(404, 또는 400+`NoSuchKey`/`statusCode:"404"`)을 user·internal readStoragePrefix에 적용 | 단위 테스트 |
| N2 | `signedURL`이 `/object/sign/...` 상대 경로 | 공통 `signedStorageUrl`(`/storage/v1` 접두, 같은 프로젝트 https·버킷 경로만 허용)을 analysis·garments·media·feed에 적용 | 상대·절대·타 호스트·타 버킷 테스트, 피드 서명 URL |
| N3 | insert 정책이 metadata size/mime 요구 | `user_media_upload`(새 `g11_can_upload_media`)·`feed_media_upload`(`g7_can_verify_feed_media`)를 경로+대기 행만으로 재생성, 옛 함수 삭제. 크기·MIME은 complete RPC가 계속 검증. 옷장 `closet_source_upload`는 원래 metadata를 쓰지 않아 해당 없음 | feed.sql·userflow_alignment.sql의 "metadata 불일치 insert 거부" 단언을 "metadata 없이 허용" 단언으로 교체 |
| N4 | `garment_aesthetic_scores` 쓰기 경로 없음 | `confirm_my_garment_batch` 재정의: draft `raw_prediction.aesthetic_scores`를 저장(모르는 aesthetic_id·형식 오류 건너뜀, 없으면 행 없음 = 기존 중립 0.5) | SQL: 알려진 1건만 저장 |
| N5 | 필드 설명 없음 | `source_recommendation_id` 설명: 추천 코디(outfit) id, 추천 요청 id 아님(이름 유지) | OpenAPI 검증 |

## #2 설계 근거
- `closet-private`에 사용자 역할이 insert할 수 있는 유일한 정책 `closet_source_upload`는 이름이 대기 중인 `kind='source'` 행의 object_key와 같아야 하고, 그 키는 서버가 `<uid>/<batch>/source.<ext>`로 만든다. 따라서 `<uid>/<batch>/cutouts/…`에는 secret key(BFF·worker)만 쓸 수 있다.
- 펜스의 경로 접두는 job 행(user_id·batch_id)에서 만들고, `apply_analysis_result`는 HMAC 검증된 callback의 살아 있는 lease(attempt·lease_token)와 객체 id·updated_at·mime·size를 함께 요구한다. 그래서 owner가 NULL이어도 다른 사용자의 객체를 끼워 넣을 수 없다.
- owner가 기록돼 있으면(향후 서명 업로드 등) job 사용자와 text로 일치해야 한다. 경로는 job_id가 아니라 기존 계약대로 batch_id 기준이다(batch당 job 하나).

## 가짜 worker용 N4 형식
callback `items[].attributes.aesthetic_scores = [{"aesthetic_id":"<aesthetics.id uuid>","score":0~1}]`(최대 15개, 선택). 확정 시 저장된다.

## #4(claim 범위) 의견
`claim_analysis_job`이 모든 사용자 job을 가져가는 것은 worker가 하나일 때는 맞다. worker를 여럿 두면 lease로 중복 처리는 막히므로 정확성 문제는 아니다. 공용 DB를 데모·실측이 같이 쓰는 동안 서로 job을 가로채는 문제라, 환경별 worker 분리(또는 `p_user_ids` 같은 필터 인자)를 다음 범위로 제안한다.

## push 시 주의
- 이 migration은 `drop policy`·`drop function`(g9_can_upload_media, g7_can_upload_feed_media)을 포함한다. 다른 객체가 두 함수를 참조하지 않음을 로컬에서 확인했다.
- 배포 환경변수: KMA를 쓰려면 `WEATHER_PROVIDER=kma`, `WEATHER_PROVIDER_API_KEY`(data.go.kr serviceKey, dev-server와 같은 형식), `WEATHER_PROVIDER_BASE_URL`은 비워도 된다. `backend/.env.example`은 범위 밖이라 고치지 않았다(`WEATHER_PROVIDER` 한 줄 추가 필요).
- 이미 owner를 SQL로 직접 기록한 데모 cutout도 그대로 통과한다(owner=job 사용자).
