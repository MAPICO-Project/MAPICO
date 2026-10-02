# A0-3·A0-7 쓰기 RPC·개발 seed 계획

기준일: 2026-09-29  
상태: done  
목표: 원격 변경 없이 계정·온보딩 쓰기의 최소 권한 RPC와 재현 가능한 fixture seed 계약을 로컬 구현·검증한다.

## 범위 결정

- 구현: 프로필 표시명/시간대 변경, 추구미 선호 1~3개 원자 교체, 온보딩 분기·튜토리얼·완료 상태 저장을 위한 migration과 RLS/RPC 테스트.
- 구현: 최종 taxonomy 미확정 상태를 오염시키지 않는 fixture 전용 seed manifest와 validator/dry-run.
- 보류: `avatar_asset_id`는 업로드·소유권·삭제 수명주기 계약 전에는 저장하지 않는다.
- 보류: OpenAPI operation의 `implemented-local` 전환과 HTTP handler 구현은 G1에서 수행한다.
- 금지: 원격 DB 적용, Vercel 배포, 비밀값 조회/출력, 실제 taxonomy라고 오인될 seed 삽입.

## 작업 순서

1. 현재 계약·스키마·테스트 기준선 확인.
2. Opus가 RPC signature, 권한, 원자성, 미결 정책 경계를 읽기 전용 검토.
3. Astra가 새 additive migration, SQL 회귀테스트, seed manifest/validator를 단일 작성자로 구현.
4. 전체 unit/schema/coverage/seed dry-run 검증.
5. Sonnet이 diff를 읽기 전용으로 최종 리뷰.
6. Astra가 지적사항을 반영하고 문서·결과·인계 기록 후 종료.

## 작업 카드

### A0-WRITE-OPUS

ID: `A0-WRITE-OPUS`  
목적: account/onboarding narrow RPC와 fixture seed 경계 설계 검토  
입력/참조: OpenAPI 관련 3개 write operation, profile/aesthetic/onboarding schema, 기존 migration/RLS/test  
출력/완료 기준: MUST 설계, 검증 규칙, 보류 범위  
소유 파일: 없음, 읽기 전용  
금지 파일·범위: 수정, 네트워크, 비밀값, 원격 DB  
선행조건: 기준선 확인  
상태: blocked — Claude CLI session limit가 2026-09-30 00:00 Asia/Seoul까지 적용되어 API 429로 종료  
모델 실제 ID: 결과 metadata 없음(`modelUsage={}`, `is_error=true`, `api_error_status=429`)  
비용 관측: USD 0, session `e5bbb4ce-c697-4cb0-81f8-ed1daa5eb68f`

### A0-WRITE-SQL

ID: `A0-WRITE-SQL`  
목적: additive profile fields와 세 narrow RPC, 권한·원자성 회귀테스트 구현  
입력/참조: Opus 결과, 기존 3 migrations와 security test  
출력/완료 기준: embedded PostgreSQL에서 본인만 변경, 타인 차단, 잘못된 입력 rollback, direct table write 차단  
소유 파일: 신규 migration, `supabase/tests/security.sql`, schema validator 관련 파일  
금지 파일·범위: 기존 migration 수정, service-role 의존, 원격 적용  
선행조건: `A0-WRITE-OPUS`  
상태: done  
모델 실제 ID: Astra 통합 작성  
비용 관측: 미측정

### A0-SEED

ID: `A0-SEED`  
목적: taxonomy/test profile/허용 이미지 metadata의 fixture 전용 재현 계약 제공  
입력/참조: taxonomy 5개 확정·명칭 미정 결정, 개인정보·이미지 사용 경계  
출력/완료 기준: manifest와 validator가 fixture 표시, 5개 항목, weight 합, 이미지 허용근거, 비밀값 부재를 검사; 기본 실행은 dry-run  
소유 파일: `fixtures/dev-seed.fixture.json`, `scripts/validate-dev-seed.mjs`, package/README  
금지 파일·범위: SQL 자동 적용, 실제 사용자 자격증명, 최종 taxonomy 주장  
선행조건: 없음  
상태: done  
모델 실제 ID: Astra 통합 작성  
비용 관측: 미측정

### A0-WRITE-SONNET

ID: `A0-WRITE-SONNET`  
목적: SQL 권한·원자성, seed 안전성, 문서 정합성 최종 검토  
입력/참조: 이번 변경 diff와 검증 결과  
출력/완료 기준: severity별 finding과 MUST-fix 여부  
소유 파일: 없음, 읽기 전용  
금지 파일·범위: 수정, 네트워크, 비밀값, 원격 DB  
선행조건: 구현·1차 검증 완료  
상태: blocked — 같은 Claude session limit 때문에 중복 실패 호출을 하지 않음  
모델 실제 ID: 미실행  
비용 관측: USD 0

### A0-WRITE-AUDIT

ID: `A0-WRITE-AUDIT`  
목적: Claude 한도 시 읽기 전용 설계·최종 diff 대체 감사  
입력/참조: 계약·migration·SQL tests·seed validator·정본 문서  
출력/완료 기준: MUST/SHOULD 설계 및 severity별 최종 finding  
소유 파일: 없음, 읽기 전용  
금지 파일·범위: 수정, 네트워크, 비밀값, 원격 DB  
선행조건: 없음  
상태: done  
모델 실제 ID: 내장 `legacy_audit` 작업자 Jason, 실제 모델 ID 미노출  
비용 관측: 미측정

## 완료 게이트

- `npm test`, `npm run test:schema`, `npm run coverage:contract` 통과.
- 새 migration은 기존 3개 뒤에만 추가되고 기존 migration을 수정하지 않는다.
- authenticated 사용자는 RPC로 자기 데이터만 변경하고 직접 table write는 계속 거절된다.
- 선호 교체는 1~3개·중복 없음·활성 항목·weight 합 허용오차를 원자적으로 검증한다.
- seed validator는 네트워크·DB를 사용하지 않고 실제 taxonomy/사용자/AI 결과로 오인될 자료를 거절한다.
- hosted Supabase 미검증과 사용자 다음 작업을 결과 보고에 분리한다.

## 종료 확인

- additive migration 1개와 `account_writes.sql`을 추가하고 기존 migration은 수정하지 않았다.
- seed manifest는 DB·네트워크·SQL을 사용하지 않는 metadata-only fixture로 고정했다.
- 최종 감사의 HIGH/MUST finding은 없었고, void RPC 재조회 계약·avatar 422·변형 path/url 차단을 반영했다.
- 실제 검증 결과와 Claude 한도는 [A0 쓰기 RPC·seed 결과](2026-09-29_A0_WRITE_SEED_RESULT.md)에 기록한다.
