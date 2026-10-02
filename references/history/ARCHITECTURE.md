# MyFit:Core 아키텍처 초안

> 프레임워크와 클라우드는 미확정입니다. 이 문서는 먼저 책임과 계약을 정의합니다.

## 서비스 구성

| 영역 | 책임 |
|---|---|
| Frontend | 온보딩, 카메라/업로드, 결과 검토, 옷장, 추천, 캘린더, 피드 |
| Backend API | 인증, 사용자·옷장·OOTD·소셜 데이터, 권한, 외부 API 조정 |
| Async Worker | 다중 의류 분석, 이미지 파생물 생성, 추천 프리컴퓨팅 |
| Vision Service | 검출, 분할/누끼, 카테고리·패턴·추구미 태깅, 임베딩 |
| Recommendation | 날씨·TPO 제약, 색상/레이어링 규칙, 추구미 점수, 다양성 재정렬 |
| Similarity Search | OOTD 아이템과 사용자 옷장 아이템의 후보 검색·대체 조합 |
| Explanation | 구조화된 추천 근거를 자연어 코멘트로 변환 |
| Weather Adapter | 좌표 변환, 기상청 응답 정규화, 캐싱 |
| Storage | 원본·누끼·OOTD 이미지와 메타데이터 분리 저장 |

## 다중 등록 흐름

```text
사진 촬영/선택
→ Pre-signed URL로 원본 업로드
→ 분석 Job 생성
→ Detection(의류별 bbox)
→ Segmentation/Matting(마스크·투명 PNG)
→ Attribute/Embedding 추론
→ 검토용 draft 반환
→ 사용자 일괄 수정
→ 확정 아이템을 옷장에 트랜잭션 저장
```

분석 결과는 즉시 확정하지 않고 `draft` 상태로 둡니다. 일부 아이템이 실패해도 성공한 결과를 검토할 수 있어야 하며 재시도 단위는 사진 전체가 아니라 아이템 또는 단계여야 합니다.

## 추천 흐름

```text
날씨 + TPO + 사용자 추구미
→ 착용 불가 후보 제거
→ 카테고리별 후보 생성
→ 조합 규칙 적용
→ 날씨/추구미/색상/TPO 점수화
→ 비슷한 3개가 나오지 않도록 다양성 재정렬
→ 구조화된 추천 근거 생성
→ 템플릿 또는 LLM 설명
```

## Styling Mimic 흐름

```text
피드 OOTD
→ 구성 아이템과 속성/임베딩 조회
→ 같은 카테고리의 내 옷장 후보 검색
→ 속성 + 임베딩 + 계절 적합성 재정렬
→ 아이템별 유사 후보와 전체 커버리지 반환
→ 부족한 파츠를 대체 가능으로 표시
```

## 주요 도메인

- User, AestheticPreference, LocationConsent
- GarmentBatch, GarmentDraft, Garment, GarmentAsset, GarmentEmbedding
- WeatherSnapshot, TPO
- OutfitRecommendation, RecommendationReason, OutfitDecision
- OOTDEntry, FeedPost, Scrap, Reaction, Comment
- MimicRequest, ItemMatch

## 기술 선택 전 지켜야 할 경계

- 원본 이미지와 AI 파생 이미지는 별도 객체로 관리합니다.
- 모델 예측값과 사용자 확정값을 덮어쓰지 않고 함께 보존합니다.
- 비동기 Job 상태와 오류 원인을 API 계약에 포함합니다.
- 추구미는 단일 정답 라벨이 아니라 다중 점수/사용자 선호로 표현합니다.
- LLM은 추천 조합을 임의로 변경하지 않습니다.
- 소셜 공개 범위와 학습 재사용 동의는 별도 권한입니다.
