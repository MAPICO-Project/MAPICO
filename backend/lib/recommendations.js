import { createHash } from 'node:crypto';
import { baseHeaders, failure } from './errors.js';
import { hasOnlyKeys, readJsonObject } from './json-body.js';
import { authenticatedUser } from './profile.js';
import { createInternalClient } from './supabase-internal.js';
import { currentWeatherSlot, resolveWeather, weatherGrid } from './weather.js';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DATE = /^\d{4}-\d{2}-\d{2}$/;
const ENGINE_VERSION = 'deterministic-g5-v1';
const RULES_VERSION = 'weather-category-g5-v1';
const CREATE_KEYS = new Set(['location', 'tpo', 'requested_count']);
const LOCATION_KEYS = new Set(['lat', 'lon']);
const ACCEPT_KEYS = new Set(['outfit_id', 'worn_on']);
const STATUSES = new Set(['ready', 'insufficient_wardrobe']);
function validDate(value) {
  if (typeof value !== 'string' || !DATE.test(value)) return false;
  const parsed = new Date(`${value}T00:00:00.000Z`);
  return Number.isFinite(parsed.getTime()) && parsed.toISOString().slice(0, 10) === value;
}

function pathId(req, name) { const value = req.query?.[name]; return typeof value === 'string' && UUID.test(value) ? value.toLowerCase() : null; }
function idempotencyKey(req) { const value = req.headers?.['idempotency-key'] ?? req.headers?.['Idempotency-Key'];
  return typeof value === 'string' && value.length >= 8 && value.length <= 128 && /^[A-Za-z0-9._:-]+$/.test(value) ? value : null; }
function validateLocation(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value) || !hasOnlyKeys(value, LOCATION_KEYS) ||
      !Number.isFinite(value.lat) || !Number.isFinite(value.lon) || value.lat < -90 || value.lat > 90 || value.lon < -180 || value.lon > 180) return null;
  return weatherGrid(value.lat, value.lon) ? { lat: value.lat, lon: value.lon } : null;
}
function createInput(req, requestId) {
  const parsed = readJsonObject(req); if (parsed.error) return { error: failure(400, parsed.error, requestId) };
  const value = parsed.data; const location = validateLocation(value.location); const count = value.requested_count ?? 3;
  if (!hasOnlyKeys(value, CREATE_KEYS) || !location || (value.tpo !== undefined && value.tpo !== null) ||
      !Number.isInteger(count) || count < 1 || count > 3) return { error: failure(422, 'VALIDATION_ERROR', requestId) };
  return { data: { location, requested_count: count, tpo: null } };
}
function stableHash(value) { return createHash('sha256').update(JSON.stringify(value)).digest('hex'); }

