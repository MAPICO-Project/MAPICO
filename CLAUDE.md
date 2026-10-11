# CLAUDE.md

MAFICO(MyFit:Core 약칭) · 마피코: 보유 의류 등록, 날씨·취향 기반 코디 추천, 착용 기록, 피드·따라입기를 잇는 모바일 앱 AI 패션 서비스(대학 팀 프로젝트).
사람과 AI 에이전트가 함께 읽는 저장소 지도입니다. 프로젝트 소개와 문서 정본 목록은 [README.md](README.md)에 있으며 여기서 반복하지 않습니다.

## 코드 지도

| 경로 | 책임 |
|---|---|
| `backend/` | Vercel 서버리스 API + Supabase(DB·RLS·Storage). 현재 유일한 구현 영역 |
| `backend/supabase/` | 팀 공용 Supabase DB의 정본(migration·SQL 테스트). 프론트·AI도 같은 DB를 쓰지만 스키마 변경은 여기서만 한다 |
| `deliverables/visuals/` | 유저플로우·아키텍처·기능맵·ERD 시각자료와 생성기. 최신 도식의 정본 |
| `deliverables/ai/` | AI 팀 산출물 자리(현재 비어 있음) |
| `demo-app/` | 유저플로우 시연용 Flutter(Web) 데모 앱. **제품 코드 아님**. 로컬 `backend/tools/dev-server.mjs`에 붙는다(실행: `demo-app/README.md`) |
| 프론트엔드·AI 코드 폴더 | 각 팀이 이름·구조를 자유롭게 정해 최상위에 추가. 추가하면 이 표에 한 줄 적기 |

### backend 흐름

- 요청은 `backend/api/**` 파일 경로 = URL 경로(Vercel 규칙). `api/v1/**` 파일은 얇은 진입점이고 `lib/route.js`의 `createRoute`로 메서드 제한·CORS·오류 봉투를 씌운 뒤 `lib/<도메인>.js`의 함수를 호출한다.
- 공통 모듈: `lib/errors.js`(오류 코드·`failure`), `lib/cors.js`, `lib/json-body.js`(본문 크기·키 검증), `lib/auth.js`(Bearer 토큰 파싱), `lib/profile.js`의 `authenticatedUser`(사용자 확인).
- DB 접근은 두 갈래다. 사용자 요청은 `lib/supabase-user.js`(사용자 JWT + publishable key, RLS 적용), 서버 전용 작업은 `lib/supabase-internal.js`(secret key, 허용된 RPC만).
- `api/internal/**`는 AI worker가 결과를 돌려주는 callback이다. 사용자 JWT가 아니라 HMAC 서명(`AI_CALLBACK_HMAC_SECRET`)으로 인증한다.
- `api/health.js`, `api/readiness.js`, `api/catalog.js`, `api/aesthetics.js`는 배포 확인용 비버전 경로(앞의 셋은 `lib/http.js` 사용), 제품 API는 `api/v1/**`.

### X를 바꾸려면

| 바꿀 것 | 볼 곳 |
|---|---|
| 인증·토큰 처리 | `backend/lib/auth.js`, `backend/lib/profile.js`, `backend/lib/supabase-user.js` |
| 날씨 | `backend/lib/weather.js`, `backend/api/v1/weather/current.js` |
| 코디 추천 규칙 | `backend/lib/recommendations.js` (현재 날씨·카테고리 규칙 기반, AI 모델 아님) |
| 피드·좋아요 | `backend/lib/feed.js`, `backend/api/v1/feed/**` |
| 옷 업로드·배치 | `backend/lib/garment-batches.js`, `backend/lib/garments.js` |
| AI 분석 요청·callback | `backend/lib/analysis.js`, `backend/lib/analysis-callback.js` |
| Styling Mimic(따라입기) | `backend/lib/mimic.js`, `backend/lib/mimic-callback.js` |
| DB 스키마·RLS·RPC | `backend/supabase/migrations/`에 새 파일 추가, SQL 테스트는 `backend/supabase/tests/` |
| API 계약 | `backend/docs/openapi.yaml`(정본) 수정 후 `backend/docs/swagger-ui/openapi.yaml` 사본 동기화 |
| 구현 상태 표 | `backend/coverage/implementation.json` + OpenAPI `x-implementation-status` |
| 시각자료 | `deliverables/visuals/*.md`의 Mermaid 수정(ERD.md는 `generate-erd.mjs`로 생성) |

