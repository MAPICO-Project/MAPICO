# DB 흐름과 상세 ERD

2026-10-02 팀 검토본. 현재 migration 12개를 일회용 PGlite에 적용해 **public 테이블 24개**의 실제 컬럼·PK·FK·UNIQUE를 조회했다. 원격 DB는 접근하지 않았고 Auth/Storage는 로컬 스텁이다.

도메인 요약도의 화살표는 업무 흐름이며 FK가 아니다. 상세 ERD는 실제 FK만 표시하며, 읽기 쉽게 PK·FK와 주요 업무 필드만 보여준다. 겹치는 테이블은 같은 테이블의 재표시다. 전체 컬럼·제약은 [migration](../../backend/supabase/migrations/)과 [DB 설계](../../backend/docs/DB_DESIGN.md)가 기준이다.

## 1. 데이터가 이어지는 흐름

```mermaid
flowchart TD
 A["계정·취향<br/>profiles / aesthetics / user_aesthetic_preferences"] --> B["옷 등록·분석<br/>garment_batches / garment_assets<br/>analysis_jobs / garment_drafts"]
 B -->|"사용자 검토·확정"| C["내 옷장<br/>garments / garment_aesthetic_scores"]
 A --> D["날씨·추천<br/>weather_snapshots / recommendation_requests<br/>outfit_recommendations / outfit_items"]
 C --> D
 C --> E["재사용 코디 보관<br/>saved_outfits / saved_outfit_items"]
 D --> E
 D -->|"채택"| F["날짜별 비공개 착용 기록<br/>ootd_entries · item_snapshot"]
 E -->|"별도 기록"| F
 F -->|"사용자가 명시적으로 공유"| G["공개 게시물·공유 복사본<br/>feed_posts / feed_media / post_likes"]
 G --> H["따라입기 작업<br/>mimic_requests / mimic_source_items<br/>mimic_candidate_items"]
 C -. "생성 시 후보 스냅샷 · FK 아님" .-> H
 H -->|"사용자 확인·별도 저장"| E
 I["공통 지원<br/>idempotency_keys: 중복 요청 방지<br/>tpo_presets: 호환 카탈로그·정책 미결"]
```

## ERD 범례

- PK: 기본 키, FK: 외래 키, UK: 유일 키. 복합 키는 여러 컬럼이 함께 구성한다.
- 관계 끝의 한 줄은 1, 원은 0 허용, 갈퀴는 여러 행을 뜻한다. 컬럼 주석 nullable은 NULL 허용이다.
- 실선은 FK 컬럼이 자식 PK에 포함되는 식별 관계, 점선은 비식별 FK다. **점선도 실제 FK**이며 논리적 추정 관계라는 뜻이 아니다.
- FK의 NULL 허용과 UNIQUE/PK 제약을 기준으로 관계 수를 도출한다. 부분 unique index 및 RPC의 추가 업무 제약은 관계 수에 모두 표현하지 않는다.
- profiles와 auth_users는 같은 ID를 쓰며 auth_users는 외부 auth.users 표시용 이름이다. 24개 public 테이블 집계에는 넣지 않는다.

## 2. 계정·취향·중복 요청

```mermaid
erDiagram
  direction TB
  profiles ||--o{ idempotency_keys : "user_id"
  tpo_presets o|..o{ profiles : "default_tpo"
  auth_users ||--o| profiles : "id"
  aesthetics ||--o{ user_aesthetic_preferences : "aesthetic_id"
  profiles ||--o{ user_aesthetic_preferences : "user_id"
  auth_users {
    uuid id PK
  }
  profiles {
    uuid id PK,FK "required"
    text display_name "nullable"
    text default_tpo FK "nullable"
    boolean onboarding_completed "required"
  }
  aesthetics {
    uuid id PK "required"
    text code UK "required"
  }
  user_aesthetic_preferences {
    uuid user_id PK,FK "required"
    uuid aesthetic_id PK,FK "required"
    numeric weight "required"
  }
  tpo_presets {
    text code PK "required"
  }
  idempotency_keys {
    uuid user_id PK,FK "required"
    text scope PK "required"
    text key PK "required"
  }
```

## 3. 옷 등록·분석·확정

