# 마피코 작업 총정리 — 2026-09-28

## 결론

프로젝트명 마피코 반영, 최신 PRD/회의 자료 정리, 기존 설계 차이 검토, Claude Opus 5.5 독립 검토, Vercel HTTP 임시 배포를 수행했다. **전체 제품 백엔드 완성·Supabase 연동 완료가 아니다.**

## 문서

- `PRD_CURRENT_2026-09-28.md`: 전달 자료 정리, 기능 ID, 회의 방향과 미결 구분.
- `PRD_DELTA_2026-09-28.md`: 이전 API/DB와 최신 제품의 차이.
- `PLATFORM_AND_ROADMAP_2026-09-28.md`: 앱/웹 판단, 병렬 일정 제안, 위험.
- `CLAUDE_REVIEW_2026-09-28.md`: 실제 Opus 5.5 실행 확인 및 검토 반영.
- `../plan/260928_0000_마피코_문서및임시배포.md`: 작업 계획.
- README/AGENTS/DECISIONS: 마피코 이름과 최신 문서 우선순위 반영. 폴더명은 링크 보존을 위해 WeatherCloset 유지.

## 배포 결과

- Vercel CLI 인증 확인 후 새 프로젝트 `iscream/backend` 생성.
- 최초 배포는 Vercel 기본 동작으로 Production 분류되었다. 이는 제품 준비 완료가 아니다.
- 최초 URL: https://backend-kuaoexua7-iscream.vercel.app
- **최신 프리뷰 URL: https://backend-71o0vfi8z-iscream.vercel.app**
- 최신 배포 ID: `dpl_5aq48gYAgWkWfgtwTwrSgrZttQjt`, 상태 READY.
- 프리뷰는 배포 보호가 적용되어 Vercel 로그인이 필요할 수 있다. 원격 검증은 인증된 Vercel CLI로 수행했다. 공개 접근 설정을 해제하지 않았다.
- `apps/backend`만 배포했으며 PRD·사용자 이미지·DB 키·전체 저장소를 배포하지 않았다.
- 정적 공개 디렉터리는 최신 배포에서 `public/`로 한정했다.

| 원격 확인 | 결과 |
|---|---|
| `/` | 200, 제품이 아닌 배포 안내 |
| `/api/health` | 200, productApiImplemented=false |
| `/api/readiness` | 503, 미연동 상태 명시 |
| `/api/catalog` | 200, 5스타일 정적 샘플·DB 미사용 표시 |
| POST `/api/health` | 405, 읽기 전용 |
| `/test/health.test.mjs` | 404, 테스트 파일 비공개 |

## 검증

- 신규 HTTP 핸들러 단위 테스트: 5/5 통과.
- 기존 OpenAPI v0.2: 23개 경로 스키마 검증 통과.
- 기존 SQL 2개: 임베디드 PostgreSQL 실행 및 security.sql 통과.
- 위 SQL 테스트의 Supabase Auth/Storage는 스텁이다. 실제 Supabase 통합 테스트가 아니다.
- 최신 PRD 전체의 API·DB 정합성은 아직 미완료이며 기존 검증 통과가 이를 의미하지 않는다.

## Supabase가 아직 연결되지 않은 이유

- 플러그인 미연결 확인.
- CLI 2.118.0 실행 가능하나 `projects list`는 AccessTokenRequiredError로 실패.
- 마피코 개발용 프로젝트 ref 미제공.
- 원격 DB를 생성·수정하거나 기존 마이그레이션을 적용하지 않았다.

필요한 사용자 조치: Supabase 로그인 또는 플러그인 연결 후 **개발용 프로젝트 이름/ref** 제공. 인증 토큰·DB 비밀번호를 채팅에 붙이지 않는다.

## 제품 해석 및 바로잡은 부분

1. 15종은 구안, 최신 명세는 페미닌/Y2K/미니멀/그런지/캐주얼 5종이다.
2. M0.5는 이전 에이전트의 축소 설계안이지 팀 확정 범위가 아니다. 최신 제품에는 수동 코디·보관함·피드·좋아요·따라입기가 있다.
3. 홈 TPO 칩 삭제와 추천에 TPO 사용 문구가 충돌한다. 삭제 확정 또는 유지로 임의 결정하지 않았다.
4. 네이티브 앱/웹은 자료만으로 확정할 수 없다. 현재는 모바일 웹을 지원할 HTTP 검증용 백엔드를 배포했다. 제품 프론트엔드는 아직 없다.
5. Supabase Auth 대시보드 설정과 버튼만으로 인증 기능 전체가 끝나는 것이 아니다. 리다이렉트·서버 토큰 검증·RLS·실패/탈퇴 처리가 필요하다.
6. 12/7 마감에 맞춘 병렬 일정은 제안이다. 주당 실제 BE 가용시간과 시험 주간을 확인해야 완료 공수를 약속할 수 있다.

## 다음 실행 순서

1. 사용자에게 TPO/추천 시간/코디 기록 정책의 충돌을 먼저 확인하고 팀 질문 문서로 확정.
2. 최신 스키마 증분 설계: saved outfits·OOTD·공개 post 분리, 카탈로그 seed, 사용자 비고, 좋아요.
3. API 계약 갱신 및 보안 테스트 후 Supabase 개발 프로젝트에 적용.
4. 카카오 로그인→선호→옷 등록→코디 보관/착용 기록의 수직 흐름을 기능별 배포.
5. AI/날씨/소셜을 계약에 맞춰 연결하고 실제 사용자·권한·비동기 E2E 테스트.

## 남겨둔 상태

Git commit은 하지 않았다. 기존 전체 작업물이 untracked인 상태를 유지했다. 로그인 정보/비밀키를 문서에 기록하지 않았다. Claude CLI는 사용자 요청 모델 사용을 위해 2.1.278에서 2.1.283으로 업데이트했다.
