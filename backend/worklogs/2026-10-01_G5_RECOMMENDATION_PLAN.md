# G5 날씨·추천 HTTP 수직 슬라이스 계획

상태: 구현·검증 완료  
범위: `getCurrentWeather`, `createRecommendation`, `getRecommendation`, `acceptRecommendation` 4개 operation  
예상 증가: G5 시작 시점 기준 `implemented-local` +4  
선행조건: G3 완료, G4의 additive migration·공통 모듈 변경과 충돌 여부를 root가 통합 직전에 재확인

## 1. 목표와 완료 경계

사용자 JWT를 검증한 HTTP 경계에서 현재 시간대 날씨를 안전한 snapshot으로 만들고, 본인의 활성 의류와 추구미만으로 0~3개 추천을 생성·조회하며, 추천 중 한 outfit을 해당 추천의 `target_date` OOTD로 원자적으로 채택한다.

다음 증거가 모두 있을 때만 네 operation을 `implemented-local`로 올린다.

1. 실제 런타임 handler와 provider/DB gateway가 연결되어 있고 fixture 전용 성공 경로가 아니다.
2. 새 additive migration이 날씨 저장, 추천 세트 원자 저장, 채택 RPC와 권한을 고정한다.
3. OpenAPI 응답 DTO와 오류, idempotency, ownership을 unit·SQL·contract fixture가 검증한다.
4. `template` 설명은 외부 LLM 없이도 실행 가능한 정식 fallback이고, `llm` 표시는 실제 adapter 결과를 검증한 경우에만 사용한다.
5. 원격 Supabase, 실제 날씨 provider, 실제 LLM을 호출하지 않은 사실을 결과 문서에 `hosted/외부 통합 미검증`으로 남긴다.

범위 밖은 05:00/07:00 예약 생성, 알림, TPO 자동 기본값, 추천 학습·평가, 보관함 저장, 수동 OOTD CRUD, 실제 provider/LLM 계정 설정이다. 추천 생성 시각과 TPO는 미결 상태를 유지하며 G5는 온디맨드와 `tpo=null`만 구현한다.

## 2. 현재 계약·DB 기준선

- OpenAPI 입력은 `/weather/current?lat&lon`, `POST /recommendations`의 `location`, 선택적 `requested_count=1..3`, 생략 또는 null만 가능한 `tpo`, 그리고 채택의 `outfit_id`, `worn_on`이다.
- `RecommendationSet`은 `ready` 또는 `insufficient_wardrobe`만 외부에 노출한다. `ready`는 outfit 1~3개, 의류 부족은 빈 배열과 1개 이상의 `shortfall_reasons`다.
- `WeatherSnapshot`은 발표·유효·수집 시각과 격자, 정규화된 날씨만 제공한다. 관측값이라고 표시하지 않고 원본 provider payload와 정확한 위·경도를 반환하지 않는다.
- 현재 DB에는 `weather_snapshots`, `recommendation_requests`, `outfit_recommendations`, `outfit_items`, `ootd_entries`, `idempotency_keys`와 owner-read RLS가 있다. `weather_snapshots`와 `idempotency_keys`는 일반 authenticated 직접 읽기·쓰기가 없다.
- 기존 `accept_outfit(uuid,date)`는 recommendation path ID와 idempotency key를 받지 않고 `wear_status=worn` 및 `item_snapshot[].unavailable`도 명시하지 않는다. HTTP 계약의 최종 구현으로 재사용하지 않고 더 좁은 새 RPC로 대체한다.
- `202610010001_analysis.sql`까지 존재하므로 G5 migration 파일명은 root가 통합 시점의 다음 충돌 없는 순번으로 정한다. 기존 migration은 수정하지 않는다.

## 3. 보안·신뢰 경계

### 사용자 경계

- 네 handler 모두 Bearer JWT를 기존 Auth gateway로 검증한다. body/query/path는 exact allowlist, UUID·날짜·숫자 범위·body 크기를 upstream 호출 전에 검사한다.
- 추천·outfit 조회는 사용자 JWT/RLS를 사용하고 타 사용자 ID는 존재 여부를 숨겨 404로 처리한다.
- 후보 의류는 같은 사용자이며 `deleted_at is null`인 확정 의류만 허용한다. 추천 저장 RPC와 채택 RPC가 BFF 조회와 별개로 이를 다시 검사한다.

### server-only 경계

