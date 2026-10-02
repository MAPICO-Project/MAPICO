# 마피코 DB 설계 v0.2 — 이전 범위

> 2026-09-28: 최신 PRD의 수동 코디·보관함·소셜 요구는 미반영입니다. M0.5는 이전 축소 설계안이지 팀 확정 범위가 아닙니다. `PRD_DELTA_2026-09-28.md` 검토 및 증분 설계 후 원격 적용하세요.

상태: 2026-09-27 구현 초안. 신규 Supabase용 SQL 제공, 원격 적용 전. 범위는 M0.5이며 실제 소셜 게시/댓글/스크랩과 벡터 검색 DB는 후속입니다.

## 테이블과 소유권

| 영역 | 테이블 | 핵심 관계 |
|---|---|---|
| 인증/취향 | profiles, aesthetics, user_aesthetic_preferences, tpo_presets | auth.users 1:1 profiles; 추구미 다대다 |
| 이미지 | garment_batches, garment_assets | 사용자별 배치 1:N 원본/누끼; 원본 1장 |
| 분석 | analysis_jobs, garment_drafts | 배치당 Job 1개, attempt 증가; Job당 최대 6 draft |
| 옷장 | garments, garment_aesthetic_scores | draft당 garment 1개; 예측과 수정값 별도 보존 |
| 추천 | weather_snapshots, recommendation_requests, outfit_recommendations, outfit_items | 요청당 최대 3순위 코디, 코디별 옷 연결 |
| 기록 | ootd_entries | 사용자/날짜당 1착장, 당시 속성 snapshot |
| 중복 방지 | idempotency_keys | 사용자/명령 범위/키 유일 |

모든 사용자 간 참조는 `(user_id, id)` 복합 FK로 소유자를 묶습니다. draft의 job은 `(user_id,batch_id,job_id)`로 동일 배치까지 검증합니다. 누끼 자산과 배치 일치, verified 상태는 완료 RPC에서 검증합니다.

회원 가입 시 trigger로 profile을 생성합니다. 기본 시간대는 Asia/Seoul. 추구미 5개의 이름은 제공되지 않았으므로 임의 seed를 넣지 않았습니다. TPO 5개 코드는 제안 기준이며 nullable 선택입니다. 선호 1~3개, 가중치 합/정규화는 BFF 계약 검증 대상입니다.

## 쓰기와 RLS

브라우저는 자기 데이터 SELECT만 가능합니다. 분석 Job의 lease_token/result는 SELECT 권한에서 제외합니다. 삭제된 옷은 RLS 조회에서도 제외합니다. 모든 직접 INSERT/UPDATE/DELETE는 금지하고, BFF가 검증한 JWT의 사용자 ID로 서버 쓰기를 수행합니다. service_role은 RLS를 우회하므로 **매 조회/수정 조건에 검증한 사용자 ID가 필수**입니다. 요청 body의 user_id를 사용하지 않습니다.

`confirm_garment_batch`, `accept_outfit`은 사용자 JWT로 호출하는 좁은 SECURITY DEFINER RPC입니다. auth.uid 확인과 소유권 확인을 함수 안에서 수행하고 search_path를 비웁니다. Job claim/finish는 신뢰하는 BFF/dispatcher의 service_role만 실행합니다. 외부 GPU Worker에 DB 키를 전달하지 않습니다. 카탈로그만 익명 읽기를 허용합니다. idempotency_keys와 weather_snapshots는 서버 전용입니다.

## 트랜잭션과 상태

- 등록: awaiting_upload → uploaded → processing → review → confirmed. 실패는 failed.
- Job: queued → running → succeeded/partial_failed/failed. dispatcher가 claim할 때 attempt 증가, lease token 신규 발급. 만료된 작업은 SKIP LOCKED로 재획득하며 최대 시도 초과 시 failed. 수동 재큐잉은 failed에 한정하고 partial_failed는 종료 상태로 유지합니다.
- 완료: token/attempt/기한 확인과 draft 생성 및 상태 반영을 하나의 트랜잭션으로 수행. 동일 완료 재전송은 payload가 같을 때만 성공 처리.
- 확정: 배치 잠금, 최대 6개 선택/버전 검증, 원본 예측+수정값 병합, 옷 생성, 나머지 draft rejected를 한 번에 처리. 동일 선택 재호출은 기존 옷 반환. 다른 선택은 conflict.
- 채택: 사용자/날짜 잠금, ready 요청과 날짜·소유권·삭제 상태 검증, OOTD 생성. 동일 선택은 재사용, 다른 코디는 conflict. 속성 snapshot은 이후 옷 수정에도 유지.

하루 1착장 정책은 구현용 제안입니다. 복수 착장이 필요하면 시간/슬롯 키와 API를 함께 바꿉니다. 현재 수동 garment 생성은 없으며 단일 촬영도 분석 배치를 거칩니다. OOTD는 추천 채택에서 생성하고 임의 수동 코디 저장은 후속입니다.

## API/DB 경계와 남은 구현

BFF는 파일 실제 검증, 배치+자산 생성, job enqueue와 batch 상태 변경의 원자성, draft patch version compare-and-swap, 추구미 선호 교체, 날씨 API, 추천 생성 트랜잭션, 삭제 및 Storage cleanup을 구현해야 합니다. DB 함수가 모든 API를 구현한 상태는 아닙니다.

멱등 키는 같은 트랜잭션에서 `(user_id,scope,key)` INSERT 충돌 후 request_hash를 비교해야 합니다. 같은 키/다른 body는 409, 처리 중은 409 또는 재시도 응답, 완료 응답 재전송으로 정의합니다. 현재 테이블과 confirm/accept 자체 멱등성은 구현했고 범용 BFF middleware는 후속입니다.

날씨는 `issued_at`(발표시각), `valid_at`(예보 유효시각), `fetched_at`을 분리합니다. 정밀 GPS는 저장하지 않고 격자만 저장합니다. 추천 요청은 날씨 snapshot 및 취향 snapshot/엔진 버전을 보존합니다. 추구미 점수는 모델 버전과 함께 저장하며 0~1을 확률로 표현하지 않습니다.

이미지 경로는 `{user_uuid}/{batch_uuid}/{asset_uuid}.{ext}` 규약입니다. private bucket 20MiB 한도, 이미지 URL은 저장하지 않고 짧은 만료 signed URL을 API에서 발급합니다. 계정 삭제/옷 삭제 시 Storage 객체는 SQL cascade로 삭제되지 않으므로 서버 cleanup 작업이 별도로 필요합니다. 현재 물리 삭제 자동화는 미구현입니다.

검증 SQL은 `supabase/tests/security.sql`. Supabase 원격 연결과 실제 Auth/Storage 통합 검증은 연결 후 수행합니다.
