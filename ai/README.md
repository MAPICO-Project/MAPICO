# AI 영역

의류 분석과 Styling Mimic 비동기 워커, 모델 adapter와 평가 코드를 관리할 영역입니다.

## 현재 상태

- 백엔드는 분석·따라입기 job 생성, lease, HMAC callback, replay 방지 계약을 구현했습니다.
- 실제 AI 워커와 모델은 아직 이 저장소에서 실행·배포 검증되지 않았습니다.
- 샘플 fixture를 실제 추론 결과나 성능 증거로 취급하지 않습니다.

## 구현 시 원칙

- 워커 코드는 이 폴더에 두고 모델 가중치는 `models/` 또는 외부 artifact storage에서 관리합니다.
- 입력·출력 계약은 `../backend/docs/openapi.yaml`과 백엔드 callback 검증 코드를 함께 확인합니다.
- 실제 사용자 이미지, signed URL, 비밀값, 원시 모델 결과를 Git이나 일반 로그에 남기지 않습니다.
- 모델 버전, 데이터 출처, 평가셋, 실패·재시도 정책을 함께 기록합니다.

AI PR은 모델/adapter 버전, 재현 명령, 평가 데이터 범위, 백엔드 계약 변경 여부를 명시합니다.

결정 모델 후보 검토: [Jev 활용 검토](../deliverables/ai/JEV_FEASIBILITY.md)
