import test from 'node:test';
import assert from 'node:assert/strict';
import { createHandler as savedCollection } from '../api/v1/saved-outfits/index.js';
import { createHandler as savedItem } from '../api/v1/saved-outfits/[savedOutfitId]/index.js';
import { createHandler as ootdCollection } from '../api/v1/ootd/index.js';
import { createHandler as ootdItem } from '../api/v1/ootd/[ootdId]/index.js';
import { createHandler as statistics } from '../api/v1/closet/statistics.js';

const requestId = '11111111-1111-4111-8111-111111111111';
const userId = '22222222-2222-4222-8222-222222222222';
const savedId = '33333333-3333-4333-8333-333333333333';
const ootdId = '44444444-4444-4444-8444-444444444444';
const topId = '55555555-5555-4555-8555-555555555555';
const bottomId = '66666666-6666-4666-8666-666666666666';
const topAssetId = '88888888-8888-4888-8888-888888888888';
const bottomAssetId = '99999999-9999-4999-8999-999999999999';
const env = { SUPABASE_URL: 'https://abcdefghijklmnopqrst.supabase.co', SUPABASE_PUBLISHABLE_KEY: 'publishable-test' };
const savedRow = { id: savedId, title: 'Office', note: null, source_recommendation_id: null, version: 1, created_at: '2026-10-01T01:00:00.000Z' };
const ootdRow = { id: ootdId, worn_on: '2026-10-01', saved_outfit_id: savedId, outfit_id: null, wear_status: 'worn', note: null,
  rating: 5, weather_snapshot_id: null, version: 1, created_at: '2026-10-01T02:00:00.000Z', visibility: 'private',
  item_snapshot: [{ garment_id: topId, category: 'top', unavailable: false }, { garment_id: bottomId, category: 'bottom', unavailable: false }] };

function response(status, body, headers = {}) { return { status, headers: { get: name => headers[name.toLowerCase()] ?? null }, async json() { return body; } }; }
function invoke(create, request, { method = 'GET', query = {}, body, headers = {} } = {}) {
  const out = { headers: {} }; const reqHeaders = { authorization: 'Bearer header.payload.signature', ...headers };
  if (body !== undefined) reqHeaders['content-type'] = 'application/json';
  const req = { method, query, body, headers: reqHeaders }; const res = { setHeader(k, v) { out.headers[k] = v; }, status(v) { out.statusCode = v; return this; },
    json(v) { out.body = v; return out; }, end() { out.ended = true; return out; } };
  return create({ env, request, createRequestId: () => requestId })(req, res);
}
const auth = url => String(url).includes('/auth/v1/user') ? response(200, { id: userId }) : null;

test('saved outfit create uses narrow RPC then overlays unavailable garments in the safe DTO', async () => {
  let rpcBody; const result = await invoke(savedCollection, async (url, options) => {
    const a = auth(url); if (a) return a; const value = String(url);
    if (value.includes('/rpc/create_my_saved_outfit')) { rpcBody = JSON.parse(options.body); return response(200, { saved_outfit_id: savedId, replayed: false }); }
    if (value.includes('/rest/v1/saved_outfits')) return response(200, [savedRow]);
    if (value.includes('/rest/v1/saved_outfit_items')) return response(200, [
      { saved_outfit_id: savedId, garment_id: topId, position: 0 }, { saved_outfit_id: savedId, garment_id: bottomId, position: 1 }]);
    if (value.includes('/rest/v1/garment_assets')) return response(200, [{ id: topAssetId }]);
    if (value.includes('/rest/v1/garments')) return response(200, [{ id: topId, asset_id: topAssetId }, { id: bottomId, asset_id: bottomAssetId }]);
    assert.fail(`unexpected ${value}`);
  }, { method: 'POST', headers: { 'idempotency-key': 'saved-one' }, body: { title: 'Office', garment_ids: [topId, bottomId] } });
  assert.equal(result.statusCode, 201); assert.deepEqual(result.body.unavailable_garment_ids, [bottomId]);
  assert.deepEqual(rpcBody.p_garment_ids, [topId, bottomId]); assert.equal(JSON.stringify(result).includes('user_id'), false);
});

test('saved outfit patch preserves null presence and delete is a bodyless 204', async () => {
  let patchBody; const request = async (url, options) => { const a = auth(url); if (a) return a; const value = String(url);
    if (value.includes('/rpc/update_my_saved_outfit')) { patchBody = JSON.parse(options.body); return response(200, { saved_outfit_id: savedId, version: 2 }); }
    if (value.includes('/rpc/delete_my_saved_outfit')) return response(204, null);
    if (value.includes('/rest/v1/saved_outfits')) return response(200, [{ ...savedRow, note: null, version: 2 }]);
    if (value.includes('/rest/v1/saved_outfit_items')) return response(200, [{ saved_outfit_id: savedId, garment_id: topId, position: 0 }]);
    if (value.includes('/rest/v1/garment_assets')) return response(200, [{ id: topAssetId }]);
    if (value.includes('/rest/v1/garments')) return response(200, [{ id: topId, asset_id: topAssetId }]); assert.fail(`unexpected ${value}`); };
  const patched = await invoke(savedItem, request, { method: 'PATCH', query: { savedOutfitId: savedId }, body: { expected_version: 1, note: null } });
  assert.equal(patched.statusCode, 200); assert.equal(patchBody.p_has_note, true); assert.equal(patchBody.p_note, null);
  const deleted = await invoke(savedItem, request, { method: 'DELETE', query: { savedOutfitId: savedId } });
  assert.equal(deleted.statusCode, 204); assert.equal(deleted.ended, true); assert.equal('body' in deleted, false);
});

