# 사용자·에이전트 분리 실행계획

기준일: 2026-09-29. 정본 로드맵은 `deliverables/product/ROADMAP.md`다.

## 1. 지금 병렬로 시작할 작업

### 사용자가 직접 할 일 — 원격·계정·팀 결정

| 우선순위 | 작업 | 필요한 이유 | 완료 증거 |
|---|---|---|---|
| U0-1 | GitHub private+지원 플랜, 별도 공개 실습 저장소, 또는 Git 연동 없는 직접 CLI Preview 중 방식을 결정 | 저장소 정책에 막히지 않는 배포 경로 확보 | 선택 결과와 대상 저장소·프로젝트 이름 |
| U0-2 | Supabase 개발 프로젝트 이름/project ref와 기존 public 테이블 유무 확인 | 잘못된 DB·기존 데이터 덮어쓰기 방지 | 비밀값 없는 테이블 목록과 대상 확인 |
| U0-3 | 빈 개발 DB 또는 승인된 대상에 migration 3개 순차 적용 | ERD 22테이블 원격 기반 확보 | 파일명·적용 시각·성공/오류 기록 |
| U0-4 | Vercel Preview의 URL/publishable key, 후속 server secret·AI HMAC·허용 origin 등록 범위와 보호 정책·고정 alias를 확인 후 새 배포 | FE·AI 공용 Backend URL 확보 | 값이 아닌 등록 여부, 고정 URL, health/aesthetics 결과 |
| U0-5 | Supabase 개발 테스트 사용자·허용 이미지 세트를 먼저 준비하고, Kakao 앱·provider·redirect URI를 R1까지 설정 | R0 Auth/RLS와 R1 실제 로그인/JWT E2E 분리 | 테스트 계정 수·데이터 출처, 설정 완료 여부와 redirect URI |
| U0-6 | Frontend Preview origin과 AI worker/callback 주소 결정 | CORS·callback allowlist | origin/endpoint 목록과 환경 구분 |
| U0-7 | 최종 추구미 5종 이름·정의·대표/제외 예시 선정 회의 주관 | 온보딩·데이터·AI 공통 기준 | taxonomy v1 표와 승인자 |
| U0-8 | AI worker 호스팅, Vision/LLM, 날씨 공급자와 예상 비용·키 소유자를 승인 | R2 이후 외부 의존성과 비용 차단 제거 | 공급자·예산 한도·키 관리자, 실제 값은 비공개 |
| U1-1 | 선택적으로 Miro 연결 및 팀 초대 | Mermaid 초안을 공동 편집 가능한 보드로 변환; D0 비차단 | 연결 완료 확인만 공유 |

비밀번호, DB URL 전체, secret/service-role 키, OAuth client secret은 채팅·Git·문서에 넣지 않는다.

### 에이전트가 바로 할 일 — 로컬 구현·검증

| 우선순위 | 작업 | 완료 기준 |
|---|---|---|
| A0-1 | 배포 전 공통 인증/오류/CORS 설계 정리 | 허용 origin, OPTIONS, request-id, 오류 envelope 테스트 |
| A0-2 | getMe 모듈을 재사용 가능한 인증·PostgREST client로 분리 | 기존 20개 테스트 유지, 새 consumer 테스트 |
| A0-3 | profile/aesthetics/onboarding 읽기·쓰기의 narrow RPC/BFF 권한 설계 | service-role 노출 없이 owner write 검증 |
| A0-4 | Preview smoke 스크립트 보강 | health/aesthetics/me와 구현 상태를 비밀값 없이 검사. 원격 GET 실행은 사용자가 URL을 제공·승인한 뒤 수행 |
| A0-5 | FE·AI용 계약 fixture와 오류 예시 생성 | OpenAPI와 일치하며 `source` 또는 `engine_version=fixture-*`로 실제 추론과 구분 |
| A0-6 | operation·ERD coverage 추적표 자동화 | 50 operation/22테이블 상태를 한 명령으로 보고 |
| A0-7 | 개발 seed·fixture 스크립트 설계 | 비밀값 없이 taxonomy/test profile/허용 이미지 metadata를 재현 |

2026-09-29 진행 상태:

