# G6 보관함·OOTD·옷장 통계 HTTP 수직 슬라이스 계획

상태: 구현·로컬 검증 완료 
범위: 보관함 5개, OOTD 5개, 옷장 통계 1개 등 11개 operation  
예상 증가: G5 완료 기준 `implemented-local` 25/50 → G6 완료 36/50  
선행조건: G5 migration·추천 채택 RPC 회수 및 G1~G5 회귀 통과

## 1. bounded goal과 완료 기준

날짜 없는 재사용 코디 보관함, 특정 날짜의 비공개 OOTD 기록, 실제 착용만 반영하는 옷장 통계를 하나의 로컬 수직 슬라이스로 구현한다.

- 보관함: `listSavedOutfits`, `createSavedOutfit`, `getSavedOutfit`, `updateSavedOutfit`, `deleteSavedOutfit`.
- OOTD: `listOotdEntries`, `createManualOotd`, `getOotd`, `updateOotdEntry`, `deleteOotdEntry`.
- 통계: `getClosetStatistics`.

다음이 모두 있어야 11개 operation을 `implemented-local`로 올린다.

1. 실제 handler와 사용자 JWT/RLS read path, authenticated narrow write RPC가 연결된다.
2. 보관함 본체+items와 OOTD snapshot 쓰기가 각각 한 DB transaction에서 끝난다.
3. 소유권, 활성 의류, 1~10개 중복 금지, optimistic version, 생성/삭제 idempotency, 하루 한 기록을 SQL과 HTTP 테스트가 함께 증명한다.
4. 보관함 편집·삭제 뒤에도 과거 OOTD `item_snapshot`이 변하지 않고, 이미 공유한 feed post를 암묵적으로 삭제·수정하지 않는다.
5. 통계는 `wear_status='worn'`인 OOTD snapshot만 집계하고 `planned`·`unconfirmed`를 제외한다.
6. 정본 OpenAPI·사본·coverage·문서·manifest와 전체 G1~G6 회귀가 일치한다.

범위 밖은 하루 여러 착장 허용, OOTD 독립 사진, 피드 게시/철회, 날씨 provider 재수집, 추천 생성, UI 위치, 통계 기반 재추천이다. 현재 하루 1개 unique와 `planned|worn` 기술 계약은 팀 정책 확정 전의 보수적 기준으로 유지한다.

## 2. 현재 계약과 데이터 기준선

- `saved_outfits`는 날짜 없는 `title`, nullable `note`, nullable `source_recommendation_id`, `version`, timestamps를 가진다. `saved_outfit_items`는 input 순서를 `position`으로 보존하고 `(user_id,id)` 복합 FK로 교차 소유 연결을 막는다.
- `ootd_entries`는 `outfit_id` 또는 `saved_outfit_id`를 최대 하나만 가질 수 있고, 둘 다 null인 순수 수동 조합도 유효하다. `item_snapshot`은 원본 보관함/추천의 이후 변경과 독립적이다.
- OpenAPI create/patch 입력은 garment ID 1~10개, source ID 최대 하나, `planned|worn`, nullable note/rating/weather snapshot이다. 미래 `worn`은 금지하고 `planned` rating은 null이어야 한다.
- 기존 `unconfirmed` 행은 조회 계약에는 남지만 create/patch의 새 값으로 만들지 않는다. patch가 status를 생략하면 기존 `unconfirmed`를 보존할 수 있고, 명시 전환은 `planned|worn`만 허용한다.
- 보관함 목록 정렬은 계약에 명시가 없어 구현 기준을 `created_at DESC,id DESC`로 문서화한다. OOTD는 계약대로 `worn_on DESC,id DESC`, `from/to` 포함, `from<=to`, 최대 366일이다.
- 현재 direct table write는 차단되고 owner-read RLS가 있다. 제품 쓰기 RPC는 아직 없으며 기존 보관함 삭제는 OOTD FK 때문에 실패할 수 있다.

G6는 기존 migration을 수정하지 않고 G5 다음의 충돌 없는 additive migration 하나로 보완한다. 파일 순번은 병렬 P1-G5-DB가 소유한 `202610010002_recommendations.sql` 회수 후 root가 확정한다.

## 3. 공통 인증·소유권·응답 경계

