# 마피코 시스템 아키텍처

2026-10-02 저장소 확인 기준. 모바일 웹 우선 방향은 사용자 채팅에서 정했으며 네이티브 앱·PWA 출시는 확정하지 않았다. 이 문서는 코드와 계약의 연결을 설명하는 검토본이며 배포 완료 그림이 아니다.

현재 G1~G8의 OpenAPI operation 49/50은 `implemented-local`이다. 탈퇴 요청은 `planned`이며 실제 AI 워커, hosted Supabase Auth·Storage·RPC 및 날씨 공급자 연동은 미검증이다. 로컬 테스트는 Auth/Storage 스텁과 embedded PostgreSQL을 포함한다. 22개 테이블의 원래 MVP 범위에 G8 snapshot 2개가 추가되어 현재 migration에는 public 테이블 24개가 있다.

## 1. 구성과 신뢰 경계

실선은 현재 서버 코드·SQL에 있는 호출 계약, 점선은 제품 클라이언트 또는 외부 연동이 필요한 경로다. 선이 존재해도 hosted 통과를 뜻하지 않는다. `[로컬]`, `[연동 미검증]`, `[목표]` 표기는 색상과 함께 읽는다.

```mermaid
flowchart TB
  subgraph browser[사용자 기기 · 입력을 검증해야 하는 경계]
    WEB["모바일 웹 · 폴더 위치 미정<br/>[목표] 화면·카메라·결과 검토"]
  end
  subgraph server[백엔드 · backend/ · Node HTTP 처리]
    BFF["[로컬] BFF /api/v1<br/>JWT 확인 · 입력 검증 · 안전한 응답"]
    INT["[로컬] 서버 전용 처리<br/>날씨 저장 · 피드 projection · callback"]
    REC["[로컬] 결정론 추천 엔진<br/>날씨·추구미 점수 + 템플릿 설명"]
  end
  subgraph sb[Supabase · 정책과 SQL의 로컬 검증 / hosted 미검증]
    AUTH["[연동 미검증] Auth<br/>카카오 OAuth · 사용자 JWT"]
    DB["[로컬] PostgreSQL<br/>RLS · 본인 고정 RPC · snapshot"]
    QUEUE["[로컬] DB job queue<br/>analysis_jobs · mimic_requests<br/>claim · lease · attempt"]
    STORAGE["[연동 미검증] 비공개 Storage<br/>closet-private / feed-private"]
  end
  AI["[연동 미검증] AI 워커 · 폴더 위치 미정<br/>분석·누끼·따라입기 모델"]
  WX["[연동 미검증] 날씨 공급자"]
  WEB -. "Auth SDK 로그인·로그아웃" .-> AUTH
  WEB -. "Bearer JWT" .-> BFF
  BFF -->|Auth 사용자 확인| AUTH
  BFF -->|같은 사용자 JWT · RLS / narrow RPC| DB
  BFF --> INT
  BFF --> REC
  INT -->|server-only RPC · 권한 재검증| DB
  DB --- QUEUE
  BFF -->|signed URL 발급 · 객체 검증| STORAGE
  WEB -. "예약 경로 signed upload / 짧은 signed read" .-> STORAGE
  AI -. "service-only claim RPC" .-> QUEUE
  AI -. "비공개 입력 접근·분석 누끼 저장은 연동 대상" .-> STORAGE
  AI -. "raw-body HMAC callback" .-> INT
  INT -. "서버 자격증명으로 요청" .-> WX
  REC -->|확정 결과·불변 날씨 근거 저장| INT
  classDef local fill:#e0f2fe,stroke:#0369a1,color:#0c4a6e;
  classDef pending fill:#fff7ed,stroke:#c2410c,color:#7c2d12,stroke-dasharray:5 3;
  class BFF,INT,REC,DB,QUEUE local;
  class WEB,AUTH,STORAGE,AI,WX pending;
```

BFF는 모바일 웹용 API 계층이다. 일반 사용자 요청은 Supabase Auth의 `/auth/v1/user`로 확인한 JWT를 RLS 조회·RPC에 그대로 전달한다. 공개 카탈로그는 publishable key로 허용 필드만 익명 조회한다. 서버 전용 키를 쓰는 날씨·피드·callback 경로는 별도로 검증하며, service role이 RLS를 우회하므로 사용자 범위를 다시 확인해야 한다. 비밀값은 브라우저에 전달하지 않는다.

Storage URL은 접근 수단이며 영구 공개 전환이 아니다. URL 자체에는 경로가 포함될 수 있지만 raw object key를 별도 응답 필드로 제공하지 않는다. 피드에는 `feed-private`의 공유 전용 복사본만 사용하고 개인 옷장 원본을 공개하지 않는다. 비공개 전환·철회 뒤 신규 URL 발급은 막지만 이미 발급한 URL은 만료까지 유효할 수 있다.

근거: [API 설계](../../backend/docs/API_DESIGN.md), [DB 설계](../../backend/docs/DB_DESIGN.md), [백엔드 README](../../backend/README.md), [현재 저장소 구조](../../README.md). 현재 루트 README는 프론트엔드·AI 팀이 작업 시작 시 폴더 구조를 정하도록 하므로 경로를 확정하지 않는다.

