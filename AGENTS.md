# MAFICO 모노레포 작업 지침

모바일 웹 관련 판단은 사용자 채팅 근거와 최신 PRD를 기준으로 하며, 과거 회의 기록으로 대체하지 않습니다.

## 읽기 순서

1. `deliverables/product/PRD.md`
2. `records/decisions/DECISIONS.md`
3. 작업 파트의 README
4. 관련 공식 산출물과 최신 worklog

백엔드 작업은 `deliverables/backend/API_DESIGN.md`, `deliverables/backend/DB_DESIGN.md`, `backend/README.md`를 추가로 읽습니다.

## 저장소 경계

- 이 프로젝트는 하나의 Git 저장소입니다. `backend/`, `apps/`, `ai/`, 문서 폴더에 별도 `.git`을 만들지 않습니다.
- 백엔드 코드·SQL 정본은 `backend/`, 팀 공유 API·DB 문서 정본은 `deliverables/backend/`입니다.
- `backend/docs/`는 배포용 계약 사본이며 export manifest와 해시를 유지합니다.
- 프론트엔드 제품 코드는 `apps/`, AI 워커·추론 연동 코드는 `ai/`에 둡니다.
- 공식 산출물은 `deliverables/`, 회의는 `records/meetings/`, 결정은 `records/decisions/`, 계획·검증 결과는 `worklogs/`에 둡니다.

## 변경 규칙

- 다른 작업자의 변경을 보존하고, 담당 폴더 중심의 작은 커밋과 PR을 사용합니다.
- API/DB 계약 변경에는 구현, 테스트, OpenAPI/설계 문서 갱신을 함께 포함합니다.
- DB 테스트는 로컬 stub/embedded PostgreSQL 결과와 실제 hosted Supabase 검증을 구분합니다.
- 모델 예측과 사용자 수정값, 추천 결정과 LLM 설명, fixture와 실제 결과를 분리합니다.
- 미결 TPO, 하루 OOTD 수, 피드 추구미 수, `wear_status`, 최종 추구미 명칭을 확정으로 기록하지 않습니다.
- `references/history/`와 `worklogs/history/`는 과거 이력이며 현재 정본이 아닙니다.

## 보안

- 비밀값은 로컬 환경변수와 배포 플랫폼 Secret에만 둡니다.
- `.env`, `.vercel`, `supabase/*.txt`, `backend/supabase/*.txt`, 토큰, 사용자 데이터, 이미지, 모델 가중치를 출력하거나 커밋하지 않습니다.
- `git add -f`로 ignore 규칙을 우회하지 않습니다.

## 병렬 작업

- [병렬 작업 규칙](worklogs/PARALLEL_WORK_RULES.md)의 카드·동시성·hand-off·검증 규칙을 따릅니다.
- 한 파일 한 작성자, 결과 회수 후 메인 작업자의 통합 검증을 원칙으로 합니다.
