import test from 'node:test';
import assert from 'node:assert/strict';
import { createHandler as createRecommendation } from '../api/v1/recommendations/index.js';
import { createHandler as getRecommendation } from '../api/v1/recommendations/[recommendationId]/index.js';
import { createHandler as acceptRecommendation } from '../api/v1/recommendations/[recommendationId]/accept.js';

const requestId = '11111111-1111-4111-8111-111111111111'; const userId = '22222222-2222-4222-8222-222222222222';
const recommendationId = '33333333-3333-4333-8333-333333333333'; const snapshotId = '44444444-4444-4444-8444-444444444444';
const outfitId = '55555555-5555-4555-8555-555555555555'; const topId = '66666666-6666-4666-8666-666666666666';
const bottomId = '77777777-7777-4777-8777-777777777777'; const ootdId = '88888888-8888-4888-8888-888888888888';
const aestheticId = '99999999-9999-4999-8999-999999999999';
const reservationToken = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const env = { SUPABASE_URL: 'https://abcdefghijklmnopqrst.supabase.co', SUPABASE_PUBLISHABLE_KEY: 'publishable-test',
  SUPABASE_SECRET_KEY: 'fixture-server-secret-key-long-enough' };
function response(status, body, headers = {}) { return { status, headers: { get: n => headers[n.toLowerCase()] ?? null }, async json() { return body; } }; }
function invoke(create, request, { method = 'GET', query = {}, body, headers = {} } = {}) { const out = { headers: {} };
  const reqHeaders = { authorization: 'Bearer header.payload.signature', ...headers }; if (body !== undefined) reqHeaders['content-type'] = 'application/json';
  const req = { method, query, body, headers: reqHeaders }; const res = { setHeader(k, v) { out.headers[k] = v; }, status(v) { out.statusCode = v; return this; },
    json(v) { out.body = v; return out; }, end() { return out; } };
  return create({ env, request, now: () => new Date('2026-10-01T03:05:00.000Z'), createRequestId: () => requestId })(req, res);
}
const weatherRow = { id: snapshotId, source: 'kma_short_term', issued_at: '2026-10-01T02:00:00.000Z', valid_at: '2026-10-01T03:00:00.000Z',
  fetched_at: '2026-10-01T03:00:00.000Z', grid_x: 62, grid_y: 89, payload: { temperature_c: 18, feels_like_c: null,
    precipitation_probability: 0, precipitation_type: 'none', humidity: 50, air_quality: null } };
const requestRow = { id: recommendationId, weather_snapshot_id: snapshotId, tpo: null, target_date: '2026-10-01', requested_count: 1,
  status: 'ready', engine_version: 'deterministic-g5-v1', rules_version: 'weather-category-g5-v1', shortfall_reasons: [],
  created_at: '2026-10-01T03:05:00.000Z', expires_at: '2026-10-02T03:05:00.000Z', weather_was_stale: false };
function successRequest() { return async (url, options) => { const value = String(url);
  if (value.includes('/auth/v1/user')) return response(200, { id: userId });
  if (value.includes('/rpc/begin_my_recommendation')) return response(200, { request_id: recommendationId, replayed: false,
    in_progress: false, reservation_token: reservationToken, lease_expires_at: '2026-10-01T03:07:00.000Z' });
  if (value.includes('/rpc/find_weather_snapshot')) return response(200, weatherRow);
  if (value.includes('/rest/v1/garments')) return response(200, [{ id: topId, category: 'top' }, { id: bottomId, category: 'bottom' }]);
  if (value.includes('/rest/v1/user_aesthetic_preferences')) return response(200, [{ aesthetic_id: aestheticId, weight: 1, role: 'main' }]);
  if (value.includes('/rest/v1/garment_aesthetic_scores')) return response(200, [
    { garment_id: topId, aesthetic_id: aestheticId, score: 0.9 }, { garment_id: bottomId, aesthetic_id: aestheticId, score: 0.7 }]);
  if (value.includes('/rpc/store_recommendation')) return response(200, { recommendation_id: recommendationId, replayed: false });
  if (value.includes('/rest/v1/recommendation_requests')) return response(200, [requestRow]);
  if (value.includes('/rest/v1/outfit_recommendations')) return response(200, [{ id: outfitId, rank: 1,
    scores: { weather: 0.8, tpo: null, aesthetic: 0.5, harmony: 0.8 }, reason_facts: ['temperature_band:mild'],
    explanation: '현재 날씨 구간과 선택한 카테고리 조합을 기준으로 만든 코디입니다.', explanation_source: 'template' }]);
  if (value.includes('/rest/v1/outfit_items')) return response(200, [{ outfit_id: outfitId, garment_id: topId, slot: '0' },
    { outfit_id: outfitId, garment_id: bottomId, slot: '1' }]);
  if (value.includes('/rpc/get_weather_snapshot')) return response(200, weatherRow);
  assert.fail(`unexpected ${value}`);
}; }

