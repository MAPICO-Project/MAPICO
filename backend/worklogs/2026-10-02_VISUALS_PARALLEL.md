# 시각자료 병렬 작업 — 2026-10-02

사용자 승인: 이 세션은 시각자료, 옆 세션은 모노레포·README/CI·Swagger·백엔드 상태·테스트·푸시를 담당한다. 사용자 최종 내용·표현 검토는 별도다. 메인 포함 동시 작업자 최대 4명, 재위임 금지.

공통 입력: AGENTS.md, worklogs/PARALLEL_WORK_RULES.md, deliverables/product/PRD.md, records/decisions/DECISIONS.md, 최신 G별 결과, backend/coverage/implementation.json. 과거 문서의 구현 예정 표현보다 최신 증거를 우선하되 로컬 구현과 hosted 검증을 구분한다.

## 작업 카드

| ID | 목적 | 입력/참조 | 출력·완료 기준 | 소유 파일 | 상태 |
|---|---|---|---|---|---|
| V1 | 사용자 흐름 | design/USER_FLOWS.md, PRD, G1~G8 결과 | 온보딩·등록·추천·OOTD·피드·따라입기 및 실패/빈 결과/건너뛰기 Mermaid, 기능 ID·근거 | deliverables/visuals/USER_FLOWS.md | done |
| V2 | 시스템 구조 | backend/API_DESIGN.md, DB_DESIGN.md, AI_ARCHITECTURE.md, backend/README.md 및 구현 | 구성·인증·Storage·비동기 작업 시퀀스, 구현/연동/제안 경계 | deliverables/visuals/ARCHITECTURE.md | done |
| V3 | 기능 연결 | PRD, OpenAPI, coverage registry | 모든 PRD 기능 ID→화면→operationId 매핑과 상태, API 없는 기능 명시 | deliverables/visuals/FEATURE_MAP.md | done |
| V0 | 통합·검증 | V1~V3 산출물 | 브라우저 검토본·Mermaid 파싱/렌더·링크 및 상태 검증, 결과 인계 | deliverables/visuals/README.md, index.html, build.mjs, assets/**; 이 작업 기록 | done |

- 공통 금지: 다른 담당자의 파일, 기존 design/·backend/·apps/·README/CI 수정, 원격 변경, 커밋·푸시. V0의 파일 경로는 deliverables/visuals/ 아래다.
- 선행조건: V1~V3은 카드 등록 후 독립 실행. V0 통합은 결과 수신 후 수행.
- 모델 실제 ID: 하위 작업자 실행 metadata에서 확인 가능한 값만 기록. 미확인 시 미확인으로 남김.
- 비용 관측: 미측정.
- 각 hand-off: 변경 파일, 검증 명령·결과, 미결 사항, 다음 행동. 사용자 검토 완료를 에이전트가 대신 선언하지 않는다.

## Swagger 인계

apps/api-docs/에는 Swagger UI와 동기화 도구가 이미 존재한다. 해당 파일은 옆 세션 소유로 유지한다. README의 정본 설명(backend/docs/openapi.yaml)은 AGENTS.md의 정본(deliverables/backend/openapi.yaml)과 달라 옆 세션에서 정리할 항목이다. 이 세션은 발견 사항만 인계하며 수정하지 않는다.

## 작업 중 경로 변경과 통합

위 카드의 입력 경로는 작업 시작 시점 기록이다. 옆 세션이 문서와 작업 기록을 backend/ 아래로 이동했다. 이 작업 기록 자체도 backend/worklogs/로 이동되어 기존 파일을 이어 갱신한다. 시각자료는 deliverables/visuals/에서 유지했다.

- 현재 PRD: backend/docs/product/PRD.md; 설계: backend/docs/design/ 및 backend/docs/; 결정: backend/records/decisions/; 결과: backend/worklogs/.
- 현재 Swagger: backend/docs/swagger-ui/. OpenAPI는 backend/docs/openapi.yaml. 이전 정본 경로 불일치는 새 구조로 재평가해야 하며 옛 경로로 복구하지 않았다.
- 루트 README가 FE/AI 팀의 폴더 선택을 열어두므로 그림의 apps/·ai/ 고정 위치 표기를 제거했다.
- 하위 에이전트 visual_flows, visual_architecture, visual_features 결과 회수 및 소유권 해제 완료. 도구 응답에는 실제 모델 ID/비용이 없어 미확인·미측정 유지.

## 검증 결과

- node deliverables/visuals/build.mjs: 문서 3개, Mermaid 11개 파싱 및 SVG 렌더 성공.
- PRD 32개 기능 ID와 기능맵 32행 순서·누락·중복 대조 통과. OpenAPI 50개 operationId 전수 포함, registry implemented-local 49개 확인.
- Markdown 상대 링크 63개 존재 확인.
- Edge headless에서 file URL로 열람: SVG 11개, page error 0, 외부 HTTP 요청 0.
- 390px 모바일 화면에서 문서 전체 가로 넘침 없음(390/390). 넓은 그림·표는 자체 가로 스크롤.
- 데스크톱·모바일 스크린샷 확인. 전체 여정은 세로 구성으로 보정하고 한글 단어 줄바꿈과 도식 원래 글자 크기를 보존했다.
- 최종 재생성 후 11개 SVG·63개 링크·모바일 390/390·브라우저 오류 0 재확인. git diff --check 통과. 모든 카드의 산출물을 메인이 회수·확인하고 파일 소유권을 해제했다.
- 백엔드 테스트는 이번 범위에서 재실행하지 않았다. 서버·Swagger·CI·원격·커밋·푸시 변경 없음.

## 인계

검토 시작점: deliverables/visuals/index.html. Mermaid 원본은 USER_FLOWS.md, ARCHITECTURE.md, FEATURE_MAP.md. 생성 도구는 build.mjs, SVG 11개는 assets/. 브라우저 열람은 의존성 없이 가능하며 재생성은 backend/.artifacts/design-validation의 기존 도구와 Edge가 필요하다. 검증 도구도 작업 도중 이동되어 생성 스크립트를 새 위치로 맞췄다.

사용자 내용·표현 최종 검토 대기. 옆 세션에서는 시각자료를 별도 커밋 대상으로 취급하고 변경된 디렉터리 구조에 맞는 링크를 유지한다. 이 기록은 옆 세션에 직접 메시지를 보냈다는 뜻이 아니며 공유 파일 기반 인계다.

최종 확인: `.git/info/exclude:15`의 `/deliverables/` 규칙 때문에 이 시각자료는 현재 Git 상태 목록에서 제외된다. 파일은 로컬에 존재한다. 이 세션은 해당 제외 규칙을 변경하거나 `git add -f`로 우회하지 않았다. 옆 세션에서 별도 커밋 전 저장 위치/추적 범위를 정리해야 한다.

## 추가 요청: 검토 수정·ERD·이미지 공유·커밋 및 푸시

사용자가 SVG/PNG 공유, ERD 추가 및 수정, 완료 후 커밋·푸시를 요청했다. 이전의 로컬 전용/커밋 미실행 상태는 이 후속 요청으로 변경된다.

- 로그인 후 온보딩 완료 사용자의 홈 이동을 추가하고 부분 성공 보완을 배치 전체 실패와 분리했다.
- 12개 migration을 일회용 PGlite에 적용하고 실제 카탈로그에서 public 24개 테이블과 FK 44개를 조회했다. 원격 DB 접근 없음.
- 기존 ERD에는 스냅샷 대상 의류·미디어 ID가 FK처럼 연결돼 있었지만 실제 제약은 없다. 새 ERD는 실제 FK와 논리적 스냅샷 참조를 분리했다. 기존 backend/docs/ERD.md는 다른 세션 범위이므로 수정하지 않았다.
- DB 전체 흐름 1개와 도메인 ERD 4개를 추가해 총 16개 도식. 표시는 주요 PK·FK·업무 필드이며 모든 컬럼을 나열한 데이터 사전은 아니다.
- 공유용 PNG 16개와 SVG 16개에 한글 번호·제목·검토 상태·주의사항을 포함했다. PNG는 2배 해상도이며 내보내기 단계에서 도식 경계가 이미지 내부에 있는지 확인한다.
- 의존성 package.json/lockfile과 브라우저 대체 실행을 추가하여 로컬 숨김 도구 폴더 없이도 설치 후 재생성 가능하게 했다.
- 명시적 커밋 요청에 따라 로컬 exclude의 /deliverables/ 전체 제외를 /deliverables/* 및 visuals 예외로 좁혔다. 다른 산출물은 계속 제외하며 force add는 사용하지 않는다.
- 새 package-lock으로 npm ci 후 npm run all(ERD→Mermaid→PNG/SVG) 통과. 문서 4개·도식 16개, 공유 PNG/SVG 각 16개, 링크 73개 존재, 390px 모바일 전체 넘침 없음, 브라우저 오류 0 확인.
- PNG ZIP 약 3.8MB, SVG ZIP 약 0.19MB. ZIP 엔트리 각 16개 확인. PNG는 최소 폭 1,920px이며 제목·주의 문구·도식 전체를 포함한다.
- 사용자 추가 지시: 카카오톡 조작 금지. 카카오톡 창 제어·메시지 전송은 수행하지 않았다. 로컬 파일 생성과 명시적으로 요청된 Git 커밋·푸시만 진행한다.