- 모든 handler는 기존 Bearer JWT 검증을 거치고 사용자 ID를 body/query에서 받지 않는다. UUID, 날짜, 배열 개수/중복, 문자열 길이, exact allowlist와 body 크기를 RPC 전에 검증한다.
- 조회는 사용자 JWT/RLS만 사용하고 타 사용자 또는 없는 resource는 동일하게 404로 처리한다.
- write RPC는 `security definer set search_path=''`, `auth.uid()` 필수, 다른 사용자 ID 인자 없음, `public/anon/authenticated` revoke 후 필요한 signature만 authenticated execute한다.
- RPC는 BFF preflight와 별도로 모든 garment/source row의 `user_id=auth.uid()`와 활성 상태를 검증한다. service role은 G6 일반 CRUD에 필요하지 않다.
- DB row를 그대로 직렬화하지 않고 OpenAPI allowlist DTO를 만든다. 내부 garment attributes, object key, feed linkage, idempotency row는 노출하지 않는다.
- DB/Auth/PostgREST 장애는 503으로 실패 폐쇄하도록 현재 OpenAPI에 빠진 503 응답을 11개 operation에 일관되게 추가하는 것을 검토한다. validation은 422, version/idempotency/date/reference 충돌은 409다.

## 4. 보관함 설계

### 생성

`create_my_saved_outfit(title,note,garment_ids,source_recommendation_id,idempotency_key)` 형태의 authenticated RPC를 둔다.

1. title 1~100자, note nullable 1,000자 이하, garment ID 1~10개·중복 없음, idempotency key 기존 8~128자 규칙을 검사한다.
2. input 배열의 순서를 position 0부터 저장한다. canonical request hash에도 배열 순서를 포함한다.
3. 모든 garment가 본인의 활성 의류인지 row lock/transaction 안에서 확인한다. 삭제 의류와 타인 의류는 저장하지 않는다.
4. `source_recommendation_id`는 DB FK상 `outfit_recommendations.id`이므로 이름과 실제 참조 대상을 문서에 명시한다. non-null이면 본인 추천 outfit이고 생성 시 garment 집합이 그 outfit items와 일치해야 한다.
5. idempotency scope를 operation별로 분리한다. 같은 key·같은 hash는 기존 201 safe response를 재생하고 같은 key·다른 hash는 409다. 만료 row 처리는 G2/G3/G5 규칙과 일치시킨다.
6. `saved_outfits`, ordered items, idempotency response를 한 transaction에서 저장한다.

### 목록·상세 projection

- 목록은 `created_at DESC,id DESC`, limit+1 keyset으로 조회한다. cursor는 schema version, 마지막 원시 timestamp·UUID, 정렬/필터 식별자를 base64url로 감싼 불투명 값이며 malformed·다른 endpoint cursor는 400이다.
- `garment_ids`는 position 순으로 과거 구성 전체를 반환한다. 현재 soft-delete된 garment도 ID를 지우지 않고 `unavailable_garment_ids`에 따로 표시한다.
- `unavailable_garment_ids`는 garment 부재/soft-delete를 현재 시점에 계산하며 input 순서를 유지한다. 이 표시 때문에 보관함 원본 row나 items를 변경하지 않는다.
- 타 사용자 상세는 RLS 결과 없음과 같은 404다.

### 수정

`update_my_saved_outfit`은 `expected_version`과 title/note/garment_ids/source 각각의 presence flag를 받는다.

- row를 `FOR UPDATE`하고 version이 다르면 409 `VERSION_CONFLICT`다. 최소 한 필드가 실제 patch에 있어야 한다.
- note/source는 생략과 명시 null을 구분한다. title은 null 불가다.
- garment_ids를 교체할 때만 새 배열 전체의 본인·활성·중복·개수와 position을 재검증하고 items를 한 transaction에서 교체한다. title/note-only patch는 기존에 삭제된 garment가 있어도 허용한다.
- 새 source를 지정하면 결과 garment 집합이 해당 본인 추천 outfit과 일치해야 한다. garment 집합을 source와 다르게 바꾸려면 caller가 source를 명시적으로 null로 해제해야 하며 서버가 provenance를 몰래 바꾸지 않는다.
- 성공 시 version을 정확히 1 증가시키고 재조회한 safe DTO를 반환한다. 보관함 변경은 기존 OOTD snapshot이나 feed에 전파하지 않는다.

