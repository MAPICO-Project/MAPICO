# Supabase 스키마

정본 migration은 이 디렉터리의 `migrations/`입니다. 파일명 순서대로 적용하며 현재 12개 migration이 24개 public table, RLS/RPC, 비공개 Storage bucket 2개를 정의합니다.

현재 상태는 로컬 embedded PostgreSQL 검증 완료, 원격 hosted Supabase 적용·통합 검증 미완료입니다.

```sh
cd backend
npm ci --ignore-scripts
npm run test:schema
```

테스트의 Auth/Storage 동작은 stub입니다. 실제 Supabase Auth, PostgREST, RLS, Storage signed URL 검증과 같지 않습니다.

원격 적용 전에는 개발 프로젝트 대상과 기존 migration 이력을 읽고, 백업·차이 확인 후 CLI `db push --dry-run`과 증분 적용을 사용합니다. 운영 DB에 `db reset --linked`를 실행하지 않습니다. 로컬 연결 txt, `.env`, CLI 토큰과 비밀값은 출력하거나 커밋하지 않습니다.

SQL은 사용자 데이터 경계와 작업 상태를 제공하지만 Kakao OAuth 설정, AI worker 실행, 날씨 provider, Storage 객체 정리, Vercel 환경변수를 대신하지 않습니다. 제품 API 49개는 로컬 구현됐고 계정 삭제 1개 및 실제 hosted 통합은 후속입니다.
