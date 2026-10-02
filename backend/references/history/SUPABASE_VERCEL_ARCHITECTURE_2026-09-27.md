# Supabase·Vercel 배포 아키텍처

## 권장 구조

```text
Next.js on Vercel
├── UI
├── Route Handlers / BFF
└── Supabase SSR Auth
        │
        ├── Supabase Auth
        ├── Postgres + RLS
        ├── Private Storage
        ├── Queues (pgmq)
        └── pg_cron / Edge Functions
                 │
                 └── External GPU AI Worker
```

## 핵심 판단

### 이미지는 Storage로 직접

Vercel Function의 요청/응답 payload 제한 때문에 원본 이미지를 BFF를 통해 전달하지 않습니다. BFF가 signed upload URL을 발급하고 클라이언트가 Supabase Storage에 직접 올립니다.

### AI는 외부 Worker

Supabase Edge Function은 사용자 검증, Job 생성, webhook 처리에는 적합하지만 메모리·CPU 제한상 검출·분할 모델을 실행하는 위치로는 부적합합니다. Vercel도 모델 번들·실행시간·이미지 payload 때문에 CV inference 호스트로 사용하지 않습니다.

### Queue로 요청과 실행 분리

분석 요청을 Postgres-native queue에 넣고 Worker가 가져가거나, 신뢰된 dispatcher가 외부 AI API를 호출합니다. `job_id`와 idempotency key를 사용하고 callback 중복을 안전하게 처리합니다.

### 오전 7시 추천

MVP에서는 홈 진입 또는 명시적 요청 시 생성합니다. 사전 생성을 추가할 때는 `next_recommendation_at` 대상만 주기적으로 처리합니다. Vercel Hobby Cron은 정시 실행 보장이 약하므로 정확한 사용자 알림에는 사용하지 않습니다.

## 환경

| 환경 | Vercel | Supabase |
|---|---|---|
| local | local dev | local stack 또는 dev project |
| preview | PR preview | shared dev 또는 branch 전략 |
| production | production deployment | production project |

운영 DB migration은 SQL 파일로 버전 관리하고, preview가 production service role을 사용하지 않게 합니다.

## 보안 기본값

- bucket은 private
- 사용자 소유 테이블은 RLS default deny
- service role은 브라우저에 절대 노출하지 않음
- signed URL은 짧은 만료시간과 object prefix 검증
- 위치·OOTD 공개·학습 재사용 동의 분리
- 삭제 요청은 원본, 파생 이미지, 임베딩, draft까지 전파

## 공식 제약 근거

- Supabase Edge Functions: 256MB 메모리, 요청당 CPU 시간 제한이 있으므로 오케스트레이션에 사용
- Vercel Functions: 요청/응답 body 제한이 있어 대용량 이미지 직접 전송을 피함
- Supabase Queues: Postgres 기반 내구성 있는 메시지 큐로 비동기 Job에 사용 가능
- 정시 Cron: Vercel 플랜별 정밀도가 다르므로 제품 요구에 맞춰 선택

관련 공식 문서:

- https://supabase.com/docs/guides/functions/limits
- https://supabase.com/docs/guides/queues
- https://supabase.com/docs/guides/functions/schedule-functions
- https://vercel.com/docs/functions/limitations
- https://vercel.com/docs/cron-jobs/usage-and-pricing