### 삭제

- OpenAPI에 idempotency header가 없으므로 첫 삭제는 204, 이후 별도 호출은 404로 정의한다. 반복 204가 필요하면 먼저 계약을 변경한다.
- 한 transaction에서 본인 saved outfit을 잠그고, 이를 출처로 삼은 OOTD의 `saved_outfit_id`만 null로 분리한 뒤 items와 본체를 hard delete한다. OOTD의 `item_snapshot`, 날짜, note/rating/status는 그대로 유지한다.
- feed post나 OOTD 자체를 cascade 삭제하지 않고 garment도 삭제하지 않는다.

## 5. OOTD snapshot과 CRUD

### snapshot 불변성

- 쓰기 시점의 garment ID, category, input position을 `item_snapshot`에 저장한다. 외부 DTO의 `garment_ids`는 snapshot position 순으로 만든다.
- 저장된 category/구성은 보관함·추천·garment category가 나중에 바뀌어도 자동 갱신하지 않는다.
- DTO의 `unavailable`은 현재 garment가 본인 소유 활성 상태인지 read 시 overlay한다. snapshot 자체를 이 표시 때문에 다시 쓰지 않는다.
- 구성 변경 PATCH는 사용자가 명시한 새 snapshot을 만들고 version을 올리는 유일한 경로다.

### 생성

`create_my_ootd`는 OpenAPI 전체 입력과 idempotency key를 받아 한 transaction에서 처리한다.

1. profile timezone의 현재 날짜를 기준으로 미래 `worn`을 422로 거절한다. `planned`이면 rating은 null이어야 한다. 날짜 문자열은 달력상 유효한 ISO date여야 한다.
2. user+`worn_on` advisory transaction lock으로 현재 하루 1개 unique를 직렬화한다. 이미 같은 날짜의 어떤 OOTD가 있으면 409이며 다른 key로 기존 행을 성공 처리하지 않는다.
3. garment_ids는 본인 활성 의류 1~10개, 중복 없음이어야 한다. DB가 현재 category를 읽어 snapshot을 만들며 클라이언트 category를 신뢰하지 않는다.
4. `saved_outfit_id`와 `outfit_id`는 최대 하나만 non-null이다. source가 있으면 본인 소유이고 입력 garment 집합이 source의 현재 items와 일치해야 한다. 둘 다 null인 수동 조합은 허용한다.
5. `visibility='private'`, version 1을 명시하고 OOTD와 idempotency response를 원자 저장한다. 생성은 feed 게시를 유발하지 않는다.

### 날씨 snapshot 검증

- 임의 weather JSON은 받지 않고 G5가 만든 `weather_snapshot_id`만 허용한다. snapshot 존재, 허용 provider/source, `valid_at`의 profile-timezone 날짜가 `worn_on`과 같은지 검증한다.
- 추천 `outfit_id`가 source이면 recommendation request의 weather snapshot과 정확히 같은 ID만 연결한다. 다르면 422 또는 null fallback 규칙을 계약에 고정한다.
- 순수 수동/보관 source에는 비교할 요청 위치가 현재 입력 계약에 없다. 따라서 G6는 snapshot의 서버 발급 격자·날짜만 검증할 수 있으며 실제 사용자 위치와 같다고 주장하지 않는다. 날짜/출처가 불명확하면 오늘 날씨를 과거·미래에 대신 붙이지 않고 null로 저장한다.
- 과거 provider 자료가 없거나 미래 예보 범위 밖인 경우 null은 정상 결과다. G6가 날씨 provider를 재호출하거나 snapshot을 생성하지 않는다.

### 상세·목록

- 상세는 owner row와 snapshot을 safe DTO로 변환한다. `visibility`는 항상 `private`이며 내부 feed 참조는 노출하지 않는다.
- 목록은 `from`/`to` 포함, 최대 366일, `worn_on DESC,id DESC` limit+1 keyset이다. cursor에 from/to와 정렬 version을 포함해 다른 범위 재사용을 400으로 막는다.
- 목록/상세는 동일 projection 함수를 사용해 legacy `unconfirmed`와 현재 unavailable overlay가 일치해야 한다.

### 수정

`update_my_ootd`는 `expected_version`과 모든 nullable/source 필드의 presence flag를 받아 원자 처리한다.