function combinations(rows, weather, count, aestheticByGarment) {
  const by = new Map(); for (const row of rows) { if (!by.has(row.category)) by.set(row.category, []); by.get(row.category).push(row.id); }
  for (const values of by.values()) values.sort();
  const bases = [];
  for (const id of by.get('dress') ?? []) bases.push([id]);
  for (const top of by.get('top') ?? []) for (const bottom of by.get('bottom') ?? []) bases.push([top, bottom]);
  bases.sort((a, b) => a.join(':').localeCompare(b.join(':')));
  const shoes = by.get('shoes') ?? []; const outerwear = weather.temperature_c < 18 ? (by.get('outerwear') ?? []) : [];
  const candidates = [];
  for (let index = 0; index < bases.length; index += 1) {
    const ids = [...bases[index]]; if (shoes.length) ids.push(shoes[index % shoes.length]);
    if (outerwear.length) ids.push(outerwear[index % outerwear.length]);
    const garment_ids = [...new Set(ids)];
    const band = weather.temperature_c < 10 ? 'cold' : weather.temperature_c < 20 ? 'mild' : 'warm';
    const aesthetic = Math.round((garment_ids.reduce((sum, id) => sum + (aestheticByGarment.get(id) ?? 0.5), 0) / garment_ids.length) * 1000) / 1000;
    const reason_facts = [`temperature_band:${band}`, `precipitation:${weather.precipitation_type}`, `aesthetic_score:${aesthetic.toFixed(3)}`,
      `categories:${garment_ids.map(id => rows.find(row => row.id === id)?.category).join(',')}`];
    candidates.push({ garment_ids, scores: { weather: weather.temperature_c < 10 && !outerwear.length ? 0.55 : 0.8,
      tpo: null, aesthetic, harmony: garment_ids.length > 1 ? 0.8 : 0.6 }, reason_facts,
      explanation: `현재 날씨 구간과 선택한 카테고리 조합을 기준으로 만든 코디입니다.`, explanation_source: 'template' });
  }
  return candidates.sort((a, b) => b.scores.aesthetic - a.scores.aesthetic ||
    a.garment_ids.join(':').localeCompare(b.garment_ids.join(':'))).slice(0, count);
}
function validWeather(value, forcedStale) {
  const payload = value?.payload ?? value;
  if (!value || !UUID.test(value.id) || typeof value.source !== 'string' || !Number.isInteger(value.grid_x) || !Number.isInteger(value.grid_y) ||
      !Number.isFinite(payload.temperature_c) || typeof payload.precipitation_type !== 'string') return null;
  return { id: value.id.toLowerCase(), source: value.source, issued_at: value.issued_at, valid_at: value.valid_at,
    fetched_at: value.fetched_at, grid_x: value.grid_x, grid_y: value.grid_y, temperature_c: payload.temperature_c,
    feels_like_c: payload.feels_like_c ?? null, precipitation_probability: payload.precipitation_probability ?? null,
    precipitation_type: payload.precipitation_type, humidity: payload.humidity ?? null, air_quality: payload.air_quality ?? null,
    is_stale: forcedStale };
}
async function readRecommendation(client, internal, userId, recommendationId, requestId) {
  const requestResult = await client.select('recommendation_requests', [['select',
    'id,weather_snapshot_id,tpo,target_date,requested_count,status,engine_version,rules_version,shortfall_reasons,created_at,expires_at,weather_was_stale'],
    ['user_id', `eq.${userId}`], ['id', `eq.${recommendationId}`]]);
  if (requestResult.error) return requestResult;
  if (!Array.isArray(requestResult.data) || requestResult.data.length > 1) return { error: failure(500, 'INTERNAL_ERROR', requestId) };
  if (requestResult.data.length === 0) return { error: failure(404, 'RECOMMENDATION_NOT_FOUND', requestId) };
  const row = requestResult.data[0];
  const outfitResult = await client.select('outfit_recommendations', [['select', 'id,rank,scores,reason_facts,explanation,explanation_source'],
    ['user_id', `eq.${userId}`], ['request_id', `eq.${recommendationId}`], ['order', 'rank.asc']]);
  if (outfitResult.error) return outfitResult;
  const outfits = outfitResult.data;
  if (!Array.isArray(outfits) || outfits.length > 3) return { error: failure(500, 'INTERNAL_ERROR', requestId) };
  const ids = outfits.map(item => item.id);
  let itemRows = [];
  if (ids.length) {
    const itemResult = await client.select('outfit_items', [['select', 'outfit_id,garment_id,slot'], ['user_id', `eq.${userId}`],
      ['outfit_id', `in.(${ids.join(',')})`], ['order', 'slot.asc,garment_id.asc']]);
    if (itemResult.error) return itemResult; if (!Array.isArray(itemResult.data)) return { error: failure(500, 'INTERNAL_ERROR', requestId) };
    itemRows = itemResult.data;
  }
  const weatherResult = await internal.getWeatherSnapshot(row.weather_snapshot_id);
  if (weatherResult.error || weatherResult.missing) return { error: weatherResult.error ?? failure(500, 'INTERNAL_ERROR', requestId) };
  const weather = validWeather(weatherResult.data, row.weather_was_stale);
  if (!weather || !STATUSES.has(row.status) || !Number.isInteger(row.requested_count) || !Array.isArray(row.shortfall_reasons)) {
    return { error: failure(500, 'INTERNAL_ERROR', requestId) };
  }
  const projected = outfits.map(outfit => ({ id: outfit.id, garment_ids: itemRows.filter(item => item.outfit_id === outfit.id).map(item => item.garment_id),
    scores: outfit.scores, reason_facts: outfit.reason_facts, explanation: outfit.explanation, explanation_source: outfit.explanation_source }));
  if ((row.status === 'ready' && projected.length < 1) || (row.status === 'insufficient_wardrobe' && (projected.length || row.shortfall_reasons.length < 1))) {
    return { error: failure(500, 'INTERNAL_ERROR', requestId) };
  }
  return { data: { id: row.id, status: row.status, requested_count: row.requested_count, outfits: projected, tpo: row.tpo,
    weather, engine_version: row.engine_version, rules_version: row.rules_version, shortfall_reasons: row.shortfall_reasons,
    created_at: row.created_at, expires_at: row.expires_at, target_date: row.target_date } };
}

