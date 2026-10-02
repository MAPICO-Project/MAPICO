import { baseHeaders, failure } from './errors.js';
import { hasOnlyKeys, readJsonObject } from './json-body.js';
import { authenticatedUser } from './profile.js';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DATE = /^\d{4}-\d{2}-\d{2}$/;
const TIMESTAMP = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})$/;
const CATEGORIES = new Set(['top', 'bottom', 'outerwear', 'dress', 'shoes', 'bag', 'accessory', 'other']);
const SAVED_FIELDS = new Set(['title', 'note', 'garment_ids', 'source_recommendation_id']);
const OOTD_FIELDS = new Set(['worn_on', 'garment_ids', 'saved_outfit_id', 'outfit_id', 'wear_status', 'note', 'rating', 'weather_snapshot_id']);
const SAVED_SELECT = 'id,title,note,source_recommendation_id,version,created_at';
const OOTD_SELECT = 'id,worn_on,saved_outfit_id,outfit_id,wear_status,note,rating,weather_snapshot_id,version,created_at,visibility,item_snapshot';

const textLength = value => [...value].length;
const scalar = value => typeof value === 'string' || typeof value === 'number' ? String(value) : null;
const validation = (requestId, status = 422) => failure(status, status === 400 ? 'INVALID_REQUEST_BODY' : 'VALIDATION_ERROR', requestId);
const okDate = value => typeof value === 'string' && DATE.test(value) && (() => {
  const [y, m, d] = value.split('-').map(Number); const date = new Date(Date.UTC(y, m - 1, d));
  return date.getUTCFullYear() === y && date.getUTCMonth() === m - 1 && date.getUTCDate() === d;
})();
const okTimestamp = value => typeof value === 'string' && TIMESTAMP.test(value) && Number.isFinite(Date.parse(value)) && (() => {
  const [datePart, timePart] = value.split('T');
  if (!okDate(datePart)) return false;
  const match = /^(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,6})?(?:Z|([+-])(\d{2}):(\d{2}))$/.exec(timePart);
  return Boolean(match) && Number(match[1]) <= 23 && Number(match[2]) <= 59 && Number(match[3]) <= 59 &&
    (match[4] === undefined || Number(match[5]) <= 23 && Number(match[6]) <= 59);
})();
const okNullableUuid = value => value === null || (typeof value === 'string' && UUID.test(value));
const okNullableText = value => value === null || (typeof value === 'string' && textLength(value) <= 1000 && !value.includes('\0'));
const okIds = value => Array.isArray(value) && value.length >= 1 && value.length <= 10 &&
  value.every(id => typeof id === 'string' && UUID.test(id)) && new Set(value.map(id => id.toLowerCase())).size === value.length;
const idempotencyKey = req => {
  const value = req.headers?.['idempotency-key'] ?? req.headers?.['Idempotency-Key'];
  return typeof value === 'string' && value.length >= 8 && value.length <= 128 && /^[A-Za-z0-9._:-]+$/.test(value) ? value : null;
};

function pathId(req, name) {
  const value = req.query?.[name];
  return typeof value === 'string' && UUID.test(value) ? value.toLowerCase() : null;
}

function encodeCursor(kind, row, filters = {}) {
  const data = kind === 'saved' ? { v: 1, kind, created_at: row.created_at, id: row.id }
    : { v: 1, kind, worn_on: row.worn_on, id: row.id, from: filters.from, to: filters.to };
  return Buffer.from(JSON.stringify(data)).toString('base64url');
}

function decodeCursor(value, kind, filters = {}) {
  if (typeof value !== 'string' || value.length < 1 || value.length > 1024 || !/^[A-Za-z0-9_-]+$/.test(value)) return null;
  try {
    const parsed = JSON.parse(Buffer.from(value, 'base64url').toString('utf8'));
    const keys = kind === 'saved' ? new Set(['v', 'kind', 'created_at', 'id']) : new Set(['v', 'kind', 'worn_on', 'id', 'from', 'to']);
    if (!parsed || Array.isArray(parsed) || typeof parsed !== 'object' || !hasOnlyKeys(parsed, keys) ||
        Object.keys(parsed).length !== keys.size || parsed.v !== 1 || parsed.kind !== kind || !UUID.test(parsed.id)) return null;
    if (kind === 'saved') return okTimestamp(parsed.created_at) ? parsed : null;
    return okDate(parsed.worn_on) && parsed.from === filters.from && parsed.to === filters.to ? parsed : null;
  } catch { return null; }
}

