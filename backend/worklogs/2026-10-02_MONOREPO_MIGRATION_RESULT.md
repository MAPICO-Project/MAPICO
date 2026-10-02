# MAFICO 모노레포 전환 결과

날짜: 2026-10-02

## 결과

- 기존 `MAFICO-Project/mafico-backend`를 `MAFICO-Project/mafico`로 이름 변경했습니다.
- 백엔드 G1~G8 변경을 먼저 `df01eac`으로 커밋·푸시해 복구점을 만들었습니다.
- 기존 백엔드 Git 이력을 유지한 채 저장소 루트를 프로젝트 루트로 승격하고 백엔드 파일을 `backend/`로 이동했습니다.
- 루트와 백엔드의 중첩 Git 경계를 제거했습니다.
- 파트별 README, 팀 온보딩, Pull Request 템플릿, backend 경로 기반 GitHub Actions를 추가했습니다.
- 팀 공유 Swagger UI를 `apps/api-docs/`에 추가했습니다.
- 원격 Supabase DB, 배포 환경변수, 비밀값은 변경하지 않았습니다.

## 검증

- backend unit: 98/98 통과
- schema: OpenAPI 36 paths, migration 12개, SQL assertion 10개 통과
- contract coverage: 50 operations 중 49 implemented-local, 1 planned, valid=true
- seed validator: network/database/SQL 사용 없이 통과
- frontend preview: UI 검증 통과
- Swagger OpenAPI SHA-256 sync: 통과
- Mermaid: 11 blocks browser validation 통과
- Git object fsck: 치명적 오류 없음
- 현재 운영 파일 범위 `git diff --cached --check`: 통과
- 비밀키 형태 스캔: 발견 없음
- Git에 포함된 중첩 `.git`: 없음

과거 문서의 Markdown 강제 줄바꿈과 과거 OpenAPI v0.2 공백은 이력 보존을 위해 일괄 재포맷하지 않았습니다.

## API 감사

- 제품 API 외부 계약 뼈대는 50/50 존재합니다.
- 로컬 구현·계약 테스트는 49/50이며 G9 `requestAccountDeletion`이 남았습니다.
- analysis worker callback의 OpenAPI server path와 실제 route 정합성, mimic callback의 OpenAPI 누락, coverage registry의 `garment_aesthetic_scores` 표기 누락을 후속 정리해야 합니다.
- hosted Supabase, Vercel, 날씨 provider, AI worker E2E는 아직 검증되지 않았습니다.

## 사용자가 직접 해야 하는 설정

1. GitHub에서 팀원에게 비공개 `MAFICO-Project/mafico` 접근 권한을 부여합니다.
2. Vercel backend 프로젝트의 Git 연결을 새 저장소로 확인하고 Root Directory를 `backend`로 설정합니다.
3. Supabase 대상 프로젝트와 기존 schema를 확인한 뒤 migration dry-run과 증분 적용을 진행합니다.
4. Auth Site URL/Redirect URL, Kakao provider, CORS, 배포 환경변수를 설정합니다.
5. 최종 추구미 5종 이름·정의를 확정해 운영 seed migration을 만듭니다.

## 남은 백엔드 예상

- 로컬 50/50과 계약·문서 정합성: 3~5 개발일
- 개발 Supabase·Preview 핵심 흐름 통합까지: 총 5~8 개발일
- 실제 worker·계정 삭제·운영 유사 회귀까지: 총 8~14 개발일

AI 모델 개발, 제품 결정 대기, 기존 원격 schema 충돌 대응은 위 기간과 별도입니다.
