# 마피코 시각자료 검토본

2026-10-02 기준. 사용자 내용·표현 최종 검토 전입니다.

[2026-10-09 시각자료·백엔드 현황 리포트](REPORT_2026-10-09.md)

[브라우저 검토본 열기](index.html) — 파일을 브라우저에서 직접 열 수 있으며 열람에 서버·CDN·로그인이 필요하지 않습니다. 큰 그림은 각 도식의 **크게 보기 / SVG** 링크로 열고 확대하거나 저장합니다. 모바일에서는 넓은 그림과 표를 가로 스크롤할 수 있습니다.

## 구성

| 문서 | 검토할 내용 |
|---|---|
| [유저플로우](USER_FLOWS.md) | 첫 사용·건너뛰기·등록·추천·OOTD·공유·따라입기 및 실패/빈 결과 분기 |
| [아키텍처](ARCHITECTURE.md) | 웹·백엔드·Auth/DB/Storage·AI의 책임과 인증·비동기 작업 경계 |
| [기능맵](FEATURE_MAP.md) | PRD 기능 ID와 화면·API의 대응, UI 요구와 백엔드 구현의 차이 |
| [DB 흐름과 ERD](ERD.md) | 실제 migration의 24개 테이블, 도메인별 PK·FK 및 스냅샷 참조 차이 |

## 채팅방 공유

[PNG 묶음](마피코_공유용_PNG.zip) · [SVG 묶음](마피코_공유용_SVG.zip) · [개별 파일 안내](share/README.md)

각 묶음은 16장입니다. 채팅방에는 PNG를 이미지로 올리고, 확대·편집이 필요하면 SVG를 파일로 전달합니다. 제목과 검토 상태가 이미지에 포함돼 있습니다. 그림은 사용자 검토본이며 확정된 화면 설계나 배포 완료 증거가 아닙니다.

## 읽는 기준

- 제품 요구사항과 구현 증거는 다릅니다. `implemented-local`은 해당 백엔드의 로컬 구현 상태이며 화면 완성·실제 AI 추론·배포 검증을 뜻하지 않습니다.
- 최신 결과 기록과 구현 registry를 참고합니다. 기존 design/AI 문서의 오래된 ‘전체 구현 예정’ 설명은 그대로 복제하지 않습니다.
- 추구미 5종의 최종 명칭, TPO 추천 반영, 하루 OOTD 수, `wear_status` 등 미결 정책은 구현상 임시 계약과 구분합니다.
- 그림에서 새로 제안한 정책을 확정하지 않습니다. 제품 결정 정본은 [PRD](../../backend/docs/product/PRD.md)와 [결정 기록](../../backend/records/decisions/DECISIONS.md)입니다. 기존 [유저플로우](../../backend/docs/design/USER_FLOWS.md)를 대체하는 정책 승인 문서가 아닙니다.

## 수정·재생성

USER_FLOWS.md, ARCHITECTURE.md, FEATURE_MAP.md의 Mermaid를 편집합니다. ERD.md는 migration에서 자동 생성하므로 직접 수정하지 않고 generate-erd.mjs를 수정합니다. HTML·SVG·PNG는 생성 결과입니다. 새 환경에서는 저장소 루트에서:

```powershell
npm --prefix backend ci --ignore-scripts
npm --prefix deliverables/visuals ci --ignore-scripts
cd deliverables/visuals
npx playwright install chromium
npm run all
```

package.json과 lockfile에 생성 도구 버전을 고정했습니다. Edge가 있으면 사용하고 없으면 설치한 Chromium으로 렌더합니다. 로컬 패키지가 없을 때만 기존 backend/.artifacts/design-validation 도구를 보조 경로로 사용합니다. ERD 생성은 일회용 PGlite에 migration을 적용하며 실제 DB에 접근하지 않습니다. 생성 결과 열람에는 Node나 브라우저 자동화 도구가 필요하지 않습니다.

ZIP 재생성은 이 폴더에서 `Compress-Archive -Path share/PNG/* -DestinationPath 마피코_공유용_PNG.zip -Force`와 SVG에 대한 동일 명령으로 수행합니다.

## Swagger와 파일 소유권

[Swagger UI 안내](../../backend/docs/swagger-ui/README.md)는 옆 세션 담당입니다. 작업 도중 Swagger는 `apps/api-docs/`에서 `backend/docs/swagger-ui/`로 이동했습니다. 이 작업은 Swagger, OpenAPI, 백엔드 코드, CI, 루트 README를 변경하지 않습니다. 별도 서버로 띄우는 Swagger 앱과 파일로 여는 이 시각자료 검토본은 서로 독립적입니다.

초기 Swagger README와 AGENTS.md의 정본 경로 불일치는 이후 옆 세션의 문서 이동으로 상황이 바뀌었습니다. 현재 API 문서는 `backend/docs/openapi.yaml`에 있고 이 검토본의 근거 링크도 새 위치로 맞췄습니다. 경로 변경과 검증 결과는 [작업 기록](../../backend/worklogs/2026-10-02_VISUALS_PARALLEL.md)에 남깁니다. 이 폴더에 API 명세 사본을 새로 만들지 않습니다.

## 사용자 검토 포인트

1. 온보딩 후 촬영을 나중에 할 수 있는 흐름과 네 탭 이동이 의도에 맞는가?
2. 코디 보관, 날짜별 착용 기록, 피드 공개가 서로 다른 행동으로 이해되는가?
3. AI 결과 수정·실패·후보 부족과 미결 사항의 표현이 적절한가?
4. 팀 설명 자료로 쓰기에 글자 크기와 정보량이 적절한가?

검증 결과와 옆 세션 인계 사항은 [작업 기록](../../backend/worklogs/2026-10-02_VISUALS_PARALLEL.md)에서 확인합니다.
