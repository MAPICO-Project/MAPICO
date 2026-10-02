# MAFICO Backend API Docs

백엔드 OpenAPI 계약을 검색하고 요청·응답 schema를 확인하는 정적 Swagger UI입니다.

## 정본과 동기화

- 정본: `backend/docs/openapi.yaml`
- Swagger 사본: `backend/docs/swagger-ui/openapi.yaml`

API 계약을 바꾼 뒤 이 디렉터리에서 동기화합니다.

```powershell
cd backend/docs/swagger-ui
npm run sync
npm run sync:check
```

## 로컬 실행

```powershell
cd backend/docs/swagger-ui
npm start
```

브라우저에서 `http://127.0.0.1:4173`을 엽니다. Swagger UI CSS와 JavaScript는 고정된 jsDelivr 버전을 사용하므로 처음 열 때 인터넷 연결이 필요합니다.

## 주의

- 상대 API 주소를 사용하므로 문서와 백엔드가 다른 도메인이면 CORS와 API server URL을 먼저 맞춰야 합니다.
- 인증 API에는 Supabase access token이 필요하지만 화면 공유·녹화 중 실제 토큰을 입력하지 않습니다.
- 쓰기 API의 `Try it out`은 개발·스테이징 환경에서만 사용합니다.
- 이 폴더에는 API key, server secret, 사용자 JWT와 개인정보를 저장하지 않습니다.
