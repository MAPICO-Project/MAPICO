# 사용자 직접 설정 체크리스트

확인일: 2026-09-28

> 2026-09-29 엄격한 MVP·백엔드 우선 결정 이후의 전체 순서와 신규 작업은 [사용자·에이전트 분리 실행계획](2026-09-29_USER_AGENT_EXECUTION_PLAN.md)을 우선한다. 아래는 기존 계정·배포 실습 체크리스트다.

이 문서는 사용자가 본인 계정에서 직접 확인·설정해야 하는 항목과 저장소에서 이미 준비된 항목을 분리한다. 이 작업에서는 원격 설정, 배포, SQL 실행, 자격증명 확인을 하지 않았다.

## 사용자가 직접 확인할 항목

- [ ] GitHub 조직 공개와 `MAFICO-Project/mafico-backend` 저장소 공개는 별개임을 확인한다. 최신 read-only 확인상 저장소는 아직 `PRIVATE`다.
- [ ] 공개 저장소로 전환할지, private + 유료 플랜을 선택할지 결정한다. 공개 전환 시 코드와 Git 이력이 공개될 수 있다.
- [ ] Vercel Login Connection에 실제 배포 계정의 GitHub 계정을 연결한다.
- [ ] Vercel GitHub App이 대상 조직과 저장소에 접근할 수 있는지 확인한다.
- [ ] Vercel 프로젝트의 저장소, Root Directory `.`, Node 22.x 및 환경변수 범위를 확인한다.
- [ ] Supabase에서 개발 프로젝트와 project ref를 확인하고, 필요한 migration 적용 여부를 사용자가 검토한다.
- [ ] Vercel Preview 환경에 `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`를 등록한 뒤 재배포한다. secret/service role key는 공개 채널이나 저장소에 넣지 않는다.
- [ ] 배포 후 `/api/health`, `/api/aesthetics` 응답과 `source`를 직접 확인한다.

## 저장소에서 준비된 항목

- 배포·Supabase 실습 순서와 제한은 [DEPLOYMENT_LAB.md](../deliverables/backend/DEPLOYMENT_LAB.md)에 정리돼 있다.
- backend에는 health/readiness/catalog/aesthetics 진단 핸들러가 있다.
- 최신 구현 상태 기준 `npm test` 20/20, `npm run test:schema` 통과다. hosted Supabase 통합 완료를 뜻하지 않는다.

## 아직 준비 완료로 간주하지 않는 항목

- readiness 503: 전체 제품 기능이 미완성인 현재 상태의 정상 응답이다.
- catalog: 기존 5종 fixture를 반환하는 진단용 경로이며 최신 추구미 명칭 확정본이 아니다.
- aesthetics: Supabase read 경로는 있으나 원격 schema 적용 완료로 간주하지 않는다.
- 추구미는 개수 5종만 확정됐고 최종 명칭은 미정이다. 기존 seed·문서 명칭 drift는 후속 버전 작업이다.
- 제품 전체 API, 실제 AI worker, 상시 배포와 원격 DB 운영은 구현·검증 완료가 아니다.

## 후속 병렬 계획

1. 사용자: GitHub/Vercel/Supabase 계정·권한·공개 여부를 직접 결정하고 설정한다.
2. backend 담당: 스키마 적용 전후 health/readiness/catalog/aesthetics 계약과 오류 응답을 재검증한다.
3. 제품/데이터 담당: 5종 최종 명칭을 확정한 뒤 문서·seed drift를 별도 변경으로 정리한다.
4. AI/클라이언트 담당: 실제 worker 연결과 모바일 웹 흐름을 구현 범위로 분리해 검증한다.
## Resume verification (2026-09-28)

- GitHub CLI read-only check: `MAFICO-Project/mafico-backend` URL `https://github.com/MAFICO-Project/mafico-backend`, visibility `PRIVATE`.
- Backend `npm test`: PASS, 10/10 tests, exit code 0.
- Backend `npm run test:schema`: PASS, OpenAPI 36 paths; all three migrations executed; SQL assertions and embedded PostgreSQL passed. Supabase Auth/Storage remain stubs, so hosted integration was not tested.
- No Vercel, Supabase, deployment, SQL, or backend source changes were made.
