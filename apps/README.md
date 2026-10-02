# 프론트엔드 영역

제품 프론트엔드와 UI 프리뷰를 관리합니다.

## 현재 구성

- `frontend-preview/`: PRD 기반 정적 모바일 웹 프리뷰. fixture만 사용하며 Auth·DB·AI와 연결되지 않았습니다.
- `api-docs/`: OpenAPI 정본을 탐색하는 팀 공유 Swagger UI입니다.
- 실제 제품 프론트엔드는 기술 스택을 확정한 뒤 `apps/frontend/`에 추가하는 것을 권장합니다.

## 연동 기준

- API 계약 정본: `../deliverables/backend/openapi.yaml`
- 테스트 fixture: `../backend/test/fixtures/`
- Supabase 로그인은 프론트엔드에서 수행하고, 백엔드 호출에는 access token을 `Authorization: Bearer`로 전달합니다.
- 브라우저에 server secret, service-role key, AI callback secret을 두지 않습니다.

프론트엔드 PR은 변경 화면, 테스트 방법, 사용한 API operationId, 미연동 fixture를 명시합니다.
