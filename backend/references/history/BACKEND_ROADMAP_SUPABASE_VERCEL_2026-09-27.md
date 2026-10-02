# Supabase·Vercel 기준 백엔드 로드맵

> `BACKEND_ROADMAP_2026-09-27.md`의 일반 산정을 관리형 서비스 전제로 보정한 최신안입니다.

## 전제

- Next.js/TypeScript와 Vercel
- Supabase Auth, Postgres, Storage, RLS, Queues/pgmq
- 5개 추구미와 사용자가 고르는 TPO 프리셋
- CV 추론은 별도 GPU AI 서비스가 제공
- 1인 백엔드, 주 5일
- FE·AI 트랙과 병렬 진행
- 소셜은 게시·스크랩까지만, 댓글·신고·랭킹은 후속

## 권장 범위와 기간

| 범위 | 1인 | 2인 | 설명 |
|---|---:|---:|---|
| M0 데모 | 3.5~4.5주 | 2.5~3.5주 | 원샷 등록, 옷장, 날씨·TPO 추천 |
| M0.5 권장 제출안 | 5~6주 | 3.5~4.5주 | M0 + Auth/영구 저장/OOTD 일부 |
| M1 서비스형 MVP | 6.6~8주 + 버퍼 1주 | 4.5~5.5주 + 버퍼 1주 | 캘린더, 제한 피드·스크랩, 배포·보안 |
| 전체 PRD | 10~13주 이상 | 7~9주 이상 | 전체 소셜, 실제 Mimic, 스케줄·알림 |

권장 제출 범위는 **M0.5**입니다. 핵심 수직 흐름을 완성하면서도 계정·저장·간단한 기록까지 보여줄 수 있습니다.

## 1인 M1 상세 일정: 6.6~8주 + 버퍼

| 단계 | 작업 | 예상 |
|---|---|---:|
| 계약 스프린트 | PRD P0, ERD, OpenAPI, AI payload, 상태·enum, RLS 정책 | 2~3일 |
| 기반 | Supabase project/migration, Auth, profiles, Vercel 환경·preview | 3~4일 |
| 이미지 | private bucket, signed upload, batch/job/draft schema | 4~5일 |
| AI 연동 | Queue, 외부 worker 계약, callback/polling, 부분 실패·재시도 | 5일 |
| 옷장 | draft 확정 트랜잭션, CRUD, 필터, soft delete·자산 정리 | 4일 |
| 날씨/TPO | 기상청 adapter, 캐시, TPO preset·rule input | 3~4일 |
| 추천 | 코디 요청, 점수·근거 저장, 확정/거절/아이템 교체 | 4~5일 |
| 기록·소셜 | OOTD 캘린더, 제한 공개 게시·스크랩, sample Mimic | 4~5일 |
| 안정화 | contract/RLS/integration test, 로깅, 배포, 성능 검증 | 4~5일 |
| 버퍼 | AI·날씨·OAuth·통합 지연 | 5일 |

세부 단계 합계는 **33~40 인일 + 버퍼 5일 = 38~45 인일(7.6~9주)**입니다. 기존 32~37 인일 표기는 합계 오류로 수정했습니다. 주 5일 전일 투입 기준이며, 학기 중 주 2~3일 투입이면 달력 기간을 투입률에 맞게 늘려야 합니다. AI 학습·추론 배포 자체는 별도 트랙의 선행 의존성입니다.

## 병렬 착수 방식

첫 2~3일에 계약 초안 70%를 만든 뒤 아래를 병렬로 진행합니다.

| Track | 내용 |
|---|---|
| PRD/UX | 예외 흐름, KPI 이벤트, 인터뷰 |
| API/DB | OpenAPI, migrations, RLS, contract tests |
| Backend | Auth, Storage, Vercel route skeleton, logging |
| AI integration | mock server, Queue, callback, golden payload |

API 설계서가 100% 끝날 때까지 기다리지는 않습니다. mock-first로 개발하되 상태·enum·AI payload 변경은 계약 변경으로 관리합니다.

## 플랫폼 역할

| 구성 | 맡길 일 | 맡기지 않을 일 |
|---|---|---|
| Vercel | Next.js, BFF, 외부 API 조정, 가벼운 추천 | 이미지 파일 중계, YOLO/SAM 실행 |
| Supabase Postgres | 데이터, RLS, RPC, 캐시 메타데이터 | 장시간 모델 추론 |
| Supabase Storage | 원본·마스크·누끼 이미지 | 공개 bucket 기본값 |
| Supabase Queues | 분석 Job 내구성·재시도 | GPU 작업 자체 |
| External AI Worker | 검출·분할·태깅·임베딩 | 사용자 인증·서비스 DB 직접 권한 |

## 추가 기간 옵션

| 옵션 | 추가 예상 |
|---|---:|
| 카카오·구글·애플 모두 지원 | 3~5일 |
| 오전 7시 프리컴퓨팅·푸시 | 3~5일 |
| 댓글·좋아요·신고·차단 | 1~2주 |
| 실제 vector search Mimic | 1~2주 |
| 캘린더 자동 TPO 추론 | 1~2주 이상 |
| 운영자 콘텐츠 관리 | 3~5일 |

## 비용·운영 주의

- 큰 이미지는 Vercel 함수를 거치지 않고 Storage로 직접 업로드합니다.
- Vercel과 Supabase 리전을 가능한 한 가깝게 맞춥니다.
- 오전 7시 기능은 개인 시간대와 마지막 위치 정책이 필요합니다.
- Hobby Cron은 정시성이 낮으므로 정확한 추천 알림이 필요하면 Supabase `pg_cron` 또는 유료 스케줄링을 사용합니다.
- RLS 회귀 테스트 없이 service role 사용 범위를 넓히지 않습니다.