function listParams(req, requestId, kind) {
  const query = req.query ?? {}; const allowed = kind === 'saved' ? new Set(['cursor', 'limit']) : new Set(['from', 'to', 'cursor', 'limit']);
  if (!query || Array.isArray(query) || typeof query !== 'object' || !hasOnlyKeys(query, allowed)) return { error: validation(requestId, 400) };
  const limit = query.limit === undefined ? 20 : Number(scalar(query.limit));
  if (!Number.isInteger(limit) || limit < 1 || limit > 100) return { error: validation(requestId) };
  const filters = kind === 'ootd' ? { from: scalar(query.from), to: scalar(query.to) } : {};
  if (kind === 'ootd') {
    if (!okDate(filters.from) || !okDate(filters.to) || filters.from > filters.to) return { error: validation(requestId) };
    const span = (Date.parse(`${filters.to}T00:00:00Z`) - Date.parse(`${filters.from}T00:00:00Z`)) / 86400000;
    if (span > 365) return { error: validation(requestId) };
  }
  const cursor = query.cursor === undefined ? null : decodeCursor(scalar(query.cursor), kind, filters);
  if (query.cursor !== undefined && !cursor) return { error: validation(requestId, 400) };
  return { limit, cursor, ...filters };
}

async function activeGarments(client, userId, ids, requestId) {
  const unique = [...new Set(ids.map(id => id.toLowerCase()))];
  if (!unique.length) return { data: new Set() };
  const result = await client.select('garments', [['select', 'id,asset_id'], ['user_id', `eq.${userId}`], ['id', `in.(${unique.join(',')})`], ['deleted_at', 'is.null']]);
  if (result.error) return result;
  if (!Array.isArray(result.data) || result.data.some(row => !row || !UUID.test(row.id) || !UUID.test(row.asset_id))) return { error: failure(500, 'INTERNAL_ERROR', requestId) };
  if (!result.data.length) return { data: new Set() };
  const assetIds = result.data.map(row => row.asset_id);
  const assets = await client.select('garment_assets', [['select', 'id'], ['id', `in.(${assetIds.join(',')})`],
    ['kind', 'eq.cutout'], ['verified_at', 'not.is.null'], ['deleted_at', 'is.null']]);
  if (assets.error) return assets;
  if (!Array.isArray(assets.data) || assets.data.some(row => !row || !UUID.test(row.id))) return { error: failure(500, 'INTERNAL_ERROR', requestId) };
  const usableAssets = new Set(assets.data.map(row => row.id.toLowerCase()));
  return { data: new Set(result.data.filter(row => usableAssets.has(row.asset_id.toLowerCase())).map(row => row.id.toLowerCase())) };
}

async function projectSaved(client, userId, rows, requestId) {
  if (!Array.isArray(rows)) return { error: failure(500, 'INTERNAL_ERROR', requestId) };
  if (!rows.length) return { data: [] };
  const ids = rows.map(row => row?.id).filter(id => typeof id === 'string' && UUID.test(id));
  if (ids.length !== rows.length) return { error: failure(500, 'INTERNAL_ERROR', requestId) };
  const items = await client.select('saved_outfit_items', [['select', 'saved_outfit_id,garment_id,position'], ['user_id', `eq.${userId}`],
    ['saved_outfit_id', `in.(${ids.join(',')})`], ['order', 'position.asc']]);
  if (items.error) return items;
  if (!Array.isArray(items.data)) return { error: failure(500, 'INTERNAL_ERROR', requestId) };
  const grouped = new Map(ids.map(id => [id.toLowerCase(), []]));
  for (const item of items.data) {
    if (!item || !UUID.test(item.saved_outfit_id) || !UUID.test(item.garment_id) || !Number.isInteger(item.position)) return { error: failure(500, 'INTERNAL_ERROR', requestId) };
    grouped.get(item.saved_outfit_id.toLowerCase())?.push(item.garment_id);
  }
  const allIds = [...grouped.values()].flat(); const active = await activeGarments(client, userId, allIds, requestId);
  if (active.error) return active;
  const projected = [];
  for (const row of rows) {
    const garmentIds = grouped.get(row.id.toLowerCase()) ?? [];
    if (typeof row.title !== 'string' || textLength(row.title) < 1 || textLength(row.title) > 100 || !okNullableText(row.note) ||
        !okNullableUuid(row.source_recommendation_id) || !Number.isInteger(row.version) || row.version < 1 || !okTimestamp(row.created_at) || !okIds(garmentIds)) {
      return { error: failure(500, 'INTERNAL_ERROR', requestId) };
    }
    projected.push({ id: row.id, title: row.title, note: row.note, garment_ids: garmentIds,
      source_recommendation_id: row.source_recommendation_id, version: row.version, created_at: row.created_at,
      unavailable_garment_ids: garmentIds.filter(id => !active.data.has(id.toLowerCase())) });
  }
  return { data: projected };
}