- 현재 row를 `FOR UPDATE`; stale version은 409다. 날짜를 바꾸면 old/new 날짜 advisory lock을 정렬된 순서로 획득해 deadlock 없이 하루 unique를 검사한다.
- patch 결과 전체를 기준으로 미래 worn, planned rating null, source 최대 하나, source-구성 일치, weather 날짜/추천 연결을 다시 검증한다.
- garment_ids가 명시되면 본인 활성 의류로 snapshot 전체를 재생성한다. 생략하면 기존 snapshot을 보존한다.
- `saved_outfit_id`/`outfit_id`는 생략과 null을 구분한다. 출처만 바꿀 때도 결과 snapshot garment 집합과 새 source가 일치해야 한다.
- 성공 시 version +1. 날짜/구성/note/rating/status 변경은 원본 saved outfit, recommendation, 이미 공유한 feed post를 자동 변경하지 않는다.

### 삭제

`delete_my_ootd(ootd_id,idempotency_key)`는 replay를 resource 존재 확인보다 먼저 판정한다.

- 같은 key·같은 OOTD의 완료 replay는 204, 같은 key·다른 ID는 409다. 다른 key로 이미 삭제된 ID는 404다.
- OOTD를 참조하는 feed post가 있으면 자동으로 게시물을 지우거나 source를 끊지 않고 409 `OOTD_IN_USE`다. 사용자가 G7의 게시물 철회/삭제를 먼저 수행해야 한다.
- 참조가 없으면 OOTD를 hard delete하고 idempotency 204를 기록한다. garment, saved outfit, recommendation은 변경하지 않는다.

## 6. 옷장 통계

authenticated read RPC `get_my_closet_statistics()` 또는 동등한 owner-fixed DB query를 사용한다. 다른 사용자 ID나 임의 `as_of`를 인자로 받지 않고 profile timezone의 현재 날짜를 서버에서 계산한다.

- 대상은 현재 본인 active garments다. soft-delete garment는 결과에서 제외한다.
- 착용 횟수는 `ootd_entries.wear_status='worn'`이고 `worn_on<=as_of`인 저장 snapshot에서 garment ID별로 센다. 현재 `outfit_items`나 `saved_outfit_items`를 join해 과거 구성을 재해석하지 않는다.
- 한 OOTD snapshot 안의 중복 ID는 DB/RPC가 금지하지만 집계도 방어적으로 distinct 처리한다.
- `wear_counts`는 active garment 전부를 안정적인 ID 순서로 반환하며 착용 이력이 없으면 count 0이다.
- `unworn_30_days`는 최근 30개 달력 날짜 `[as_of-29, as_of]`에 worn snapshot이 없는 active garment다. 등록 30일 미만 의류도 등록 이후 한 번도 worn이 없으면 포함하며, 클라이언트는 garment created_at과 함께 신규 의류로 별도 해석할 수 있다.
- planned/unconfirmed, 미래 날짜, saved outfit 생성/수정, 추천 조회는 통계를 올리지 않는다. OOTD를 worn↔planned로 수정하거나 삭제하면 다음 조회부터 자연스럽게 반영된다.

RPC 결과 또는 BFF projection은 OpenAPI의 `as_of`, `wear_counts[{garment_id,count}]`, `unworn_30_days[]`만 반환한다.

## 7. G5·G7 충돌 경계

### G5 추천 채택과의 공통 규칙

- P1-G5-DB가 만드는 추천 채택 RPC/migration을 먼저 회수한다. G6는 같은 `ootd_entries`에 중복 column/constraint/function을 만들지 않는다.
- 추천 채택 OOTD도 `wear_status='worn'`, private, version 1, recommendation weather snapshot, category snapshot과 동일한 `unavailable` projection 규칙을 만족해야 한다.
- G5가 기존 `accept_outfit` 실행권을 회수하고 새 `accept_my_recommendation`을 제공하면 G6는 이를 다시 교체하지 않고 공통 snapshot helper가 필요할 때 additive helper만 조정한다.
- 추천 채택 idempotency scope와 수동 OOTD create/delete scope를 분리한다. 같은 key 문자열이 operation 간 충돌하면 안 된다.
- G5 recommendation의 `outfit_id`와 G6 `saved_outfit_id`는 provenance일 뿐 OOTD snapshot의 현재 구성을 동적으로 바꾸지 않는다.

