# 프로필 조회 API 첫 수직 슬라이스 계획

## 목표와 범위

계획된 50개 operation 전체를 한 번에 구현하지 않고 `GET /api/v1/me` 하나로 인증·RLS·응답 투영·오류 경계를 먼저 검증한다. `PATCH/DELETE /me`, Storage, 원격 Supabase 적용·배포는 이번 범위가 아니다.

## 완료 기준

1. Authorization bearer가 없거나 형식이 잘못되면 외부 호출 전에 401을 반환한다.
2. Supabase Auth `/auth/v1/user`로 토큰을 검증하고, 확인된 사용자 ID와 동일한 프로필만 조회한다.
3. 사용자 JWT를 REST 요청에 전달해 기존 RLS를 유지하고 service-role 키를 요구하지 않는다.
4. `Profile` 계약의 허용 필드만 반환하며 토큰·내부 오류·불필요 DB 열을 노출하지 않는다.
5. GET/HEAD만 제공하고 아직 미구현인 PATCH/DELETE는 구현 완료로 표시하지 않는다.
6. 단위 테스트, OpenAPI/SQL 스키마 테스트, 문서 export 해시 검증이 모두 통과한다.
7. hosted Supabase Auth/Storage 미검증 상태와 원격 작업 미수행을 결과 보고서에 명시한다.

## 작업 카드

### OPUS-AUTH-DESIGN

ID: OPUS-AUTH-DESIGN  
목적: OpenAPI·SQL RLS·현재 런타임을 대조해 `GET /me`의 최소 안전 구현과 오류 매핑을 판정한다.  
입력/참조: `AGENTS.md`, 운영규칙, 본 계획, OpenAPI의 `/me`·Profile·오류 계약, core migration, 현재 `lib/`와 테스트.  
출력/완료 기준: 요청 흐름, 실패 상태, 보안 불변조건, 문서 변경 범위를 읽기 전용으로 보고한다.  
소유 파일: 없음.  
금지 파일·범위: 파일 수정, 원격 요청, 배포, 비밀값 접근, 하위 에이전트 실행.  
선행조건: 계획 카드 작성.  
상태: done  
모델 실제 ID: `claude-opus-5-5` (`provider=firstParty`, `is_error=false`)  
비용 관측: USD 1.317749 (`costBasis=list`; 실제 청구액 확정 아님)

### SONNET-PROFILE-IMPLEMENTATION

ID: SONNET-PROFILE-IMPLEMENTATION  
목적: 승인된 설계에 따라 `GET/HEAD /api/v1/me`의 인증·프로필 조회 코드와 단위 테스트에 적용할 정확한 패치를 작성한다.  
입력/참조: OPUS-AUTH-DESIGN 결과, OpenAPI 계약, 현재 backend 코드와 테스트 관례.  
출력/완료 기준: 완전한 파일 내용 또는 적용 가능한 unified diff와 로컬 mock 테스트 설계를 읽기 전용 hand-off로 남긴다. 실제 적용·실행은 Astra가 검증한다.  
소유 파일: 없음(읽기 전용 패치 제안). 실제 코드 파일의 단일 작성자는 Astra다.  
금지 파일·범위: 모든 파일 수정, 명령 실행, deliverables·OpenAPI·worklogs, SQL/migration, 기존 진단 handler, 원격 요청·배포·환경 설정, 비밀값 읽기, 하위 에이전트 실행.  
선행조건: OPUS-AUTH-DESIGN 회수.  
상태: done  
모델 실제 ID: `claude-sonnet-5` (`provider=firstParty`; 최종 리뷰 `is_error=false`)  
비용 관측: 최종 성공 리뷰 USD 0.0992122 (`costBasis=list`; 실제 청구액 확정 아님). 앞선 1회 리뷰는 USD 0.6556124에서 예산 상한으로 결과 없이 종료했고, 장기 실행된 패치 초안 호출은 수동 중단하여 비용 미측정.

### ASTRA-PROFILE-INTEGRATION

ID: ASTRA-PROFILE-INTEGRATION  
목적: 코드 hand-off를 검토하고 OpenAPI 구현 상태·설계/README·export·작업 로그를 동기화한 뒤 전체 로컬 검증한다.  
입력/참조: Opus 판정, Sonnet 변경과 테스트 결과.  
출력/완료 기준: diff 검토, 정본/사본 일치, 전체 테스트 통과, 결과 보고서와 세션 인계 갱신.  
소유 파일: `deliverables/backend/openapi.yaml`, `deliverables/backend/API_DESIGN.md`, `backend/README.md`, 대응 export 사본/manifest, 본 계획·결과·인계 문서.  
금지 파일·범위: SQL/migration, 원격 Supabase·Vercel·GitHub, 비밀값 출력.  
선행조건: 앞 두 카드 완료.  
상태: done  
모델 실제 ID: gpt-6-astra  
비용 관측: 미측정

## 실행 순서

1. Opus 읽기 전용 설계 검토.
2. Astra가 판정과 범위를 고정하고 Sonnet에 코드·테스트 파일만 위임.
3. Astra가 diff·테스트를 독립 검증하고 문서 정본을 갱신.
4. export 동기화, 해시·전체 테스트 확인, 결과 보고와 인계 후 파일 소유권 해제.

## 종료

- 세 카드 모두 완료했다. 실제 파일 작성은 Astra가 `apply_patch`로만 수행했다.
- Opus는 인증·RLS·오류 경계를 판정했고, Sonnet 최종 사후 리뷰는 수정 필수 결함 없음으로 종료했다.
- Sonnet의 긴 패치 초안 호출은 출력 없이 장기화되어 중단했고, 첫 사후 리뷰는 예산 상한으로 결과가 없었다. 두 실행 모두 읽기 전용이어서 작업공간 변경은 없었다.
- `npm test` 20/20, `npm run test:schema`, 정본/사본·manifest 해시 검증을 통과했다.
- 파일 소유권을 모두 해제한다.