test('recommendation create reserves idempotency before weather and returns stored safe projection', async () => {
  const calls = []; let storedBody; const request = successRequest();
  const result = await invoke(createRecommendation, async (url, options) => { calls.push(String(url));
    if (String(url).includes('/rpc/store_recommendation')) storedBody = JSON.parse(options.body);
    return request(url, options); }, {
    method: 'POST', headers: { 'idempotency-key': 'recommend-one' }, body: { location: { lat: 37.45, lon: 127.12 }, requested_count: 1 } });
  assert.equal(result.statusCode, 201); assert.equal(result.body.id, recommendationId); assert.equal(result.body.outfits[0].garment_ids.length, 2);
  assert.ok(calls.findIndex(value => value.includes('/rpc/begin_my_recommendation')) < calls.findIndex(value => value.includes('/rpc/find_weather_snapshot')));
  assert.equal(storedBody.p_outfits[0].scores.aesthetic, 0.8);
  assert.equal(storedBody.p_reservation_token, reservationToken);
  assert.equal(JSON.stringify(result).includes('payload'), false); assert.equal(JSON.stringify(result).includes('preference_snapshot'), false);
});

test('recommendation get hides cross-owner absence', async () => {
  const result = await invoke(getRecommendation, async url => String(url).includes('/auth/v1/user') ? response(200, { id: userId }) : response(200, []),
    { query: { recommendationId } });
  assert.equal(result.statusCode, 404);
});

test('recommendation accept uses path-bound RPC and returns exact private OOTD', async () => {
  const calls = []; const result = await invoke(acceptRecommendation, async (url, options) => { calls.push({ url: String(url), options });
    if (String(url).includes('/auth/v1/user')) return response(200, { id: userId });
    if (String(url).includes('/rpc/accept_my_recommendation')) return response(200, { ootd_id: ootdId, replayed: false });
    if (String(url).includes('/rpc/get_my_ootd_weather')) return response(200, [{ weather_snapshot_id: snapshotId,
      valid_at: '2026-10-01T03:00:00+00:00', temperature_c: 4, feels_like_c: 1.5, precipitation_type: 'snow', precipitation_probability: 60 }]);
    if (String(url).includes('/rest/v1/ootd_entries')) return response(200, [{ id: ootdId, worn_on: '2026-10-01', saved_outfit_id: null,
      outfit_id: outfitId, wear_status: 'worn', note: null, rating: null, weather_snapshot_id: snapshotId, version: 1,
      created_at: '2026-10-01T03:06:00.000Z', visibility: 'private', item_snapshot: [
        { garment_id: topId, category: 'top', unavailable: false }, { garment_id: bottomId, category: 'bottom', unavailable: false }] }]);
    assert.fail(`unexpected ${url}`);
  }, { method: 'POST', query: { recommendationId }, headers: { 'idempotency-key': 'accept-one' },
    body: { outfit_id: outfitId, worn_on: '2026-10-01' } });
  assert.equal(result.statusCode, 201); assert.equal(result.body.id, ootdId);
  assert.match(calls[1].url, /\/rpc\/accept_my_recommendation$/);
  assert.equal(result.body.photo, null);
  assert.deepEqual(result.body.weather, { weather_code: 'snow', temperature_c: 4, feels_like_c: 1.5, precipitation_type: 'snow',
    precipitation_probability: 60, valid_at: '2026-10-01T03:00:00+00:00' });
  assert.equal(JSON.parse(calls[1].options.body).p_recommendation_id, recommendationId);
});