async function projectOotd(client, userId, rows, requestId) {
  if (!Array.isArray(rows)) return { error: failure(500, 'INTERNAL_ERROR', requestId) };
  const snapshots = [];
  for (const row of rows) {
    if (!row || !UUID.test(row.id) || !okDate(row.worn_on) || !okNullableUuid(row.saved_outfit_id) || !okNullableUuid(row.outfit_id) ||
        !['unconfirmed', 'planned', 'worn'].includes(row.wear_status) || !okNullableText(row.note) ||
        !(row.rating === null || Number.isInteger(row.rating) && row.rating >= 1 && row.rating <= 5) || !okNullableUuid(row.weather_snapshot_id) ||
        !Number.isInteger(row.version) || row.version < 1 || !okTimestamp(row.created_at) || row.visibility !== 'private' ||
        !Array.isArray(row.item_snapshot) || row.item_snapshot.length < 1 || row.item_snapshot.length > 10) return { error: failure(500, 'INTERNAL_ERROR', requestId) };
    const seen = new Set(); const snapshot = [];
    for (const item of row.item_snapshot) {
      if (!item || !UUID.test(item.garment_id) || !CATEGORIES.has(item.category) || seen.has(item.garment_id.toLowerCase())) return { error: failure(500, 'INTERNAL_ERROR', requestId) };
      seen.add(item.garment_id.toLowerCase()); snapshot.push({ garment_id: item.garment_id, category: item.category });
    }
    snapshots.push(snapshot);
  }
  const active = await activeGarments(client, userId, snapshots.flat().map(item => item.garment_id), requestId);
  if (active.error) return active;
  return { data: rows.map((row, index) => ({ worn_on: row.worn_on, garment_ids: snapshots[index].map(item => item.garment_id),
    saved_outfit_id: row.saved_outfit_id, outfit_id: row.outfit_id, wear_status: row.wear_status, note: row.note, rating: row.rating,
    weather_snapshot_id: row.weather_snapshot_id, id: row.id, version: row.version, created_at: row.created_at, visibility: 'private',
    item_snapshot: snapshots[index].map(item => ({ ...item, unavailable: !active.data.has(item.garment_id.toLowerCase()) })) })) };
}

async function readSaved(client, userId, filters, requestId) {
  const result = await client.select('saved_outfits', [['select', SAVED_SELECT], ['user_id', `eq.${userId}`], ...filters]);
  return result.error ? result : projectSaved(client, userId, result.data, requestId);
}
async function readOotd(client, userId, filters, requestId) {
  const result = await client.select('ootd_entries', [['select', OOTD_SELECT], ['user_id', `eq.${userId}`], ...filters]);
  return result.error ? result : projectOotd(client, userId, result.data, requestId);
}

