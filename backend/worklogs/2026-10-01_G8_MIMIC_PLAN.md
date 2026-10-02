# G8 따라입기 HTTP 수직 슬라이스 bounded plan

상태: 로컬 구현·검토·검증 완료  
범위: `createMimicJob`, `getMimicJob` 2개 operation  
예상 증분: G7 완료 기준 `implemented-local` 47/50 → G8 완료 49/50  
선행조건: G7 migration·HTTP·회귀 gate 통과, `feed-private` 공개 media 계약 확정

## 1. 목표와 완료 기준

현재 공개 중인 G7 게시물을 입력으로 받아 본인 옷장의 활성 의류와 비동기 매칭하고, 요청자에게만 안전한 결과를 폴링으로 제공한다.

- `POST /mimic-jobs`는 `Idempotency-Key`와 `{post_id}`를 받아 현재 `public`·미삭제이며 검증된 media가 있는 게시물에 한해 job을 예약하고 `202 MimicResult`를 반환한다.
- `GET /mimic-jobs/{jobId}`는 job 소유권과 원본 게시물의 **현재** 공개성을 매번 재검사하고 `200 MimicResult`를 반환한다.
- `queued`, `running`, `succeeded`, `no_match`, `failed`의 durable 상태, lease, attempt, callback replay를 DB transaction으로 보호한다.
- worker에는 짧은 수명의 private 입력만 전달하고 Supabase DB/Storage credential, raw object key, 장기 signed URL을 주지 않는다.
- DB의 raw 결과를 클라이언트가 직접 읽지 못하게 하고 BFF projection에서 현재 본인 소유·활성 의류만 `garment_id`로 노출한다.
- 부분 매칭은 `succeeded`, 전부 미매칭은 `no_match`로 구분한다. 결과 저장은 자동 부수효과가 아니며 사용자가 별도로 `POST /saved-outfits`를 호출한다.

아래 증거가 모두 있을 때만 두 operation을 `implemented-local`로 올린다.

1. additive migration과 SQL assertion으로 RLS, idempotency, queue/lease/callback, 공개성, TTL, 결과 소유권이 증명된다.
2. 두 public handler와 필요한 service-only dispatcher/callback 경로가 구현되고 unit/contract test가 통과한다.
3. OpenAPI `MimicResult`와 실제 응답이 정확히 일치하며 내부 입력·결과·오류가 응답과 로그에 없다.
4. G1~G8 전체 로컬 gate와 manifest/coverage/doc 동기화가 통과한다.

실제 매칭 모델의 정확도, 실제 외부 worker 실행, hosted Storage signed read, hosted 동시성·secret 주입은 별도 미검증으로 남긴다. mock worker만 통과한 상태를 AI 연동 완료로 표현하지 않는다.

## 2. 고정 계약과 구현 전 결정

### 공개 HTTP 계약

| operation | 성공 | 입력 | 핵심 오류 |
|---|---:|---|---|
| `createMimicJob` | 202 | Bearer JWT, `Idempotency-Key`, exact body `{post_id}` | 400 malformed, 404 비공개·삭제·없음, 409 key 충돌/상태 충돌, 422 유효성, 429 제한 |
| `getMimicJob` | 200 | Bearer JWT, UUID `jobId` | 400 malformed, 404 타인 job·없음·현재 비공개/삭제 원본 |

OpenAPI상 POST 202도 `MimicResult`를 반환한다. 신규 job은 `status='queued'`, `matches=[]`, `model_version=null`, `coverage=null`, `error=null`로 응답하여 별도 `JobAccepted` DTO를 만들지 않는다. idempotent replay도 같은 job의 현재 안전 projection을 202로 반환한다.

`MimicMatch.similarity`는 `[-1,1]`의 모델 원시 유사도이지 확률이 아니다. UI나 `reason`에서 백분율 신뢰도로 바꾸지 않는다. `source_item_key`는 worker가 입력 snapshot 내 항목에 부여한 불투명 키이며 feed/OOTD/garment/object 식별자를 인코딩하지 않는다.

### visibility 결정

G8 입력은 **현재 public·미삭제 G7 post만** 허용한다. 작성자 자신이라도 private post로 job을 생성하거나 조회할 수 없다. 이는 G7의 owner-private 상세 조회 허용과 의도적으로 다르다.