### 경계와 불변조건

- `SUPABASE_SECRET_KEY`, `AI_CALLBACK_HMAC_SECRET`, 날씨 API 키는 서버 환경변수에만 둔다. 브라우저 코드·`NEXT_PUBLIC_*`·응답 본문에 넣지 않는다.
- 이미 공유·적용된 migration 파일은 고치지 않는다. 변경은 새 migration으로 추가한다. 운영 DB에 `db reset --linked`를 실행하지 않는다.
- 개인 옷장 이미지(`garment_assets`)와 공개 피드 이미지(`feed_media`)는 분리한다. 옷장 원본을 공개하지 않는다.
- `implemented-local`은 로컬 테스트 통과만 뜻한다. hosted Supabase·실제 AI worker·프론트엔드 통합 완료로 쓰지 않는다.
- 끝난 계획·기록은 저장소에 남기지 않고 지운다. 필요하면 git 이력(`git log --all -- <경로>`)에서 찾는다.

## 작업 규칙

1. 테스트: `npm --prefix backend ci` 후 `npm --prefix backend test`(단위·계약), `npm --prefix backend run test:schema`(PGlite에 migration 적용 + SQL 테스트). OpenAPI를 바꿨다면 `npm --prefix backend/docs/swagger-ui run sync:check`.
2. 비밀값은 `.env`에만 둔다(커밋 금지, 예시는 `backend/.env.example`). 키 원본 메모는 저장소 밖 `../_key/`에 두며, `backend/tools/*`는 그 위치(또는 `MAFICO_KEY_DIR`)에서 읽는다. 출력·커밋·문서 인용하지 않는다.
3. `backend/records/decisions/DECISIONS.md`에 "(PM 협의)"로 표시된 항목은 우리 안으로 구현했지만 PM 확인 전이다. 문서에는 확정처럼 쓰지 말고 PM 협의 중으로 표시한다(안건: `backend/worklogs/`의 최신 `*_PM_협의안건.md`).
4. 문서는 README 문서 지도의 정본 한 곳만 고친다. 같은 내용의 사본을 새로 만들지 않는다. 정본이 새 판으로 바뀌면 구판은 같은 위치의 `old/`에 `이름_YYYY-MM-DD.md`로 옮기고 맨 위에 "구판 — 정본: 링크" 한 줄을 단다. `old/`는 요청이 없으면 읽거나 근거로 쓰지 않는다.
5. 작업 기록은 `backend/worklogs/`에 남긴다. 형식은 `backend/worklogs/README.md`를 따른다.
6. 최상위 폴더를 추가·이동·삭제하면 위 코드 지도 표를 같은 변경에서 갱신한다.
7. 샘플 데이터·목표 수치를 실제 사용자 결과나 모델 성능으로 쓰지 않는다.

## 병렬 작업

- 여러 사람·에이전트가 동시에 작업할 때 같은 파일을 동시에 수정하지 않는다. 시작 전에 맡을 파일 범위를 나눈다.
- 파트 간 작업은 계약(`backend/docs/openapi.yaml`, migration)을 먼저 맞춘 뒤 병렬로 진행한다.
- 끝나면 서로의 변경을 검토한 뒤 합친다. 남의 완료 보고는 diff와 테스트로 직접 확인한다.

## 이 파일을 고칠 때

- 줄마다 "이 줄을 지우면 사람이나 AI가 실수하는가?"를 묻고, 아니면 넣지 않는다. 200줄을 넘기지 않는다.
- 넣는 것: 추측할 수 없는 명령어, 폴더 책임과 경계, 프로젝트 고유의 결정·함정.
- 넣지 않는 것: 코드를 읽으면 알 수 있는 내용, 파일·함수별 설명, 줄 번호, 자주 바뀌는 진행 현황(현황은 `backend/worklogs/SESSION_HANDOFF.md`).
- 특정 폴더에만 해당하는 규칙이 길어지면 그 폴더에 짧은 `CLAUDE.md`를 따로 둔다.
- 근거: [Claude Code best practices](https://code.claude.com/docs/en/best-practices), [Memory](https://code.claude.com/docs/en/memory), [matklad ARCHITECTURE.md](https://matklad.github.io/2021/02/06/ARCHITECTURE.md.html)