test('manual OOTD creation uses the exact source fields and recomputes snapshot availability', async () => {
  let rpcBody; const result = await invoke(ootdCollection, async (url, options) => { const a = auth(url); if (a) return a; const value = String(url);
    if (value.includes('/rpc/create_my_ootd')) { rpcBody = JSON.parse(options.body); return response(200, { ootd_id: ootdId, replayed: false }); }
    if (value.includes('/rest/v1/ootd_entries')) return response(200, [ootdRow]);
    if (value.includes('/rest/v1/garment_assets')) return response(200, [{ id: topAssetId }]);
    if (value.includes('/rest/v1/garments')) return response(200, [{ id: topId, asset_id: topAssetId }, { id: bottomId, asset_id: bottomAssetId }]); assert.fail(`unexpected ${value}`);
  }, { method: 'POST', headers: { 'idempotency-key': 'ootd-one' }, body: { worn_on: '2026-10-01', garment_ids: [topId, bottomId],
    saved_outfit_id: savedId, wear_status: 'worn', rating: 5 } });
  assert.equal(result.statusCode, 201); assert.equal(result.body.item_snapshot[1].unavailable, true);
  assert.equal(rpcBody.p_saved_outfit_id, savedId); assert.equal(rpcBody.p_outfit_id, null);
});

test('OOTD list binds dates into its cursor and invalid source/rating combinations fail before auth', async () => {
  const network = async (url) => { const a = auth(url); if (a) return a; const value = String(url);
    if (value.includes('/rest/v1/ootd_entries')) return response(200, [ootdRow, { ...ootdRow, id: '77777777-7777-4777-8777-777777777777', worn_on: '2026-09-30' }]);
    if (value.includes('/rest/v1/garment_assets')) return response(200, [{ id: topAssetId }, { id: bottomAssetId }]);
    if (value.includes('/rest/v1/garments')) return response(200, [{ id: topId, asset_id: topAssetId }, { id: bottomId, asset_id: bottomAssetId }]); assert.fail(`unexpected ${value}`); };
  const page = await invoke(ootdCollection, network, { query: { from: '2026-09-01', to: '2026-10-01', limit: '1' } });
  assert.equal(page.statusCode, 200); assert.equal(typeof page.body.next_cursor, 'string');
  const rebound = await invoke(ootdCollection, async () => assert.fail('network'), { query: { from: '2026-08-01', to: '2026-10-01', cursor: page.body.next_cursor } });
  assert.equal(rebound.statusCode, 400);
  const invalid = await invoke(ootdCollection, async () => assert.fail('network'), { method: 'POST', headers: { 'idempotency-key': 'invalid-one' },
    body: { worn_on: '2026-10-01', garment_ids: [topId], saved_outfit_id: savedId, outfit_id: ootdId, wear_status: 'planned', rating: 3 } });
  assert.equal(invalid.statusCode, 422);
});

test('saved list rejects impossible timestamp cursors before authentication', async () => {
  const cursor = Buffer.from(JSON.stringify({ v: 1, kind: 'saved', created_at: '2026-99-31T01:00:00Z', id: savedId })).toString('base64url');
  const result = await invoke(savedCollection, async () => assert.fail('network'), { query: { cursor } });
  assert.equal(result.statusCode, 400);
});

test('OOTD delete requires idempotency and statistics accept only the safe aggregate projection', async () => {
  const noKey = await invoke(ootdItem, async () => assert.fail('network'), { method: 'DELETE', query: { ootdId } }); assert.equal(noKey.statusCode, 422);
  const deleted = await invoke(ootdItem, async (url) => auth(url) ?? response(200, { ootd_id: ootdId, replayed: false }),
    { method: 'DELETE', query: { ootdId }, headers: { 'idempotency-key': 'delete-one' } });
  assert.equal(deleted.statusCode, 204); assert.equal(deleted.ended, true);
  const stats = await invoke(statistics, async (url) => auth(url) ?? response(200, { as_of: '2026-10-01', wear_counts: [{ garment_id: topId, count: 2 }], unworn_30_days: [bottomId], ignored: 'x' }));
  assert.deepEqual(stats.body, { as_of: '2026-10-01', wear_counts: [{ garment_id: topId, count: 2 }], unworn_30_days: [bottomId] });
});