export async function listSavedOutfitsResponse(req, d) {
  const parsed = listParams(req, d.requestId, 'saved'); if (parsed.error) return parsed.error;
  const auth = await authenticatedUser(req, d); if (auth.error) return auth.error;
  const filters = parsed.cursor ? [['or', `(created_at.lt."${parsed.cursor.created_at}",and(created_at.eq."${parsed.cursor.created_at}",id.lt.${parsed.cursor.id}))`]] : [];
  filters.push(['order', 'created_at.desc,id.desc'], ['limit', String(parsed.limit + 1)]);
  const rows = await readSaved(auth.client, auth.user.id, filters, d.requestId); if (rows.error) return rows.error;
  const page = rows.data.slice(0, parsed.limit); return { status: 200, headers: baseHeaders(d.requestId), body: { items: page,
    next_cursor: rows.data.length > parsed.limit ? encodeCursor('saved', page.at(-1)) : null } };
}

export async function getSavedOutfitResponse(req, d) {
  const id = pathId(req, 'savedOutfitId'); if (!id) return validation(d.requestId);
  const auth = await authenticatedUser(req, d); if (auth.error) return auth.error;
  const rows = await readSaved(auth.client, auth.user.id, [['id', `eq.${id}`]], d.requestId); if (rows.error) return rows.error;
  if (rows.data.length !== 1) return failure(rows.data.length ? 500 : 404, rows.data.length ? 'INTERNAL_ERROR' : 'SAVED_OUTFIT_NOT_FOUND', d.requestId);
  return { status: 200, headers: baseHeaders(d.requestId), body: rows.data[0] };
}

function savedBody(req, requestId, patch) {
  const parsed = readJsonObject(req); if (parsed.error) return { error: failure(400, parsed.error, requestId) }; const body = parsed.data;
  const allowed = new Set([...SAVED_FIELDS, ...(patch ? ['expected_version'] : [])]);
  if (!hasOnlyKeys(body, allowed) || (patch ? !Number.isInteger(body.expected_version) || body.expected_version < 1 || Object.keys(body).length < 2
    : !Object.hasOwn(body, 'title') || !Object.hasOwn(body, 'garment_ids'))) return { error: validation(requestId) };
  if (Object.hasOwn(body, 'title') && (typeof body.title !== 'string' || textLength(body.title.trim()) < 1 || textLength(body.title) > 100 || body.title.includes('\0'))) return { error: validation(requestId) };
  if (Object.hasOwn(body, 'note') && !okNullableText(body.note)) return { error: validation(requestId) };
  if (Object.hasOwn(body, 'garment_ids') && !okIds(body.garment_ids)) return { error: validation(requestId) };
  if (Object.hasOwn(body, 'source_recommendation_id') && !okNullableUuid(body.source_recommendation_id)) return { error: validation(requestId) };
  return { data: body };
}

export async function createSavedOutfitResponse(req, d) {
  const parsed = savedBody(req, d.requestId, false); if (parsed.error) return parsed.error; const key = idempotencyKey(req); if (!key) return validation(d.requestId);
  const auth = await authenticatedUser(req, d); if (auth.error) return auth.error; const b = parsed.data;
  const write = await auth.client.rpc('create_my_saved_outfit', { p_title: b.title, p_note: b.note ?? null, p_garment_ids: b.garment_ids,
    p_source_recommendation_id: b.source_recommendation_id ?? null, p_idempotency_key: key }); if (write.error) return write.error;
  const id = write.data?.saved_outfit_id; if (!UUID.test(id ?? '')) return failure(500, 'INTERNAL_ERROR', d.requestId);
  const rows = await readSaved(auth.client, auth.user.id, [['id', `eq.${id}`]], d.requestId); if (rows.error) return rows.error;
  return rows.data.length === 1 ? { status: 201, headers: baseHeaders(d.requestId), body: rows.data[0] } : failure(500, 'INTERNAL_ERROR', d.requestId);
}

