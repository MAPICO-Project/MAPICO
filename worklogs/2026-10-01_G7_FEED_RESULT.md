# G7 피드·공유 미디어·좋아요 결과

상태: 로컬 구현·검토·검증 완료
범위: 피드 5개, 공유 media 2개, 좋아요 2개, 내 게시물·좋아요 목록 2개 — 누적 `implemented-local` 47/50

## Situation

G6의 비공개 OOTD와 `closet-private` 원본을 노출하지 않으면서 사용자가 선택한 복사본만 피드에 공개해야 했다. 게시물은 private draft에서 검증된 공유 media를 거쳐 public으로 전환되어야 했고, 이후 비공개 전환·철회가 feed, 좋아요 archive, signed URL 발급, G8 입력에서 즉시 같은 의미를 가져야 했다. 원격 Supabase·배포·비밀값은 범위에서 제외했다.

## Task

- 피드 CRUD, media upload/complete, like/unlike, 내 게시물·좋아요 목록의 11개 operation을 구현한다.
- `feed-private` upload와 실제 Storage object 검증을 공개 전제조건으로 연결한다.
- 공개 DTO에서 OOTD·garment ID, closet/feed raw object key, Auth metadata를 제거한다.
- public/private/deleted lifecycle, 좋아요 멱등성, 안정적인 keyset pagination과 G6/G8 참조 경계를 보장한다.

## Action

- `202610010004_feed.sql`에 private draft, 최대 10개 media, public 전환, soft withdrawal, like/unlike와 service-only projection을 위한 narrow RPC를 추가했다.
- 공유 media에 MIME·크기 metadata를 고정하고 서버 생성 경로만 upload하도록 Storage policy를 제한했다. complete 단계는 Storage object ID·`updated_at` fence까지 확인해 동일 경로 객체 교체 race를 차단했다.
- `closet-private`와 분리된 `feed-private` 복사본만 사용하고, 공개 응답에는 object key 대신 짧은 signed read URL만 조립하도록 했다.
- public feed, 본인 private 상세·목록, 타인 private/deleted 404 규칙을 한 projection 경계로 맞췄다. 비공개 전환·철회 후에는 신규 sign, 타인의 좋아요 archive와 G8 입력이 즉시 차단된다.
- like는 PK와 `ON CONFLICT DO NOTHING`으로 중복 PUT을 멱등 처리했다. unlike는 자신의 like만 privacy-safe하게 삭제하고 게시물의 현재 visibility·존재 여부와 무관하게 204로 멱등 처리한다.
- feed/my/liked 목록은 endpoint·filter에 묶인 keyset cursor와 stable ordering을 사용했다. 작성자 projection, `like_count`, `liked_by_me`는 raw profile/table join을 클라이언트에 열지 않고 서버 경계에서 계산했다.
- SQL assertions와 HTTP unit test에서 cross-owner OOTD/media, max 10, Storage metadata·identity fence, private/public/delete, like 중복, cursor/filter, raw key 비노출과 G3 Storage 회귀를 검증했다.

## Result

- 전체 `npm test`: 98/98 통과.
- 독립 `npm run test:schema`: 전체 migration과 SQL assertion 통과.
- `npm run coverage:contract`: 49/50, valid=true. G7의 11개 operation은 `implemented-local`로 정합하다.
- `npm run seed:validate`, `npm run smoke:preview -- --dry-run`: 통과.
- 원격 DB·배포·bucket policy·비밀값은 변경하지 않았다.
- 실제 hosted Auth/PostgREST와 `feed-private` signed upload/read, Range·object metadata, URL 만료·동시 visibility race는 미검증으로 남겼다.

## 검토에서 수정한 release blocker

- 일반 authenticated Storage INSERT 권한 회수로 기존 G3 `closet-private` upload가 깨지던 회귀를 bucket별 exact policy로 수정했다.
- Storage 경로·metadata만 확인하던 complete race에 object ID·`updated_at` fence를 추가했다.
- service-only feed projection과 authenticated helper 권한을 분리해 raw object key의 공개 RPC 노출을 막았다.
- post당 media 최대 10개를 DB transaction에서 고정했다.
- hidden/deleted post unlike는 existence oracle 없이 204로 유지하고, 읽기·상세 경로의 private/deleted lifecycle은 privacy-safe 404로 통일했다.