```mermaid
erDiagram
  direction TB
  garment_batches ||..o| analysis_jobs : "batch_id"
  profiles ||..o{ analysis_jobs : "user_id"
  aesthetics ||--o{ garment_aesthetic_scores : "aesthetic_id"
  garments ||..o{ garment_aesthetic_scores : "garment_id"
  garment_batches ||..o{ garment_assets : "batch_id"
  profiles ||..o{ garment_assets : "user_id"
  profiles ||..o{ garment_batches : "user_id"
  analysis_jobs ||..o{ garment_drafts : "batch_id_job_id"
  garment_assets ||..o{ garment_drafts : "asset_id"
  garment_batches ||..o{ garment_drafts : "batch_id"
  profiles ||..o{ garment_drafts : "user_id"
  analysis_jobs ||..o{ garment_drafts : "job_id"
  garment_assets ||..o{ garments : "asset_id"
  profiles ||..o{ garments : "user_id"
  garment_drafts ||..o| garments : "source_draft_id"
  auth_users ||--o| profiles : "id"
  auth_users {
    uuid id PK
  }
  profiles {
    uuid id PK,FK "required"
    text display_name "nullable"
    text default_tpo FK "nullable"
    boolean onboarding_completed "required"
  }
  aesthetics {
    uuid id PK "required"
    text code UK "required"
  }
  garment_batches {
    uuid id PK "required"
    uuid user_id FK "required"
    text status "required"
  }
  garment_assets {
    uuid id PK "required"
    uuid user_id FK "required"
    uuid batch_id FK "required"
  }
  analysis_jobs {
    uuid id PK "required"
    uuid user_id FK "required"
    uuid batch_id FK,UK "required"
    text status "required"
  }
  garment_drafts {
    uuid id PK "required"
    uuid user_id FK "required"
    uuid batch_id FK "required"
    uuid job_id FK "required"
    uuid asset_id FK "required"
    text status "required"
  }
  garments {
    uuid id PK "required"
    uuid user_id FK "required"
    uuid source_draft_id FK,UK "required"
    uuid asset_id FK "required"
    text category "required"
  }
  garment_aesthetic_scores {
    uuid user_id FK "required"
    uuid garment_id PK,FK "required"
    uuid aesthetic_id PK,FK "required"
  }
```

## 4. 추천·보관함·착용 기록

```mermaid
erDiagram
  direction TB
  profiles ||..o{ garments : "user_id"
  profiles ||..o{ ootd_entries : "user_id"
  outfit_recommendations o|..o{ ootd_entries : "outfit_id"
  weather_snapshots o|..o{ ootd_entries : "weather_snapshot_id"
  saved_outfits o|..o{ ootd_entries : "saved_outfit_id"
  garments ||..o{ outfit_items : "garment_id"
  outfit_recommendations ||..o{ outfit_items : "outfit_id"
  recommendation_requests ||..o{ outfit_recommendations : "request_id"
  tpo_presets o|..o{ profiles : "default_tpo"
  auth_users ||--o| profiles : "id"
  tpo_presets o|..o{ recommendation_requests : "tpo"
  profiles ||..o{ recommendation_requests : "user_id"
  weather_snapshots o|..o{ recommendation_requests : "weather_snapshot_id"
  garments ||..o{ saved_outfit_items : "garment_id"
  saved_outfits ||..o{ saved_outfit_items : "saved_outfit_id"
  profiles ||..o{ saved_outfits : "user_id"
  outfit_recommendations o|..o{ saved_outfits : "source_recommendation_id"
  auth_users {
    uuid id PK
  }
  profiles {
    uuid id PK,FK "required"
    text display_name "nullable"
    text default_tpo FK "nullable"
    boolean onboarding_completed "required"
  }
  tpo_presets {
    text code PK "required"
  }
  garments {
    uuid id PK "required"
    uuid user_id FK "required"
    uuid source_draft_id FK,UK "required"
    uuid asset_id FK "required"
    text category "required"
  }
  weather_snapshots {
    uuid id PK "required"
  }
  recommendation_requests {
    uuid id PK "required"
    uuid user_id FK "required"
    uuid weather_snapshot_id FK "nullable"
    text tpo FK "nullable"
    text status "required"
  }
  outfit_recommendations {
    uuid id PK "required"
    uuid user_id FK "required"
    uuid request_id FK "required"
  }
  outfit_items {
    uuid user_id FK "required"
    uuid outfit_id PK,FK "required"
    uuid garment_id PK,FK "required"
  }
  saved_outfits {
    uuid id PK "required"
    uuid user_id FK "required"
    uuid source_recommendation_id FK "nullable"
  }
  saved_outfit_items {
    uuid user_id FK "required"
    uuid saved_outfit_id PK,FK "required"
    uuid garment_id PK,FK "required"
    integer position "required"
  }
  ootd_entries {
    uuid id PK "required"
    uuid user_id FK "required"
    uuid outfit_id FK "nullable"
    date worn_on "required"
    text visibility "required"
    jsonb item_snapshot "required"
    uuid saved_outfit_id FK "nullable"
    text wear_status "required"
    uuid weather_snapshot_id FK "nullable"
  }
```

