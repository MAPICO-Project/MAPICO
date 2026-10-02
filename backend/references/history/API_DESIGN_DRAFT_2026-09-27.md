# API 설계 초안 v0.1

## 목적과 전제

PRD 검토와 백엔드 구축을 병렬로 시작하기 위한 계약 초안입니다.

- Web/BFF: Next.js Route Handlers on Vercel
- Auth/DB/Storage: Supabase Auth, Postgres, Storage, RLS
- 비동기 작업: Supabase Queues 또는 Job 테이블 + 소비자
- CV 추론: 별도 GPU AI 서비스
- 추천: 초기에는 Vercel 또는 별도 추천 서비스, 무거워지면 분리
- API prefix: `/api/v1`
- 사용자 인증: Supabase access token

## 배치 원칙

```text
Browser/App
├── Supabase Auth: 로그인·세션
├── Supabase Storage: signed URL로 이미지 직접 업로드
└── Vercel BFF: 권한이 필요한 도메인 명령·외부 API 오케스트레이션
        ├── Supabase Postgres/RLS
        ├── Supabase Queue
        ├── 기상청 API
        └── External AI Service
```

표준 CRUD를 모두 서버리스 API로 감싸지는 않습니다. 단순 사용자 소유 데이터 조회는 RLS가 보장되면 Supabase SDK를 사용할 수 있습니다. 여러 테이블을 함께 변경하거나 외부 호출이 필요한 명령은 BFF 또는 Postgres RPC로 처리합니다.

## 핵심 상태 머신

### GarmentBatch

```text
created → uploading → uploaded → queued → analyzing
                                      ├→ review_ready → confirmed
                                      ├→ partial_failed → review_ready/retry
                                      └→ failed → retry/cancelled
```

### AnalysisJob

```text
queued → running → succeeded
                 ├→ partial_failed
                 └→ failed
```

### GarmentDraft

```text
predicted → edited → confirmed
          └→ rejected
```

### Recommendation

```text
generating → ready → accepted
                  ├→ dismissed
                  └→ expired
```

## 외부 API 엔드포인트

### Profile / preference

| Method | Path | 설명 |
|---|---|---|
| GET | `/api/v1/me` | 내 프로필·온보딩 상태 |
| PATCH | `/api/v1/me` | 프로필과 기본 설정 변경 |
| PUT | `/api/v1/me/aesthetics` | 5개 중 1~2개와 가중치 저장 |
| PUT | `/api/v1/me/default-tpo` | 기본 TPO 저장 |

### Garment ingestion

| Method | Path | 설명 |
|---|---|---|
| POST | `/api/v1/garment-batches` | 배치와 업로드 경로 생성 |
| POST | `/api/v1/garment-batches/{batchId}/complete-upload` | 업로드 완료·파일 검증 |
| POST | `/api/v1/garment-batches/{batchId}/analysis-jobs` | 분석 Job 생성·큐 적재 |
| GET | `/api/v1/analysis-jobs/{jobId}` | 상태·단계·오류·진행률 조회 |
| GET | `/api/v1/garment-batches/{batchId}/drafts` | 검토할 아이템 목록 |
| PATCH | `/api/v1/garment-drafts/{draftId}` | 카테고리·색상·패턴 등 수정 |
| POST | `/api/v1/garment-batches/{batchId}/confirm` | 선택된 draft를 옷장에 원자적 확정 |
| POST | `/api/v1/analysis-jobs/{jobId}/retry` | 실패 단계 재시도 |

### Closet

| Method | Path | 설명 |
|---|---|---|
| GET | `/api/v1/garments` | 카테고리·상태·태그별 목록 |
| GET | `/api/v1/garments/{garmentId}` | 의류와 자산·착용 요약 |
| PATCH | `/api/v1/garments/{garmentId}` | 사용자 확정 메타데이터 변경 |
| DELETE | `/api/v1/garments/{garmentId}` | soft delete 및 자산 삭제 Job 생성 |

### Weather / TPO / recommendations

| Method | Path | 설명 |
|---|---|---|
| GET | `/api/v1/weather/current?lat=&lon=` | 정규화된 현재/단기 날씨 |
| GET | `/api/v1/tpo-presets` | 활성 TPO 프리셋 목록 |
| POST | `/api/v1/recommendations` | 날씨·TPO·추구미 기반 3개 생성 |
| GET | `/api/v1/recommendations/{id}` | 조합·점수·근거 조회 |
| POST | `/api/v1/recommendations/{id}/accept` | 오늘 입기와 OOTD 생성 |
| POST | `/api/v1/recommendations/{id}/dismiss` | 거절 이유·피드백 저장 |
| POST | `/api/v1/recommendations/{id}/swap` | 한 파츠 대체 후보 생성 |

