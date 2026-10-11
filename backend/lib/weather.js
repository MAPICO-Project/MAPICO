import { baseHeaders, failure } from './errors.js';
import { authenticatedUser } from './profile.js';
import { createInternalClient } from './supabase-internal.js';

const SOURCE = 'kma_short_term';
const FRESH_MS = 10 * 60 * 1000;
const STALE_MS = 3 * 60 * 60 * 1000;
const PRECIPITATION = new Set(['none', 'rain', 'snow', 'mixed', 'unknown']);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// 시·도 17개 대표 좌표(위치 권한 거절 시 지역 직접 선택용). 각 시청·도청 소재지 부근의 근사 좌표로,
// 공개 지도에서 소수 넷째 자리까지 옮긴 값이다(정밀 측량 값 아님). 날씨는 이 좌표가 속한 격자로 조회하므로
// 같은 시·도 안의 다른 지역 날씨와 다를 수 있다. 코드는 영문 소문자 고정 문자열로 API 계약의 enum과 같다.
export const REGIONS = Object.freeze({
  seoul: { label: '서울특별시', lat: 37.5665, lon: 126.978 },
  busan: { label: '부산광역시', lat: 35.1796, lon: 129.0756 },
  daegu: { label: '대구광역시', lat: 35.8714, lon: 128.6014 },
  incheon: { label: '인천광역시', lat: 37.4563, lon: 126.7052 },
  gwangju: { label: '광주광역시', lat: 35.1601, lon: 126.8514 },
  daejeon: { label: '대전광역시', lat: 36.3504, lon: 127.3845 },
  ulsan: { label: '울산광역시', lat: 35.5384, lon: 129.3114 },
  sejong: { label: '세종특별자치시', lat: 36.48, lon: 127.289 },
  gyeonggi: { label: '경기도', lat: 37.2885, lon: 127.0535 }, // 수원 광교 도청
  gangwon: { label: '강원특별자치도', lat: 37.8813, lon: 127.7298 }, // 춘천
  chungbuk: { label: '충청북도', lat: 36.6357, lon: 127.4917 }, // 청주
  chungnam: { label: '충청남도', lat: 36.6588, lon: 126.6728 }, // 홍성 내포
  jeonbuk: { label: '전북특별자치도', lat: 35.8203, lon: 127.1088 }, // 전주
  jeonnam: { label: '전라남도', lat: 34.8161, lon: 126.4629 }, // 무안 남악
  gyeongbuk: { label: '경상북도', lat: 36.576, lon: 128.5056 }, // 안동 도청신도시
  gyeongnam: { label: '경상남도', lat: 35.2383, lon: 128.6922 }, // 창원
  jeju: { label: '제주특별자치도', lat: 33.489, lon: 126.4983 } // 제주시
});
export function regionCoordinates(code) {
  if (typeof code !== 'string' || !Object.hasOwn(REGIONS, code)) return null;
  return { lat: REGIONS[code].lat, lon: REGIONS[code].lon };
}

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
// PostgREST returns timestamptz as "2026-10-11T03:00:00+00:00" while toISOString() gives "...00.000Z":
// compare instants, never the text.
export function sameInstant(left, right) {
  const a = typeof left === 'string' ? Date.parse(left) : NaN; const b = typeof right === 'string' ? Date.parse(right) : NaN;
  return Number.isFinite(a) && Number.isFinite(b) && a === b;
}
function snapshot(row, now, slot, forceStale) {
  const payload = canonicalPayload(row?.payload); const fetched = Date.parse(row?.fetched_at); const issued = Date.parse(row?.issued_at);
  const age = now.getTime() - fetched;
  if (!row || !UUID.test(row.id) || row.source !== SOURCE || !sameInstant(row.valid_at, slot) || !payload ||
      !Number.isInteger(row.grid_x) || !Number.isInteger(row.grid_y) || !Number.isFinite(fetched) || !Number.isFinite(issued) ||
      issued > now.getTime() || age < -60_000 || age > STALE_MS) return null;
  return { id: row.id.toLowerCase(), source: row.source, issued_at: row.issued_at, valid_at: row.valid_at,
    fetched_at: row.fetched_at, grid_x: row.grid_x, grid_y: row.grid_y, ...payload,
    is_stale: forceStale ?? age > FRESH_MS };
}
// WEATHER_PROVIDER selects the upstream: "adapter"(default) = HTTPS adapter returning the normalized JSON below,
// "kma" = 기상청 data.go.kr 단기예보 서비스(초단기실황 + 단기예보 POP) called directly.
const KMA_DEFAULT_BASE_URL = 'https://apis.data.go.kr/1360000/VilageFcstInfoService_2.0';
function providerConfig(env) {
  const kind = env.WEATHER_PROVIDER === undefined || env.WEATHER_PROVIDER === '' ? 'adapter' : env.WEATHER_PROVIDER;
  if (!['adapter', 'kma'].includes(kind)) return null;
  if (typeof env.WEATHER_PROVIDER_API_KEY !== 'string' || env.WEATHER_PROVIDER_API_KEY.length < 8) return null;
  const raw = typeof env.WEATHER_PROVIDER_BASE_URL === 'string' && env.WEATHER_PROVIDER_BASE_URL !== ''
    ? env.WEATHER_PROVIDER_BASE_URL : kind === 'kma' ? KMA_DEFAULT_BASE_URL : null;
  if (!raw) return null;
  try {
    const url = new URL(raw);
    if (url.protocol !== 'https:' || url.username || url.password || url.hash) return null;
    return { kind, url, key: env.WEATHER_PROVIDER_API_KEY };
  } catch { return null; }
}