## 5. 피드·좋아요·따라입기

```mermaid
erDiagram
  direction TB
  feed_posts ||..o{ feed_media : "post_id"
  aesthetics o|..o{ feed_posts : "aesthetic_id"
  profiles ||..o{ feed_posts : "user_id"
  ootd_entries o|..o{ feed_posts : "source_ootd_id"
  mimic_requests ||--o{ mimic_candidate_items : "job_id"
  feed_posts ||..o{ mimic_requests : "post_id"
  profiles ||..o{ mimic_requests : "user_id"
  mimic_requests ||--o{ mimic_source_items : "job_id"
  profiles ||..o{ ootd_entries : "user_id"
  feed_posts ||--o{ post_likes : "post_id"
  profiles ||--o{ post_likes : "user_id"
  auth_users ||--o| profiles : "id"
  auth_users {
    uuid id PK
  }
  profiles {
    uuid id PK,FK "required"
    text display_name "nullable"
    text default_tpo FK "nullable"
    boolean onboarding_completed "required"
  }
  aesthetics {
    uuid id PK "required"
    text code UK "required"
  }
  ootd_entries {
    uuid id PK "required"
    uuid user_id FK "required"
    uuid outfit_id FK "nullable"
    date worn_on "required"
    text visibility "required"
    jsonb item_snapshot "required"
    uuid saved_outfit_id FK "nullable"
    text wear_status "required"
    uuid weather_snapshot_id FK "nullable"
  }
  feed_posts {
    uuid id PK "required"
    uuid user_id FK "required"
    uuid source_ootd_id FK "nullable"
    uuid aesthetic_id FK "nullable"
    text visibility "required"
  }
  feed_media {
    uuid id PK "required"
    uuid user_id FK "required"
    uuid post_id FK "required"
    integer position "required"
  }
  post_likes {
    uuid user_id PK,FK "required"
    uuid post_id PK,FK "required"
  }
  mimic_requests {
    uuid id PK "required"
    uuid user_id FK "required"
    uuid post_id FK "required"
    text status "required"
  }
  mimic_source_items {
    uuid job_id PK,FK "required"
    integer position "required"
    text source_item_key PK "required"
    uuid feed_media_id "required"
    uuid storage_object_id "required"
  }
  mimic_candidate_items {
    uuid job_id PK,FK "required"
    uuid garment_id PK "required"
    uuid asset_id "required"
    integer garment_version "required"
    uuid storage_object_id "required"
  }
```

## 관계를 읽을 때 주의할 점

1. mimic_source_items.feed_media_id와 mimic_candidate_items.garment_id·asset_id는 저장된 식별자지만 **실제 FK가 아니다**. 두 테이블의 job_id만 mimic_requests를 참조한다. 공개성·자산 변경·후보 유효성은 RPC가 스냅샷과 현재 상태를 대조한다. 기존 ERD의 이 부분은 논리 참조와 FK가 섞여 있어 이번 공유본에서 바로잡았다.
2. ootd_entries.item_snapshot은 기록 당시 의류를 담는 JSON이다. garments를 직접 가리키는 항목별 FK 테이블이 아니다. saved_outfit_id와 outfit_id는 둘 다 NULL일 수 있고 동시에 지정할 수는 없다.
3. 사용자 소유권은 여러 관계에서 (user_id, id) 복합 FK로 확인한다. 실제 컬럼을 생략한 단순 ID 관계로 바꾸지 않았다.
4. 원본·누끼는 garment_assets, 공유 이미지는 feed_media로 분리한다. Storage 객체의 ID/경로를 갖는 것과 storage.objects에 FK가 있는 것은 다르다. DB 행 삭제가 Storage 파일 삭제를 자동 보장하지 않는다.
5. 하루 OOTD 수, wear_status, TPO 제품 정책과 최종 추구미 명칭은 DB의 현재 제약과 별개로 미결 상태를 유지한다.

[기존 ERD](../../backend/docs/ERD.md) · [DB 설계](../../backend/docs/DB_DESIGN.md) · [시스템 아키텍처](ARCHITECTURE.md). 기존 백엔드 문서와 SQL은 이 작업에서 수정하지 않았다.