### OOTD / limited social

| Method | Path | 설명 |
|---|---|---|
| GET | `/api/v1/ootd?from=&to=` | 내 캘린더 조회 |
| POST | `/api/v1/ootd` | 수동 OOTD 기록 |
| PATCH | `/api/v1/ootd/{id}` | 만족도·공개범위 수정 |
| DELETE | `/api/v1/ootd/{id}` | 기록/게시 철회 |
| GET | `/api/v1/feed` | 초기에는 curated/sample 피드 |
| POST | `/api/v1/feed/{postId}/scraps` | 스크랩 |
| DELETE | `/api/v1/feed/{postId}/scraps` | 스크랩 취소 |
| POST | `/api/v1/mimic-jobs` | 피드 OOTD의 내 옷장 치환 요청 |
| GET | `/api/v1/mimic-jobs/{jobId}` | 아이템별 후보·커버리지 조회 |

## AI 서비스 계약

### 분석 요청

```json
{
  "job_id": "uuid",
  "batch_id": "uuid",
  "source_object_key": "user-id/original/uuid.jpg",
  "pipeline_version": "flatlay-v1",
  "requested_outputs": ["bbox", "mask", "category", "color", "pattern", "aesthetic_scores", "embedding"]
}
```

### 분석 결과

```json
{
  "job_id": "uuid",
  "status": "succeeded",
  "model_versions": {
    "detector": "...",
    "segmenter": "...",
    "embedder": "..."
  },
  "items": [
    {
      "client_item_key": "item-1",
      "bbox": [0.1, 0.2, 0.4, 0.7],
      "mask_object_key": "user-id/masks/uuid.png",
      "category": {"value": "top", "confidence": 0.93},
      "colors": [{"hex": "#223344", "ratio": 0.71}],
      "pattern": {"value": "solid", "confidence": 0.84},
      "aesthetic_scores": {"aesthetic_id": 0.82},
      "embedding_ref": "uuid"
    }
  ],
  "errors": []
}
```

AI 서비스는 Storage의 service key를 전달받지 않습니다. 짧은 만료시간의 signed download/upload URL 또는 제한된 callback을 사용합니다.

## 추천 요청 계약

```json
{
  "tpo": "date_social",
  "aesthetic_weights": {"aesthetic-id-1": 0.7, "aesthetic-id-2": 0.3},
  "location": {"lat": 37.0, "lon": 127.0},
  "requested_count": 3
}
```

응답은 코디마다 다음을 포함합니다.

- garment IDs와 파츠 역할
- 날씨·TPO·추구미·색상 점수
- 적용 규칙과 제외 이유
- 설명용 구조화 facts
- 추천 엔진·규칙 버전

## 오류 형식

```json
{
  "error": {
    "code": "ANALYSIS_PARTIAL_FAILURE",
    "message": "일부 의류 분석에 실패했습니다.",
    "retryable": true,
    "details": {"failed_item_count": 1},
    "request_id": "uuid"
  }
}
```

## 주요 테이블

- `profiles`, `aesthetics`, `user_aesthetics`, `tpo_presets`
- `garment_batches`, `analysis_jobs`, `garment_drafts`
- `garments`, `garment_assets`, `garment_embeddings`
- `weather_snapshots`
- `recommendation_requests`, `outfit_recommendations`, `outfit_items`, `outfit_feedback`
- `ootd_entries`, `feed_posts`, `scraps`
- `mimic_jobs`, `mimic_matches`

모든 사용자 소유 테이블은 `user_id`를 가지며 RLS를 기본 거부로 시작합니다. 서비스 역할은 Vercel 서버와 신뢰된 Worker에서만 사용합니다.

## 병렬 개발 계약

PRD와 API 설계를 병렬로 진행할 수 있지만 아래 항목은 코드 착수 전 잠급니다.

1. 5개 추구미 ID와 변경 정책
2. TPO enum과 기본값
3. 의류 카테고리/속성 enum
4. 배치·Job·draft 상태와 재시도 의미
5. AI 분석 요청/응답 스키마
6. 공개/비공개와 이미지 삭제 규칙

이후 변경은 OpenAPI/DB migration/TypeScript 타입을 함께 변경하고 breaking change를 기록합니다.
