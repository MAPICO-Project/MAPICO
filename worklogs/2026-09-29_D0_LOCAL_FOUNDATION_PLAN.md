# D0 로컬 기반 구현 계획

기준일: 2026-09-29  
목표: 원격 계정·비밀값·배포를 변경하지 않고, Preview 배포 직전까지 필요한 공통 HTTP/Auth/CORS 기반과 검증 도구를 완성한다.
상태: 완료

## 범위와 순서

1. 기존 20개 테스트와 계약을 기준선으로 고정한다.
2. Opus가 공통 HTTP/Auth/CORS 경계와 파일 분리안을 읽기 전용 검토한다.
3. Astra가 단일 작성자로 공통 모듈과 `getMe` 리팩터링을 구현한다.
4. 독립 산출물인 smoke script, 계약 fixture, coverage report를 구현한다.
5. Sonnet이 변경 diff를 읽기 전용으로 리뷰한다.
6. Astra가 지적사항을 반영하고 전체 테스트·schema·coverage·smoke dry-run을 검증한다.
7. 결과 보고와 세션 인계를 갱신한 뒤 사용자 원격 작업만 분리해 전달한다.

## 작업 카드

### D0-OPUS-DESIGN

ID: `D0-OPUS-DESIGN`  
목적: 최소 공통 계층의 보안·계약·테스트 누락 검토  
입력/참조: `backend/lib`, `backend/api/v1/me.js`, 관련 테스트, OpenAPI  
출력/완료 기준: 구현 전 필수 수정과 보류 항목을 우선순위로 반환  
소유 파일: 없음, 읽기 전용  
금지 파일·범위: 파일 수정, 원격 호출, 비밀값 조회  
선행조건: 현재 테스트 기준선 확인  
상태: done  
모델 실제 ID: `claude-opus-5-5` (`provider=firstParty`, `is_error=false`)  
비용 관측: list 기준 USD 1.0166888, session `901fc388-b9b9-4842-b980-51d4a6126f4b`

### D0-COMMON

ID: `D0-COMMON`  
목적: request-id·오류 envelope·method·CORS·사용자 JWT/RLS upstream client를 재사용 가능한 계층으로 분리  
입력/참조: Opus 검토, 기존 `profile.js` 동작과 OpenAPI  
출력/완료 기준: 기존 동작 유지, preflight·origin·인증·upstream mapping 테스트 추가  
소유 파일: `backend/lib/*`, `backend/api/v1/me.js`, 관련 신규/기존 테스트  
금지 파일·범위: migration, 원격 환경, 서비스 역할키 사용  
선행조건: `D0-OPUS-DESIGN`  
상태: done  
모델 실제 ID: Astra 통합 작성  
비용 관측: 미측정

### D0-TOOLS

ID: `D0-TOOLS`  
목적: Preview smoke, FE·AI 계약 fixture, 50 operation·22 table coverage 자동검사 제공  
입력/참조: OpenAPI, ERD/DB 설계, 현재 endpoint  
출력/완료 기준: 비밀값 없는 dry-run과 단일 coverage 명령, fixture 검증  
소유 파일: `backend/scripts/*`, `backend/fixtures/*`, `backend/package.json`, 도구 테스트  
금지 파일·범위: 원격 GET 실행, 실제 추론 표방, 원격 DB 변경  
선행조건: 계약 정본 유지  
상태: done  
모델 실제 ID: Astra 통합 작성  
비용 관측: 미측정

### D0-SONNET-REVIEW

ID: `D0-SONNET-REVIEW`  
목적: 구현 diff의 보안·정확성·회귀 가능성 최종 검토  
입력/참조: D0 변경 파일과 테스트 결과  
출력/완료 기준: 수정 필수 항목과 근거 반환  
소유 파일: 없음, 읽기 전용  
금지 파일·범위: 파일 수정, 원격 호출, 비밀값 조회  
선행조건: `D0-COMMON`, `D0-TOOLS`  
상태: done  
모델 실제 ID: `claude-sonnet-5` (`provider=firstParty`, `is_error=false`)  
비용 관측: list 기준 USD 1.2195404, session `a1a3274b-1328-402d-8235-a263424aa9c5`

## 완료 게이트

- `npm test` 전체 통과.
- `npm run test:schema` 통과.
- coverage 명령이 OpenAPI 50개·ERD 22개와 구현 상태를 재현 가능하게 보고.
- smoke 명령은 URL·토큰을 출력하지 않고, 원격 호출 없는 dry-run을 지원.
- fixture는 OpenAPI에 맞고 `fixture-*` 출처로 실제 추론과 구분.
- 비밀값·`.env`·`.vercel` 출력 및 원격 변경 없음.

## 종료 확인

- 로컬 테스트 29/29, schema/embedded PostgreSQL, coverage 50 operation·22 table, smoke dry-run, `git diff --check`를 통과했다.
- Sonnet 리뷰의 RLS 증거 과장과 405 CORS 일관성 지적을 반영했다.
- 결과와 hosted 미검증 경계는 [D0 로컬 기반 구현 결과](2026-09-29_D0_LOCAL_FOUNDATION_RESULT.md)에 기록했다.