- 날씨 snapshot upsert와 추천 결과 저장은 클라이언트가 payload·점수·설명을 위조할 수 없도록 server-only narrow RPC/gateway로 분리한다. 해당 RPC는 `public`, `anon`, `authenticated` 실행권을 제거하고 `service_role`에만 부여한다.
- service-role 사용 코드는 격리된 server-only 모듈 한 곳에 두며 브라우저 bundle, 응답, fixture, 로그에 키를 넣지 않는다. 사용자 JWT 검증으로 확정한 user ID만 전달하고 RPC도 소유 의류·요청·snapshot 관계를 독립 검증한다.
- 실제 비밀값을 생성·수정·출력하지 않는다. 설정이 없고 사용 가능한 cache도 없으면 성공을 꾸미지 않고 503으로 실패 폐쇄한다.
- 날씨 provider·LLM 요청에는 정확한 사용자 ID, 닉네임, 이미지 URL/object key, 원본 AI 속성을 전달하지 않는다. 날씨 provider에는 위치 좌표만 일시적으로 사용하고 DB에는 변환된 격자만 남긴다. LLM에는 정규화 날씨와 근거 문장/카테고리만 보낸다.

## 4. 날씨 provider gateway와 snapshot

1. `lat`, `lon`을 유한한 숫자로 검증하고 provider adapter가 지원 격자로 변환한다. KMA 지원영역 밖이면 provider 호출 없이 422 `UNSUPPORTED_LOCATION`으로 종료한다.
2. 현재 시간대는 provider가 반환한 발표 시각(`issued_at`)과 예보 대상 시각(`valid_at`)을 구분한다. adapter는 현재 provider 시간 슬롯에 해당하는 한 건만 정규화하며 임의의 과거·미래 snapshot을 오늘 날씨로 대체하지 않는다.
3. 내부 canonical payload는 `temperature_c`, nullable `feels_like_c`, nullable 0~100 강수확률, `none|rain|snow|mixed|unknown`, nullable 0~100 습도, nullable 대기질만 저장한다. 원본 응답 전체와 위·경도는 저장하지 않는다.
4. `(grid_x, grid_y, issued_at, valid_at, source)` unique를 이용해 narrow RPC가 upsert/replay하고, 같은 격자·유효시각 조회용 index를 additive migration에 추가한다. 동시 provider 응답도 snapshot을 중복 생성하지 않는다.
5. cache 정책은 코드 상수와 테스트로 고정한다. 제안 기본값은 같은 격자·같은 현재 유효 슬롯에서 수집 후 10분 이내면 fresh, provider 실패 시 최대 3시간 이내 snapshot만 stale fallback으로 허용하는 것이다. 시간은 구현 전 read-only 검토에서 확정하고 API/DB 문서에 함께 기록한다.
6. fresh cache가 있으면 provider를 생략하고 `is_stale=false`, fetch가 성공하면 새 snapshot과 `false`, fetch/timeout/스키마 오류 때 허용 cache가 있으면 `true`, 없으면 503 `WEATHER_UNAVAILABLE`을 반환한다.
7. `/weather/current`와 추천 생성은 같은 resolver를 사용한다. 서로 다른 cache·시간 판정 로직을 만들지 않는다.

provider adapter는 timeout, abort, HTTP status, JSON 크기/형태를 제한하고 주입 가능하게 만든다. 단위 테스트는 가짜 adapter를 주입하지만 기본 runtime adapter는 실제 환경 설정으로 HTTP 요청할 수 있어야 한다. 로컬 fixture 응답을 runtime 기본값으로 쓰지 않는다.

## 5. 추천 생성과 조회

### 생성 순서