## 2. 등록 → 비동기 분석 → 사용자 확정

아래는 구현된 서버 계약과 아직 연결하지 않은 워커를 함께 보여주는 시퀀스다. HTTP 요청이 AI 추론 종료까지 대기하지 않고, 웹은 job을 조회한다. 별도 Redis·메시지 브로커 도입은 이 구현에서 확인되지 않는다.

```mermaid
sequenceDiagram
  participant W as 모바일 웹
  participant B as BFF
  participant D as DB / RLS·RPC
  participant S as 비공개 Storage
  participant A as AI 워커 · 연동 미검증
  W->>B: POST garment-batches + Idempotency-Key
  B->>D: batch·source asset·서버 경로 원자 예약
  B->>S: signed upload 발급
  B-->>W: batch ID · 업로드 URL
  W->>S: 예약된 source 객체 업로드
  W->>B: complete-upload
  B->>S: Range 읽기 · MIME·크기·magic bytes 검사
  B->>D: owner·metadata 재확인 후 uploaded 전이
  W->>B: POST analysis-jobs
  B->>D: 멱등 queued job 생성
  B-->>W: job ID · 비동기 상태
  Note over A,S: 아래 워커 실행·입력 접근·업로드는 실제 연동 미검증
  A->>D: service-only claim_analysis_job
  D-->>A: running · attempt · lease_token
  A->>S: 입력 접근 및 누끼 결과 저장
  A->>B: POST internal analysis result / HMAC
  B->>B: raw-body 서명·timestamp·schema 검증
  B->>D: event·payload hash replay 선조회
  alt 이미 반영한 동일 이벤트
    B-->>A: 200 · applied=false
  else 새 이벤트
    B->>S: canonical 누끼 경로·실파일 검사
    B->>D: lease·객체 identity/version 재검증 후 원자 반영
    D-->>B: job 종료 · draft·asset·batch 전이
    B-->>A: 200 · applied 결과
  end
  W->>B: job·draft 조회 후 사용자 보정
  B->>D: safe projection · override 저장
  W->>B: confirm + 정확한 draft version 집합
  B->>D: 잠금·자산 검증 후 의류 원자 확정
  B-->>W: 확정 결과
```

모델 원본 예측과 사용자 수정값은 분리하며 일반 draft 응답에 raw 예측을 노출하지 않는다. callback은 5분 timestamp 창과 HMAC을 확인한다. 동일 이벤트 replay는 변경 가능한 lease·Storage 검사보다 먼저 처리한다. 분석 claim은 만료된 lease를 재획득할 수 있으며 재시도 한도를 넘으면 실패 처리한다. 실패 결과는 안전한 상태로 조회하고 허용된 오류만 사용자 retry API로 재시도한다.

근거: [G4 결과](../../backend/worklogs/2026-10-01_G4_ANALYSIS_RESULT.md), [분석 claim SQL](../../backend/supabase/migrations/202609270002_transactions.sql), [분석 확정 SQL](../../backend/supabase/migrations/202610010001_analysis.sql), [분석 callback](../../backend/lib/analysis-callback.js).

## 3. 피드 따라입기: snapshot과 현재 권한을 함께 확인

```mermaid
sequenceDiagram
  participant W as 모바일 웹
  participant B as BFF
  participant D as DB job·snapshot
  participant A as AI 워커 · 연동 미검증
  W->>B: POST mimic-jobs / 공개 post ID
  B->>D: 본인 사용자 고정 create RPC
  D->>D: 공개 media·본인 활성 의류 snapshot 고정
  D-->>B: queued 또는 같은 user/post의 진행 중 job
  B-->>W: 202 · job ID
  A->>D: service-only claim_mimic_job
  D->>D: 공개성·객체·후보 fence 재검증
  D-->>A: source·candidate snapshot · lease · attempt
  Note over A: 입력 이미지 접근·실제 매칭 실행은 미검증
  A->>B: 결과 callback / mimic.v1 HMAC
  B->>D: replay 선조회 후 apply RPC
  D->>D: lease·deadline·현재 공개성·snapshot fence 검사
  D-->>B: succeeded / no_match / failed
  W->>B: GET mimic-jobs/{jobId}
  B->>D: 현재 공개성·의류 가용성 재확인
  alt 원본 비공개 또는 삭제
    B-->>W: 404
  else 열람 가능
    B-->>W: source-N · 본인 후보 · 안전한 설명
  end
  W->>B: 사용자 확인 후 POST saved-outfits
  B->>D: 본인 활성 의류 검증 후 별도 저장
```

DB queue는 사용자 진행 중 job 최대 3개, 2시간 deadline, 최대 3회 lease attempt, 종료 후 7일 결과 보존을 적용한다. similarity는 일치 확률이 아니다. 일부 매칭도 `succeeded`가 될 수 있고, 완료 뒤 후보가 모두 사용 불가해지면 조회 projection이 `no_match`가 된다. callback에는 분석과 다른 `mimic.v1` HMAC domain을 사용한다. 결과 조회가 보관함 저장을 자동으로 수행하지 않는다.