test('recommendation accept rejects impossible calendar dates before authentication', async () => {
  const result = await invoke(acceptRecommendation, async () => assert.fail('network'), { method: 'POST',
    query: { recommendationId }, headers: { 'idempotency-key': 'accept-invalid' },
    body: { outfit_id: outfitId, worn_on: '2026-02-31' } });
  assert.equal(result.statusCode, 422);
});

// 2026-10-10 track C: home aesthetic chip, wardrobe sufficiency (2 garments), region selection.
const subAestheticId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'; const otherAestheticId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const top2Id = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'; const shoesId = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
function scenario({ garments, preferences = [{ aesthetic_id: aestheticId, weight: 0.6, role: 'main' },
  { aesthetic_id: subAestheticId, weight: 0.4, role: 'sub' }], scores = [], requestOverride = {} }) {
  const captured = { calls: [] }; const base = successRequest();
  const request = async (url, options) => { const value = String(url); captured.calls.push(value);
    if (value.includes('/rpc/begin_my_recommendation')) captured.begin = JSON.parse(options.body);
    if (value.includes('/rpc/store_recommendation')) captured.store = JSON.parse(options.body);
    if (value.includes('/rest/v1/garments')) return response(200, garments);
    if (value.includes('/rest/v1/user_aesthetic_preferences')) return response(200, preferences);
    if (value.includes('/rest/v1/garment_aesthetic_scores')) return response(200, scores);
    if (value.includes('/rest/v1/recommendation_requests')) return response(200, [{ ...requestRow, ...requestOverride }]);
    return base(url, options); };
  return { captured, request };
}
const create = (request, body) => invoke(createRecommendation, request, { method: 'POST', headers: { 'idempotency-key': 'recommend-c' }, body });

test('home chip: default is main, a selected sub outranks it, and the choice is reserved and hashed', async () => {
  const garments = [{ id: topId, category: 'top' }, { id: top2Id, category: 'top' }, { id: bottomId, category: 'bottom' }];
  const scores = [{ garment_id: topId, aesthetic_id: aestheticId, score: 0.9 }, { garment_id: topId, aesthetic_id: subAestheticId, score: 0.1 },
    { garment_id: top2Id, aesthetic_id: aestheticId, score: 0.1 }, { garment_id: top2Id, aesthetic_id: subAestheticId, score: 0.9 }];
  const main = scenario({ garments, scores }); const mainResult = await create(main.request, { location: { lat: 37.45, lon: 127.12 }, requested_count: 1 });
  assert.equal(mainResult.statusCode, 201); assert.equal(main.captured.begin.p_selected_aesthetic_id, aestheticId);
  assert.ok(main.captured.store.p_outfits[0].items.some(item => item.garment_id === topId));
  assert.ok(main.captured.store.p_outfits[0].reason_facts.includes(`selected_aesthetic:${aestheticId}`));
  const sub = scenario({ garments, scores }); await create(sub.request, { location: { lat: 37.45, lon: 127.12 }, requested_count: 1, aesthetic_id: subAestheticId });
  assert.equal(sub.captured.begin.p_selected_aesthetic_id, subAestheticId);
  assert.ok(sub.captured.store.p_outfits[0].items.some(item => item.garment_id === top2Id));
  assert.notEqual(sub.captured.begin.p_request_hash, main.captured.begin.p_request_hash);
});

test('home chip outside the user preferences is a validation error before reservation', async () => {
  const { captured, request } = scenario({ garments: [] });
  const result = await create(request, { location: { lat: 37.45, lon: 127.12 }, aesthetic_id: otherAestheticId });
  assert.equal(result.statusCode, 422); assert.equal(captured.begin, undefined);
  const malformed = await create(request, { location: { lat: 37.45, lon: 127.12 }, aesthetic_id: 'minimal' });
  assert.equal(malformed.statusCode, 422);
  const tpo = await create(request, { location: { lat: 37.45, lon: 127.12 }, tpo: 'office_business' });
  assert.equal(tpo.statusCode, 422);
});

test('wardrobe of 1 garment is insufficient: no outfits and explicit reasons', async () => {
  const { captured, request } = scenario({ garments: [{ id: topId, category: 'top' }] });
  await create(request, { location: { lat: 37.45, lon: 127.12 } });
  assert.deepEqual(captured.store.p_outfits, []);
  assert.deepEqual(captured.store.p_shortfall_reasons, ['insufficient_wardrobe', 'missing_category:bottom', 'missing_category:shoes']);
});

