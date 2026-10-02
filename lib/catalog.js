import { baseHeaders, failure } from './errors.js';
import { projectUrl, upstreamFailure } from './supabase-user.js';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const TPO_DESCRIPTIONS = Object.freeze({
  daily_campus: '일상과 등교 상황',
  office_business: '출근과 비즈니스 상황',
  date_social: '데이트와 모임 상황',
  formal_event: '격식과 행사 상황',
  outdoor_active: '야외와 활동 상황'
});

async function readCatalog(table, select, env, request, requestId) {
  const base = projectUrl(env);
  if (!base) return { error: failure(503, 'SUPABASE_NOT_CONFIGURED', requestId) };
  const url = new URL(`/rest/v1/${table}`, base);
  url.searchParams.set('select', select);
  url.searchParams.set('active', 'eq.true');
  url.searchParams.set('order', 'code.asc');
  let response;
  try {
    response = await request(url, {
      method: 'GET',
      headers: { apikey: env.SUPABASE_PUBLISHABLE_KEY, Accept: 'application/json' },
      redirect: 'error', signal: AbortSignal.timeout(5000)
    });
  } catch {
    return { error: failure(503, 'SUPABASE_UNAVAILABLE', requestId, true) };
  }
  if (response.status !== 200) {
    if (response.status === 429) return { error: upstreamFailure(response, requestId, 'rest') };
    if ([403, 404].includes(response.status)) return { error: failure(503, 'DATABASE_SCHEMA_NOT_READY', requestId) };
    return { error: failure(503, 'SUPABASE_UNAVAILABLE', requestId, true) };
  }
  try {
    const data = await response.json();
    return Array.isArray(data) ? { data } : { error: failure(503, 'SUPABASE_UNAVAILABLE', requestId, true) };
  } catch {
    return { error: failure(503, 'SUPABASE_UNAVAILABLE', requestId, true) };
  }
}

export async function listAestheticsResponse(_req, { env, request = fetch, requestId }) {
  const result = await readCatalog('aesthetics', 'id,code,label,active', env, request, requestId);
  if (result.error) return result.error;
  const items = [];
  for (const row of result.data) {
    if (!row || !UUID.test(row.id) || typeof row.code !== 'string' || !row.code ||
        typeof row.label !== 'string' || !row.label || row.active !== true) {
      return failure(503, 'SUPABASE_UNAVAILABLE', requestId, true);
    }
    items.push({ id: row.id, code: row.code, display_name: row.label, active: true });
  }
  return { status: 200, headers: baseHeaders(requestId), body: { items } };
}

export async function listTpoPresetsResponse(_req, { env, request = fetch, requestId }) {
  const result = await readCatalog('tpo_presets', 'code,label,active', env, request, requestId);
  if (result.error) return result.error;
  const items = [];
  for (const row of result.data) {
    if (!row || typeof row.code !== 'string' || typeof row.label !== 'string' || !row.label ||
        row.active !== true || !Object.hasOwn(TPO_DESCRIPTIONS, row.code)) {
      return failure(503, 'SUPABASE_UNAVAILABLE', requestId, true);
    }
    items.push({ code: row.code, display_name: row.label, description: TPO_DESCRIPTIONS[row.code] });
  }
  return { status: 200, headers: baseHeaders(requestId), body: { items } };
}
