# Supabase 스키마

정본 migration은 이 독립 백엔드 저장소의 migrations/입니다. 202609270001 → 202609270002 → 202609280001 순서이며 총 22 public 테이블을 정의합니다.

현재 상태: 로컬 임베디드 PostgreSQL 검증 완료, 원격 적용 미완료. API 키 연결은 준비됐지만 Postgres 접속 호스트/권한이 추가로 필요합니다.

```sh
npm ci --ignore-scripts
npm run test:schema
```

테스트는 Auth/Storage 스텁을 이용합니다. 실제 Supabase 통합 테스트와 같지 않습니다.

원격 적용 전: 개발용 프로젝트 대상 확인 → 기존 테이블/마이그레이션 이력 읽기 → 백업/차이 확인 → CLI dry-run → 증분 적용 → Auth/RLS/Storage 검증. 운영 DB 초기화 금지. 로컬 사용자 연결 txt/.env를 커밋하거나 CLI 출력에 노출하지 마세요.

SQL만으로 제품 API·AI Worker·카카오 OAuth·스토리지 삭제 작업이 구현되지 않습니다. 보관함/수동 OOTD/피드 등의 쓰기 API는 후속입니다. planned/worn 등 미결 정책은 docs/DB_DESIGN.md 참조.
