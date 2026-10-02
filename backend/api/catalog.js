import { readOnly } from '../lib/http.js';

export default function handler(req, res) {
  return readOnly(req, res, {
    source: 'prd-2026-09-28',
    persistence: 'none',
    contract: 'preview-only-not-openapi-v0.2',
    aesthetics: [
      { code: 'feminine', label: '페미닌' },
      { code: 'y2k', label: 'Y2K' },
      { code: 'minimal', label: '미니멀' },
      { code: 'grunge', label: '그런지' },
      { code: 'casual', label: '캐주얼' }
    ]
  });
}
