# G8 따라입기 결과

상태: 로컬 구현·검토·검증 완료
범위: `createMimicJob`, `getMimicJob` 2개 operation — 누적 `implemented-local` 49/50

## Situation

G7의 공개 게시물 이미지를 본인 옷장과 비동기로 매칭하되, private 전환·삭제 뒤 결과 재노출, 타인 의류 ID 주입, stale worker callback과 raw AI 결과 노출을 막아야 했다. 외부 AI worker가 아직 hosted에 연결되지 않은 상태에서도 durable queue와 callback 경계는 실제 계약대로 검증 가능해야 했다.

## Task

- 현재 public·미삭제 G7 post만 따라입기 job으로 생성하고 요청자만 결과를 폴링하게 한다.
- source media와 본인 active garment 후보를 생성 시점 snapshot으로 고정한다.
- user/post open job 재사용, 사용자 open cap 3, lease/attempt/callback replay, 2시간 deadline과 7일 terminal retention을 보장한다.
- raw 결과를 숨기고 현재 사용 가능한 본인 garment만 `MimicResult`에 투영한다.

## Action

- `202610010005_mimic.sql`에 source/candidate snapshot, durable queue, authenticated create/get RPC와 service-only claim/inspect/apply RPC를 추가하고 exact revoke/grant를 적용했다.
- source item을 verified `feed_media` 한 개당 `media:<media UUID>` 한 개로 고정했다. feed media와 Storage object identity를 snapshot하고 callback 전 post→media→candidate 순서로 fence를 다시 확인한다.
- 후보는 요청자의 active garment, verified cutout, garment version, asset·Storage object identity만 snapshot했다. callback match는 해당 snapshot 구성원만 허용해 cross-owner와 뒤늦은 후보 주입을 차단했다.
- 사용자 advisory lock, `(user_id,post_id)` open unique 경계, 사용자 전체 open cap 3으로 동시 create와 다른 idempotency key 중복 실행을 직렬화했다.
- queued/running absolute deadline은 2시간, terminal result retention은 완료 시점부터 7일로 분리했다. get과 claim 모두 만료 open job을 안전한 failed로 전이한다.
- G4 패턴대로 attempt·lease token과 callback event/payload hash를 검증하고 replay를 mutable lease 검사보다 먼저 판정했다. runtime callback은 기존 AI worker secret을 사용하되 HMAC 입력에 `mimic.v1` domain을 포함해 G4와 교차 replay되지 않게 했다.
- public visibility를 create, claim, callback, get에서 재검사했다. terminal 뒤 garment가 삭제·미검증되어 유효 후보가 모두 사라지면 raw 상태를 바꾸지 않고 외부 projection만 `no_match`로 내린다.
- `mimic_requests` authenticated direct SELECT를 완전히 회수했다. 결과 projection은 object key, signed worker input, lease, raw error/result를 반환하지 않는다. 내부 `media:<UUID>` source key는 `source-N`으로 바꾸고 worker reason도 서버 소유 안전 문구로 대체하며, 저장은 G6 `saved-outfits` 별도 호출로 남겼다.
- HTTP create/get, internal raw-body callback, SQL lifecycle assertion에서 ownership, visibility, no-match, candidate fence, deadline/retention, replay/conflict, cascade를 검증했다.

## Result

- 전체 `npm test`: 98/98 통과.
- 독립 `npm run test:schema`: `202610010005_mimic.sql`, `202610010006_weather_refresh_order.sql`, `mimic.sql`을 포함한 전체 schema gate 통과. 날씨 동률 보정 후 3회 연속 재실행도 통과했다.
- `npm run coverage:contract`: 49/50, valid=true. G8 두 operation은 `implemented-local`, G9 `requestAccountDeletion`만 planned다.
- `npm run seed:validate`, `npm run smoke:preview -- --dry-run`: 통과.
- 원격 DB·배포·비밀값은 변경하지 않았다.
- 실제 hosted Auth/PostgREST, private Storage signed input, 외부 AI worker 실행·정확도·지연·비용, hosted callback secret 주입과 동시 lease race는 미검증으로 남겼다.

## 검토에서 수정한 release blocker

- 임의 모델 item key 대신 verified feed media UUID 1:1 source 계약을 고정했다.
- callback 시점의 현재 옷장 조회만으로는 막을 수 없는 후보 교체 race를 immutable candidate snapshot과 garment/asset/object fence로 차단했다.
- idempotency key가 달라도 같은 user/post open job을 재사용하고 사용자별 open job을 3개로 제한했다.
- 실행 deadline과 terminal 보존기간을 분리하고 get/claim 양쪽에서 만료 전이를 수행했다.
- 결과 의류가 이후 모두 unavailable이면 stale garment ID를 노출하지 않고 외부 `no_match`로 투영했다.
- callback HMAC을 `mimic.v1`로 domain-separate하고 event replay를 stale lease보다 먼저 처리했다.
- worker가 reason에 내부 식별자를 되풀이해도 외부에 노출되지 않도록 source key와 설명을 모두 BFF에서 재투영했다.
- 기존 G5 weather refresh의 동일 clock tick 최신행 선택 flake를 별도 additive migration의 key lock·단조 `fetched_at`으로 제거했다.