export async function updateSavedOutfitResponse(req, d) {
  const id = pathId(req, 'savedOutfitId'); if (!id) return validation(d.requestId); const parsed = savedBody(req, d.requestId, true); if (parsed.error) return parsed.error;
  const auth = await authenticatedUser(req, d); if (auth.error) return auth.error; const b = parsed.data;
  const write = await auth.client.rpc('update_my_saved_outfit', { p_saved_outfit_id: id, p_expected_version: b.expected_version,
    p_has_title: Object.hasOwn(b, 'title'), p_title: b.title ?? null, p_has_note: Object.hasOwn(b, 'note'), p_note: b.note ?? null,
    p_has_garment_ids: Object.hasOwn(b, 'garment_ids'), p_garment_ids: b.garment_ids ?? null,
    p_has_source_recommendation_id: Object.hasOwn(b, 'source_recommendation_id'), p_source_recommendation_id: b.source_recommendation_id ?? null });
  if (write.error) return write.error; const rows = await readSaved(auth.client, auth.user.id, [['id', `eq.${id}`]], d.requestId); if (rows.error) return rows.error;
  return rows.data.length === 1 ? { status: 200, headers: baseHeaders(d.requestId), body: rows.data[0] } : failure(500, 'INTERNAL_ERROR', d.requestId);
}

export async function deleteSavedOutfitResponse(req, d) {
  const id = pathId(req, 'savedOutfitId'); if (!id) return validation(d.requestId); const auth = await authenticatedUser(req, d); if (auth.error) return auth.error;
  const write = await auth.client.rpc('delete_my_saved_outfit', { p_saved_outfit_id: id }); if (write.error) return write.error;
  return { status: 204, headers: baseHeaders(d.requestId), body: null };
}

function ootdBody(req, requestId, patch) {
  const parsed = readJsonObject(req); if (parsed.error) return { error: failure(400, parsed.error, requestId) }; const b = parsed.data;
  const allowed = new Set([...OOTD_FIELDS, ...(patch ? ['expected_version'] : [])]);
  if (!hasOnlyKeys(b, allowed) || (patch ? !Number.isInteger(b.expected_version) || b.expected_version < 1 || Object.keys(b).length < 2
    : !Object.hasOwn(b, 'worn_on') || !Object.hasOwn(b, 'garment_ids') || !Object.hasOwn(b, 'wear_status'))) return { error: validation(requestId) };
  if (Object.hasOwn(b, 'worn_on') && !okDate(b.worn_on) || Object.hasOwn(b, 'garment_ids') && !okIds(b.garment_ids) ||
      Object.hasOwn(b, 'saved_outfit_id') && !okNullableUuid(b.saved_outfit_id) || Object.hasOwn(b, 'outfit_id') && !okNullableUuid(b.outfit_id) ||
      Object.hasOwn(b, 'wear_status') && !['planned', 'worn'].includes(b.wear_status) || Object.hasOwn(b, 'note') && !okNullableText(b.note) ||
      Object.hasOwn(b, 'rating') && !(b.rating === null || Number.isInteger(b.rating) && b.rating >= 1 && b.rating <= 5) ||
      Object.hasOwn(b, 'weather_snapshot_id') && !okNullableUuid(b.weather_snapshot_id)) return { error: validation(requestId) };
  if (b.saved_outfit_id != null && b.outfit_id != null || b.wear_status === 'planned' && b.rating != null) return { error: validation(requestId) };
  return { data: b };
}

export async function listOotdResponse(req, d) {
  const parsed = listParams(req, d.requestId, 'ootd'); if (parsed.error) return parsed.error; const auth = await authenticatedUser(req, d); if (auth.error) return auth.error;
  const filters = [['worn_on', `gte.${parsed.from}`], ['worn_on', `lte.${parsed.to}`]];
  if (parsed.cursor) filters.push(['or', `(worn_on.lt.${parsed.cursor.worn_on},and(worn_on.eq.${parsed.cursor.worn_on},id.lt.${parsed.cursor.id}))`]);
  filters.push(['order', 'worn_on.desc,id.desc'], ['limit', String(parsed.limit + 1)]);
  const rows = await readOotd(auth.client, auth.user.id, filters, d.requestId); if (rows.error) return rows.error;
  const page = rows.data.slice(0, parsed.limit); return { status: 200, headers: baseHeaders(d.requestId), body: { items: page,
    next_cursor: rows.data.length > parsed.limit ? encodeCursor('ootd', page.at(-1), parsed) : null } };
}

