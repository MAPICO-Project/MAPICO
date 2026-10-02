import { baseHeaders, failure } from './errors.js';
import { authenticatedUser } from './profile.js';
import { createInternalClient } from './supabase-internal.js';

const SOURCE = 'kma_short_term';
const FRESH_MS = 10 * 60 * 1000;
const STALE_MS = 3 * 60 * 60 * 1000;
const PRECIPITATION = new Set(['none', 'rain', 'snow', 'mixed', 'unknown']);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function single(value) { return typeof value === 'string' && value.trim() !== '' ? value : null; }
function number(value) { const parsed = Number(value); return Number.isFinite(parsed) ? parsed : null; }
export function weatherGrid(lat, lon) {
  if (!Number.isFinite(lat) || !Number.isFinite(lon) || lat < 33 || lat > 39 || lon < 124 || lon > 132) return null;
  return { grid_x: Math.round((lon - 124) * 20), grid_y: Math.round((lat - 33) * 20) };
}
export function currentWeatherSlot(now) {
  const value = new Date(now); value.setUTCMinutes(0, 0, 0); return value.toISOString();
}
function canonicalPayload(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  const temperature = number(value.temperature_c); const feels = value.feels_like_c === null ? null : number(value.feels_like_c);
  const probability = value.precipitation_probability === null ? null : number(value.precipitation_probability);
  const humidity = value.humidity === null ? null : number(value.humidity);
  if (temperature === null || temperature < -80 || temperature > 60 ||
      (feels !== null && (feels < -80 || feels > 60)) ||
      (probability !== null && (probability < 0 || probability > 100)) ||
      (humidity !== null && (humidity < 0 || humidity > 100)) || !PRECIPITATION.has(value.precipitation_type) ||
      (value.air_quality !== null && (typeof value.air_quality !== 'string' || value.air_quality.length > 40))) return null;
  return { temperature_c: temperature, feels_like_c: feels, precipitation_probability: probability,
    precipitation_type: value.precipitation_type, humidity, air_quality: value.air_quality };
}
function snapshot(row, now, slot, forceStale) {
  const payload = canonicalPayload(row?.payload); const fetched = Date.parse(row?.fetched_at); const issued = Date.parse(row?.issued_at);
  const age = now.getTime() - fetched;
  if (!row || !UUID.test(row.id) || row.source !== SOURCE || row.valid_at !== slot || !payload ||
      !Number.isInteger(row.grid_x) || !Number.isInteger(row.grid_y) || !Number.isFinite(fetched) || !Number.isFinite(issued) ||
      issued > now.getTime() || age < -60_000 || age > STALE_MS) return null;
  return { id: row.id.toLowerCase(), source: row.source, issued_at: row.issued_at, valid_at: row.valid_at,
    fetched_at: row.fetched_at, grid_x: row.grid_x, grid_y: row.grid_y, ...payload,
    is_stale: forceStale ?? age > FRESH_MS };
}
function providerConfig(env) {
  if (typeof env.WEATHER_PROVIDER_BASE_URL !== 'string' || typeof env.WEATHER_PROVIDER_API_KEY !== 'string' ||
      env.WEATHER_PROVIDER_API_KEY.length < 8) return null;
  try {
    const url = new URL(env.WEATHER_PROVIDER_BASE_URL);
    if (url.protocol !== 'https:' || url.username || url.password || url.hash) return null;
    return { url, key: env.WEATHER_PROVIDER_API_KEY };
  } catch { return null; }
}
async function fetchProvider(lat, lon, slot, { env, request }, now) {
  const config = providerConfig(env); if (!config) return null;
  const url = new URL(config.url); url.searchParams.set('lat', String(lat)); url.searchParams.set('lon', String(lon));
  url.searchParams.set('valid_at', slot);
  let response;
  try { response = await request(url, { headers: { Accept: 'application/json', 'X-API-Key': config.key }, redirect: 'error', signal: AbortSignal.timeout(4000) }); }
  catch { return null; }
  if (response.status !== 200) return null;
  const length = response.headers?.get?.('content-length'); if (length && Number(length) > 65536) return null;
  let body; try { body = await response.json(); } catch { return null; }
  const payload = canonicalPayload(body); const issued = Date.parse(body?.issued_at); const valid = Date.parse(body?.valid_at);
  if (!payload || !Number.isFinite(issued) || issued > now.getTime() || !Number.isFinite(valid) || new Date(valid).toISOString() !== slot) return null;
  return { issued_at: new Date(issued).toISOString(), valid_at: slot, payload };
}

export async function resolveWeather(lat, lon, context) {
  const grid = weatherGrid(lat, lon); if (!grid) return { error: failure(422, 'UNSUPPORTED_LOCATION', context.requestId) };
  const now = context.now(); const slot = currentWeatherSlot(now);
  const internal = createInternalClient(context); if (internal.error) return { error: internal.error };
  const cachedResult = await internal.findWeatherSnapshot({ p_grid_x: grid.grid_x, p_grid_y: grid.grid_y, p_valid_at: slot, p_source: SOURCE });
  if (cachedResult.error) return cachedResult;
  const cached = cachedResult.missing ? null : snapshot(cachedResult.data, now, slot);
  if (cached && !cached.is_stale) return { data: cached };
  const fetched = await fetchProvider(lat, lon, slot, context, now);
  if (fetched) {
    const stored = await internal.upsertWeatherSnapshot({ p_grid_x: grid.grid_x, p_grid_y: grid.grid_y,
      p_issued_at: fetched.issued_at, p_valid_at: slot, p_source: SOURCE, p_payload: fetched.payload });
    if (stored.error) return stored;
    const value = snapshot(stored.data, now, slot, false);
    return value ? { data: value } : { error: failure(503, 'WEATHER_UNAVAILABLE', context.requestId, true) };
  }
  return cached ? { data: { ...cached, is_stale: true } }
    : { error: failure(503, 'WEATHER_UNAVAILABLE', context.requestId, true) };
}

export async function getCurrentWeather(req, dependencies) {
  const keys = Object.keys(req.query ?? {}); const latText = single(req.query?.lat); const lonText = single(req.query?.lon);
  const lat = number(latText); const lon = number(lonText);
  if (keys.length !== 2 || !keys.includes('lat') || !keys.includes('lon') || lat === null || lon === null ||
      lat < -90 || lat > 90 || lon < -180 || lon > 180) return failure(422, 'VALIDATION_ERROR', dependencies.requestId);
  if (!weatherGrid(lat, lon)) return failure(422, 'UNSUPPORTED_LOCATION', dependencies.requestId);
  const auth = await authenticatedUser(req, dependencies); if (auth.error) return auth.error;
  const result = await resolveWeather(lat, lon, { ...dependencies, request: dependencies.request ?? fetch,
    now: dependencies.now ?? (() => new Date()), env: dependencies.env, requestId: dependencies.requestId });
  return result.error ? result.error : { status: 200, headers: baseHeaders(dependencies.requestId), body: result.data };
}
