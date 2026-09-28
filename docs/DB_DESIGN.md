# 마피코 DB 설계 v0.3

기준: 2026-09-28 최신 기능 표 및 회의. **SQL 스키마 작성 및 로컬 검증 완료, 제품 API/원격 Supabase 적용 완료를 뜻하지 않는다.**

## 적용 경로

워크스페이스 기준 `backend/supabase/migrations/202609270001_core.sql` → `202609270002_transactions.sql` → `202609280001_product.sql` 순서. 독립 backend 저장소에서는 `supabase/migrations/`이다. 기존 16테이블에 6테이블을 더해 22테이블이다. 기존 SQL은 수정하지 않았다.

## 도메인 데이터 사전

| 테이블 | 목적·주요 필드 | 접근 |
|---|---|---|
| profiles | auth.users와 1:1, display_name, timezone, onboarding_completed | 본인 |
| aesthetics | feminine/y2k/minimal/grunge/casual, 표시명·정의·버전 | 활성 카탈로그 공개 |
| user_aesthetic_preferences | 유저별 스타일 가중치 | 본인 |
| tpo_presets | 이전 TPO 카탈로그, 삭제하지 않음 | 활성 카탈로그 공개 |
| garment_batches | 업로드·분석·검토 단위 | 본인 |
| garment_assets | closet-private 원본/누끼 경로·검증시각 | 본인 |
| analysis_jobs | 분석 상태·재시도·lease | 본인 제한 필드/서버 |
| garment_drafts | AI 원본 예측 + 사용자 수정값 + version | 본인 |
| garments | 확정 의류, category, 선택 memo(1,000자), 내부 속성 | 본인 |
| garment_aesthetic_scores | 모델 버전별 추구미 점수 | 본인 |
| weather_snapshots | 발표·유효·수집 시간, 격자, 공급자, payload | 서버 |
| recommendation_requests | 사용자·대상 날짜·날씨·조건·상태 | 본인 |
| outfit_recommendations | AI 추천 순위·설명·근거 | 본인 |
| outfit_items | 추천별 의류·slot | 본인 |
| saved_outfits | 날짜 없는 보관함, title(100자), note, source_recommendation_id?, version | 본인 |
| saved_outfit_items | 코디 구성 garment_id, position, 동일 소유자 복합 FK | 본인 |
| ootd_entries | worn_on, outfit_id?, saved_outfit_id?, item_snapshot, note, rating, weather_snapshot_id?, wear_status | 본인, 비공개 유지 |
| feed_posts | caption(2,000자), aesthetic_id?, weather_code?, temperature_c?, visibility, source_ootd_id? | 공개 게시물 또는 본인; source_ootd_id 제외 |
| feed_media | 공유용 복사본, feed-private 경로, 검증시각, 순서 | 서버 전용 |
| post_likes | user_id + post_id 유일; 좋아요 아카이브 | 본인 + 현재 열람 가능한 게시물만 |
| mimic_requests | post_id, queued/running/succeeded/no_match/failed, result, model_version | 본인 상태만; raw result/모델 버전 서버 전용 |
| idempotency_keys | 중복 요청·응답 기록·만료 | 서버 |

`bag` 카테고리를 추가했다. 모자는 accessory 하위 세부분류로 처리할 수 있으나 하위 코드 목록은 팀 합의 전 고정하지 않는다. 기존 내부 색상/추구미 데이터는 유지하되 최신 CLO-005 화면 DTO에서는 제외한다.

## 코디 / 착장 / 게시물 분리

- **보관함**: 실제 착용과 무관한 재사용 조합. 아이템 변경은 보관함만 갱신한다.
- **OOTD**: 특정 날짜 기록. 추천 없이 수동 생성 가능하도록 outfit_id NOT NULL을 해제했다. 두 원본 링크는 동시에 지정할 수 없고, 수동 조합은 둘 다 null일 수 있다. 기록 당시 아이템 스냅샷은 보관함 편집과 독립적이다.
- **게시물**: OOTD를 자동 공개하지 않는다. 별도 게시 행위로 공개 데이터와 검증된 공유 이미지 복사본을 만든다.
- **따라입기**: 게시물에서 요청 생성 → AI 결과 → 본인 옷으로 검증된 후보를 보관함에 저장. JSON 결과의 타인 의류 ID를 그대로 저장하지 않는다.

## 확정되지 않은 정책과 보수적 기본값

