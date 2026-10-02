# G6 보관 코디·OOTD·옷장 통계 결과

상태: 로컬 구현·검토·검증 완료  
범위: 보관 코디 5개, OOTD 5개, 옷장 통계 1개 — 누적 `implemented-local` 36/50

## Situation

G5 추천 채택이 만든 OOTD와 수동·보관 코디 경로를 하나의 소유권·스냅샷 규칙으로 연결해야 했다. 기존 변경과 G5 멱등 replay를 보존하면서 보관 코디 편집이 과거 OOTD를 바꾸지 않도록 해야 했고, 원격 Supabase·배포·비밀값은 작업 범위에서 제외했다.

## Task

- 보관 코디 CRUD, OOTD CRUD, 실제 착용 기준 통계 11개 operation을 구현한다.
- user JWT/RLS 조회와 authenticated narrow RPC 쓰기를 분리한다.
- source 구성 일치, optimistic version, 날짜 충돌, 생성·삭제 멱등성, 현재 unavailable overlay를 보장한다.
- G5 추천 수락 replay, G7 feed 참조, Storage asset 상태와 충돌하지 않도록 한다.

## Action

- `202610010003_outfits_ootd.sql`에 보관 코디·OOTD·통계 RPC와 exact execute 권한을 추가했다.
- OOTD snapshot은 입력 순서와 당시 category를 보존하고, 조회 시 현재 garment와 verified cutout 상태로 `unavailable`만 다시 계산한다.
- 날짜 변경은 old/new 날짜 advisory lock을 정렬 획득한 뒤 행과 version을 재확인하도록 해 교차 변경 deadlock을 피했다.
- 보관 코디 삭제는 과거 OOTD의 source ID만 분리하고 snapshot은 유지한다. feed 참조 OOTD와 G5 accept replay 대상 OOTD는 변경·삭제를 차단한다.
- 삭제된 resource의 create idempotency tombstone을 정리해 과거 ID replay로 HTTP 500이 되는 경계를 제거했다.
- cursor endpoint/filter binding, 실제 달력 timestamp 검증, strict body/path/query allowlist, bodyless 204를 구현했다.
- 단위 테스트와 SQL assertions에서 cross-owner, version, idempotency, 날짜, source exact set, snapshot 불변, worn-only 통계, malformed legacy snapshot, 권한을 검증했다.

## Result

- `node --test test/outfits.test.mjs`: 6/6 통과.
- `npm run test:schema`: migration 10개와 SQL assertion 9개 전체 통과.
- `npm run coverage:contract`: 36/50 registry와 OpenAPI 상태 일치, valid=true.
- 원격 DB·배포·비밀값은 변경하지 않았다. hosted Auth/Storage/RLS 동시성 검증은 사용자 환경에서 수행할 항목으로 남겼다.

## 검토에서 수정한 release blocker

- OOTD 날짜 교차 변경 잠금 순서와 feed 생성/삭제 race.
- G5 추천 수락 OOTD 변경·삭제 후 replay 응답 변질.
- 삭제 후 create key replay의 dangling ID.
- soft-delete뿐 아니라 cutout 미검증·삭제를 포함한 unavailable 판정.
- 잘못된 달력 timestamp cursor의 400/503 오분류와 G6 오류 DTO 문구.
