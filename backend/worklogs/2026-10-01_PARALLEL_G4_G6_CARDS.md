# G4~G6 병렬 작업 카드

## P1 — G4 DB 경계

ID: P1-G4-DB  
목적: G4 사용자 job/draft/confirm RPC와 service-only callback transaction을 additive migration으로 구현한다.  
입력/참조: G4 plan, OpenAPI G4 schema, 기존 core/transactions/ingestion migration.  
출력/완료 기준: migration 1개와 SQL assertion 1개, PGlite schema 통과, hand-off.  
소유 파일: `backend/supabase/migrations/202610010001_analysis.sql`, `backend/supabase/tests/analysis.sql`.  
금지 파일·범위: 그 외 모든 파일, 원격 DB, 배포, 비밀값, 기존 migration 수정.  
선행조건: G3 완료.  
상태: done  
모델 실제 ID: 협업 agent 실행 metadata 기준  
비용 관측: 미측정

## P2 — G4 보안 검토

ID: P2-G4-REVIEW  
목적: callback HMAC·service credential·lease/event idempotency·Storage TOCTOU·confirm 설계를 읽기 전용 검토한다.  
입력/참조: G4 plan, OpenAPI, 기존 transactions/ingestion SQL과 runtime 경계.  
출력/완료 기준: MUST/SHOULD findings와 안전한 구현 권고 hand-off.  
소유 파일: 없음.  
금지 파일·범위: 모든 파일 수정, web, 하위 agent, 원격 변경.  
선행조건: 없음.  
상태: done  
모델 실제 ID: 협업 agent 실행 metadata 기준  
비용 관측: 미측정

## P3 — G5 상세 계획

ID: P3-G5-PLAN  
목적: 날씨·추천 G5 4개 operation의 구현 가능한 상세 계획과 위험을 작성한다.  
입력/참조: master plan, OpenAPI, PRD/decisions/API/DB design, 현재 migrations.  
출력/완료 기준: 한국어 bounded plan 1개와 hand-off; 코드 구현 없음.  
소유 파일: `worklogs/2026-10-01_G5_RECOMMENDATION_PLAN.md`.  
금지 파일·범위: 소유 파일 외 수정, 원격 변경, 비밀값, 하위 agent.  
선행조건: G3 완료.  
상태: done  
모델 실제 ID: 협업 agent 실행 metadata 기준  
비용 관측: 미측정

## Root — G4 HTTP 경계

ID: ROOT-G4-HTTP  
목적: P1/P2와 충돌하지 않는 G4 사용자 DTO/handler 및 callback raw-body/HMAC/internal gateway를 구현한다.  
입력/참조: G4 plan, P2 hand-off, 현행 runtime.  
출력/완료 기준: runtime·unit fixture 구현; P1 병합 뒤 전체 검증.  
소유 파일: `backend/api/**`, `backend/lib/**`, `backend/test/**` 중 G4 신규·공통 최소 변경.  
금지 파일·범위: P1/P3 소유 파일, 공용 OpenAPI/coverage/docs는 병렬 회수 전 수정 금지, 원격 변경.  
선행조건: P2 주요 findings 회수 또는 자체 fail-closed 경계 확정.  
상태: done  
모델 실제 ID: gpt-5 계열 현재 root  
비용 관측: 미측정