1. 인증과 `Idempotency-Key`(기존 8~128자 규칙), exact body, location, `requested_count`, `tpo`를 검증한다. 생략한 count는 3, `tpo`는 생략/null만 허용한다.
2. profile timezone의 현재 날짜를 `target_date`로 고정한다. request hash는 정확한 좌표 대신 privacy-preserving provider 격자, `requested_count`, 명시적 `tpo=null`, `target_date`, 계약 version으로 canonicalize한다. 같은 키·같은 의미는 기존 201 응답을 재생하고 같은 키·다른 hash는 409 `IDEMPOTENCY_CONFLICT`다.
3. 같은 격자의 현재 시간대 Weather resolver를 실행한다. 과거 또는 미래의 다른 유효 슬롯을 추천에 붙이지 않는다.
4. 사용자 JWT/RLS로 활성 의류, 허용된 내부 추천 속성, 사용자 추구미 선호를 읽는다. 삭제 의류, 타인 의류, 검증되지 않았거나 삭제 표시된 asset에만 의존하는 의류는 후보에서 제외한다.
5. versioned deterministic rule engine이 outfit 후보와 0~1 점수(`weather`, nullable `tpo`, `aesthetic`, `harmony`) 및 사실 근거를 만든다. LLM은 의류 선택이나 점수를 바꾸지 않는다. `engine_version`과 `rules_version`은 실제 코드 상수로 저장하고 fixture/실제 AI를 혼동하지 않는다.
6. 외부 LLM 전에도 각 outfit의 template 설명을 먼저 생성한다. LLM adapter가 설정되어 있고 timeout·HTTP·schema·길이·근거 검증을 모두 통과한 outfit만 `explanation_source=llm`; 미설정, 일부 실패, 허구 근거, 1,000자 초과는 해당 outfit만 template으로 되돌린다. template도 `explanation_source=template`을 명시한다.
7. server-only 원자 저장 RPC가 recommendation request, outfits, items, idempotency response를 한 transaction에서 저장한다. RPC는 사용자 존재, snapshot 존재/현재 슬롯, `tpo is null`, target date, count, rank, score 범위, 중복 의류, outfit/item 소유권, 활성 의류, 설명 source를 다시 검증한다.
8. 후보가 없으면 오류가 아니라 201 `insufficient_wardrobe`, `outfits=[]`, 구체적이고 안정적인 `shortfall_reasons`를 저장한다. 1개 이상이면 `ready`; 요청 수보다 적으면 `ready`와 부족 근거를 함께 반환한다.

동일 idempotency key의 DB mutation은 원자적으로 하나만 남긴다. 저장 전 provider/선택적 LLM 호출이 배포 인스턴스 간 동시에 중복될 수 있는 비용 경계는 별도 claim/queue 계약이 없는 현재 동기 API의 제한으로 결과 문서에 명시한다. DB 중복 생성이나 서로 다른 응답 재생은 허용하지 않는다.

### 규칙 engine 최소 경계

- outfit은 1~10개의 중복 없는 본인 garment ID로만 구성한다.
- category 조합, 날씨 적합, 선택 추구미 점수, 조화 점수는 versioned 상수/함수로 분리하고 동일 입력에 동일 출력을 내며 tie-breaker는 안정적인 ID 순서로 고정한다.
- 학습되지 않은 thermal/color 의미나 누락 속성을 추측하지 않는다. 데이터가 없으면 명시한 neutral score/shortfall 규칙을 사용한다.
- `reason_facts`와 template 설명은 실제 선택 의류 category, 정규화 날씨, 저장된 선호 점수에서만 만든다. similarity를 확률이나 정확도로 표현하지 않는다.

### 조회 projection

- `GET /recommendations/{recommendationId}`는 owner request, rank 순 outfit, item을 조회하고 safe DTO를 재구성한다. raw `preference_snapshot`, provider payload, 내부 garment attributes/object key, idempotency row는 노출하지 않는다.
- snapshot payload는 Weather DTO allowlist로만 변환한다. DB에 저장된 outfit ID와 garment ID 순서를 안정적으로 반환한다.
- 생성 후 의류가 삭제돼도 과거 추천 행을 조용히 재작성하지 않는다. 조회는 저장된 세트를 보여주되 채택 시 활성 여부를 다시 검사해 409로 막는다.

## 6. 추천 채택 RPC

새 authenticated narrow RPC의 제안 signature는 `accept_my_recommendation(p_recommendation_id uuid, p_outfit_id uuid, p_worn_on date, p_idempotency_key text)`다. 기존 `accept_outfit(uuid,date)`의 authenticated 실행권은 새 RPC 검증과 테스트가 준비된 migration에서 제거한다.

RPC는 한 transaction에서 다음을 수행한다.