export async function createRecommendation(req, dependencies) {
  const input = createInput(req, dependencies.requestId); if (input.error) return input.error;
  const key = idempotencyKey(req); if (!key) return failure(422, 'VALIDATION_ERROR', dependencies.requestId);
  const auth = await authenticatedUser(req, dependencies); if (auth.error) return auth.error;
  const now = (dependencies.now ?? (() => new Date()))(); const slot = currentWeatherSlot(now);
  const grid = weatherGrid(input.data.location.lat, input.data.location.lon);
  const requestHash = stableHash({ grid, valid_at: slot, requested_count: input.data.requested_count, tpo: null,
    engine_version: ENGINE_VERSION, rules_version: RULES_VERSION });
  const reservation = await auth.client.rpc('begin_my_recommendation', { p_grid_x: grid.grid_x, p_grid_y: grid.grid_y,
    p_valid_at: slot, p_requested_count: input.data.requested_count, p_idempotency_key: key,
    p_request_hash: requestHash, p_engine_version: ENGINE_VERSION, p_rules_version: RULES_VERSION });
  if (reservation.error) return reservation.error;
  if (!reservation.data || !UUID.test(reservation.data.request_id)) return failure(500, 'INTERNAL_ERROR', dependencies.requestId);
  const internal = createInternalClient({ env: dependencies.env, request: dependencies.request ?? fetch, requestId: dependencies.requestId });
  if (internal.error) return internal.error;
  if (reservation.data.replayed === true && reservation.data.in_progress === true) {
    return failure(409, 'RECOMMENDATION_CONFLICT', dependencies.requestId, true);
  }
  if (reservation.data.replayed === true && UUID.test(reservation.data.recommendation_id ?? reservation.data.request_id)) {
    const replay = await readRecommendation(auth.client, internal, auth.user.id,
      (reservation.data.recommendation_id ?? reservation.data.request_id).toLowerCase(), dependencies.requestId);
    return replay.error ? replay.error : { status: 201, headers: baseHeaders(dependencies.requestId), body: replay.data };
  }
  if (!UUID.test(reservation.data.reservation_token)) return failure(500, 'INTERNAL_ERROR', dependencies.requestId);
  const weatherResult = await resolveWeather(input.data.location.lat, input.data.location.lon, { ...dependencies,
    request: dependencies.request ?? fetch, now: () => now, env: dependencies.env, requestId: dependencies.requestId });
  if (weatherResult.error) return weatherResult.error;
  const garmentsResult = await auth.client.select('garments', [['select', 'id,category'], ['user_id', `eq.${auth.user.id}`],
    ['deleted_at', 'is.null'], ['order', 'id.asc'], ['limit', '100']]);
  if (garmentsResult.error) return garmentsResult;
  if (!Array.isArray(garmentsResult.data) || garmentsResult.data.some(row => !UUID.test(row.id) || typeof row.category !== 'string')) {
    return failure(500, 'INTERNAL_ERROR', dependencies.requestId);
  }
  const preferencesResult = await auth.client.select('user_aesthetic_preferences', [['select', 'aesthetic_id,weight'],
    ['user_id', `eq.${auth.user.id}`], ['order', 'aesthetic_id.asc']]);
  if (preferencesResult.error) return preferencesResult.error;
  const scoresResult = await auth.client.select('garment_aesthetic_scores', [['select', 'garment_id,aesthetic_id,score'],
    ['user_id', `eq.${auth.user.id}`], ['order', 'garment_id.asc,aesthetic_id.asc']]);
  if (scoresResult.error) return scoresResult.error;
  if (!Array.isArray(preferencesResult.data) || !Array.isArray(scoresResult.data)) return failure(500, 'INTERNAL_ERROR', dependencies.requestId);
  const weights = new Map();
  for (const preference of preferencesResult.data) {
    if (!UUID.test(preference.aesthetic_id) || !Number.isFinite(preference.weight) || preference.weight <= 0 || preference.weight > 1) {
      return failure(500, 'INTERNAL_ERROR', dependencies.requestId);
    }
    weights.set(preference.aesthetic_id, preference.weight);
  }
  const weighted = new Map();
  for (const score of scoresResult.data) {
    if (!UUID.test(score.garment_id) || !UUID.test(score.aesthetic_id) || !Number.isFinite(score.score) || score.score < 0 || score.score > 1) {
      return failure(500, 'INTERNAL_ERROR', dependencies.requestId);
    }
    const weight = weights.get(score.aesthetic_id); if (weight === undefined) continue;
    const previous = weighted.get(score.garment_id) ?? { total: 0, weight: 0 };
    weighted.set(score.garment_id, { total: previous.total + score.score * weight, weight: previous.weight + weight });
  }
  const aestheticByGarment = new Map([...weighted].map(([id, value]) => [id, value.weight ? value.total / value.weight : 0.5]));
  const outfits = combinations(garmentsResult.data, weatherResult.data, input.data.requested_count, aestheticByGarment);
  const shortfall = outfits.length ? (outfits.length < input.data.requested_count ? ['requested_count_not_reached'] : []) : ['missing_complete_base_outfit'];
  const storedOutfits = outfits.map((outfit, index) => ({ rank: index + 1, scores: outfit.scores,
    reason_facts: outfit.reason_facts, explanation: outfit.explanation, explanation_source: outfit.explanation_source,
    items: outfit.garment_ids.map((garmentId, position) => ({ garment_id: garmentId, slot: String(position) })) }));
  const stored = await internal.storeRecommendation({ p_request_id: reservation.data.request_id,
    p_reservation_token: reservation.data.reservation_token, p_weather_snapshot_id: weatherResult.data.id,
    p_weather_was_stale: weatherResult.data.is_stale, p_outfits: storedOutfits, p_shortfall_reasons: shortfall });
  if (stored.error) return stored.error;
  const recommendationId = stored.data.recommendation_id ?? reservation.data.request_id;
  if (!UUID.test(recommendationId)) return failure(500, 'INTERNAL_ERROR', dependencies.requestId);
  const result = await readRecommendation(auth.client, internal, auth.user.id, recommendationId.toLowerCase(), dependencies.requestId);
  return result.error ? result.error : { status: 201, headers: baseHeaders(dependencies.requestId), body: result.data };
}