- 완료: A0-1 공통 인증/오류/CORS, A0-2 `getMe` 재사용 구조, A0-4 Preview smoke dry-run/실행 도구, A0-5 `fixture-*` 계약 샘플, A0-6 50 operation·22 table coverage 자동검사.
- 완료: A0-3 계정/온보딩 narrow write/RPC와 로컬 권한 검증, A0-7 metadata-only fixture seed/validator. HTTP write operation은 아직 planned이며 상세는 [A0 쓰기 RPC·seed 결과](2026-09-29_A0_WRITE_SEED_RESULT.md)를 본다.
- 완료: G1 계정·온보딩 HTTP handler와 catalog 읽기 5개 operation 구현. 누적 6/50 implemented-local, 상세는 [G1 결과](2026-09-30_G1_ACCOUNT_ONBOARDING_RESULT.md)를 본다.
- 다음 에이전트 작업 후보: G2 옷장 읽기 operation. 실제 G1 Preview/Auth E2E는 사용자 환경 준비 후 공동 검증한다.
- 사용자 입력 후 공동 검증: 실제 Preview smoke와 hosted Auth/RLS. 결과는 [D0 로컬 기반 구현 결과](2026-09-29_D0_LOCAL_FOUNDATION_RESULT.md)를 본다.

### 함께 해야 할 일

| 작업 | 사용자·팀 입력 | 에이전트 지원 | 종료 조건 |
|---|---|---|---|
| D0 실배포 검증 | Dashboard 설정·배포 실행 | 명령·체크리스트·응답 분석 | 세 팀이 같은 URL 사용 |
| taxonomy v1 | 이름·정의·예시 승인 | 표준 code/version·데이터 CSV 반영 | FE·AI·DB가 같은 version 사용 |
| 대표 시연 흐름 | 반드시 성공할 흐름과 fallback 승인 | 해당 E2E·관측·복구 설계 | 시연 스크립트 고정 |
| 유저플로우 보드 | 선택적 Miro 연결과 팀 초대 | Mermaid→보드 변환·변경 반영 | 기능 ID와 coverage 보고 기준 상태가 표시됨 |

## 2. D0 완료 직후의 goal 순서

각 goal은 계획→Opus 설계 검토→Claude Sonnet 구현 또는 리뷰→Astra 통합→테스트→로그/결과 보고→Preview 검증으로 닫는다. 실제 모델 ID와 실행 증거를 기록한다.

1. G1 계정·온보딩 전체: profile update, aesthetics, onboarding.
2. G2 옷장 읽기: garments list/detail, asset projection.
3. G3 등록 기반: batch, signed upload, upload verification.
4. G4 AI job: analysis job, drafts, retry, confirm.
5. G5 추천 기반: weather snapshot, recommendation request/results/items.
6. G6 보관·OOTD: saved outfits, OOTD, statistics.
7. G7 피드·미디어·좋아요: 공개 projection과 가시성.
8. G8 따라입기: mimic worker contract와 saved outfit handoff.
9. G9 탈퇴·삭제·정리: DB/Storage/파생 데이터 lifecycle.
10. G10 전체 coverage·성능·시연 동결.

## 3. 작업 상태 보고 형식

매 goal 결과에는 다음을 남긴다.

- 구현/계획 operation 수와 관련 ERD 테이블
- 변경 파일과 migration 유무
- 로컬 테스트와 Preview smoke 결과
- FE·AI에 전달할 URL·fixture·오류 예시
- hosted 미검증 항목과 사용자 다음 작업
- 비용·모델 metadata와 중단/재시도 이력

## 4. 현재 출발점

- 로컬: getMe 1/50 operation `implemented-local`, 나머지 49개 planned.
- DB: 22테이블 migration과 embedded PostgreSQL 검증 완료, 원격 적용 미확인.
- 테스트: backend 20/20, schema 검증 통과.
- 원격: GitHub 저장소는 2026-09-29 read-only 확인상 PRIVATE.
- 배포: 과거 Preview URL은 존재하지만 오늘 응답을 재확인하지 못했고 최신 getMe 배포 증거가 없다.
- 다이어그램: ERD 1개, 유저플로우 4개, AI 2개 Mermaid가 존재하며 새 시작자료를 추가한다.
