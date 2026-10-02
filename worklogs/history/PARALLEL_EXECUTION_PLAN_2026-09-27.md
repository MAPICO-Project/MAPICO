# PRD·API·백엔드 병렬 진행안

## 의견

병렬 진행에 찬성합니다. 다만 PRD가 바뀌는 동안 API와 DB를 무계약으로 구현하면 재작업이 커지므로, 첫 2~3일을 `계약 스프린트`로 사용하고 이후 트랙을 나눕니다.

## Phase 0 — 계약 스프린트(2~3일)

- P0 사용자 스토리와 제외 범위
- 5개 추구미, TPO, 의류 속성 정의
- ERD v0.1
- API/AI 스키마 v0.1
- 상태 머신과 오류 코드
- RLS/공개범위/삭제 정책

이 단계에서 모든 세부 화면을 확정할 필요는 없지만 ID, enum, 상태, 소유권은 고정해야 합니다.

## Phase 1 — 병렬 구축

### Track A: PRD/UX

- 사용자 흐름과 예외 상태
- KPI 이벤트 정의
- 촬영·수정·추천 확정 UX
- 인터뷰로 가설 검증

### Track B: API/Database

- OpenAPI와 타입
- Supabase schema/migration/RLS
- mock response와 contract test
- AI callback/job 계약

### Track C: Backend foundation

- Vercel/Supabase 환경 분리
- Auth·Storage signed upload
- Queue/worker skeleton
- 로깅·request ID·배포

### Track D: AI integration

- 외부 GPU inference endpoint
- 분석 결과 schema adapter
- 실패·부분 성공·재시도
- golden payload test

## 병렬화 경계

| 병렬화하기 좋은 작업 | 먼저 계약이 필요한 작업 |
|---|---|
| Auth와 환경 구성 | 사용자·공개 범위 |
| Storage 업로드 | 객체 경로와 삭제 정책 |
| 기상청 adapter | 내부 WeatherSnapshot schema |
| 화면 mock과 skeleton | Job 상태·오류·polling 방식 |
| AI 모델 실험 | 결과 payload와 enum |
| RLS 테스트 틀 | 테이블 소유권과 서비스 역할 |

## 완료 게이트

- OpenAPI/타입과 실제 route 응답이 contract test에서 일치
- migration을 빈 DB에 재실행 가능
- RLS에서 다른 사용자 데이터 접근이 차단됨
- AI 성공·부분 실패·timeout fixture가 통과
- FE가 mock에서 실제 API로 base URL만 바꿔 연결 가능