export async function getRecommendation(req, dependencies) {
  const id = pathId(req, 'recommendationId'); if (!id) return failure(422, 'VALIDATION_ERROR', dependencies.requestId);
  const auth = await authenticatedUser(req, dependencies); if (auth.error) return auth.error;
  const internal = createInternalClient({ env: dependencies.env, request: dependencies.request ?? fetch, requestId: dependencies.requestId });
  if (internal.error) return internal.error;
  const result = await readRecommendation(auth.client, internal, auth.user.id, id, dependencies.requestId);
  return result.error ? result.error : { status: 200, headers: baseHeaders(dependencies.requestId), body: result.data };
}

function validOotd(value) {
  if (!value || !UUID.test(value.id) || !validDate(value.worn_on) || !Array.isArray(value.garment_ids) || value.garment_ids.length < 1 ||
      value.garment_ids.length > 10 || value.garment_ids.some(id => !UUID.test(id)) || value.wear_status !== 'worn' || value.visibility !== 'private' ||
      !Array.isArray(value.item_snapshot) || value.item_snapshot.length !== value.garment_ids.length || !Number.isInteger(value.version)) return null;
  return { worn_on: value.worn_on, garment_ids: value.garment_ids, saved_outfit_id: null, outfit_id: value.outfit_id,
    wear_status: 'worn', note: null, rating: null, weather_snapshot_id: value.weather_snapshot_id, id: value.id,
    version: value.version, created_at: value.created_at, visibility: 'private', item_snapshot: value.item_snapshot };
}
export async function acceptRecommendation(req, dependencies) {
  const recommendationId = pathId(req, 'recommendationId'); const key = idempotencyKey(req);
  const parsed = readJsonObject(req); if (parsed.error) return failure(400, parsed.error, dependencies.requestId);
  if (!recommendationId || !key || !hasOnlyKeys(parsed.data, ACCEPT_KEYS) || !UUID.test(parsed.data.outfit_id) || !validDate(parsed.data.worn_on)) {
    return failure(422, 'VALIDATION_ERROR', dependencies.requestId);
  }
  const auth = await authenticatedUser(req, dependencies); if (auth.error) return auth.error;
  const result = await auth.client.rpc('accept_my_recommendation', { p_recommendation_id: recommendationId,
    p_outfit_id: parsed.data.outfit_id.toLowerCase(), p_worn_on: parsed.data.worn_on, p_idempotency_key: key });
  if (result.error) return result.error;
  const ootdId = result.data?.ootd_id; if (!UUID.test(ootdId)) return failure(500, 'INTERNAL_ERROR', dependencies.requestId);
  const read = await auth.client.select('ootd_entries', [['select',
    'id,worn_on,outfit_id,saved_outfit_id,wear_status,note,rating,weather_snapshot_id,version,created_at,visibility,item_snapshot'],
    ['user_id', `eq.${auth.user.id}`], ['id', `eq.${ootdId}`]]);
  if (read.error) return read.error;
  if (!Array.isArray(read.data) || read.data.length !== 1) return failure(500, 'INTERNAL_ERROR', dependencies.requestId);
  const row = read.data[0]; const garmentIds = Array.isArray(row.item_snapshot) ? row.item_snapshot.map(item => item.garment_id) : [];
  const dto = validOotd({ ...row, garment_ids: garmentIds });
  return dto ? { status: 201, headers: baseHeaders(dependencies.requestId), body: dto }
    : failure(500, 'INTERNAL_ERROR', dependencies.requestId);
}