- create, worker claim, get에서 각각 현재 공개성을 검사한다.
- public→private 또는 soft-delete 직후 신규 create, 기존 get, 신규 worker claim은 모두 차단한다.
- claim 뒤 private 전환이 일어나면 이미 발급된 입력 URL은 짧은 TTL까지 회수할 수 없으므로, callback 적용 시 다시 검사해 job을 안전한 `failed/SOURCE_UNAVAILABLE`로 종결하고 raw 결과는 채택하지 않는다.
- 이후 재공개하더라도 폐기된 실행 결과를 되살리지 않는다. 사용자는 새 idempotency key로 다시 요청한다.
- post hard-delete 또는 작성자 계정 cascade 시 연결된 mimic row도 삭제된다. 요청자 계정 삭제 시에도 mimic row가 cascade된다.

### 기존 테이블 보완

기존 `mimic_requests`에는 기본 상태와 raw `result`, `model_version`만 있다. 다음을 additive migration에서 보완한다.

- queue: `attempt`, `max_attempts`, `available_at`, `lease_token`, `lease_expires_at`, `updated_at`.
- retention: `expires_at`; terminal row와 idempotency response의 보존 경계를 명시한다.
- safe failure: 내부 `error_code`; 사용자 응답은 allowlist된 코드/문구로만 변환한다.
- input: service-only `input_snapshot` 또는 별도 내부 테이블에 post/media ID, 순서, 검증 metadata와 snapshot version을 보존한다. raw object key가 필요하면 service-only 열에만 두며 public projection에는 포함하지 않는다.
- result: 기존 `result`에는 callback 원본을 그대로 저장하지 않고 schema 검증·canonicalize된 내부 결과만 저장한다. feature vector, prompt, signed URL, worker stack/message는 저장하지 않는다.
- callback replay: 기존 `idempotency_keys`에 별도 전역 scope `mimic_callback`과 event ID/payload hash를 기록하거나 동일 보장을 하는 service-only event table을 둔다.

`mimic_requests`의 기존 owner direct SELECT는 회수한다. narrow projection RPC만 authenticated에 허용하여 private 전환 뒤 status/post_id까지 우회 조회되는 것을 막는다. table insert/update/delete, raw `result`, internal `model_version`, input snapshot, lease/error 열은 계속 service-only다.

## 3. create 경로와 idempotency

authenticated `create_my_mimic_job(post_id,idempotency_key,request_hash)` 계열 RPC를 한 transaction으로 둔다. 사용자 ID는 입력받지 않고 `auth.uid()`로 고정한다.

1. UUID, key 8~128자와 문자 allowlist, canonical request hash를 검사한다.
2. `feed_posts`를 잠그고 `visibility='public'`, `deleted_at is null`을 확인한다. 누락·비공개·삭제·타인 공개 여부와 무관하게 사용할 수 없으면 외부에는 동일한 404를 준다.
3. 위치 순서대로 verified·nondeleted `feed_media`가 1~10개인지 확인한다. G7 public invariant가 깨졌다면 공개 응답에 raw 경로를 넣지 않고 내부 무결성 오류로 실패한다.
4. idempotency scope는 `mimic_create`이며 `(user_id,scope,key)`에 canonical `{post_id}` hash를 묶는다. 동일 hash replay는 같은 job, 다른 hash는 409다.
5. replay 전에도 현재 post 공개성을 다시 검사한다. 과거 성공한 key가 비공개 원본의 존재·job 상태를 노출하는 우회가 되어서는 안 된다.
6. input snapshot과 `queued` job, 202 response reference를 원자 생성한다. Storage signed URL은 이 transaction이나 idempotency 응답에 저장하지 않는다.
7. 사용자별 open job(`queued|running`) 상한을 정해 초과는 429로 매핑한다. 다른 key로 같은 post의 중복 실행을 허용할지는 구현 검토에서 고정하되, 허용 시에도 open-job 상한을 우회하지 못한다. 권장안은 `(user_id,post_id)`의 활성 job을 재사용하고 terminal 뒤 새 key로 재실행하는 것이다.

권장 시간값은 migration 상수/함수 한 곳에 고정하고 테스트에서 clock을 제어한다.