### G7 피드와의 경계

- G6는 feed post를 생성·수정·삭제하지 않는다. OOTD 삭제 시 참조 feed가 있으면 409로 막고 G7 명령을 선행시킨다.
- OOTD 수정은 이미 공유된 게시물 caption/tag/media를 갱신하지 않는다. G7은 게시물 공개 projection에서 private OOTD linkage를 노출하지 않는다.

## 8. migration/RPC 예정 단위

root 구현 시 다음을 하나의 additive G6 migration과 SQL assertion으로 구성한다.

- 보관함 create/update/delete authenticated RPC와 목록용 index.
- OOTD create/update/delete authenticated RPC, 목록용 `(user_id,worn_on desc,id desc)` index, snapshot JSON shape 방어 검증.
- owner-fixed closet statistics read RPC.
- 필요하면 공통 내부 validation/snapshot helper. helper 자체는 public/anon/authenticated execute를 revoke하고 공개 RPC를 통해서만 호출한다.
- 각 public RPC signature의 exact revoke/grant. table direct INSERT/UPDATE/DELETE 차단은 유지한다.

RPC는 safe JSON 또는 생성 ID만 반환하고 BFF가 사용자 JWT/RLS로 재조회한다. raw composite row를 그대로 외부 DTO로 사용하지 않는다.

## 9. pagination·version·idempotency 행렬

| operation | 동시성/재시도 기준 |
|---|---|
| 보관함 목록 | `created_at DESC,id DESC`, limit+1, cursor version/filter binding |
| OOTD 목록 | `worn_on DESC,id DESC`, from/to cursor binding, 최대 366일 |
| 보관함 생성 | idempotency key + ordered body canonical hash, 201 replay |
| 보관함 수정 | row lock + `expected_version`, 성공 시 +1 |
| 보관함 삭제 | header 없음; 첫 204, 이후 404, OOTD source detach |
| OOTD 생성 | idempotency key + 날짜 advisory lock, 동일 날짜 충돌 409 |
| OOTD 수정 | row lock + `expected_version`, 날짜 lock, 성공 시 +1 |
| OOTD 삭제 | idempotency key, 완료 replay 204, feed 참조 409 |
| 통계 | profile timezone의 서버 `as_of`, mutation 없음 |

모든 idempotency hash는 null/생략을 계약에 맞게 canonicalize하고 scope를 operation별로 분리한다. response 저장과 domain mutation은 같은 transaction이어야 한다.

## 10. HTTP·SQL 테스트 계획

### 보관함

- title/note 경계, 0·11개/중복/잘못된 UUID, exact field allowlist와 body 제한.
- create replay/conflict/expired key, input position 보존, 타인·soft-delete garment 차단.
- source recommendation owner 및 초기 구성 일치, 위조 provenance 거절.
- list keyset 무중복·무누락, malformed/다른 cursor 거절, limit 1·100.
- 상세 cross-owner 404, 삭제 garment가 `garment_ids`에는 남고 unavailable에만 표시.
- update stale version, omitted/null 구분, items 원자 교체/rollback, metadata-only patch가 기존 unavailable item 때문에 실패하지 않음.
- delete가 OOTD source만 null로 만들고 snapshot을 보존하며 다른 사용자 row는 건드리지 않음.

### OOTD

- 순수 수동, saved source, recommendation source 생성과 source 둘 동시 non-null 거절.
- active owner garments, ordered category snapshot, 보관함 수정·garment category 변경 후 snapshot 불변.
- 미래 worn, planned rating, invalid date, 하루 중복, 생성 replay/conflict.
- weather snapshot 같은 날짜/추천 연결 성공, 과거·미래 슬롯 또는 잘못된 source 거절/null 처리.
- from/to 포함·역전·367일, keyset ordering/cursor filter binding, 상세 cross-owner 404.
- patch stale version, 날짜 충돌, old/new 날짜 동시 수정, snapshot 재생성, unconfirmed 보존/명시 전환.
- unavailable overlay가 저장 category를 바꾸지 않음.
- delete replay, 다른 key not-found, feed reference 409, 비참조 hard delete.

### 통계·권한