// 기상청 Lambert Conformal Conic 격자(5 km) 변환. 기상청 단기예보 OpenAPI 활용가이드의 상수를 그대로 쓴다.
export function kmaGrid(lat, lon) {
  if (!Number.isFinite(lat) || !Number.isFinite(lon)) return null;
  const RE = 6371.00877 / 5.0, DEG = Math.PI / 180, slat1 = 30 * DEG, slat2 = 60 * DEG, olon = 126 * DEG, olat = 38 * DEG;
  let sn = Math.tan(Math.PI * 0.25 + slat2 * 0.5) / Math.tan(Math.PI * 0.25 + slat1 * 0.5);
  sn = Math.log(Math.cos(slat1) / Math.cos(slat2)) / Math.log(sn);
  let sf = Math.tan(Math.PI * 0.25 + slat1 * 0.5); sf = Math.pow(sf, sn) * Math.cos(slat1) / sn;
  let ro = Math.tan(Math.PI * 0.25 + olat * 0.5); ro = RE * sf / Math.pow(ro, sn);
  let ra = Math.tan(Math.PI * 0.25 + lat * DEG * 0.5); ra = RE * sf / Math.pow(ra, sn);
  let theta = lon * DEG - olon; if (theta > Math.PI) theta -= 2 * Math.PI; if (theta < -Math.PI) theta += 2 * Math.PI; theta *= sn;
  return { nx: Math.floor(ra * Math.sin(theta) + 43 + 0.5), ny: Math.floor(ro - ra * Math.cos(theta) + 136 + 0.5) };
}
// PTY(강수형태): 0 없음, 1 비, 2 비/눈, 3 눈, 4 소나기(예보), 5 빗방울, 6 빗방울눈날림, 7 눈날림.
const KMA_PTY = { 0: 'none', 1: 'rain', 2: 'mixed', 3: 'snow', 4: 'rain', 5: 'rain', 6: 'mixed', 7: 'snow' };
const KST_MS = 9 * 3600 * 1000;
function kstParts(ms) {
  const value = new Date(ms + KST_MS);
  return { date: value.toISOString().slice(0, 10).replaceAll('-', ''), hour: value.getUTCHours() };
}
function kmaBaseInstant(date, hour) {
  return Date.UTC(Number(date.slice(0, 4)), Number(date.slice(4, 6)) - 1, Number(date.slice(6, 8)), hour) - KST_MS;
}
async function kmaItems(config, operation, params, request) {
  const url = new URL(`${config.url.pathname.replace(/\/$/, '')}/${operation}`, config.url);
  for (const [name, value] of Object.entries({ serviceKey: config.key, pageNo: '1', dataType: 'JSON', ...params })) {
    url.searchParams.set(name, value);
  }
  let response;
  try { response = await request(url, { headers: { Accept: 'application/json' }, redirect: 'error', signal: AbortSignal.timeout(4000) }); }
  catch { return null; }
  if (response.status !== 200) return null;
  const length = response.headers?.get?.('content-length'); if (length && Number(length) > 262144) return null;
  let body; try { body = await response.json(); } catch { return null; } // data.go.kr reports key errors as XML.
  if (body?.response?.header?.resultCode !== '00') return null;
  const items = body?.response?.body?.items?.item;
  return Array.isArray(items) ? items : null;
}
// 체감온도: 기온 10°C 이하·풍속 1.3 m/s 이상이면 기상청 겨울철 체감온도식, 아니면 기온 그대로.
function feelsLike(temperature, windMs) {
  if (!Number.isFinite(windMs) || temperature > 10 || windMs < 1.3) return temperature;
  const v = Math.pow(windMs * 3.6, 0.16);
  return Math.round((13.12 + 0.6215 * temperature - 11.37 * v + 0.3965 * temperature * v) * 10) / 10;
}
function forecastBase(now) {
  // 단기예보: 02·05·08·11·14·17·20·23시(KST) 발표, 발표 후 약 10분 뒤 제공.
  const clock = kstParts(now.getTime() - 15 * 60 * 1000);
  const hour = [23, 20, 17, 14, 11, 8, 5, 2].find(value => value <= clock.hour);
  return hour === undefined ? { date: kstParts(now.getTime() - 15 * 60 * 1000 - 24 * 3600 * 1000).date, hour: 23 } : { date: clock.date, hour };
}
async function fetchKma(config, lat, lon, slot, request, now) {
  const grid = kmaGrid(lat, lon); if (!grid) return null;
  // 초단기실황: 정시 자료가 40분 무렵 제공되므로 45분을 빼서 확정된 최신 base_time을 쓴다.
  const base = kstParts(now.getTime() - 45 * 60 * 1000); const fcst = forecastBase(now);
  const at = { nx: String(grid.nx), ny: String(grid.ny) };
  const [nowcast, forecast] = await Promise.all([
    kmaItems(config, 'getUltraSrtNcst', { numOfRows: '20', base_date: base.date, base_time: `${String(base.hour).padStart(2, '0')}00`, ...at }, request),
    kmaItems(config, 'getVilageFcst', { numOfRows: '400', base_date: fcst.date, base_time: `${String(fcst.hour).padStart(2, '0')}00`, ...at }, request)
  ]);
  if (!nowcast) return null;
  const value = {};
  for (const item of nowcast) {
    if (!item || typeof item.category !== 'string') continue;
    const parsed = Number(item.obsrValue); if (Number.isFinite(parsed)) value[item.category] = parsed;
  }
  if (!Number.isFinite(value.T1H)) return null;
  // POP(강수확률)는 선택: slot 시각(KST) 또는 그 뒤 첫 예보 시각의 값. 단기예보가 실패하면 null.
  let probability = null;
  if (forecast) {
    const target = kstParts(Date.parse(slot)); const key = `${target.date}${String(target.hour).padStart(2, '0')}00`;
    const pops = forecast.filter(item => item?.category === 'POP' && Number.isFinite(Number(item.fcstValue)))
      .map(item => ({ at: `${item.fcstDate}${item.fcstTime}`, value: Number(item.fcstValue) }))
      .filter(item => item.at >= key).sort((left, right) => (left.at < right.at ? -1 : left.at > right.at ? 1 : 0));
    if (pops.length) probability = pops[0].value;
  }
  const payload = canonicalPayload({ temperature_c: value.T1H, feels_like_c: feelsLike(value.T1H, value.WSD),
    precipitation_probability: probability, precipitation_type: KMA_PTY[value.PTY] ?? 'unknown',
    humidity: Number.isFinite(value.REH) ? value.REH : null, air_quality: null });
  const issued = kmaBaseInstant(base.date, base.hour);
  if (!payload || issued > now.getTime()) return null;
  return { issued_at: new Date(issued).toISOString(), valid_at: slot, payload };
}