- `wear_status=unconfirmed`는 기존 기록을 실제 착용으로 오인하지 않기 위한 중립 기본값. `planned/worn`은 기술 제안이며 사용자 UX 확정이 아니다. 착용 통계는 worn만 집계한다.
- 하루 1기록 유일 제약은 기존대로 유지. 다중 착장 확정 시 별도 마이그레이션 필요.
- 별점 1~5는 nullable. 예정 착장 별점/미래 worn 제한, 날짜 변경 규칙은 API 정책 확정 전 미구현.
- 1~3 추구미/대표 순위/무드보드 점수 산정은 아직 DB 자동 계산 안 함. seed는 이름만 확정; 학습 정의·벡터 차원은 미확정.
- TPO 칩 제거를 TPO 내부 데이터 삭제로 단정하지 않으며 자동 기본값 적용은 별도 결정.
- 피드 최초 스키마는 추구미 1개 태그. 여러 개 선택 확정 시 연결 테이블 필요.
- OOTD 과거/미래 날짜에 오늘 날씨를 붙이지 않는다. 서버가 대상 시점의 snapshot을 선택하며 미확보는 null. 내부 weather_snapshot_id는 외부 응답에서 안전한 요약으로 변환한다.

## 권한·트랜잭션

신규 테이블은 RLS를 활성화하고 브라우저 직접 쓰기를 허용하지 않는다. BFF는 JWT 검증 후 본인 user_id를 주입해야 한다. service_role은 RLS를 우회하므로 단순 키 연결만으로 안전해지지 않는다.

보관함/아이템, OOTD 원본 링크, 게시물 원본 링크는 `(user_id,id)` 복합 FK로 교차 소유자 연결을 차단한다. 저장·수정 API는 아이템 수/중복/soft-delete 여부와 version을 확인하고 한 트랜잭션으로 처리해야 한다. 이 제품 쓰기 RPC/API는 아직 구현하지 않았다.

피드 SELECT 권한은 안전한 열만 부여한다. `SELECT *`는 의도적으로 실패한다. 공개 게시물도 다른 사용자의 OOTD ID·옷장 경로·원본 사진에 대한 권한을 주지 않는다. `feed_media`는 서버 전용이고 `feed-private` 버킷에는 브라우저 정책이 없다. BFF가 공개 여부·검증·삭제 상태 확인 후 짧은 만료의 signed URL을 반환해야 한다. 비공개 전환 전 발급된 URL은 만료 전까지 유효할 수 있다.

좋아요/따라입기 생성도 BFF에서 현재 게시물 접근 가능 여부를 확인한다. 게시물 비공개 전환 후 좋아요 아카이브 RLS는 숨긴다. 이미 생성된 따라입기 결과의 재노출 정책은 구현 시 재검증한다.

탈퇴·삭제는 관계 FK 순서와 Storage 삭제 작업을 고려한 트랜잭션/정리 작업이 필요하다. source 참조가 있는 보관함/OOTD/게시물 hard delete는 현재 RESTRICT로 실패할 수 있어 BFF에서 참조를 먼저 해제/삭제해야 한다. Storage 객체는 DB cascade로 삭제되지 않는다.

기존 `accept_outfit` RPC는 수동 OOTD의 nullable outfit_id를 null-safe 비교하도록 교체했다. 날짜 충돌 시 수동 기록을 추천 채택 성공으로 잘못 반환하지 않는다.

## 검증과 남은 작업

`node scripts/validate_design.mjs`로 3개 마이그레이션 및 `security.sql`, `product.sql` 통과. 신규 검증: 5종 seed, 소유자 FK, 비공개 조합 차단, 피드 제한 열, Storage 경로 차단, 직접 쓰기 거절, 비공개 전환 시 아카이브 숨김, 수동 OOTD 충돌.

PGlite에서 Auth/Storage는 테스트 스텁이다. 실제 Supabase Auth/Storage, 동시 요청, 서명 URL, 탈퇴 정리, 제품 endpoint, pgvector 검색은 통합 검증 전이다. 기존 OpenAPI v0.2 검사 통과와 최신 v0.3 요구사항 충족은 별개다.

Claude CLI `claude-opus-5-5` 읽기 전용 검토를 수행했다. 피드 열 권한을 이용하는 좋아요 RLS 오류를 테스트로 수정했고, 게시자 탈퇴를 타인 따라입기 FK가 막지 않도록 CASCADE로 변경했으며 raw 모델 결과 직접 조회를 차단했다. 수동 OOTD는 원본 링크가 없어도 유효하므로 '원본 정확히 하나 필수' 제안은 채택하지 않고 '최대 하나'로 제한했다. 게시자 계정 삭제 시 타인의 연결된 따라입기 행 정리까지 테스트했다.
