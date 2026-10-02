# 무료 MVP 배포 경로 검토

확인일: 2026-09-28. 공식 문서 읽기만 수행했다. 원격 설정 변경, 저장소 공개 전환, 배포를 실행하지 않았고 자격증명 파일을 읽지 않았다. 현재 `iscream` Hobby와 조직의 비공개 `mafico-backend` 조합이 차단됐다는 상태는 상위 작업에서 전달받은 사실이며 이 검토에서 계정을 재조회하지 않았다.

## 판단

**비상업적 학습·시연 용도라면 Vercel Hobby + Supabase Free + 기존 PC의 AI worker 조합이 무료 MVP 후보**다. 다만 현재의 GitHub 조직 비공개 저장소→Hobby 직접 연결은 지원되지 않는다. 공식 문서는 공개 저장소로 변경하거나 Pro를 사용하는 경로를 안내한다. 공개 전환은 코드와 Git 이력 공개를 수반하므로 별도 사용자 선택이며 이 문서는 전환을 승인하거나 실행하지 않는다. [Vercel Git 배포 문서](https://vercel.com/docs/git)

## 조직 공개 저장소를 선택할 때의 조건

| 항목 | 확인 내용 |
|---|---|
| 공개 협업 | 공식 협업 문서는 공개 저장소 협업이 무료라고 명시한다. 비공개 저장소의 Hobby 소유자 commit 제한을 공개 저장소 전체에 그대로 적용해 “다른 팀원 커밋은 전부 불가”라고 단정하면 안 된다. |
| 포크 PR | 공개 저장소라도 외부 포크에서 들어온 PR 배포에는 승인 링크가 필요할 수 있다. 작성자가 Vercel 팀 구성원이면 해당 승인이 생략될 수 있다. |
| Git 연결 | Hobby 소유자의 실제 GitHub 계정을 Vercel Login Connections에 연결한다. 실제 작성자와 커밋 이메일의 계정 귀속을 확인하며, 배포 제한을 피하려고 작성자를 위조하거나 `.git`을 제거하지 않는다. |
| 조직 import 권한 | 조직 Owner 또는 저장소 접근권을 가진 Member여야 한다. Outside Collaborator만으로는 Vercel import/connect가 불가능하다. |
| GitHub App | Vercel GitHub 연동이 대상 조직·저장소에 접근하도록 설치/권한이 설정돼 있어야 한다. 공개로 바꾼 것만으로 연결이 완료되는 것은 아니다. |
| 배포 검증 | 연결 후 작은 변경의 preview·production 동작과 외부 PR 승인 흐름을 실제 검증한다. 현재 계정에서의 성공을 보장한 상태는 아니다. |

공개 협업 및 작성자 연결 기준은 [프로젝트 협업 문제 해결](https://vercel.com/docs/deployments/troubleshoot-project-collaboration), 공개 포크 승인은 [Git 배포 문서](https://vercel.com/docs/git), 조직 권한과 GitHub 연동은 [Vercel for GitHub](https://vercel.com/docs/git/vercel-for-github)를 근거로 했다.

Hobby는 **비상업적 개인 사용**으로 제한된다. 학습 데모라는 현재 목적을 기준으로 검토하되, 학교 팀이라는 이유만으로 어떤 사용도 자동 허용된다고 해석하지 않는다. 유료 서비스·광고·제휴 수익 운영으로 전환할 때는 플랜 적합성을 다시 확인한다. 사용량 초과 시 일부 기능은 재사용까지 대기해야 할 수 있어 상시 서비스 보장을 기대하면 안 된다. [Hobby 공식 안내](https://vercel.com/docs/plans/hobby)

## 가능한 경로 비교

| 경로 | 현재 적합성 | 비용/결정 |
|---|---|---|
| 조직 public + Hobby | 공식 문서가 제시하는 무료 Git 연동 후보 | 코드/이력 공개에 대한 사용자 결정, 조직/App 권한 확인 필요 |
| 조직 private 유지 + Pro | 비공개 팀 협업을 유지하는 정식 경로 | 유료이므로 이번 무료안에는 미포함 |
| 개인 소유 저장소 + Hobby | 개인 프로젝트 경로는 검토 가능 | 소유권·동기화 구조가 달라져 단순 우회로 취급하지 않음. 자동 생성/이전하지 않음 |
| 현재 코드로 로컬 데모 | 원격 Git 제한과 무관하게 개발·시연 준비 가능 | PC 가동 필요, 공개 URL 상시 운영과는 다름 |

무료를 우선하되 원본 비공개를 유지해야 한다면, 공개 전환을 서두르기보다 로컬 데모를 유지한 채 공개 가능한 코드 범위와 호스팅 선택을 결정하는 편이 낫다. CLI 배포가 조직 비공개 제한을 항상 우회한다는 가정은 하지 않는다.

## Supabase Free 범위

공식 과금 표 기준 Free는 활성 프로젝트 2개, 프로젝트당 DB 500MB, Storage 1GB, egress 5GB, 월간 활성 사용자 50,000을 제공한다. 일부 한도는 조직 단위로 합산되므로 프로젝트를 나누면 모든 한도가 배가되는 것으로 계산하지 않는다. Free에는 Storage 이미지 변환이 포함되지 않는다. [Supabase 과금·한도](https://supabase.com/docs/guides/platform/billing-on-supabase)

의류 사진은 사용자 수보다 먼저 저장·전송 한도에 도달할 수 있다. 원본·누끼·피드 복제본을 모두 산정하고, 업로드 전 해상도 축소·썸네일 사전 생성·중복 제거와 삭제 작업을 구현한다. 예를 들어 원본 2MB에 파생파일 합계 1MB라는 가정이면 한 등록당 3MB가 소모된다. 이는 제품 실측이 아니라 용량 계획 예시다.

Free 프로젝트는 최근 7일 활동이 적으면 일시중지될 수 있다. 공식 문서는 중지 후 복구 절차를 제공하지만 발표 직전 자동 가용성을 보장하지 않는다. 데모 전 Dashboard 상태와 로그인/DB/Storage 실동작을 확인하고 필요한 데이터와 마이그레이션을 별도로 보관한다. [Free 프로젝트 일시중지 안내](https://supabase.com/docs/guides/platform/free-project-pausing)

## AI를 포함한 무료 데모 구성

```text
모바일 웹 → Vercel: 화면·JWT 검증·가벼운 API
         → Supabase: Auth·DB·비공개 Storage·분석 Job
기존 PC AI worker → 인증된 서버 경유로 Job 수신 → 이미지 분석 → 결과 callback
```

이는 권장 구성안이며 worker가 구현·배포됐다는 뜻이 아니다. 기존 GPU/PC로 분석하면 추가 호스팅 비용을 줄일 수 있지만 PC가 꺼지면 분석도 멈춘다. 데모 중 worker 상태 표시, 타임아웃·실패 메시지·재시도가 필요하다. 사전 계산 결과로 시연한다면 화면에 데모 데이터임을 표시하고 실시간 AI 처리 성공으로 보고하지 않는다. LLM은 별도 API 비용이 발생할 수 있어 무료 데모에서는 템플릿 설명을 기본으로 두고 모델 호출은 명시적 선택으로 둔다.

Vercel Function의 요청·응답 payload 상한은4.5MB다. 사진은 함수가 중계하지 않고 signed URL로 Storage에 직접 업로드한다. [Vercel Functions 제한](https://vercel.com/docs/functions/limitations)

Supabase Edge Functions는 메모리256MB·요청당 CPU2초 제한이 있다. 이를 YOLO/SAM GPU 서버로 간주하지 않고 인증·작업 중계에 사용한다. AI 실행 장비와 worker는 별도로 필요하다. [Supabase Edge Functions 제한](https://supabase.com/docs/guides/functions/limits)

## 다음 결정 순서

1. 현재 단계가 비상업적 데모임을 기준으로 무료 운영 범위를 정한다.
2. 조직 저장소 공개 여부를 사용자가 결정한다. 검토 문서만으로 전환하지 않는다.
3. 선택한 경로에서 GitHub 계정 연결·조직 역할·Vercel App 접근권을 확인한다.
4. 작은 HTTP 배포를 검증한 다음 Supabase 인증·DB·이미지 저장을 붙인다.
5. 로컬 AI worker를 시연 시간에 연결하고, 상시 AI가 필요해질 때 별도 운영 비용을 산정한다.

이 문서 작성으로 바뀐 원격 상태는 없다. 무료 배포 후보와 제한 조건만 정리했다.
