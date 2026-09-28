# MyFit:Core · 마피코 백엔드

독립 Git 저장소: https://github.com/MAFICO-Project/mafico-backend (비공개).
모바일 웹 우선. 현재 구현은 배포/연결 검증 단계이며 제품 API 전체 구현이 아닙니다.

## 실제 구현
| 경로 | 동작 |
|---|---|
| / | 배포 안내 |
| /api/health | HTTP 런타임 200, 제품 준비 완료 아님 |
| /api/readiness | 제품 통합 미완료이므로 503 |
| /api/catalog | 정적 5스타일 샘플, DB 아님 |
| /api/aesthetics | Supabase 공개 카탈로그 읽기; 미설정/스키마없음/오류는 503 |

GET/HEAD만 지원합니다. 인증·사용자 쓰기·AI·피드 API는 아직 미구현입니다. docs/openapi.yaml v0.3은 계획 계약이며 36경로/50operation이 모두 배포된 것이 아닙니다.

## 실행/검증
```sh
npm ci --ignore-scripts
npm test
npm run test:schema
```

Node 22. 서버 런타임 외부 의존성 없음. SQL 검증의 Auth/Storage는 스텁이며 실제 Supabase 검증이 아닙니다.

## 배포
Vercel Node Functions, public/ 정적 안내. 환경변수 SUPABASE_URL/SUPABASE_PUBLISHABLE_KEY를 서버 환경에 설정합니다. 카탈로그 읽기는 공개 키만 사용하고 secret/service_role이 필요하지 않습니다.

현재 Vercel 프리뷰: https://backend-cbv0u73ct-iscream.vercel.app
Supabase REST가 프로젝트에 응답하는 것은 확인했으나 스키마는 아직 원격 적용하지 않았습니다. 정확한 DB 연결 대상 확인 후 마이그레이션합니다.

## 구성
api/ HTTP 핸들러 · lib/ 공통 처리 · test/ 단위 테스트 · supabase/ migrations/tests · docs/ 계약 스냅샷 · scripts/ 로컬 스키마 검증.

.gitignore의 .env/.vercel/비밀 txt를 유지하세요. 배포는 이 저장소만 사용하고 상위 워크스페이스를 통째로 올리지 않습니다.