- signed input URL: 최대 5분이며 worker lease보다 길지 않게 한다.
- worker lease: 기본 2분, 허용 30~900초.
- 최대 attempt: 3회. lease 만료 job은 backoff 후 재claim하고 모두 소진하면 `failed/ATTEMPTS_EXHAUSTED`다.
- create idempotency: 기존 공통 정책과 동일한 24시간.
- job/result TTL: terminal 후 7일을 기본안으로 삼고, 만료 job은 외부 404로 취급한다. 실제 hard cleanup은 별도 scheduler 책임이다.

시간값은 제품 합의 전 임의로 여러 파일에 복제하지 않는다. OpenAPI에 만료 필드가 없으므로 `expires_at`은 외부 DTO에 추가하지 않는다.

## 4. private worker input과 기존 G4 패턴 재사용

사용자가 G8 전용 파일을 새로 업로드하지 않는다. 입력은 G7이 이미 검증한 `feed-private` media다.

- trusted BFF/dispatcher만 service-only claim RPC를 호출한다. 외부 GPU/AI worker에 Supabase URL·service role·사용자 JWT를 전달하지 않는다.
- claim RPC는 `FOR UPDATE SKIP LOCKED`로 하나를 고르고 attempt를 증가시키며 새 lease token을 발급한다. expired running job을 재claim하고 attempt 소진 job을 terminal 실패시킨다.
- claim 직전 source post 공개성과 snapshot media의 verified·nondeleted 상태를 재확인한다. 깨진 job은 worker에 전달하지 않고 `SOURCE_UNAVAILABLE`로 종결한다.
- dispatcher가 snapshot의 정확한 object key만 server-side로 5분 이하 signed read URL로 바꾼다. URL은 worker 요청 body에만 존재하며 DB, callback, 일반 로그, error context에 쓰지 않는다.
- worker 요청은 private allowlisted endpoint와 HTTPS를 사용한다. 가능하면 worker가 다운로드를 시작한 뒤 URL을 보존하지 않으며 응답에는 URL/object key를 되돌리지 않는다.

G4의 durable queue와 raw-body HMAC callback 패턴은 재사용하되 G4 함수·event scope·검증 schema에 G8 payload를 억지로 섞지 않는다.

- 내부 경로 예: `POST /api/internal/mimic-jobs/{jobId}/result`.
- body parser를 끄고 `timestamp.raw_body` HMAC을 검증한다. 5분 clock skew, constant-time comparison, content length 상한을 둔다.
- `event_id`, `job_id`, `attempt`, `lease_token`, `status`, `model_version`, `matches`, `coverage/error`의 exact allowlist를 검증한다.
- callback event replay 판정을 lease/stale 판정보다 먼저 한다. 같은 event+payload는 200 `{applied:false}`, 같은 event+다른 payload는 409다.
- 새 event는 현재 running, attempt 일치, token 일치, 미만료 lease만 적용한다. stale attempt/token/lease는 409이고 terminal 결과를 덮어쓰지 않는다.
- 별도 `MIMIC_WORKER_HMAC_SECRET`을 권장한다. G4 secret을 공유해야 한다면 서명 입력에 `mimic` domain을 포함해 교차 endpoint replay를 막아야 하지만, 별도 secret이 더 단순한 기본안이다.

실제 worker callback이 없으면 G8은 mock-only다. public operation이 두 개뿐이어도 dispatcher/claim/callback은 비동기 상태를 성립시키는 필수 내부 경로이며 coverage operation 수에는 포함하지 않는다.

## 5. callback 결과 검증과 상태 전이

service-only 적용 RPC가 callback event, job, source post, candidate garments를 잠그고 한 transaction에서 검증·전이한다.