1. `auth.uid()` 존재, 인자·idempotency key를 검증하고 `(recommendation_id, outfit_id, worn_on)` canonical hash로 replay/conflict를 판정한다.
2. 사용자+날짜 advisory transaction lock과 recommendation/outfit row lock을 잡는다.
3. path의 recommendation이 본인 소유이며 `ready`, 만료 전이고 `target_date=p_worn_on`인지, outfit이 정확히 그 recommendation 소속인지 확인한다.
4. 모든 outfit item이 본인의 활성 garment인지 재검증한다. 빈 outfit, 삭제 의류, 타인 연결, 만료는 409이며 기존 OOTD를 덮어쓰지 않는다.
5. 같은 날짜·같은 outfit OOTD가 있으면 기존 행을 성공 replay한다. 같은 날짜의 다른 outfit 또는 수동 OOTD는 409 `OOTD_DATE_CONFLICT`다.
6. 새 OOTD는 `wear_status='worn'`, `visibility='private'`, `saved_outfit_id=null`, 추천의 `weather_snapshot_id`, `version=1`을 명시한다. `item_snapshot`은 garment ID/category와 `unavailable=false`를 저장해 OpenAPI DTO를 만족한다.
7. 201 safe response 또는 재조회에 필요한 OOTD ID를 idempotency row에 기록한다. 같은 key·다른 payload는 409이고 만료 key 처리도 기존 G2/G3 규칙과 일치시킨다.

RPC는 recommendation ID와 outfit ID를 모두 받으므로 다른 추천의 outfit을 path에 끼워 넣을 수 없다. SQL 예외는 404(본인에게 없는 resource), 409(만료·상태·의류·날짜·idempotency 충돌), 422(형식/날짜 불일치)로 고정 매핑한다.

## 7. 예정 변경 단위

root 구현 시 아래 단위로 최소 변경한다. 실제 파일명은 기존 구조와 G4 통합 결과에 맞춰 확정한다.

- additive G5 migration 1개: cache index, server-only snapshot/recommendation 저장 함수, authenticated 채택 함수, 정확한 revoke/grant.
- SQL 테스트 1개: 추천 저장·소유권·idempotency·채택 transaction/RLS.
- `lib/weather*`: grid 변환, provider HTTP adapter, cache resolver, safe DTO.
- `lib/recommendations*`: strict validation, deterministic engine, template builder, 선택적 LLM adapter, projection.
- HTTP handler 4개: weather current, recommendation create/get/accept.
- unit/fixture와 공통 error/RPC allowlist 최소 확장.
- 정본 OpenAPI와 backend 사본, API/DB design, coverage registry, manifest, G5 결과 worklog 동기화.

G4/G6와 공통인 `ootd_entries`, 오류 모듈, Supabase gateway는 root 단일 작성자가 통합한다. 이 계획 단계에서는 해당 파일을 수정하지 않는다.

## 8. 검토 체크리스트

구현 전에 읽기 전용 고난도 검토에서 다음을 확정한다.

- 10분 fresh/3시간 stale와 현재 유효 슬롯 판정이 KMA 발표 주기 및 계약에 맞는가.
- server-only 추천 저장 RPC가 service-role 우회 상황에서도 user ID, snapshot, garment ownership을 충분히 재검증하는가.
- deterministic 조합 규칙이 의류 부족과 1~3개 shortfall을 일관되게 만드는가.
- LLM에 보낼 최소 fact와 출력 validator가 설명만 허용하고 선택·점수 변경을 차단하는가.
- 기존 `accept_outfit` 권한 제거가 G6 계획과 충돌하지 않고, 새 OOTD snapshot이 현재 OpenAPI를 정확히 만족하는가.
- create idempotency가 DB 중복은 막되 저장 전 외부 호출 중복이라는 한계를 정직하게 문서화하는가.

검토 결과가 계약을 바꾸면 먼저 이 계획/OpenAPI를 정합화하고 구현한다. 검토 실패·응답 없음은 성공 리뷰로 기록하지 않는다.

## 9. 테스트 계획

### HTTP/unit

- 인증 없음/잘못된 JWT, HEAD·허용 method, CORS, body 제한과 exact allowlist.
- lat/lon 경계, NaN/중복 query/지원 격자 밖, count 0·4, non-null TPO, UUID·날짜·idempotency 형식.
- fresh cache hit, provider 성공 upsert, timeout/5xx/invalid JSON, stale fallback, stale 한도 초과 503, 과거·미래 슬롯 오용 차단.
- active owner garments만 후보가 되고 삭제·타인 의류가 제외되는지, 동일 입력 ordering/점수 안정성, 0·1·2·3개와 shortfall.
- LLM 성공/timeout/invalid schema/근거 외 문장/1,000자 초과별 per-outfit template fallback 및 source 표기.
- create replay와 hash conflict, get owner 200/cross-owner 404, raw payload·object key·preference snapshot 비노출.
- accept 성공, 같은 key replay, 다른 key 같은 outfit replay, 같은 key 다른 body 충돌, 만료 추천, target date 불일치, 다른 추천 outfit, 삭제 의류, 날짜의 다른 OOTD 충돌.

