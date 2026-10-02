# Jev 활용 검토

검토일: 2026-10-02

이 문서는 사용자가 말한 `jev`를 [TypeSafe AI의 Jev/System One](https://docs.typesafe.ai/introduction)으로 해석한 결과입니다. 다른 제품을 뜻했다면 재검토가 필요합니다.

## 결론

MVP 핵심 경로의 필수 의존성으로 도입하는 것은 권장하지 않습니다. 기존 추천 후보를 바꾸지 않는 **shadow 재랭킹 PoC**만 조건부로 권장합니다.

Jev는 텍스트 또는 구조화 상태를 Choice, Score, Noul 형태로 판정하는 비생성 결정 모델입니다. 이미지 분할·누끼·직접 이미지 분류나 자연어 설명 생성의 대체재가 아닙니다. 공식 API는 `POST /v1/systemone`을 제공하며 early-access 상태입니다.

## 적합한 후보

1. 기존 deterministic 추천 후보의 weather-fit, aesthetic-fit, harmony shadow 점수
2. 임베딩 top-k 이후 Styling Mimic 후보의 선택·no-match·manual-review 판정
3. AI callback schema 검증 이후 category/attribute 의미 일관성 QA
4. 한국어 자체 평가 이후 피드 캡션 moderation review routing

보안 검증, Auth/RLS, HMAC, 입력 schema, idempotency 같은 결정론 규칙은 Jev로 대체하지 않습니다.

## 권장 PoC

- 백엔드 또는 AI worker에서만 호출하고 브라우저에는 API key를 노출하지 않습니다.
- 사용자 ID, 정확 위치, 원문 개인정보 대신 weather band, taxonomy code, garment attribute처럼 비식별 구조화 정보만 전송합니다.
- 기존 추천 결과는 유지하고 Jev 점수·latency·model version·question schema version만 별도 평가합니다.
- 공급자 오류, timeout, rate limit 시 기존 deterministic 결과를 그대로 반환합니다.
- `jev-latest` 대신 평가가 끝난 명시적 모델 버전을 고정합니다.

예상 작업은 adapter/mock 1~2일, 한국어 패션 평가셋 200~500건과 threshold 평가 3~7일, feature flag·관측·fallback 2~3일로 총 1~2주입니다. 실제 데이터 라벨링 시간은 별도입니다.

## 승격 조건

- 기존 baseline보다 추천 top-1 또는 사용자 채택 지표가 유의미하게 개선
- p95 latency 예산 충족
- confidence threshold별 자동결정 coverage와 오판률 측정
- 공급자 장애 시 기존 추천 경로 100% 유지
- 개인정보와 국외 처리 검토 완료

공식 자료: [제품 소개](https://typesafe.ai/blog/introducing-system-one-models-and-jev), [API 문서](https://api.typesafe.ai/redoc), [Privacy Policy](https://typesafe.ai/legal/privacy-policy). 독립 평가 참고: [arXiv 2609.37647](https://arxiv.org/abs/2609.37647).