async function fetchProvider(lat, lon, slot, { env, request }, now) {
  const config = providerConfig(env); if (!config) return null;
  if (config.kind === 'kma') return fetchKma(config, lat, lon, slot, request, now);
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

// 위치 입력: lat+lon(위치 권한 허용) 또는 region_code(거절 후 직접 선택) 중 정확히 하나.
function currentWeatherLocation(query) {
  const keys = Object.keys(query ?? {});
  if (keys.length === 1 && keys[0] === 'region_code') return regionCoordinates(single(query.region_code));
  const lat = number(single(query?.lat)); const lon = number(single(query?.lon));
  if (keys.length !== 2 || !keys.includes('lat') || !keys.includes('lon') || lat === null || lon === null ||
      lat < -90 || lat > 90 || lon < -180 || lon > 180) return null;
  return { lat, lon };
}
export async function getCurrentWeather(req, dependencies) {
  const location = currentWeatherLocation(req.query); if (!location) return failure(422, 'VALIDATION_ERROR', dependencies.requestId);
  const { lat, lon } = location;
  if (!weatherGrid(lat, lon)) return failure(422, 'UNSUPPORTED_LOCATION', dependencies.requestId);
  const auth = await authenticatedUser(req, dependencies); if (auth.error) return auth.error;
  const result = await resolveWeather(lat, lon, { ...dependencies, request: dependencies.request ?? fetch,
    now: dependencies.now ?? (() => new Date()), env: dependencies.env, requestId: dependencies.requestId });
  return result.error ? result.error : { status: 200, headers: baseHeaders(dependencies.requestId), body: result.data };
}
