import test from 'node:test';
import assert from 'node:assert/strict';
import { createHandler as statistics } from '../api/v1/closet/statistics.js';

// 2026-10-10 track C: '최다 추구미' is computed in get_my_closet_statistics (SQL test: reco_weather_stats.sql);
// the API only validates and projects it.
const requestId = '11111111-1111-4111-8111-111111111111'; const userId = '22222222-2222-4222-8222-222222222222';
const topId = '55555555-5555-4555-8555-555555555555'; const minimalId = '77777777-7777-4777-8777-777777777777';
const casualId = '99999999-9999-4999-8999-999999999999';
const env = { SUPABASE_URL: 'https://abcdefghijklmnopqrst.supabase.co', SUPABASE_PUBLISHABLE_KEY: 'publishable-test' };
function response(status, body) { return { status, headers: { get: () => null }, async json() { return body; } }; }
function invoke(body) { const out = { headers: {} };
  const req = { method: 'GET', query: {}, headers: { authorization: 'Bearer header.payload.signature' } };
  const res = { setHeader(k, v) { out.headers[k] = v; }, status(v) { out.statusCode = v; return this; }, json(v) { out.body = v; return out; }, end() { return out; } };
  return statistics({ env, createRequestId: () => requestId, request: async url => String(url).includes('/auth/v1/user')
    ? response(200, { id: userId }) : response(200, body) })(req, res);
}
const base = { as_of: '2026-10-10', wear_counts: [{ garment_id: topId, count: 3 }], unworn_30_days: [] };
const totals = [{ aesthetic_id: minimalId, code: 'minimal', label: '미니멀', score_total: 2.4 },
  { aesthetic_id: casualId, code: 'casual', label: '캐주얼', score_total: 0.9 }];

test('statistics project the most-worn aesthetic and the per-aesthetic totals', async () => {
  const result = await invoke({ ...base, aesthetic_totals: totals, top_aesthetic: totals[0] });
  assert.equal(result.statusCode, 200);
  assert.deepEqual(result.body.top_aesthetic, totals[0]); assert.deepEqual(result.body.aesthetic_totals, totals);
});

test('statistics return null top aesthetic when nothing worn has aesthetic scores', async () => {
  const result = await invoke({ ...base, aesthetic_totals: [], top_aesthetic: null });
  assert.equal(result.statusCode, 200); assert.equal(result.body.top_aesthetic, null); assert.deepEqual(result.body.aesthetic_totals, []);
});

test('statistics fail closed on an inconsistent or missing aesthetic aggregate', async () => {
  for (const body of [base, { ...base, aesthetic_totals: totals, top_aesthetic: null },
    { ...base, aesthetic_totals: totals, top_aesthetic: totals[1] }, { ...base, aesthetic_totals: [], top_aesthetic: totals[0] },
    { ...base, aesthetic_totals: [{ ...totals[0], score_total: 'x' }], top_aesthetic: totals[0] }]) {
    const result = await invoke(body); assert.equal(result.statusCode, 500);
  }
});