근거: [G8 결과](../../backend/worklogs/2026-10-01_G8_MIMIC_RESULT.md), [따라입기 SQL](../../backend/supabase/migrations/202610010005_mimic.sql), [따라입기 callback](../../backend/lib/mimic-callback.js), [G7 피드 결과](../../backend/worklogs/2026-10-01_G7_FEED_RESULT.md).

## 4. 현재 추천 경로와 AI 목표의 구분

```mermaid
flowchart TD
  R["웹의 온디맨드 추천 요청"] --> LOCK["[로컬] 사용자 reservation<br/>Idempotency-Key · 2분 lease"]
  LOCK --> CACHE["현재 시간 slot 날씨 cache 조회"]
  CACHE -->|10분 이내 fresh| SNAP["사용할 불변 weather snapshot"]
  CACHE -->|갱신 필요| PROVIDER["[연동 미검증] 날씨 공급자 호출"]
  PROVIDER -->|성공| NEW["새 불변 snapshot 저장"]
  NEW --> SNAP
  PROVIDER -->|실패 · 허용된 동일 slot cache 존재| STALE["3시간 이내 stale 사용<br/>stale 여부 보존"]
  STALE --> SNAP
  PROVIDER -->|사용 가능한 cache 없음| FAIL["오류 반환 · 날씨를 만들지 않음"]
  SNAP --> ENGINE["[로컬] 결정론 조합·순위<br/>활성 의류 + 추구미 가중치·점수"]
  PREF["DB 사용자 선호·검증된 의류"] --> ENGINE
  ENGINE --> TEXT["[로컬] 검증된 근거의 템플릿 설명"]
  TEXT --> SAVE["lease·snapshot·활성 자산 재검증<br/>추천과 버전·근거 저장"]
  SAVE --> RESULT["추천 조회 · 후보 부족 사유 표시"]
  FUTURE["[목표] LLM 설명 모듈<br/>선택된 조합의 근거 표현"] -. "별도 구현·평가 필요" .-> TEXT
```

현재 추천은 AI 워커 job이 아니라 BFF의 결정론 엔진이며 자유 형식 LLM을 호출하지 않는다. 목표 구조에서는 Vision, 5종 추구미 추론, 추천 결정, 설명 생성을 분리한다. 5종 개수만 확정됐고 이름·정의·학습 성능은 미확정이다. 남성용 스타일 확장은 후속 선택사항이다. TPO 유지 여부와 5시/7시 생성 정책은 미결이므로 이 그림에 필수 입력이나 확정 스케줄을 넣지 않았다.

근거: [G5 결과](../../backend/worklogs/2026-10-01_G5_RECOMMENDATION_RESULT.md), [추천 코드](../../backend/lib/recommendations.js), [날씨 코드](../../backend/lib/weather.js), [AI 목표 설계](../../backend/docs/AI_ARCHITECTURE.md), [PRD](../../backend/docs/product/PRD.md).

## 검토 시 남겨둘 경계

| 구분 | 확인된 범위 | 남은 검증·결정 |
|---|---|---|
| 인증·데이터 | JWT 전달, RLS·RPC, 소유권·멱등성 로컬 구현 | 실제 카카오 로그인, hosted Auth/RLS·동시 요청 |
| 이미지 | 비공개 bucket 계약, 실파일·객체 version 검증 코드 | hosted signed upload/read·만료·삭제 cleanup 워커 |
| 분석·따라입기 | DB queue·claim·lease·HMAC callback·safe projection | 워커 실행, 입력 전달·Storage 접근, 실제 추론·평가 |
| 추천 | 결정론 엔진·불변 날씨 snapshot·템플릿 설명 | 실제 공급자, 시간대 자정 E2E, LLM 설명 구현 |
| 보관·OOTD·피드 | 별도 데이터·사용자 저장·명시적 공개 경계 | 하루 OOTD 수·wear_status UX·피드 추구미 수 최종 결정 |
| 탈퇴 | OpenAPI 계약 | 요청 구현·재인증·DB/Storage·공유 데이터 정리 |

보관함 수정은 과거 OOTD snapshot을 바꾸지 않는다. OOTD 자체는 비공개이며 피드 게시를 별도 수행한다. 현재 하루 1기록 제약과 `planned/worn` 처리는 로컬 기술 계약이지 미결 제품 정책의 최종 승인으로 읽지 않는다. [G6 결과](../../backend/worklogs/2026-10-01_G6_OUTFIT_OOTD_RESULT.md)와 [결정 기록](../../backend/records/decisions/DECISIONS.md)을 함께 확인한다.

이 문서 작성 시 서버 테스트를 재실행하지 않았다. 기존 G8 결과의 테스트 통과 기록과 현재 파일을 대조했으며 Mermaid 렌더링·통합 검증은 시각자료 통합 단계에서 수행한다.
