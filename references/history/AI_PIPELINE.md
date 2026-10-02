# AI 파이프라인

## 1. 다중 의류 등록

### 단계별 계약

1. Detection: bbox, detection score, class 후보
2. Segmentation/Matting: binary/alpha mask, crop, transparent asset
3. Attribute: 대분류, 세부 카테고리, 색상, 패턴
4. Aesthetic: 15개 추구미별 적합 점수
5. Embedding: 유사도 검색용 버전이 명시된 벡터

YOLO·Grounding DINO, SAM 계열, BiRefNet, Fashion-CLIP 등은 후보 구현입니다. 데이터와 지연시간 베이스라인을 측정하기 전에 특정 조합을 확정하지 않습니다.

### 평가

- Detection: item recall, precision, mAP
- Segmentation: mask IoU/Dice, 경계 품질 표본 검수
- Category: Macro F1, 클래스별 recall
- Color/Pattern: 속성별 F1 또는 허용 오차
- End-to-end: 실제 2~6벌 사진에서 `검출 → 수정 → 저장` 완료율
- Latency: 단계별 p50/p95, 하드웨어·해상도·업로드 제외 여부 명시

## 2. 추구미 태깅

15대 추구미의 목록, 정의, 양성/음성 예시, 유사 추구미 경계를 먼저 고정해야 합니다. 단일 클래스보다 다중 라벨 점수로 다루고, 모델 점수를 객관적 사실이 아닌 추천용 특징으로 사용합니다.

초기에는 제로샷 Fashion-CLIP 베이스라인과 사람이 만든 속성 규칙을 비교합니다. 자체 라벨 없이 바로 지도학습 정확도를 목표로 두지 않습니다.

## 3. 코디 추천

```text
hard constraints:
  카테고리 구성, 계절/기온, 강수, 사용 가능 상태

soft scores:
  날씨 적합도 + TPO + 추구미 + 색상 조화 + 사용자 선호

reranking:
  세 추천 간 다양성 + 최근 착용 중복 회피
```

추천마다 사용된 아이템, 적용된 규칙, 점수 구성, 제외 이유를 저장합니다. 설명은 이 구조화 근거만 사용합니다.

## 4. Styling Mimic

같은 카테고리 후보를 먼저 제한한 후 속성 점수와 이미지 임베딩 유사도를 결합합니다. 오프라인 평가는 사람이 만든 OOTD-대체 아이템 판단셋의 Recall@K/NDCG로, 제품 평가는 사용자의 대체 후보 선택률로 봅니다.

원시 코사인 유사도를 확률처럼 표시하지 않습니다. 사용자용 매칭 점수는 별도 보정 후 사용합니다.

## 5. 모델 등록과 배포 게이트

- 모델·임베딩 버전, 코드 커밋, 데이터/split 버전
- 전처리, 클래스/속성 순서, 입력 해상도
- 공개셋과 실제 Flat Lay 골든셋 성능
- 단계별 지연시간과 하드웨어
- 알려진 실패 조건: 겹침, 유사색 배경, 검은 옷, 반사/레이스, 작은 잡화
- 이전 모델로 롤백 가능한 아티팩트
- 서비스 계약과 회귀 테스트 통과
