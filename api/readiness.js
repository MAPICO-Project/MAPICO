import { readOnly } from '../lib/http.js';

export default function handler(req, res) {
  return readOnly(req, res, {
    ready: false,
    code: 'PRODUCT_BACKEND_NOT_READY',
    dependencies: {
      supabase: 'not_integrated',
      kakaoAuth: 'not_integrated',
      weather: 'not_integrated',
      aiWorker: 'not_integrated'
    }
  }, 503);
}
