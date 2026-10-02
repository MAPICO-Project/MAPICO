# G6~G8 병렬 작업 카드

공통 금지: 원격 DB·배포·비밀값 변경/출력, 기존 migration 수정, commit/reset/clean, 하위 agent 위임.

## P1 — G6 DB 경계

ID: P1-G6-DB  
목적: 보관함·OOTD·통계 authenticated RPC와 SQL assertions를 additive migration으로 구현한다.  
입력: G6 계획, G5 완료 migration, OpenAPI/DB 설계.  
소유 파일: `backend/supabase/migrations/202610010003_outfits_ootd.sql`, `backend/supabase/tests/outfits_ootd.sql`.  
완료 기준: schema/SQL 통과, exact RPC hand-off.  
상태: active

## P2 — G6 읽기 전용 검토

ID: P2-G6-REVIEW  
목적: source provenance, snapshot 불변성, cursor/version/idempotency, 날짜 lock, feed 참조 삭제, 통계 경계를 검토한다.  
소유 파일: 없음.  
금지: 파일 수정·웹·원격 작업.  
완료 기준: release-blocker hand-off.  
상태: active

## P3 — G7 상세 계획

ID: P3-G7-PLAN  
목적: feed·media·like·내 게시물 11개 operation의 bounded plan을 작성한다.  
소유 파일: `worklogs/2026-10-01_G7_FEED_PLAN.md`.  
금지: 그 외 파일·코드·웹·원격 작업.  
완료 기준: 보안·Storage·privacy·pagination·테스트·hosted 후속 설정을 포함한 계획.  
상태: active

## Root — G6 HTTP·projection

ID: ROOT-G6-HTTP  
목적: 보관함/OOTD keyset read, strict write handler, snapshot unavailable overlay, 통계 projection과 unit fixture를 구현하고 P1/P2를 통합한다.  
소유 파일: `backend/api/**`, `backend/lib/**`, `backend/test/**` 중 G6 신규·공통 최소 변경.  
완료 기준: 11 operation 전체 gate와 누적 36/50 계약·기록 동기화.  
상태: active
