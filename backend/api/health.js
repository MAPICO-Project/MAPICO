import { readOnly } from '../lib/http.js';

export default function handler(req, res) {
  return readOnly(req, res, {
    service: 'mafico-backend-preview',
    projectName: '마피코',
    status: 'ok',
    stage: 'deployment-smoke-test',
    productApiImplemented: false,
    note: 'HTTP 런타임 확인용입니다. 인증·옷장·추천·피드 API의 준비 상태를 뜻하지 않습니다.'
  });
}
