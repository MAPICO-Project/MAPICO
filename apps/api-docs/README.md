# Mafico API Docs

팀원이 백엔드 API 계약을 검색하고 요청·응답 스키마를 확인할 수 있는 정적 Swagger UI입니다.

## 문서 정본과 동기화

- 정본: `backend/docs/openapi.yaml`
- Swagger UI 배포 사본: `apps/api-docs/openapi.yaml`

API를 변경할 때는 **정본만 먼저 수정**한 뒤 이 디렉터리에서 사본을 갱신합니다.

```powershell
cd apps/api-docs
npm run sync
npm run sync:check
```

`sync:check`는 두 파일의 SHA-256을 비교하며, 사본이 누락되었거나 정본과 다르면 실패합니다. CI에서는 배포 전에 `npm --prefix apps/api-docs run sync:check`를 실행하면 문서 드리프트를 막을 수 있습니다. 사본을 직접 편집하지 마세요.

## 로컬 실행

Node.js만 있으면 별도 패키지 설치 없이 실행할 수 있습니다.

```powershell
cd apps/api-docs
npm start
```

브라우저에서 `http://127.0.0.1:4173`을 엽니다. 다른 포트가 필요하면 PowerShell에서 다음처럼 실행합니다.

```powershell
$env:PORT = "8080"
npm start
```

`index.html`을 파일로 직접 열면 브라우저 보안 정책 때문에 `openapi.yaml` 로딩이 차단될 수 있으므로 로컬 서버를 사용해야 합니다.

## 정적 배포

빌드 단계가 없는 정적 앱입니다. 배포 서비스에서 다음처럼 설정합니다.

| 항목 | 값 |
|---|---|
| Root/Base directory | `apps/api-docs` |
| Build command | 없음 |
| Output/Publish directory | `.` |

GitHub Pages, Netlify, Vercel 같은 정적 호스팅에 `index.html`과 `openapi.yaml`이 함께 배포되면 됩니다. 접근 제한이 필요한 프로젝트라면 호스팅 서비스의 팀 인증 또는 비밀번호 보호를 별도로 적용하세요.

## CDN 의존성

Swagger UI CSS와 JavaScript는 jsDelivr에서 정확한 버전 `swagger-ui-dist@5.33.1`을 받아옵니다. 따라서 문서 페이지를 처음 열 때 인터넷 접속과 CDN 접근이 필요합니다. 사내망·오프라인 배포가 필요하면 해당 파일을 이 앱에 vendoring한 뒤 `index.html`의 경로와 무결성 설정을 함께 변경해야 합니다.

## `Try it out` 주의사항

정본의 서버 주소는 상대 경로 `/api/v1`입니다. 따라서 `Try it out` 요청은 기본적으로 **문서가 열린 호스트의 `/api/v1`**로 전송됩니다.

- Swagger UI와 백엔드를 같은 도메인에서 제공하거나 reverse proxy를 둔 환경에서는 사용할 수 있습니다.
- 문서와 백엔드 도메인이 다르면 백엔드 CORS 허용 목록과 실제 API 서버 주소 설계가 먼저 필요합니다.
- 인증 API는 Supabase access token이 필요합니다. 공유·녹화·화면 캡처 중에는 실제 토큰을 입력하지 마세요.
- 운영 데이터 변경 위험이 있으므로 팀 공용 문서에서는 조회 확인을 우선하고, 쓰기 요청은 개발·스테이징 환경에서만 실행하세요.
- Swagger UI의 인증값 저장은 꺼져 있어 새로고침하면 토큰이 사라집니다.

이 앱에는 API 키, Supabase secret, 사용자 JWT 또는 실제 요청 예시의 개인정보를 저장하지 않습니다.
