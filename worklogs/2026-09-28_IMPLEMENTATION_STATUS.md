# 구현 상태 요약

확인일: 2026-09-28

## 준비 완료 또는 확인된 항목

- 모바일 웹 우선은 회의 확정이 아니라 사용자의 채팅 제안으로 기록돼 있다.
- backend에 health, readiness, catalog, aesthetics 4개 진단 핸들러가 있다.
- backend에 첫 제품 handler `GET/HEAD /api/v1/me`가 추가됐다. Supabase Auth로 bearer를 검증하고 사용자 JWT/RLS로 Profile을 읽는 로컬 구현이며 hosted 통합은 미검증이다.
- `npm test`: 20/20 통과(최근 로컬 검증).
- `npm run test:schema`: OpenAPI 36 paths, migration 3개, SQL assertions, embedded PostgreSQL 통과.
- Vercel·Supabase 실습 절차와 무료 MVP 제약은 `deliverables/backend/DEPLOYMENT_LAB.md`에 정리돼 있다.

## 부분 구현·검증 대기

- readiness는 전체 제품 미완성 상태를 503으로 표시한다. 이는 현재 의도된 상태다.
- catalog는 구 5종 fixture 기반이다.
- aesthetics는 실제 Supabase read 경로가 있으나 원격 schema가 적용됐다고 확인하지 않았다.
- OpenAPI 50 operation 중 getMe 1개만 `implemented-local`, 나머지 49개는 `planned`다.
- 추구미는 5종이라는 개수만 확정됐고 최종 명칭은 미정이다. 기존 코드·SQL·문서의 명칭 drift는 후속 변경 대상이다.

## 미구현 또는 사용자 작업인 항목

- GitHub 조직 공개와 저장소 공개는 동일하지 않다. 최신 확인상 `MAFICO-Project/mafico-backend`는 여전히 private이며, 공개 전환은 사용자 결정이다.
- Vercel GitHub 연결, 조직/App 권한, 환경변수 등록, 실제 배포와 URL 검증은 사용자가 계정에서 수행해야 한다.
- 원격 Supabase migration/SQL 적용, getMe의 실제 hosted 통합, 나머지 제품 API, 실제 AI worker와 운영 배포는 완료되지 않았다.

## 다음 작업 순서

에이전트 로컬 작업은 인증 기반 읽기 API를 작은 수직 슬라이스로 계속 구현한다. 사용자 실습은 원격 schema 적용 여부 확인 → getMe 실제 토큰/RLS 검증 → 새 배포 검증 순서로 분리한다. 최종 5종 명칭 확정 뒤 seed·코드 변경을 별도 수행한다.

이 문서 작성 자체로 원격 상태나 코드·SQL은 변경하지 않았다.
## 이전 Resume verification (getMe 구현 전 체크포인트)

- `gh repo view MAFICO-Project/mafico-backend --json visibility,url` confirmed `PRIVATE` at `https://github.com/MAFICO-Project/mafico-backend`.
- `backend/npm test` PASS: 10/10 tests, exit 0.
- `backend/npm run test:schema` PASS: OpenAPI 36 paths; three migrations executed; SQL assertions and embedded PostgreSQL passed. Hosted Supabase Auth/Storage integration was not tested.
- 당시에는 documentation-only refresh였으며 backend code, SQL, deployment lab은 변경하지 않았다. 이후 본 문서 상단에 기록한 getMe 로컬 구현이 추가됐다.

## getMe 구현 후 검증 (2026-09-28)

- `backend/npm test` PASS: 20/20, exit 0.
- `backend/npm run test:schema` PASS: OpenAPI 36 paths, migration 3개, SQL assertions, embedded PostgreSQL.
- OpenAPI 구현 상태: getMe 1개 `implemented-local`, 나머지 49개 `planned`.
- SQL·migration·원격 Supabase·Vercel 배포는 변경하거나 실행하지 않았다.