export async function getOotdResponse(req, d) {
  const id = pathId(req, 'ootdId'); if (!id) return validation(d.requestId); const auth = await authenticatedUser(req, d); if (auth.error) return auth.error;
  const rows = await readOotd(auth.client, auth.user.id, [['id', `eq.${id}`]], d.requestId); if (rows.error) return rows.error;
  if (rows.data.length !== 1) return failure(rows.data.length ? 500 : 404, rows.data.length ? 'INTERNAL_ERROR' : 'OOTD_NOT_FOUND', d.requestId);
  return { status: 200, headers: baseHeaders(d.requestId), body: rows.data[0] };
}

export async function createOotdResponse(req, d) {
  const parsed = ootdBody(req, d.requestId, false); if (parsed.error) return parsed.error; const key = idempotencyKey(req); if (!key) return validation(d.requestId);
  const auth = await authenticatedUser(req, d); if (auth.error) return auth.error; const b = parsed.data;
  const write = await auth.client.rpc('create_my_ootd', { p_worn_on: b.worn_on, p_garment_ids: b.garment_ids,
    p_saved_outfit_id: b.saved_outfit_id ?? null, p_outfit_id: b.outfit_id ?? null, p_wear_status: b.wear_status,
    p_note: b.note ?? null, p_rating: b.rating ?? null, p_weather_snapshot_id: b.weather_snapshot_id ?? null, p_idempotency_key: key });
  if (write.error) return write.error; const id = write.data?.ootd_id; if (!UUID.test(id ?? '')) return failure(500, 'INTERNAL_ERROR', d.requestId);
  const rows = await readOotd(auth.client, auth.user.id, [['id', `eq.${id}`]], d.requestId); if (rows.error) return rows.error;
  return rows.data.length === 1 ? { status: 201, headers: baseHeaders(d.requestId), body: rows.data[0] } : failure(500, 'INTERNAL_ERROR', d.requestId);
}

export async function updateOotdResponse(req, d) {
  const id = pathId(req, 'ootdId'); if (!id) return validation(d.requestId); const parsed = ootdBody(req, d.requestId, true); if (parsed.error) return parsed.error;
  const auth = await authenticatedUser(req, d); if (auth.error) return auth.error; const b = parsed.data; const args = { p_ootd_id: id, p_expected_version: b.expected_version };
  for (const field of OOTD_FIELDS) { args[`p_has_${field}`] = Object.hasOwn(b, field); args[`p_${field}`] = b[field] ?? null; }
  const write = await auth.client.rpc('update_my_ootd', args); if (write.error) return write.error;
  const rows = await readOotd(auth.client, auth.user.id, [['id', `eq.${id}`]], d.requestId); if (rows.error) return rows.error;
  return rows.data.length === 1 ? { status: 200, headers: baseHeaders(d.requestId), body: rows.data[0] } : failure(500, 'INTERNAL_ERROR', d.requestId);
}

export async function deleteOotdResponse(req, d) {
  const id = pathId(req, 'ootdId'); if (!id) return validation(d.requestId); const key = idempotencyKey(req); if (!key) return validation(d.requestId);
  const auth = await authenticatedUser(req, d); if (auth.error) return auth.error; const write = await auth.client.rpc('delete_my_ootd', { p_ootd_id: id, p_idempotency_key: key });
  if (write.error) return write.error; return { status: 204, headers: baseHeaders(d.requestId), body: null };
}

export async function closetStatisticsResponse(req, d) {
  if (req.query && Object.keys(req.query).length) return validation(d.requestId, 400); const auth = await authenticatedUser(req, d); if (auth.error) return auth.error;
  const result = await auth.client.rpc('get_my_closet_statistics', {}); if (result.error) return result.error; const value = result.data;
  if (!value || !okDate(value.as_of) || !Array.isArray(value.wear_counts) || !Array.isArray(value.unworn_30_days) ||
      value.wear_counts.some(item => !item || !UUID.test(item.garment_id) || !Number.isInteger(item.count) || item.count < 0) ||
      value.unworn_30_days.some(id => typeof id !== 'string' || !UUID.test(id))) return failure(500, 'INTERNAL_ERROR', d.requestId);
  return { status: 200, headers: baseHeaders(d.requestId), body: { as_of: value.as_of,
    wear_counts: value.wear_counts.map(item => ({ garment_id: item.garment_id, count: item.count })), unworn_30_days: value.unworn_30_days } };
}
