# 통합 로드맵·실행계획 작성 로그

## 목표

ERD 22테이블 전체를 엄격한 MVP 범위로 고정하고, 백엔드 조기 배포를 중심으로 FE·AI 병렬 테스트가 가능한 통합 로드맵, 다이어그램 시작자료, 사용자/에이전트 분리 실행계획을 만든다.

## 작업 카드

### ROADMAP-INTEGRATION

ID: ROADMAP-INTEGRATION  
목적: 최신 PRD·결정·API·DB·일정·구현 상태를 하나의 실행 로드맵으로 통합한다.  
입력/참조: PRD, MVP_AND_DATA_PLAN, API/DB/ERD, AI_ARCHITECTURE, 구현 상태, 사용자 체크리스트.  
출력/완료 기준: ERD 전체 coverage, 백엔드 조기 배포, 단계별 gate와 날짜, 병렬 트랙이 포함된 정본 로드맵.  
소유 파일: `deliverables/product/ROADMAP.md`.  
금지 파일·범위: 원격 DB·배포·계정 설정, 미결 정책의 임의 확정.  
상태: done  
모델 실제 ID: gpt-6-astra  
비용 관측: 미측정

### DIAGRAM-STARTER

ID: DIAGRAM-STARTER  
목적: 기존 Mermaid와 MCP 협업 도구를 연결하는 유저플로우·통합·배포 다이어그램 시작자료를 만든다.  
입력/참조: USER_FLOWS, ERD, AI_ARCHITECTURE, LobeHub 저장소, 연결 가능한 diagram plugin 검색 결과.  
출력/완료 기준: 로컬 Mermaid 정본, 보드 프레임, 도구 선택 근거, 변환 요청문, Mermaid 구문 검증.  
소유 파일: `deliverables/design/DIAGRAM_STARTER.md`, `scripts/validate_diagrams.mjs`.  
금지 파일·범위: 외부 plugin 임의 설치·연결, 보드 생성, 비밀값·사용자 데이터 전송.  
상태: done  
모델 실제 ID: gpt-6-astra  
비용 관측: 미측정

### EXECUTION-SPLIT

ID: EXECUTION-SPLIT  
목적: 사용자가 직접 해야 하는 계정·결정·원격 작업과 에이전트가 수행할 구현·검증을 순서와 의존성으로 분리한다.  
입력/참조: 통합 로드맵, DEPLOYMENT_LAB, 현재 구현 상태.  
출력/완료 기준: 지금/다음/후속 단계별 담당, 입력, 완료 증거, 차단 관계가 명시된 실행계획.  
소유 파일: `worklogs/2026-09-29_USER_AGENT_EXECUTION_PLAN.md`.  
금지 파일·범위: 사용자의 비용·공개·계정 결정을 대신 수행.  
상태: done  
모델 실제 ID: gpt-6-astra  
비용 관측: 미측정

### OPUS-ROADMAP-REVIEW

ID: OPUS-ROADMAP-REVIEW  
목적: 통합 로드맵이 사용자 결정, ERD 22테이블, OpenAPI 50 operation, 일정·배포 의존성과 사용자 경계를 빠뜨리지 않았는지 검토한다.  
입력/참조: `ROADMAP.md`, `DIAGRAM_STARTER.md`, 사용자·에이전트 실행계획, PRD, ERD, API/DB 설계, 구현 상태.  
출력/완료 기준: 치명적 누락·모순·비현실적 gate와 최소 수정안을 읽기 전용으로 보고한다.  
소유 파일: 없음.  
금지 파일·범위: 모든 파일 수정, 원격 조작, 비밀값 접근, 하위 에이전트 실행.  
상태: done  
모델 실제 ID: `claude-opus-5-5` (`provider=firstParty`, `is_error=false`)  
비용 관측: USD 0.6892226 (`costBasis=list`; 실제 청구액 확정 아님)

## 종료

- 사용자의 2026-09-29 결정을 PRD·결정 기록·MVP 계획에 최우선 상태로 반영했다.
- ERD 22테이블 coverage를 도메인별 MVP gate로 만들고, OpenAPI 50개 operation을 R0~R6에 누락·중복 없이 배정했다.
- 백엔드 조기 Preview의 D0 gate, 시험 주간 저용량 규칙, FE·AI consumer test, AI 평가·fallback·privacy gate를 반영했다.
- Miro는 연결 후보로 제안했지만 연결·설치·보드 생성은 하지 않았다. LobeHub는 다이어그램 형식이 아니라 MCP/에이전트 플랫폼으로 분류했다.
- 브라우저 Mermaid 파서에서 ERD 1, USER_FLOWS 4, DIAGRAM_STARTER 3, AI_ARCHITECTURE 2, ROADMAP 1개 블록이 모두 통과했다.
- 작업 카드의 파일 소유권을 모두 해제한다.
