# MAFICO 데모 앱 (데모용, 제품 코드 아님)

백엔드가 [유저플로우](../backend/docs/design/USER_FLOWS.md)대로 어떻게 동작하는지 보여 주는 Flutter 예시 앱이다. 디자인과 최종 화면은 프론트 팀이 만든다.
API는 [openapi.yaml](../backend/docs/openapi.yaml) 계약을 그대로 호출한다. PM 협의 중인 항목은 화면에 노란 **제안** 배지를 단다([PM 협의 안건](../backend/worklogs/2026-10-10_PM_협의안건.md)).
계획과 계약 문제 기록: [2026-10-11 데모앱 PLAN](../backend/worklogs/2026-10-11_데모앱_PLAN.md).

## 실행 (Windows, 터미널 3개)

준비: Node 22, Python + Pillow(가짜 worker의 이미지 자르기), Flutter SDK(`~/dev/flutter` 또는 PATH), Chrome. 키는 저장소 밖 `../_key/`에서 읽고 출력하지 않는다.

```bash
# 1) 로컬 백엔드(원격 Supabase에 붙음). 날씨: --weather kma|fake|down
npm --prefix backend/tools ci
node backend/tools/dev-server.mjs

# 2) 가짜 AI worker(분석 job을 기다렸다가 처리). 모드는 앱의 "데모 제어" 패널로 바꾼다.
node backend/tools/fake-ai-worker.mjs --watch

# 3) 앱(Chrome, http://localhost:5173 — dev 서버 CORS 허용 origin과 같아야 함)
node demo-app/run-demo.mjs
```

데모 계정이 없으면 한 번만 `node backend/tools/demo-seed.mjs --password <비밀번호>`로 만든다(계정 생성 + 준비된 옷장·OOTD·피드를 API로 채움). 비밀번호는 저장소에 적지 않는다.

| 계정 | 용도 |
|---|---|
| `new@mafico.dev` | 신규 회원: 온보딩·고지·첫 옷 등록 |
| `demo@mafico.dev` | 준비된 옷장: 홈 추천·캘린더·통계 |
| `friend@mafico.dev` | 피드 작성자: 따라입기 대상 포스트 |

## 시연 순서 (PM 협의용)

1. **진입·온보딩** (`new@`): 로그인 → "추구미를 아나요?" 예(직접 선택 메인1+보조0~2) / 아니오(무드보드 3~6장 → 분석 → 동점이면 Tie-break) → 결과 수정/시작 → 외부 AI 전송 고지(학습 동의 선택) → 원샷 등록 안내 → 홈
2. **옷 등록**: 옷장 + → 촬영 가이드 → 앨범/촬영 → 분석 중 → 검토(카테고리 수정·비고, 한 벌 빼고 저장, 원피스=카테고리 직접 선택) → 저장. 데모 제어로 `fail` → 분석 실패 → 다시 시도. 고지 미동의면 403 `AI_NOTICE_REQUIRED` → 고지 화면 → 동의 후 자동 재시도
3. **홈** (`demo@`): 날씨(위치 거절 → 시·도 선택, 오래된 날씨 배지) → 추구미 Chip → 추천 1/3~3/3(부족 사유) → 보관함 저장 / 스타일 믹스 / 오늘 입기 → OOTD 상세
4. **스타일 믹스·캘린더**: 월별 캘린더(대표 사진 + 건수) → 날짜 → OOTD 상세(공유·수정·삭제) / 없으면 작성 → + 코디 조합 → 보관함 → 통계
5. **소셜 피드**: 필터 → 그리드 → 상세 → 좋아요 → 따라입기(등급, 0%면 옷 등록 유도) → 보관함 저장 → + 포스트 작성(OOTD/갤러리, 아이템 1개 이상 필수)
6. **마이페이지**: 프로필 이미지·닉네임, 추구미 관리, 좋아요한 코디, 내 포스트, 로그아웃, 회원 탈퇴(삭제 범위 안내 — 제안)

각 화면 앱바의 영수증 아이콘은 방금 호출한 API와 응답 코드를 보여 준다.

## 구조

`13. AI CCTV 알람` 앱의 골격(`config / services / providers / screens / widgets`, go_router + riverpod + supabase_flutter)을 참고했다. 그 앱의 키·Firebase·전용 기능은 가져오지 않았다.

| 경로 | 내용 |
|---|---|
| `lib/app.dart` | 라우트 지도(GNB 4탭 shell + 상세 화면), 로그인 가드 |
| `lib/services/api.dart` | 계약 호출, 오류 봉투(`ApiException`), Idempotency-Key, signed 업로드 |
| `lib/providers/` | `/me`, `/aesthetics`, `/garments` 캐시 |
| `lib/screens/<영역>/` | auth · onboarding · home · closet · mix · feed · mypage |
| `run-demo.mjs` | `../_key`에서 Supabase URL·publishable key만 읽어 `--dart-define`으로 실행 |

## 한계

- 로그인은 이메일 테스트 계정이다(카카오는 "설정 필요"). 웹 실행이라 카메라·위치 권한은 브라우저 권한으로 대신한다.
- AI 분석은 가짜 worker가 사진을 격자로 자른 것이다. 실제 검출·배경 제거·분류가 아니며 결과를 모델 성능으로 쓰지 않는다.
- 샘플 이미지(도형 그림)와 무드보드 카드는 시연용이다.