### SQL/RLS

- authenticated가 weather/recommendation server-only 저장 RPC와 테이블 write를 직접 수행하지 못한다.
- server-only 저장 함수도 타인/삭제 garment, 잘못된 score/rank/count/source, 다른 슬롯 snapshot을 거절한다.
- request/outfit/item owner-read RLS와 cross-owner 복합 FK가 유지된다.
- snapshot unique race, recommendation 세 테이블+idempotency의 전부 성공/전부 rollback.
- 채택 RPC의 advisory lock, path association, 활성 의류 재검증, `wear_status=worn`, weather 연결, snapshot 구조, 날짜 conflict와 replay.

### 회귀 gate

G5 종료 시 `npm test`, `npm run test:schema`, `npm run coverage:contract`, `npm run seed:validate`, `npm run smoke:preview`, `git diff --check`를 모두 실행한다. OpenAPI 정본/사본 hash와 operation registry를 확인하고 정확히 네 operation만 새 `implemented-local`로 집계한다.

## 10. 오류와 fallback 정책 요약

| 상황 | 결과 |
|---|---|
| 지원 격자 밖 위치 | 422 `UNSUPPORTED_LOCATION` |
| provider 실패 + 허용 cache | 200/201, `weather.is_stale=true` |
| provider 실패 + cache 없음/만료 | 503 `WEATHER_UNAVAILABLE` |
| 의류가 조합 기준에 부족 | 201 `insufficient_wardrobe`, 빈 outfits, shortfall |
| LLM 미설정·실패·부적합 | 성공 유지, 해당 outfit `template` 설명 |
| 같은 idempotency key·같은 의미 | 저장된 성공 응답 replay |
| 같은 key·다른 의미 | 409 `IDEMPOTENCY_CONFLICT` |
| 타 사용자 recommendation/outfit | 404 |
| 만료·삭제 의류·다른 날짜/세트 outfit | 409 |
| 같은 날짜 다른 OOTD | 409, 덮어쓰기 없음 |
| DB/Auth/server-only 설정 장애 | 503, 내부 본문·비밀값 비노출 |

## 11. 미검증 경계와 사용자 Supabase 후속 설정

로컬 완료 뒤에도 다음은 완료로 주장하지 않는다.

- 실제 hosted Supabase migration/RLS/RPC와 service-role server runtime.
- 실제 KMA 좌표→격자, 발표 주기, quota, timeout, 장애 cache 동작.
- 실제 LLM latency·비용·출력 품질·개인정보 처리.
- Preview의 동시 idempotency, timezone 자정 경계, 날씨/추천/채택 end-to-end.

사용자가 나중에 수행할 항목은 G5 migration 적용, 서버 전용 Supabase secret 설정, 날씨 provider key/base URL 설정, 선택 시 LLM endpoint/secret 설정, 테스트 사용자 두 명으로 owner/cross-owner E2E 실행이다. 키 값은 프론트 공개 변수에 넣지 않고 저장소·로그·채팅에 남기지 않는다. G5 구현 결과에서 최종 환경변수 이름과 hosted 검증 명령을 별도 체크리스트로 확정한다.

## 12. 구현 순서와 종료 조건

1. 이 계획 read-only 검토 및 cache/engine/RPC 경계 확정.
2. G4 변경 회수 후 migration 순번·공통 파일 충돌 확인.
3. additive migration과 SQL 테스트 작성·실행.
4. weather provider/cache 수직 경로 구현·unit 검증.
5. deterministic recommendation/template/선택적 LLM과 원자 저장 구현·검증.
6. 조회 projection과 accept RPC/handler 구현·권한·idempotency 검증.
7. contract fixture/OpenAPI/coverage/문서 사본·manifest 동기화.
8. 전체 G1~G5 회귀 gate 실행 후 `worklogs/2026-10-01_G5_RECOMMENDATION_RESULT.md`에 통과 수, hosted 미검증, 사용자 설정을 기록.

테스트 실패, provider나 DB가 mock-only인 상태, 설명 source 허위 표기, 권한/문서/coverage 불일치가 하나라도 있으면 G5는 checkpoint로 남기고 완료 처리하지 않는다.