- `matches`는 source snapshot에 존재하는 `source_item_key`마다 최대 한 항목이며 키 중복·알 수 없는 키·과다 cardinality를 거절한다.
- `garment_id`가 있으면 반드시 job 요청자의 nondeleted 활성 garment여야 한다. 다른 사용자 garment, soft-deleted garment, 존재하지 않는 garment는 callback 전체를 422/409로 거절해 raw result를 저장하지 않는다.
- `similarity`는 finite number `[-1,1]` 또는 null이다. `garment_id=null`이면 similarity도 null이어야 한다.
- `reason`은 길이·문자 제한과 safe text 규칙을 적용한다. prompt, 경로, 모델 내부 오류, 개인정보를 그대로 통과시키지 않는다.
- `model_version`은 제한된 길이와 문자 집합의 식별자다. raw worker metadata나 weights URI가 아니다.
- `coverage`는 finite `[0,1]`이고 canonical source item 수와 matched item 수의 정의에 맞아야 한다. 서버가 재계산 가능한 경우 callback 값을 신뢰하지 않고 재계산한다.
- 하나 이상 유효 매칭이면 `succeeded`; 일부 null match도 허용한다. 모두 null이면 `no_match`; `failed`에는 matches가 없고 allowlist internal error code만 저장한다.
- source가 callback 시점에 private/deleted/unverified이면 raw 결과를 저장하지 않고 `failed/SOURCE_UNAVAILABLE`로 종결한다.
- terminal 전이는 `completed_at`과 `expires_at`을 함께 설정하고 lease token을 제거한다.

worker transport/network 오류는 dispatcher가 임의로 성공 callback을 만들지 않는다. lease가 만료되어 재시도되고 최대 attempt 소진 시 안전한 실패로 전이한다. 모델 timeout·rate limit 중 재시도 가능 여부는 allowlist로 나누며 무제한 retry는 금지한다.

## 6. get과 safe result projection

`get_my_mimic_job(job_id)` 계열 narrow RPC 또는 동등한 service-only projection은 다음 순서를 지킨다.

1. auth 사용자 소유 job인지 확인한다. 타인/없음/만료는 동일한 404다.
2. 연결된 post가 지금 public·미삭제인지 확인한다. private/deleted이면 404이며 status나 존재 여부도 노출하지 않는다.
3. terminal result의 모든 non-null garment ID를 다시 잠금 없이 현재 본인 소유·활성 조건으로 검증한다. callback 뒤 삭제된 의류는 projection에서 `garment_id`, similarity를 null로 바꾸고 안전한 reason으로 대체한다.
4. 현재 projection 기준으로 coverage를 다시 계산한다. 유효 후보가 모두 사라져도 DB terminal status를 몰래 바꾸지 않으며, 응답은 contract 합의에 따라 `no_match` projection 또는 `succeeded`+0 coverage 중 하나를 고정해야 한다. 권장안은 사용자 의미에 맞게 외부 projection을 `no_match`, matches의 항목은 null로 하되 내부 원본 상태는 보존하는 것이다.
5. `queued/running`은 `matches=[]`, `model_version=null`, `coverage=null`, `error=null`이다.
6. `failed`는 `matches=[]`, `coverage=null`, 필요 시 `model_version`은 null, `error`는 `ErrorDetail` allowlist만 반환한다. stack, provider 응답, lease/attempt는 노출하지 않는다.

OpenAPI가 `model_version`을 공개 필드로 요구하므로 succeeded/no_match에 safe identifier만 내보낸다. DB의 raw result 직접 조회를 허용한다는 뜻은 아니다. 응답에는 object key, signed URL, post 내부 OOTD ID, source garment ID, feature vector, prompt, worker event/lease, raw failure message가 없어야 한다.

클라이언트가 결과를 저장하려면 반환된 non-null `garment_id`를 골라 G6 `POST /saved-outfits`를 별도로 호출한다. G8 callback/get이 saved outfit을 만들거나 수정하지 않는다. G6가 그 시점의 garment 소유권·활성 상태를 다시 검사하는 것이 마지막 방어선이다.

## 7. RLS와 exact grants

- anon은 두 public operation과 모든 mimic table/RPC에 접근할 수 없다.
- authenticated는 create/get narrow RPC만 실행할 수 있다. `mimic_requests`, input snapshot, callback events의 direct INSERT/UPDATE/DELETE/SELECT를 모두 회수한다.
- service_role만 claim, callback inspect/apply, internal projection/storage lookup을 실행한다.
- SECURITY DEFINER 함수는 `search_path=''`, schema-qualified 객체, 입력 allowlist, `auth.uid()` 고정을 사용한다.
- public helper가 raw row type이나 `jsonb` 전체 result를 반환하지 않는다. service-only 함수도 arbitrary table/path/filter를 입력받지 않는다.
- G7 public projection 함수가 raw feed object key를 authenticated에 반환하지 않는 계약을 보존한다. G8의 Storage lookup은 별도 service-only exact job/media 함수로 제한한다.
- 모든 신규 함수에 `revoke all ... from public,anon,authenticated` 후 필요한 role만 exact `grant execute`한다. 기본 함수 실행 권한에 기대지 않는다.

