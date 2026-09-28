# 마피코 ERD v0.3

실제 SQL의 핵심 관계. auth.users/storage 객체는 외부 플랫폼 영역이며 총 public 테이블 22개다. 제품 단계 신규 관계를 포함하되 API 구현 완료를 뜻하지 않는다.

```mermaid
erDiagram
    profiles ||--o{ user_aesthetic_preferences : prefers
    aesthetics ||--o{ user_aesthetic_preferences : defines
    tpo_presets o|--o{ profiles : optional_default
    profiles ||--o{ garment_batches : uploads
    garment_batches ||--o{ garment_assets : contains
    garment_batches ||--o| analysis_jobs : analyzes
    analysis_jobs ||--o{ garment_drafts : predicts
    garment_assets ||--o{ garment_drafts : cutout
    garment_drafts ||--o| garments : confirms
    garment_assets ||--o{ garments : image
    garments ||--o{ garment_aesthetic_scores : scores
    aesthetics ||--o{ garment_aesthetic_scores : "style"
    profiles ||--o{ recommendation_requests : requests
    tpo_presets o|--o{ recommendation_requests : optional_tpo
    weather_snapshots o|--o{ recommendation_requests : weather
    recommendation_requests ||--o{ outfit_recommendations : results
    outfit_recommendations ||--o{ outfit_items : contains
    garments ||--o{ outfit_items : uses
    profiles ||--o{ saved_outfits : saves
    outfit_recommendations o|--o{ saved_outfits : optional_origin
    saved_outfits ||--o{ saved_outfit_items : contains
    garments ||--o{ saved_outfit_items : uses
    profiles ||--o{ ootd_entries : records
    saved_outfits o|--o{ ootd_entries : optional_origin
    outfit_recommendations o|--o{ ootd_entries : optional_origin
    weather_snapshots o|--o{ ootd_entries : snapshot
    profiles ||--o{ feed_posts : publishes
    ootd_entries o|--o{ feed_posts : optional_origin
    aesthetics o|--o{ feed_posts : tag
    feed_posts ||--o{ feed_media : shared_copies
    feed_posts ||--o{ post_likes : liked
    profiles ||--o{ post_likes : likes
    feed_posts ||--o{ mimic_requests : inspiration
    profiles ||--o{ mimic_requests : requests
    profiles ||--o{ idempotency_keys : deduplicates
    saved_outfits {
      uuid id PK
      uuid user_id FK
      text title
      text note
      int version
    }
    ootd_entries {
      uuid id PK
      uuid user_id FK
      uuid outfit_id FK "nullable recommendation"
      uuid saved_outfit_id FK "nullable"
      date worn_on "unique with user_id"
      text wear_status "unconfirmed planned worn"
      jsonb item_snapshot
      int rating "nullable 1 to 5"
    }
    feed_posts {
      uuid id PK
      uuid user_id FK
      uuid source_ootd_id FK "server only"
      text caption
      text visibility
      timestamptz deleted_at
    }
```

테이블 접근·필드 정의·미결 사항은 [DB 설계](DB_DESIGN.md)를 기준으로 한다. 공개 게시물과 비공개 OOTD/옷장 데이터는 분리된다. 선호 무드보드·pgvector 차원은 아직 스키마에 고정하지 않았다.
