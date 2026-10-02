# 구 추구미 명칭 잠정 표시·export 동기화 작업

## 작업 카드

### OPUS-TAXONOMY-REVIEW

ID: OPUS-TAXONOMY-REVIEW  
목적: 최신 PRD·결정 기록과 API/DB 설계의 추구미 taxonomy 표현을 대조해 최소 정정안과 OpenAPI 영향 범위를 판정한다.  
입력/참조: `AGENTS.md`, `worklogs/PARALLEL_WORK_RULES.md`, `deliverables/product/PRD.md`, `records/decisions/DECISIONS.md`, `deliverables/backend/API_DESIGN.md`, `deliverables/backend/DB_DESIGN.md`, 두 `openapi.yaml`.  
출력/완료 기준: 읽기 전용 검토 결과에 수정 필요 문구, OpenAPI 변경 필요 여부, 검증 항목이 명시되고 실행 metadata에서 실제 모델·provider·오류 상태를 확인한다.  
소유 파일: 없음(읽기 전용).  
금지 파일·범위: 모든 파일 수정, 코드·SQL 변경, 원격 DB·배포·GitHub 조작.  
선행조건: 최신 문서와 운영규칙 확인.  
상태: done  
모델 실제 ID: `claude-opus-5-5` (`provider=firstParty`, `is_error=false`)  
비용 관측: USD 1.0894494 (`costBasis=list`; 실제 청구액 확정 아님)

### LUNA-LEGACY-AUDIT

ID: LUNA-LEGACY-AUDIT  
목적: API/DB 문서와 export 사본에서 구 추구미 명칭 및 동기화 대상을 단순 전수검사한다.  
입력/참조: API/DB 설계 정본, `backend/docs/` 사본, 두 `openapi.yaml`, 관련 검증 스크립트.  
출력/완료 기준: 파일별 일치 위치, 정본/사본 차이, 권장 검증 명령을 읽기 전용 보고한다.  
소유 파일: 없음(읽기 전용).  
금지 파일·범위: 모든 파일 수정, 코드·SQL 변경, 원격 조작, 하위 에이전트 재위임.  
선행조건: 작업 카드 작성.  
상태: done  
모델 실제 ID: gpt-5.6-luna  
비용 관측: 미측정

### ASTRA-INTEGRATION

ID: ASTRA-INTEGRATION  
목적: 검토 결과를 반영해 원본문서의 구명칭을 잠정 상태로 정정하고 export를 동기화한 뒤 로컬 검증한다.  
입력/참조: 위 두 읽기 전용 결과와 최신 PRD·결정 기록.  
출력/완료 기준: 필요한 문서·export만 수정, 정본/사본 해시 일치, `npm test`와 `npm run test:schema` 통과, diff 검토 및 카드 종료.  
소유 파일: `deliverables/backend/API_DESIGN.md`, `deliverables/backend/DB_DESIGN.md`, 필요 시 `deliverables/backend/openapi.yaml`, 대응 `backend/docs/` 사본과 `backend/docs/export-manifest.json`, 본 작업 로그.  
금지 파일·범위: 코드·SQL·seed 변경, 원격 DB·배포·GitHub 조작, 비밀값 출력.  
선행조건: OPUS-TAXONOMY-REVIEW 및 LUNA-LEGACY-AUDIT 회수.  
상태: done  
모델 실제 ID: gpt-6-astra  
비용 관측: 미측정

## 결과 및 hand-off

- 변경: API 설계의 추구미 5종을 `개수 확정·명칭/정의 선정 대기`로 정정했다. DB 설계의 현 seed를 이전 임시 카탈로그로 표시하고, 최종 명칭 확정 뒤 별도 migration 대상으로 명시했다.
- export: `node scripts/sync_backend_docs.mjs`로 `backend/docs/API_DESIGN.md`, `DB_DESIGN.md`, `openapi.yaml`, `ERD.md`와 `export-manifest.json`을 동기화했다. OpenAPI와 ERD 내용은 변경되지 않았다.
- Opus 검토: CLI metadata에서 `canonicalModel=claude-opus-5-5`, `provider=firstParty`, `is_error=false`, `terminal_reason=completed`를 확인했다. 세션 ID는 `8813a4d8-f069-4a57-9aaa-e74fb1309a0e`다. 파일 수정 없이 최소 정정 3곳과 OpenAPI 내용 유지 결론을 제시했다.
- Luna 검사: 정본·사본·OpenAPI·검증 코드에서 구명칭 위치와 export 대상을 읽기 전용으로 전수검사했다. 파일 수정과 하위 재위임은 없었다.
- 검증: `npm test` 10/10 통과. `npm run test:schema`에서 OpenAPI 36 paths, migration 3개, SQL assertions, embedded PostgreSQL 통과. hosted Supabase Auth/Storage 검증은 아니다.
- 동기화: openapi/API/DB/ERD의 정본·사본 SHA-256 및 manifest 값이 모두 일치한다. OpenAPI 해시 `5f69ff...7ab03a`, ERD 해시 `a97174...f0705`는 작업 전과 같다.
- 금지 범위 보존: `202609280001_product.sql`, `product.sql`, `api/catalog.js`의 작업 전후 SHA-256이 동일하다. 원격 DB·배포·GitHub·비밀값은 건드리지 않았다.
- 남은 위험: 구 seed와 정적 catalog는 의도적으로 유지했다. 팀이 최종 5종 명칭·정의를 확정하면 별도 migration·코드·테스트 변경이 필요하다.
- 파일 소유권: 모든 카드 종료와 함께 해제한다.