## 8. 테스트 계획

### SQL assertion

- authenticated/anon direct mimic table write와 raw result/input/model/lease 조회 실패, create/get exact 실행 권한, internal 함수 authenticated 실행 실패.
- public+verified media post create 성공; private, soft-deleted, media 없음/unverified post는 privacy-safe 실패.
- idempotency 동일 key/hash replay는 동일 job 한 행, 다른 post/hash는 conflict, replay 시에도 현재 private 전환은 404, expiry 정책 일치.
- 사용자별 open-job 상한 및 같은 post 중복 정책, 동시 create에서 중복 job/상한 초과가 생기지 않음.
- claim `SKIP LOCKED`, available ordering, attempt 증가, 고유 lease, expired lease 재claim, max attempts terminal failure.
- claim 전 private/delete/media invalid 전환 차단.
- callback 동일 event/payload replay가 stale lease보다 먼저 성공, 같은 event/다른 hash conflict, 다른 event의 stale attempt/token/lease conflict.
- malformed status/cardinality/source key/duplicate key/nonfinite·범위 밖 similarity·coverage, 과도한 reason/model_version 거절.
- 타인 garment injection, soft-deleted/missing garment 거절; 본인 활성 garment 성공.
- succeeded partial, no_match, failed 각각 canonical result와 completed/expiry/lease clear 검증.
- callback 직전 private/delete 전환은 `SOURCE_UNAVAILABLE`이며 raw result 미저장.
- get은 owner only; 타인 job, 만료 job, 현재 private/deleted source 404. post 재공개가 폐기 callback 결과를 복구하지 않음.
- callback 뒤 garment 삭제 시 safe projection에서 제거되고 raw internal result는 authenticated가 읽지 못함.
- 요청자 계정 삭제와 source post hard-delete cascade, 작성자 계정 삭제 cascade.

### HTTP/unit/contract

- Bearer 누락/오류, method, content type, malformed JSON, additional property, invalid UUID/key, body size의 400/401/405/413/415 mapping.
- create 202와 queued `MimicResult` exact fixture; replay 202, hash 충돌 409, rate limit 429.
- get의 다섯 status exact fixture, partial succeeded, no_match CTA 의미, failed safe error.
- source private/delete가 create/get 모두 동일 404이고 job/post 존재 oracle이 없음.
- worker input에는 짧은 signed URL과 safe media metadata만 있고 raw key, Supabase credential, 사용자 JWT가 없음. URL/object key가 로그·DB result에 없음.
- callback raw-byte HMAC, missing secret 503, invalid/stale signature 401, endpoint/job mismatch, replay/conflict/stale lease, payload size/schema 검증.
- Storage signing 실패와 worker dispatch 실패는 안전한 retry/503이며 queued job을 중복 생성하지 않음.
- callback 뒤 삭제 garment projection, saved outfit 자동 생성 없음, 별도 G6 create 요청에서 재검증.
- OpenAPI response validator로 `additionalProperties:false`, nullable fields, similarity `[-1,1]`, coverage `[0,1]` 확인.

### 전체 gate

구현 종료 시 `npm test`, `npm run test:schema`, `npm run coverage:contract`, `npm run seed:validate`, `npm run smoke:preview`, `git diff --check`를 실행한다. G1~G7 회귀, 특히 G4 callback과 G7 feed-private Storage policy/visibility, G6 saved-outfit 소유권 테스트를 함께 통과해야 한다.

## 9. 오류와 fallback

| 상황 | 외부 결과 |
|---|---|
| 인증 없음/잘못된 JWT | 401 |
| malformed body/path/key | 400 |
| 타인 job, 없는/만료 job, private/deleted source | 404 |
| idempotency hash 충돌, stale worker lease/event 충돌 | 409 |
| 유효하지만 허용 범위 밖 입력/callback schema | public 422 / internal callback 422 |
| 사용자 open-job 제한 | 429 |
| Storage signing, DB, worker integration 미설정 | 503 또는 안전한 queued retry; raw 원인 비노출 |
| partial match | 200/202 `succeeded`, null candidate 포함, coverage < 1 가능 |
| 전부 미매칭 | `no_match`, 등록 CTA를 위한 빈/nullable matches |
| attempt 소진·모델 실패 | `failed`, allowlist error만 노출 |