test('wardrobe of 2 garments without a bottom still yields an outfit and names the missing parts', async () => {
  const { captured, request } = scenario({ garments: [{ id: topId, category: 'top' }, { id: shoesId, category: 'shoes' }] });
  await create(request, { location: { lat: 37.45, lon: 127.12 } });
  assert.equal(captured.store.p_outfits.length, 1);
  assert.deepEqual(captured.store.p_outfits[0].items.map(item => item.garment_id), [topId, shoesId]);
  assert.deepEqual(captured.store.p_shortfall_reasons, ['missing_category:bottom', 'requested_count_not_reached']);
});

test('wardrobe of 3 garments returns as many distinct outfits as possible (fewer than 3) with a reason', async () => {
  const { captured, request } = scenario({ garments: [{ id: topId, category: 'top' }, { id: top2Id, category: 'top' },
    { id: bottomId, category: 'bottom' }] });
  await create(request, { location: { lat: 37.45, lon: 127.12 }, requested_count: 3 });
  assert.equal(captured.store.p_outfits.length, 2);
  assert.equal(new Set(captured.store.p_outfits.map(outfit => outfit.items.map(item => item.garment_id).sort().join(','))).size, 2);
  assert.deepEqual(captured.store.p_shortfall_reasons, ['missing_category:shoes', 'requested_count_not_reached']);
});

test('recommendation accepts a province region code instead of coordinates', async () => {
  const { captured, request } = scenario({ garments: [{ id: topId, category: 'top' }, { id: bottomId, category: 'bottom' }] });
  const result = await create(request, { location: { region_code: 'seoul' } });
  assert.equal(result.statusCode, 201); assert.equal(captured.begin.p_grid_x, 60); assert.equal(captured.begin.p_grid_y, 91);
  for (const location of [{ region_code: 'tokyo' }, { region_code: 'seoul', lat: 37.5, lon: 127 }, {}]) {
    const bad = await create(async () => assert.fail('network'), { location });
    assert.equal(bad.statusCode, 422);
  }
});

test('recommendation projection exposes the selected chip and parsed missing categories', async () => {
  const { request } = scenario({ garments: [], requestOverride: { selected_aesthetic_id: subAestheticId,
    shortfall_reasons: ['missing_category:bottom', 'requested_count_not_reached'] } });
  const result = await invoke(getRecommendation, request, { query: { recommendationId } });
  assert.equal(result.statusCode, 200); assert.equal(result.body.selected_aesthetic_id, subAestheticId);
  assert.deepEqual(result.body.missing_categories, ['bottom']);
  const legacy = scenario({ garments: [], requestOverride: { shortfall_reasons: ['missing_complete_base_outfit'] } });
  const legacyResult = await invoke(getRecommendation, legacy.request, { query: { recommendationId } });
  assert.equal(legacyResult.body.selected_aesthetic_id, null); assert.deepEqual(legacyResult.body.missing_categories, []);
});

test('two garments of one category never produce a one-item outfit and fall back to shortfall reasons', async () => {
  const bag2Id = 'ffffffff-ffff-4fff-8fff-ffffffffffff';
  for (const garments of [[{ id: topId, category: 'bag' }, { id: bag2Id, category: 'bag' }],
    [{ id: topId, category: 'top' }, { id: top2Id, category: 'top' }]]) {
    const { captured, request } = scenario({ garments });
    await create(request, { location: { lat: 37.45, lon: 127.12 } });
    assert.deepEqual(captured.store.p_outfits, []);
    assert.equal(captured.store.p_shortfall_reasons[0], 'insufficient_wardrobe');
    assert.ok(captured.store.p_shortfall_reasons.includes('missing_category:bottom'));
  }
  const { captured, request } = scenario({ garments: [{ id: topId, category: 'top' }, { id: bag2Id, category: 'bag' }] });
  await create(request, { location: { lat: 37.45, lon: 127.12 } });
  assert.deepEqual(captured.store.p_outfits.map(outfit => outfit.items.length), [2]);
});
