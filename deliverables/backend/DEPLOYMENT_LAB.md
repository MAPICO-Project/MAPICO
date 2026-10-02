# 마피코 Vercel → Supabase 연결 실습

> 상태 갱신 (2026-10-02): 저장소는 비공개 `MAFICO-Project/mafico` 모노레포로 통합됐다. 백엔드 배포의 Root Directory는 `backend`로 설정한다. 아래 계정 설정은 사용자가 직접 확인하며, 비밀값과 원격 SQL은 Git 구조 변경으로 자동 이전되지 않는다.

2026-09-28 확인. 사용자가 직접 실습하기 위한 안내이며 이 문서를 만들면서 계정·요금제·원격 DB·배포를 변경하지 않았다.

## 0. 먼저 이해할 연결 두 가지

### 무료 MVP 권장안 (추가 요청 반영)

- GitHub 조직의 **공개 저장소** + Vercel Hobby + Supabase Free로 비상업적 수업용 데모를 구성한다. 조직이라는 이유로 공개 저장소까지 금지되는 것은 아니다. Hobby는 비상업적 개인 용도로 제한되므로 MVP라는 이름만으로 상업 서비스가 허용되지는 않는다. [Git 제한](https://vercel.com/docs/git) · [Hobby 범위](https://vercel.com/docs/plans/hobby)
- 공개 전 기존 커밋 이력까지 비밀키·개인정보·비공개 자료를 검사한다. 현재 저장소를 자동 공개하지 않는다. 필요하면 공개 가능한 코드만 새 공개 저장소에 구성한다.
- Vercel 담당자 한 명이 계정/GitHub 연결과 배포를 관리하고, 팀원은 GitHub PR로 협업한다. 공개 저장소의 외부 PR은 Vercel 승인 조건을 따르며 계정·토큰을 공유하지 않는다.
- 무료 인프라에 GPU 모델 상시 운영이 포함되지는 않는다. AI는 개발 PC/허가된 학교 장비에서 검증하고 데모 때 연결하거나, 사전 계산된 결과임을 명시한다. 설명은 초기 규칙 기반 템플릿을 사용하면 유료 LLM 호출 없이 시연할 수 있다. 이는 구현 제안이지 이미 구현된 기능이 아니다.
- 이미지 업로드 크기/개수와 테스트 사용자 수를 제한하고 사용량을 확인한다. Supabase Free는 비활동 프로젝트가 일시 중지될 수 있으므로 발표 전에 상태와 백업을 확인한다. [프로젝트 일시 중지](https://supabase.com/docs/guides/platform/free-project-pausing)
- 무료 범위의 공개 접속 웹/API/DB 검증을 목표로 하며, 전체 AI 서비스의 24시간 가동·2초 추론·무제한 저장은 보장하지 않는다.

```text
[서비스에서 데이터 읽기]
브라우저 → Vercel의 backend API → Supabase HTTPS Data API → Postgres
                               URL + publishable key

[테이블 만들기 / SQL 관리]
Supabase Dashboard SQL Editor → Postgres
또는 로컬 CLI → DB 연결 주소 + DB 비밀번호 → Postgres
```

Vercel은 코드를 실행하고, Supabase는 DB/Auth/Storage를 제공한다. 두 회사 계정을 하나로 합치는 작업이 아니다. 지금 구현된 카탈로그 읽기는 HTTPS API를 사용하므로 DB 연결 문자열이 필요하지 않다. SQL Editor 역시 내 PC의 direct DB DNS 문제와 별개로 이용할 수 있다. [Supabase 연결 방식](https://supabase.com/docs/guides/database/connecting-to-postgres)

## 1. Vercel 계정 연결과 현재 제한

현재 프로젝트는 iscream/backend, 임시 화면은 iscream/mafico-preview. GitHub 코드는 MAFICO-Project/mafico의 비공개 모노레포다.

### 1-1. 개인 계정에 GitHub 연결

1. Vercel 로그인 → 우측 상단 프로필 → Settings → **Authentication**.
2. Login Connections 영역에서 GitHub를 연결한다.
3. 조직 저장소에 접근하는 본인 GitHub 계정을 선택한다. 현재 CLI가 확인한 GitHub 계정은 kimdaeone.
4. 계정 연결과 프로젝트의 Git Repository 연결은 별개다.

근거: [Vercel Account Management](https://vercel.com/docs/accounts#login-methods-and-connections).

### 1-2. 반드시 요금제/저장소 조건 확인

이번 읽기 전용 확인에서 iscream은 **Hobby**였다. 공식 정책상 Hobby는 GitHub 조직의 private repository 배포를 지원하지 않는다. Pro는 커밋 작성자의 팀/프로젝트 접근 권한도 필요하다. 앞선 '로그인 연결만 하면 해결' 안내는 불충분했으며 이 조건을 추가한다. [공식 Git 배포 제한](https://vercel.com/docs/git#deploying-private-git-repositories)

선택지는 사용자/팀이 결정한다:

- 조직 비공개 저장소 유지: 지원되는 Vercel 팀 플랜/권한을 검토. 비용 확인 후 선택, 자동 결제/업그레이드하지 않음.
- 무료 실습: 팀이 공개해도 된다고 승인한 비밀정보 없는 공개 실습 저장소를 별도로 사용하는 방법 검토. 현재 비공개 프로젝트를 임의 공개하지 않음.
- 기존 배포의 endpoint를 활용해 Supabase 연결을 먼저 익히기. 이미 배포된 https://backend-cbv0u73ct-iscream.vercel.app 의 Preview 환경변수는 이전 작업에서 설정했다. 배포 보호가 있다면 본인 Vercel 계정으로 접근한다. 새 빌드 권한 문제는 별도로 해결해야 한다.

커밋 작성자를 타인으로 바꾸거나 Git 메타데이터를 숨겨 제한을 우회하지 않는다.

### 1-3. 조건 해결 후 저장소 연결

Vercel Dashboard → iscream → **backend** → Settings → Git → Connect Git Repository → MAFICO-Project/mafico. 연결 후 Root Directory를 `backend`로 지정한다.

저장소가 목록에 없으면 GitHub의 Vercel GitHub App 설치/권한에서 **해당 저장소만** 허용됐는지 확인한다. OAuth Login Connection과 GitHub App repository access는 다르다. [GitHub 연동 안내](https://vercel.com/docs/git/vercel-for-github)

설정 기준은 현재 저장소 코드다:

- Root Directory: 저장소 루트 `.`. 독립 저장소이므로 `backend`를 또 입력하지 않는다.
- Framework: Other/프레임워크 없음.
- Node: 22.x.
- 별도 빌드 명령 없음, 정적 디렉터리 public/. /api/*.js는 Vercel Node 함수.
- 배포 후 `/api/health`의 JSON 200을 확인한다. readiness는 전체 제품 미완성이므로 503이 정상이다.

## 2. Supabase에서 테이블 준비 — SQL Editor 실습

### 2-1. 대상 확인

1. Supabase Dashboard에서 본인이 실습할 **개발용 프로젝트**를 선택한다. 운영/다른 팀 DB가 아닌지 이름과 project ref를 확인한다.
2. 왼쪽 **SQL Editor → New query**에서 아래 읽기 전용 쿼리를 실행한다.

```sql
select tablename from pg_tables
where schemaname = 'public'
order by tablename;
```

표가 있으면 바로 아래 초기 SQL을 실행하지 말고 기존 스키마/이력을 대조한다. 이 실습은 **아직 public 제품 테이블이 없는 개발 DB**를 전제로 한다. 기존 테이블 삭제/초기화는 하지 않는다. [SQL Editor와 Table Editor](https://supabase.com/docs/guides/database/overview)

### 2-2. 빈 개발 DB에서 준비된 SQL을 순서대로 실행

로컬 backend/supabase/migrations 또는 GitHub 저장소의 같은 경로에서 파일 내용을 확인한다.

1. `202609270001_core.sql`
2. `202609270002_transactions.sql`
3. `202609280001_product.sql`

각 파일 전체를 새 query에 붙여 넣고 실행한다. 앞 파일 성공 확인 후 다음 파일로 넘어간다. 재실행용 SQL이 아니므로 오류가 나면 멈추고 원인을 확인한다. 가능하면 각 파일을 `begin;`과 `commit;`으로 감싸 파일 단위로 적용한다. 파괴적 변경 경고가 보이면 내용을 읽고, 기존 데이터가 있는 DB라면 실행하지 않는다.

이 SQL은 **전체 제품 설계의 개발용 구조**이지 이번 MVP 기능 전부 구현을 뜻하지 않는다. 기존 5종 seed는 페미닌/Y2K/미니멀/그런지/캐주얼이라는 **이전 임시 카탈로그**이며 최신 최종 분류가 아니다. 연결 실습에만 이용하고, 팀의 최종 이름 선정 후 추가 migration으로 교체/버전 관리한다.

### 2-3. 확인

```sql
select count(*) as table_count
from pg_tables where schemaname = 'public';

select code, label, active from public.aesthetics order by code;

select tablename, rowsecurity
from pg_tables where schemaname = 'public' order by tablename;
```

아무 추가 테이블이 없는 시작점이면 22테이블, 이전 임시 카탈로그 5행, 제품 테이블 RLS 활성화를 기대한다. Auth/Storage 시스템 테이블은 public count에 포함하지 않는다. Table Editor에서도 확인한다. RLS를 꺼서 연결 오류를 해결하지 않는다.

**이력 주의:** SQL Editor 실행은 CLI migration history를 자동으로 맞춰주지 않는다. 실행한 파일명·시각을 기록한다. 이후 CLI `db push`를 바로 실행하면 중복 생성 오류가 날 수 있으므로 원격 스키마와 이력을 먼저 대조/동기화한다. 운영·팀 협업은 CLI migration 관리로 전환한다. [환경/마이그레이션 관리](https://supabase.com/docs/guides/deployment/managing-environments)

## 3. URL·키를 Vercel에 넣기

Supabase 프로젝트의 **Connect**에서 Project URL과 publishable key를 확인한다. 키 목록은 **Settings → API Keys**에 있다. [API 키 안내](https://supabase.com/docs/guides/getting-started/api-keys)

Vercel의 **backend 프로젝트 → Settings → Environment Variables**에 아래 두 이름으로 등록/확인한다.

| 이름 | 값 | 현재 코드에서의 역할 |
|---|---|---|
| SUPABASE_URL | https://해당-project-ref.supabase.co | HTTPS API 주소 |
| SUPABASE_PUBLISHABLE_KEY | 해당 프로젝트의 publishable key | 공개 카탈로그의 제한된 읽기 |

이번 서버는 Next.js가 아니므로 이름 앞에 NEXT_PUBLIC_를 붙이지 않는다. 같은 프로젝트 URL·키를 짝지어야 한다. Preview/Production/Development는 별도 적용 범위다. 우선 Preview를 사용하고, 실제 배포가 Production이면 그 범위에도 올바른 개발용 값을 설정해야 한다. 이전 작업은 Preview에만 넣었다.

환경변수 변경은 이미 만들어진 배포에 소급 적용되지 않으므로 새 배포가 필요하다. 위 Git 권한/플랜 문제가 해결된 뒤 Deployments에서 새로 배포하고 **새 배포 URL**로 확인한다. [Vercel 환경변수](https://vercel.com/docs/environment-variables)

publishable key는 RLS/권한 제한과 함께 사용한다. secret/service_role 키는 권한이 강하므로 프론트엔드, Git, 채팅에 넣지 않는다. 이번 공개 카탈로그 확인에는 secret key도 DB 비밀번호도 필요 없다.

## 4. 실제 연결 성공 확인

백엔드 배포 URL에 `/api/aesthetics`를 붙여 브라우저에서 연다.

```json
{
  "data": [{"id":"실제 DB UUID", "code":"casual", "label":"캐주얼"}],
  "source":"supabase"
}
```

위는 형식 예시다. 3개 migration을 그대로 적용한 개발DB는 이전 임시 카탈로그 5개가 반환되어야 한다. 단순히 200만 보지 말고 JSON과 source를 확인한다. 배포 중 안내 HTML의 200은 API 성공이 아니다.

| 관찰 | 의미/다음 확인 |
|---|---|
| health 200 | Vercel 함수 실행 성공만 확인 |
| aesthetics 200 + source=supabase + rows | 해당 배포에서 Supabase 카탈로그 읽기 성공 |
| SUPABASE_NOT_CONFIGURED | 환경변수 이름/Preview vs Production/재배포 확인 |
| DATABASE_SCHEMA_NOT_READY | 테이블 없음, 적용 프로젝트가 다름, 또는 schema cache 반영 상태 확인 |
| SUPABASE_UNAVAILABLE | 키/URL/권한/네트워크/응답형식 확인. 키를 출력하지 말고 안전한 서버 로그 이용 |
| data=[] | 빈 카탈로그, active 필터 또는 RLS 확인. 연결 실패와 구분 |
| Vercel 로그인 HTML | Deployment Protection. 본인 계정으로 접근, 보안 해제는 별도 결정 |
| readiness 503 | 전체 제품 미구현 상태 표시. 이 실습만으로 200으로 바꾸지 않음 |

임시 프론트 mafico-preview.vercel.app은 fixture만 사용하므로 위 연결이 성공해도 화면이 자동으로 실제 DB 데이터로 바뀌지는 않는다. 현재 실습 완료 기준은 **backend API → Supabase 실제 조회**까지다.

## 5. 나중에 CLI로 DB를 관리하려면

Supabase **Connect → Session pooler**에서 정확한 Host, Port, Database, User를 확인한다. IPv4 환경에서는 session pooler가 direct IPv6 연결의 대안이 될 수 있다. 호스트의 aws index를 추측하지 말고 표시된 값을 사용한다. [연결 문서](https://supabase.com/docs/guides/database/connecting-to-postgres)

- DB 비밀번호: Postgres 로그인용.
- publishable/secret API key: Data API용. DB 비밀번호 대신 쓸 수 없음.
- Supabase personal access token: CLI/Management API 계정 인증용. 위 API 키와 다름.

SQL Editor 실습에는 pooler 설정이 필수가 아니다. 이미 수동 적용했다면 추후 CLI 도입 전에 이력을 정합화한다.

## 실습 체크리스트

- [ ] Vercel Authentication에서 본인 GitHub 연결 확인
- [ ] Hobby + 조직 private repo 제한에 대한 팀 선택 확정
- [ ] backend 프로젝트 Root Directory는 . 확인
- [ ] 개발 DB의 기존 테이블 확인, 초기 SQL 적용 여부 기록
- [ ] URL/publishable key를 올바른 Vercel 배포 환경에 등록
- [ ] backend /api/aesthetics의 JSON을 Table Editor 내용과 비교
- [ ] 실제 제품 기능/AI 연결과 구분하여 실습 결과 기록
