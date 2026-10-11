# MAFICO(MyFit:Core) · 마피코

실제 보유한 옷을 간편하게 등록하고, 날씨와 취향에 맞는 코디 추천·착용 기록·소셜 영감을 연결하는 AI 패션 서비스입니다.

MAFICO는 정식 이름이며 MyFit:Core의 약칭이고, 마피코는 한글 이름입니다. 플랫폼은 모바일 앱으로 확정했습니다(2026-10-09).

## 해결하려는 문제

- 여러 벌의 옷을 하나씩 등록해야 하는 불편
- 보유한 옷은 많지만 날씨와 취향에 맞춰 조합하기 어려운 문제
- 코디 보관, 실제 착용 기록, 다른 사용자의 스타일 참고가 분리된 경험
- 마음에 든 타인의 코디를 내 옷으로 재현하기 어려운 문제

## 핵심 사용자 흐름

1. 카카오 로그인 후 추구미(메인 1 + 보조 0~2)를 직접 고르거나 무드보드 탐색으로 찾습니다.
2. 여러 의류를 한 번에 촬영·업로드하고 AI 분할·분류 결과를 확인합니다.
3. 날씨와 추구미를 반영한 보유 의류 코디를 추천받습니다.
4. 코디를 보관하거나 오늘의 착장으로 기록합니다.
5. 피드에서 다른 사용자의 코디를 보고 좋아요하거나 내 옷으로 따라입기를 시도합니다.

## 주요 기능

| 영역 | 기능 |
|---|---|
| 계정·온보딩 | 카카오 로그인, 추구미 5종(페미닌·Y2K·미니멀·그런지·캐주얼) 중 메인 1 + 보조 0~2, 무드보드 탐색, 원샷 등록 안내 |
| 옷장 | 다중 의류 업로드, 분할·누끼·카테고리 확인, 수정·삭제 |
| 추천 | 위치 기반 날씨와 추구미를 반영한 보유 의류 코디 |
| 코디·OOTD | 날짜 없는 코디 보관, 오늘 입기, 월별 착용 기록과 통계 |
| 피드 | 코디 게시, 이미지 검증, 좋아요, 내 게시물·좋아요 모아보기 |
| Styling Mimic | 타인의 공개 코디를 내 보유 의류와 매칭 |

## 시스템 구성

| 파트 | 책임 | 현재 상태 |
|---|---|---|
| Product/Design | 기능명세, 유저플로우, 화면·정책 결정 | Canva 유저플로우 확정(2026-10-09), 일부 정책 미결 |
| Frontend | 모바일 앱, Supabase 로그인, API 연동과 사용자 경험 | 제품 프론트엔드 구조는 팀이 추가 예정 |
| Backend | API, DB/RLS, Storage, 작업 상태와 외부 연동 경계 | 제품 API 53개 모두 로컬 구현 |
| AI | 의류 분할·분류, 추천 보조, Styling Mimic worker | 인터페이스 설계, 실제 worker·모델 통합 미검증 |
| Infrastructure | Supabase, Vercel, 날씨 provider | 로컬 계약 검증 완료, hosted E2E 미검증 |

## 현재 저장소

현재 Git에 준비된 구현은 [`backend/`](backend/)입니다. 프론트엔드·AI·디자인 팀은 작업을 시작할 때 각자 필요한 최상위 폴더와 내부 구조를 직접 추가할 수 있습니다. 루트에서는 특정 파트의 폴더 구조나 개발 방식을 미리 강제하지 않습니다.

## 문서 지도

각 주제의 정본은 아래 한 곳입니다. 다른 위치에 같은 내용이 있으면 아래 문서를 기준으로 합니다.

| 주제 | 정본 |
|---|---|
| 최신 현황 | [시각자료·백엔드 현황 리포트 (2026-10-09)](deliverables/visuals/REPORT_2026-10-09.md) |
| 세션 인계 | [SESSION_HANDOFF](backend/worklogs/SESSION_HANDOFF.md) |
| 제품 요구사항 | [PRD](backend/docs/product/PRD.md) |
| 통합 로드맵 | [ROADMAP](backend/docs/product/ROADMAP.md) |
| 유저플로우 | [USER_FLOWS](backend/docs/design/USER_FLOWS.md) — [Canva 원본](https://www.canva.com/design/DAHW1gVlGD4/2IqavaVEc6wZIxsb_uNvGA/view) 텍스트 정리 |
| 전체 아키텍처 | [ARCHITECTURE](deliverables/visuals/ARCHITECTURE.md) |
| 기능맵 | [FEATURE_MAP](deliverables/visuals/FEATURE_MAP.md) |
| ERD | [ERD](deliverables/visuals/ERD.md) — migration에서 자동 생성 |
| API 설계 | [API_DESIGN](backend/docs/API_DESIGN.md) |
| API 계약 | [OpenAPI](backend/docs/openapi.yaml) |
| DB 설계 | [DB_DESIGN](backend/docs/DB_DESIGN.md) |
| DB 스키마 | [`backend/supabase/migrations/`](backend/supabase/migrations/) — migration 17개, public 테이블 28개 |
| AI 아키텍처 | [AI_ARCHITECTURE](backend/docs/AI_ARCHITECTURE.md) |
| 백엔드 개발·배포 | [백엔드 README](backend/README.md) |
| 작업 규칙(사람·AI 공통) | [CLAUDE.md](CLAUDE.md) |

유저플로우는 PM 겸 프론트가 작성한 Canva가 정본이며 `backend/docs/design/USER_FLOWS.md`가 그 텍스트 정리입니다. 구판은 같은 위치의 `old/` 폴더에 있습니다. 아키텍처·기능맵·ERD는 실제 migration과 OpenAPI를 기준으로 다시 그린 `deliverables/visuals/` 판이 최신이며, `backend/docs/`의 같은 이름 문서는 이전 설계 근거로 남아 있습니다.

## 아직 결정이 필요한 항목

2026-10-10 설계 보드 결정 중 **(PM 협의)** 표시 항목(하루 OOTD 여러 건, 따라입기 등급, 홈 Chip 0~2, TPO 제외, 지역 직접 선택, 원피스 등)과 플로우에 추가를 요청할 화면은 [PM 협의 안건](backend/worklogs/2026-10-10_PM_협의안건.md) 한 곳에 모아 두었습니다. 그 외 미결은 실제 AI worker와 모델 평가·배포 방식입니다. 결정 원문은 [의사결정 기록](backend/records/decisions/DECISIONS.md)에 있습니다.

2026-10-09·10-10에 결정된 항목: 옷 카테고리는 유저플로우 6종, FCM 푸시는 MVP 제외, 앱스토어 없이 웹페이지에서 설치 파일 배포, 신고·차단은 스토어 등록 시점에 추가, 회원 탈퇴 시 전부 삭제, 외부 AI 전송 고지(필수)와 사진 학습 동의(선택, 기본 꺼짐).

샘플 데이터와 목표 수치는 실제 사용자 결과나 모델 성능으로 간주하지 않습니다. 환경변수, 사용자 데이터, 이미지와 모델 가중치는 git에 올리지 않습니다.

