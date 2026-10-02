# 병렬 작업 운영규칙

> WeatherCloset 자체 운영규칙이다. 공식 OpenAI 워크플로우의 scope·hand-off·gates 개념을 참고했다: <https://developers.openai.com/cookbook/examples/codex/codex_mcp_agents_sdk/building_consistent_workflows_codex_cli_agents_sdk>

## 1. 지휘와 역할

- Astra가 작업을 분해·배정·우선순위화하고 최종 통합·종료를 지휘한다.
- Claude Opus 5.5는 고난도 설계·추론·리뷰를 우선 담당한다. 실제 CLI model ID와 실행 증거를 기록하며 GPT-5.5와 혼동하지 않는다. 모델 자기소개는 실행 metadata의 대체가 아니다.
- Claude Sonnet은 Opus가 고정한 범위의 bounded 구현안 작성·코드 리뷰·반복 검증에 사용할 수 있다. 실제 CLI model ID와 실행 증거를 기록하고 파일 수정 권한은 카드의 단일 작성자 규칙을 따른다.
- Luna는 기본적으로 단순·반복·bounded 작업을 담당한다.
- 모델별 성능·가격 수치는 추정하지 않는다. 실제 관측값이 없으면 `미측정`으로 기록한다.

## 2. 병렬화·예산 경계

- 입력·출력·소유 파일이 분리되고 완료 기준이 명확한 bounded 독립 작업만 병렬화한다.
- root를 포함한 독립 사고 작업은 최대 4개다. 숨은 추가 CLI·하위 에이전트의 무제한 실행은 금지한다.
- CLI subprocess도 프로젝트 실행예산과 동시성에 포함한다. Claude CLI wrapper는 대기·수집만 하며 별도 실무 병렬 작업을 수행하지 않는다.
- 한 파일은 한 작성자만 수정한다. 같은 자원에 대한 중복 작업을 금지한다.
- read-only 조사·리뷰는 작성 작업과 분리하고, 리뷰어는 파일을 수정하지 않는다.
- 하위 에이전트 재위임은 기본 금지한다. 필요하면 Astra가 명시적으로 승인한다.
- 원격 DB 변경·배포·외부 시스템 조작은 사용자가 직접 실습·확인하는 boundary로 둔다.

## 3. 작업 카드와 hand-off

모든 병렬 작업은 다음 카드를 먼저 남긴다.

```text
ID:
목적:
입력/참조:
출력/완료 기준:
소유 파일:
금지 파일·범위:
선행조건:
상태: queued | active | checkpointed | blocked | done
모델 실제 ID:
비용 관측: 미측정 또는 관측값/출처
```

- 전체 대화 history를 복제하지 말고 카드와 필요한 최소 context만 전달한다.
- hand-off에는 변경 파일, 검증 명령·결과, 남은 위험·다음 행동을 포함한다.
- 완료 선언은 산출물 존재 확인과 완료 기준 검증 뒤에만 한다.

## 4. 실행·중단·회수

- 작업자는 최소 60초마다 진행상태를 보고한다(짧은 작업은 시작·종료 보고로 대체 가능).
- 중단되면 즉시 `checkpointed` 카드에 현재 단계, 변경 파일, 검증 결과, 재개 지점을 기록한다.
- 정상 턴 종료 전에는 root가 진행 중 작업을 회수하고 결과를 검증한다. 실제 interrupt가 필요하면 먼저 checkpoint를 요청·기록한 뒤 중단하며, 강제중단 시에도 기존 결과와 checkpoint를 보존한다. 사용자가 중단한 경우는 예외다.
- 결과 회수는 단순 수신으로 끝내지 않고 diff·테스트·문서 링크를 확인한다.
- 관측하지 않은 비용·성능·성공률은 숫자로 보고하지 않는다.

## 5. CLI 지시와 컨텍스트 수명

- 반복 CLI 검토는 세션 지속 여부를 카드에 기록한다. `--no-session-persistence` 사용 시 resume할 수 없으며, 동일 프로젝트 재검토는 금지하고 bounded 새 질문만 허용한다.
- `list`의 비용과 실제 청구를 구분하고, `cacheCreation` 등 초기 문맥 비용의 관측값을 기록한다. 긴 context를 무조건 복제하지 말고 필요한 최소 문맥만 전달한다.

- Astra가 CLI를 통해 Claude Opus를 직접 지시하고 결과를 수집하는 것을 기본으로 한다. 내장 `spawn`의 Claude 지원을 전제하지 않는다.
- CLI wrapper는 이번 초기 이력처럼 사용할 수 있지만, wrapper를 별도 실무 병렬 작업으로 세지 않는다.
- 실제 provider와 model ID는 실행 metadata·로그로 입증한다. 자기소개나 표시 문자열만으로 확정하지 않는다.
- `clear`·`compact` 전에는 파일 소유권을 해제하고 완료·checkpoint를 인계한다. root가 임의로 컨텍스트를 지우지 않는다.

## 6. 최소 게이트

1. **Scope gate**: 목적, 입력, 소유 파일, 금지 범위가 카드에 있는가?
2. **Conflict gate**: 독립 사고 4개 이하이며 파일·자원 충돌이 없는가?
3. **Handoff gate**: 완료 기준과 검증 방법이 전달되었는가?
4. **Close gate**: root가 결과를 회수·검증하고 상태를 `done`으로 갱신했는가?