가짜 template 결과, 임의 garment fallback, stale raw result, public media URL 전환은 사용하지 않는다. 모델이 없거나 연동되지 않았으면 job을 성공으로 꾸미지 않고 `failed` 또는 명시적 integration unavailable로 처리한다.

## 10. hosted 미검증과 사용자 Supabase 설정

로컬 구현 후에도 다음은 hosted에서 별도 확인해야 한다.

- 실제 `feed-private` signed read URL의 TTL, Range/download, private bucket RLS와 public/private 전환 직후 신규 sign 차단.
- 실제 worker의 네트워크 접근, timeout/retry, 동시 claim, lease 만료와 callback race.
- raw-body HMAC secret 주입, 서버 clock 동기화, replay window, request body 보존.
- 모델 input/output schema, 모델 버전, source item 분해 안정성, similarity scale, 정확도·지연·비용·유해 출력.
- terminal TTL cleanup과 post/account cascade 뒤 Storage/worker 잔여 데이터 삭제.
- 두 사용자로 public→private/delete, cross-owner garment, 결과 폴링 E2E.

사용자가 해야 할 Supabase/hosting 설정은 구현 완료 후 다음으로 제한한다.

1. G7 다음 순서의 G8 additive migration을 hosted 프로젝트에 적용한다.
2. `feed-private` bucket을 계속 private로 유지한다. public 전환, broad SELECT/INSERT, worker용 광역 policy를 추가하지 않는다.
3. 서버/worker secret store에 `MIMIC_WORKER_HMAC_SECRET`을 생성·주입하고 rotation 절차를 둔다. 브라우저 환경변수나 DB row에 넣지 않는다.
4. 배포된 BFF가 worker private endpoint에 outbound HTTPS를 할 수 있게 하고, worker callback은 BFF 내부 callback 주소만 사용한다. 외부 worker에 service-role key를 주지 않는다.
5. cleanup/reaper scheduler를 연결해 expired running job 재처리와 terminal TTL cleanup을 수행한다. scheduler가 없으면 DB 상태는 안전하지만 row/result 물리 정리는 미완료로 기록한다.
6. test user A/B로 public post 생성→mimic→private 전환→404, cross-owner 후보 차단, no_match/failed, callback replay를 확인한다.

이 계획 단계에서는 원격 DB, 배포, bucket policy, secret, worker를 변경하지 않는다.

## 11. 구현 순서와 중단 조건

1. G7 최종 migration/API와 OpenAPI fixture를 읽기 전용 재검토해 public visibility와 media projection을 동결한다.
2. callback schema와 TTL/open-job 정책을 AI·제품 계약으로 확정한다. 불확정 필드를 임의 모델 출력에 맞추지 않는다.
3. additive G8 migration과 SQL assertion으로 RLS/idempotency/queue/callback/projection을 먼저 고정한다.
4. service-only claim/input gateway와 raw-body callback을 G4 패턴으로 구현한다.
5. create/get domain module과 handler를 구현하고 strict fixture를 추가한다.
6. G6 saved-outfit handoff, G7 visibility race, G4 callback 회귀를 통합 테스트한다.
7. OpenAPI implementation status, API/DB/AI 설계, coverage registry, manifest, 결과 worklog를 동기화하고 전체 gate를 실행한다.

다음 중 하나라도 남으면 G8을 완료 처리하지 않는다.

- private/deleted post 또는 타인 job이 create/get/claim 중 하나에서 보임.
- raw feed key, signed input URL, raw model result, 타인·삭제 garment ID가 응답/로그에 노출됨.
- callback replay가 lease 검사 뒤에 있어 정상 재전송이 실패함.
- idempotency가 job 생성과 원자적이지 않거나 다른 body를 재생함.
- worker/callback 없이 mock 결과만으로 succeeded를 만듦.
- 결과 조회가 garment 소유권·활성 상태를 재검증하지 않음.
- direct table 권한 또는 broad Storage policy가 필요함.
- G1~G7 회귀, schema/contract/seed/preview/diff gate 중 하나가 실패함.
