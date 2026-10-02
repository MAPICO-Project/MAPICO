# G5~G7 병렬 작업 카드

공통 금지: 원격 DB·배포·비밀값 변경/출력, 기존 migration 수정, commit/reset/clean, 하위 agent 위임.

## P1 — G5 DB 경계

ID: P1-G5-DB  
목적: 날씨 snapshot·추천 원자 저장·추천 채택 RPC와 SQL assertion을 additive migration으로 구현한다.  
입력: G5 계획, 현행 OpenAPI/DB, G4 완료 기준선.  
소유 파일: `backend/supabase/migrations/202610010002_recommendations.sql`, `backend/supabase/tests/recommendations.sql`.  
금지: 그 외 파일, 원격 작업.  
완료 기준: schema/SQL 통과와 hand-off.  
상태: done

## P2 — G5 읽기 전용 검토

ID: P2-G5-REVIEW  
목적: cache·service-only 저장·deterministic engine·채택 transaction·idempotency 위험을 검토한다.  
입력: G5 계획, OpenAPI, 현재 migration/runtime.  
소유 파일: 없음.  
금지: 모든 파일 수정, 웹, 원격 작업.  
완료 기준: release-blocker와 구현 권고 hand-off.  
상태: done

## P3 — G6 상세 계획

ID: P3-G6-PLAN  
목적: 보관함·OOTD·통계 11개 operation의 구현 가능한 bounded plan을 작성한다.  
입력: master plan, OpenAPI, PRD/API/DB 설계, 현재 migrations.  
소유 파일: `worklogs/2026-10-01_G6_OUTFIT_OOTD_PLAN.md`.  
금지: 그 외 파일, 코드 구현, 원격 작업.  
완료 기준: 한국어 상세 계획과 위험·테스트·사용자 후속 설정 hand-off.  
상태: done

## Root — G5 HTTP·provider·engine

ID: ROOT-G5-HTTP  
목적: weather resolver, deterministic recommendation, safe projection, 4개 handler·unit fixture를 구현하고 P1/P2를 통합한다.  
소유 파일: `backend/api/**`, `backend/lib/**`, `backend/test/**` 중 G5 신규·공통 최소 변경.  
금지: P1/P3 소유 파일, 병렬 회수 전 공용 계약 문서, 원격 작업.  
완료 기준: G5 전체 gate와 25/50 계약·기록 동기화.  
상태: done
