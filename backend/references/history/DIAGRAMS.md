# MyFit:Core 설계 다이어그램

상태: M0.5 구현 계약을 위한 설계. 실제 서버 배포를 나타내지 않습니다.
ERD, 유스케이스, 등록 시퀀스는 지금 필요합니다. 화면별 클래스도와 상세 배포 토폴로지는 프레임워크·AI 실행 환경 확정 후 추가합니다.
각 Mermaid 블록은 Mermaid 지원 뷰어에서 렌더링하거나 소스로 내보낼 수 있습니다.

## 사용자 유스케이스

Mermaid flowchart로 표현한 유스케이스 관계도입니다. 정식 UML 표기와는 구분합니다.

```mermaid
flowchart LR
  user[사용자]
  auth[Supabase Auth]
  ai[외부 AI 서비스]
  weather[날씨 제공자]
  subgraph system[MyFit Core - M0.5]
    login([로그인])
    pref([추구미 1~3개 선택])
    upload([의류 사진 업로드])
    analyze([의류 분석])
    review([분류 결과 수정·확정])
    closet([내 옷장 관리])
    recommend([날씨·선택 TPO로 추천])
    accept([코디 선택·OOTD 기록])
    history([착용 기록 조회])
  end
  user --- login
  user --- pref
  user --- upload
  user --- review
  user --- closet
  user --- recommend
  user --- accept
  user --- history
  auth --- login
  upload --> analyze
  ai --- analyze
  analyze --> review
  review --> closet
  weather --- recommend
  recommend --> accept
  accept --> history
```

소셜 게시·댓글·실사용자 OOTD 따라입기는 후속 범위입니다. 추가 테이블을 지금 강제하지 않습니다.

## 시스템 책임

```mermaid
flowchart TB
  client[브라우저]
  bff[Vercel API - 인증·검증·업무 처리]
  auth[Supabase Auth]
  db[(Supabase Postgres - RLS)]
  storage[(Private Storage)]
  dispatcher[신뢰된 작업 조정 서비스]
  worker[외부 AI Worker]
  weather[기상 데이터 API]
  client --> auth
  client --> bff
  client -->|기한 제한 업로드 URL| storage
  bff -->|사용자 JWT 또는 소유권 검증 RPC| db
  bff --> weather
  dispatcher -->|Job lease·재시도| db
  dispatcher -->|작업별 URL·attempt 토큰| worker
  worker -->|서명 callback| bff
  worker -->|제한된 이미지 URL| storage
```

## 다중 등록 시퀀스

```mermaid
sequenceDiagram
  actor U as 사용자
  participant FE as 프론트엔드
  participant API as Vercel API
  participant DB as Supabase DB
  participant S as Storage
  participant W as AI Worker
  U->>FE: 사진 선택
  FE->>API: 배치 생성
  API->>DB: 소유자·경로·상태 저장
  API-->>FE: signed upload URL
  FE->>S: 사진 직접 업로드
  FE->>API: 업로드 완료 요청
  API->>S: 파일 존재·타입·크기 검사
  API->>DB: uploaded 기록
  FE->>API: 분석 요청 + Idempotency-Key
  API->>DB: Job 영속 저장
  API-->>FE: 202 + job ID
  Note over DB,W: 조정 서비스가 lease를 획득하고 AI 호출
  W->>S: 작업 전용 URL로 이미지 읽기·결과 쓰기
  W->>API: 서명 결과 + job ID + attempt + event ID
  API->>DB: 중복·오래된 attempt 차단 후 draft 저장
  FE->>API: Job·draft 조회
  API-->>FE: 성공·부분 실패 및 검토 결과
  U->>FE: 수정 후 선택 항목 확정
  FE->>API: 확정 요청
  API->>DB: 소유권 확인·트랜잭션으로 의류 생성
  API-->>FE: 확정된 의류 IDs
```

## 추천과 OOTD

```mermaid
flowchart TD
  request[날씨 위치·시간 + 추구미 + 선택 TPO]
  candidates[사용 가능한 내 의류 조회]
  filter[날씨·명시된 활동 제약 검사]
  ranking[추구미·상황·색상·다양성 평가]
  result[추천 요청 묶음과 개별 코디 저장]
  choice[사용자가 개별 outfit ID 선택]
  tx[소유권·요청 일치 확인 + 중복 방지]
  ootd[착용 날짜와 아이템 스냅샷 저장]
  request --> candidates --> filter --> ranking --> result --> choice --> tx --> ootd
  filter -->|후보 부족| empty[조건 완화 안내·등록 유도]
```

후보가 부족하면 3개를 강제 생성하지 않습니다. 추천 개수와 부족 사유를 반환합니다. TPO 미선택은 상황 제약을 적용하지 않으며 자동으로 등교·출근을 가정하지 않습니다.
