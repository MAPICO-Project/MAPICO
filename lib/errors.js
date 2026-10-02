export const MESSAGES = Object.freeze({
  METHOD_NOT_ALLOWED: '지원하지 않는 요청 방식입니다.',
  AUTH_REQUIRED: '인증이 필요합니다.',
  INVALID_TOKEN: '유효하지 않은 인증 토큰입니다.',
  SUPABASE_NOT_CONFIGURED: '데이터베이스 연결이 설정되지 않았습니다.',
  AUTH_UNAVAILABLE: '인증 서비스를 사용할 수 없습니다.',
  SUPABASE_UNAVAILABLE: '데이터베이스 서비스를 사용할 수 없습니다.',
  DATABASE_SCHEMA_NOT_READY: '데이터베이스 스키마가 준비되지 않았습니다.',
  RATE_LIMITED: '요청이 너무 많습니다. 잠시 후 다시 시도해 주세요.',
  PROFILE_NOT_FOUND: '프로필을 찾을 수 없습니다.',
  GARMENT_NOT_FOUND: '의류를 찾을 수 없습니다.',
  VERSION_CONFLICT: '다른 변경이 먼저 저장되었습니다.',
  IDEMPOTENCY_CONFLICT: '같은 요청 키가 다른 요청에 사용되었습니다.',
  STORAGE_UNAVAILABLE: '이미지 저장소를 사용할 수 없습니다.',
  BATCH_NOT_FOUND: '의류 등록 배치를 찾을 수 없습니다.',
  TOO_MANY_OPEN_BATCHES: '완료되지 않은 업로드 배치가 너무 많습니다.',
  INVALID_BATCH_STATE: '현재 배치 상태에서는 요청을 처리할 수 없습니다.',
  UPLOAD_NOT_FOUND: '업로드된 이미지를 찾을 수 없습니다.',
  ANALYSIS_JOB_NOT_FOUND: '분석 작업을 찾을 수 없습니다.',
  GARMENT_DRAFT_NOT_FOUND: '의류 분석 초안을 찾을 수 없습니다.',
  ANALYSIS_CONFLICT: '분석 작업의 현재 상태와 요청이 충돌합니다.',
  ANALYSIS_FAILED: '의류 분석 작업이 실패했습니다.',
  UNSUPPORTED_LOCATION: '지원하지 않는 위치입니다.',
  WEATHER_UNAVAILABLE: '날씨 정보를 사용할 수 없습니다.',
  RECOMMENDATION_NOT_FOUND: '추천 결과를 찾을 수 없습니다.',
  RECOMMENDATION_CONFLICT: '추천 결과의 현재 상태와 요청이 충돌합니다.',
  OOTD_DATE_CONFLICT: '해당 날짜에 다른 착장 기록이 있습니다.',
  INTERNAL_INTEGRATION_NOT_CONFIGURED: '내부 분석 연동이 설정되지 않았습니다.',
  INVALID_WORKER_SIGNATURE: '분석 결과 요청을 인증할 수 없습니다.',
  INVALID_REQUEST_BODY: 'JSON 요청 본문을 확인해 주세요.',
  VALIDATION_ERROR: '요청 값이 유효하지 않습니다.',
  UNSUPPORTED_FIELD: '아직 지원하지 않는 필드입니다.',
  SAVED_OUTFIT_NOT_FOUND: '저장 코디를 찾을 수 없습니다.',
  OOTD_NOT_FOUND: '착장 기록을 찾을 수 없습니다.',
  OUTFIT_CONFLICT: '현재 코디 상태와 요청이 충돌합니다.',
  OOTD_IN_USE: '공유 게시물에서 사용 중인 착장 기록입니다.',
  FEED_POST_NOT_FOUND: '피드 게시물을 찾을 수 없습니다.',
  FEED_MEDIA_NOT_FOUND: '피드 미디어를 찾을 수 없습니다.',
  FEED_CONFLICT: '현재 피드 상태와 요청이 충돌합니다.',
  MIMIC_JOB_NOT_FOUND: '따라입기 작업을 찾을 수 없습니다.',
  MIMIC_CONFLICT: '현재 따라입기 작업 상태와 요청이 충돌합니다.',
  INTERNAL_ERROR: '서버 내부 오류가 발생했습니다.'
});

export function baseHeaders(requestId) {
  return {
    'Cache-Control': 'no-store',
    'Content-Type': 'application/json; charset=utf-8',
    'X-Request-Id': requestId
  };
}

export function failure(status, code, requestId, retryable = false, extraHeaders = {}) {
  return {
    status,
    headers: { ...baseHeaders(requestId), ...extraHeaders },
    body: { error: { code, message: MESSAGES[code] ?? MESSAGES.INTERNAL_ERROR, retryable, request_id: requestId } }
  };
}