- worn만 count; planned/unconfirmed/future 제외.
- OOTD snapshot 기준 count라 saved outfit/추천 변경에 영향 없음.
- active garment count 0 포함, soft-delete 제외, 30일 경계와 신규 garment 미착용.
- 직접 table write 거절, RPC의 auth 없음/타인 garment/source 거절, helper execute 권한 차단, cross-owner FK 회귀.
- G5 추천 채택 OOTD가 G6 상세·목록·통계에 동일하게 나타남.

### 전체 gate

G6 종료 시 `npm test`, `npm run test:schema`, `npm run coverage:contract`, `npm run seed:validate`, `npm run smoke:preview`, `git diff --check`를 실행한다. 정본/사본 hash, migration 개수, SQL assertion, operation registry 36/50을 함께 확인한다.

## 11. 오류 정책

| 상황 | HTTP 결과 |
|---|---|
| 인증 없음/잘못된 JWT | 401 |
| malformed query/cursor/path/body | 400 |
| 길이·개수·상태·날짜 정책 위반 | 422 |
| 타인 또는 없는 보관함/OOTD/source | 404 |
| stale version, idempotency mismatch, 하루 중복 | 409 |
| source와 garment 구성 불일치 | 409 또는 계약상 validation 422로 한 번 고정 |
| 미래 worn, planned non-null rating | 422 |
| 날씨 snapshot 날짜/추천 불일치 | 422; 불명확·자료 없음은 null |
| OOTD를 참조하는 feed가 존재 | 409 `OOTD_IN_USE` |
| Auth/DB/PostgREST 설정·upstream 장애 | 503, 내부 본문 비노출 |

## 12. hosted 미검증과 사용자 후속 설정

로컬 완료 뒤에도 다음은 별도 hosted 검증으로 남긴다.

- 실제 Supabase의 RPC 권한, RLS, FK, advisory lock, 동시 version/idempotency/date 충돌.
- profile timezone 자정 경계와 PostgREST date/timestamptz 직렬화.
- G5 추천 채택→G6 조회/통계, 보관함 삭제→OOTD snapshot 보존, G7 feed 참조→OOTD 삭제 충돌 end-to-end.
- 큰 옷장/366일 범위의 query plan과 p95. 로컬 fixture 시간은 성능 보장이 아니다.

G6 자체로 새 provider key나 비밀값은 필요 없다. 사용자는 G5와 G6 migration을 확정 순서로 개발 Supabase에 적용하고, 기존 서버 Auth/Supabase 환경변수를 유지하며, 테스트 사용자 두 명과 다음 hosted 시나리오를 실행하면 된다.

1. 사용자 A/B 의류로 cross-owner create/update가 거절되는지 확인.
2. A의 보관함 생성·수정 후 과거 OOTD snapshot이 그대로인지 확인.
3. 같은 날짜 동시 OOTD 요청 중 하나만 성공하는지 확인.
4. G5 추천 채택 OOTD가 G6 목록과 worn 통계에 한 번만 반영되는지 확인.
5. feed 참조 OOTD 삭제가 409이고 게시물 철회 후 정책대로 삭제되는지 확인.

원격 DB·배포·비밀값 변경은 이 bounded goal에서 수행하지 않는다.

## 13. 구현 순서와 중단 조건

1. G5 DB/HTTP 결과와 migration 순번, 추천 채택 OOTD shape를 회수한다.
2. 이 계획을 read-only 검토해 source provenance, 날씨 위치 검증 한계, saved delete detach, feed reference 정책을 확정한다.
3. additive migration+SQL 테스트로 보관함/OOTD/statistics transaction과 권한을 먼저 고정한다.
4. 공통 validation/projection/cursor 모듈과 보관함 5개 handler를 구현·검증한다.
5. OOTD 5개 handler와 G5 채택 결과 호환을 구현·검증한다.
6. 통계 RPC/handler와 30일 경계를 검증한다.
7. fixture/OpenAPI/coverage/API·DB design/manifest/result worklog을 동기화한다.
8. G1~G6 전체 gate 후 결과를 기록한다.

G5 RPC shape 불일치, source/weather 계약 모순, snapshot 오염, mock-only 성공, SQL/회귀 실패, 정본/사본 hash 불일치 중 하나라도 있으면 G6를 완료 처리하지 않고 checkpoint와 정확한 재개 지점을 남긴다.
