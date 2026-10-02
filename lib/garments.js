import { baseHeaders, failure } from './errors.js';
import { hasOnlyKeys, readJsonObject } from './json-body.js';
import { authenticatedUser } from './profile.js';
import { projectUrl } from './supabase-user.js';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const TIMESTAMP = /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,6})?(?:Z|[+-][0-9]{2}:[0-9]{2})$/;
const CATEGORIES = new Set(['top', 'bottom', 'outerwear', 'dress', 'shoes', 'bag', 'accessory', 'other']);
const QUERY_KEYS = new Set(['cursor', 'limit', 'category']);
const PATCH_KEYS = new Set(['expected_version', 'attributes']);
const ATTRIBUTE_KEYS = new Set(['category', 'subcategory', 'note']);
const GARMENT_SELECT = 'id,asset_id,category,attributes,memo,version,created_at,updated_at';

function scalar(value) { return typeof value === 'string' || typeof value === 'number' ? String(value) : null; }
function validation(requestId, status = 422) {
  return failure(status, status === 400 ? 'INVALID_REQUEST_BODY' : 'VALIDATION_ERROR', requestId);
}
function codePoints(value) { return [...value].length; }

function encodeCursor(row, category) {
  return Buffer.from(JSON.stringify({ v: 1, created_at: row.created_at, id: row.id, category: category ?? null })).toString('base64url');
}

function decodeCursor(value, category) {
  if (typeof value !== 'string' || value.length < 1 || value.length > 1024 || !/^[A-Za-z0-9_-]+$/.test(value)) return null;
  try {
    const parsed = JSON.parse(Buffer.from(value, 'base64url').toString('utf8'));
    if (!parsed || Array.isArray(parsed) || typeof parsed !== 'object' ||
        !hasOnlyKeys(parsed, new Set(['v', 'created_at', 'id', 'category'])) || Object.keys(parsed).length !== 4 ||
        parsed.v !== 1 || !TIMESTAMP.test(parsed.created_at) || !UUID.test(parsed.id) ||
        (parsed.category !== null && !CATEGORIES.has(parsed.category)) || parsed.category !== (category ?? null)) return null;
    return parsed;
  } catch { return null; }
}

function parseListQuery(req, requestId) {
  const query = req.query ?? {};
  if (!query || Array.isArray(query) || typeof query !== 'object' || !hasOnlyKeys(query, QUERY_KEYS)) {
    return { error: validation(requestId, 400) };
  }
  const categoryValue = query.category === undefined ? null : scalar(query.category);
  if (query.category !== undefined && (!categoryValue || !CATEGORIES.has(categoryValue))) return { error: validation(requestId) };
  const limitValue = query.limit === undefined ? 20 : Number(scalar(query.limit));
  if (!Number.isInteger(limitValue) || limitValue < 1 || limitValue > 100) return { error: validation(requestId) };
  const cursor = query.cursor === undefined ? null : decodeCursor(scalar(query.cursor), categoryValue);
  if (query.cursor !== undefined && !cursor) return { error: validation(requestId) };
  return { category: categoryValue, limit: limitValue, cursor };
}

function pathId(req) {
  const value = req.query?.garmentId;
  return typeof value === 'string' && UUID.test(value) ? value.toLowerCase() : null;
}

function projectRow(row) {
  if (!row || typeof row !== 'object' || !UUID.test(row.id) || !UUID.test(row.asset_id) ||
      !CATEGORIES.has(row.category) || !Number.isInteger(row.version) || row.version < 1 ||
      !TIMESTAMP.test(row.created_at) || !TIMESTAMP.test(row.updated_at) ||
      (row.memo !== null && (typeof row.memo !== 'string' || codePoints(row.memo) > 1000))) return null;
  const rawSubcategory = row.attributes && typeof row.attributes === 'object' && !Array.isArray(row.attributes)
    ? row.attributes.subcategory : null;
  const subcategory = typeof rawSubcategory === 'string' && codePoints(rawSubcategory) <= 80 ? rawSubcategory : null;
  return {
    id: row.id,
    attributes: { category: row.category, subcategory, note: row.memo },
    image: null,
    version: row.version,
    created_at: row.created_at,
    updated_at: row.updated_at,
    original_image: null,
    _asset_id: row.asset_id
  };
}

function assetRow(row, expectedKind) {
  return row && typeof row === 'object' && UUID.test(row.id) && UUID.test(row.batch_id) &&
    row.kind === expectedKind && row.bucket_id === 'closet-private' && typeof row.object_key === 'string' &&
    row.object_key.length > 0 && row.object_key.length <= 1024 && row.verified_at !== null && row.deleted_at === null ? row : null;
}

async function loadAssets(client, garments, env, requestId, now) {
  const assetIds = [...new Set(garments.map(item => item._asset_id))];
  if (assetIds.length === 0) return { data: garments };
  const cutoutResult = await client.select('garment_assets', [
    ['select', 'id,batch_id,kind,bucket_id,object_key,verified_at,deleted_at'],
    ['id', `in.(${assetIds.join(',')})`], ['kind', 'eq.cutout'], ['verified_at', 'not.is.null'], ['deleted_at', 'is.null']
  ]);
  if (cutoutResult.error) return cutoutResult;
  if (!Array.isArray(cutoutResult.data)) return { error: failure(500, 'INTERNAL_ERROR', requestId) };
  const cutouts = new Map();
  for (const row of cutoutResult.data) {
    const asset = assetRow(row, 'cutout');
    if (!asset) return { error: failure(500, 'INTERNAL_ERROR', requestId) };
    cutouts.set(asset.id.toLowerCase(), asset);
  }
  const batchIds = [...new Set([...cutouts.values()].map(asset => asset.batch_id))];
  const sources = new Map();
  if (batchIds.length > 0) {
    const sourceResult = await client.select('garment_assets', [
      ['select', 'id,batch_id,kind,bucket_id,object_key,verified_at,deleted_at'],
      ['batch_id', `in.(${batchIds.join(',')})`], ['kind', 'eq.source'], ['verified_at', 'not.is.null'], ['deleted_at', 'is.null']
    ]);
    if (sourceResult.error) return sourceResult;
    if (!Array.isArray(sourceResult.data)) return { error: failure(500, 'INTERNAL_ERROR', requestId) };
    for (const row of sourceResult.data) {
      const asset = assetRow(row, 'source');
      if (!asset || sources.has(asset.batch_id.toLowerCase())) return { error: failure(500, 'INTERNAL_ERROR', requestId) };
      sources.set(asset.batch_id.toLowerCase(), asset);
    }
  }

  const candidates = new Map();
  for (const asset of [...cutouts.values(), ...sources.values()]) candidates.set(asset.object_key, asset);
  const signed = new Map();
  const paths = [...candidates.keys()];
  const expiresAt = new Date(now().getTime() + 300000).toISOString();
  const base = projectUrl(env);
  if (!base) return { error: failure(503, 'SUPABASE_NOT_CONFIGURED', requestId) };
  for (let offset = 0; offset < paths.length; offset += 100) {
    const result = await client.signStorage('closet-private', paths.slice(offset, offset + 100), 300);
    if (result.error) return result;
    for (const item of result.data) {
      if (!item || typeof item !== 'object' || typeof item.path !== 'string') continue;
      if (item.error || typeof item.signedURL !== 'string' || item.signedURL.length < 1) continue;
      let url;
      try { url = new URL(item.signedURL, base); } catch { continue; }
      if (url.protocol !== 'https:' || url.hostname !== base.hostname || !url.pathname.startsWith('/storage/v1/object/sign/closet-private/')) continue;
      signed.set(item.path, { url: String(url), expires_at: expiresAt });
    }
  }
  for (const garment of garments) {
    const cutout = cutouts.get(garment._asset_id.toLowerCase());
    if (cutout) {
      garment.image = signed.get(cutout.object_key) ?? null;
      garment.original_image = signed.get(sources.get(cutout.batch_id.toLowerCase())?.object_key) ?? null;
    }
    delete garment._asset_id;
  }
  return { data: garments };
}

async function readRows(client, userId, filters, requestId) {
  const result = await client.select('garments', [['select', GARMENT_SELECT], ['user_id', `eq.${userId}`],
    ['deleted_at', 'is.null'], ...filters]);
  if (result.error) return result;
  if (!Array.isArray(result.data)) return { error: failure(500, 'INTERNAL_ERROR', requestId) };
  const rows = [];
  for (const row of result.data) {
    const projected = projectRow(row);
    if (!projected) return { error: failure(500, 'INTERNAL_ERROR', requestId) };
    rows.push(projected);
  }
  return { data: rows };
}

async function readOne(client, userId, garmentId, dependencies, missingStatus = 404) {
  const rows = await readRows(client, userId, [['id', `eq.${garmentId}`]], dependencies.requestId);
  if (rows.error) return rows;
  if (rows.data.length !== 1) return { error: rows.data.length === 0 && missingStatus === 404
    ? failure(404, 'GARMENT_NOT_FOUND', dependencies.requestId) : failure(500, 'INTERNAL_ERROR', dependencies.requestId) };
  const assets = await loadAssets(client, rows.data, dependencies.env, dependencies.requestId, dependencies.now ?? (() => new Date()));
  return assets.error ? assets : { data: assets.data[0] };
}

export async function readGarmentsByIds(client, userId, garmentIds, dependencies) {
  if (!Array.isArray(garmentIds) || garmentIds.length < 1 || garmentIds.some(id => !UUID.test(id))) {
    return { error: failure(500, 'INTERNAL_ERROR', dependencies.requestId) };
  }
  const rows = await readRows(client, userId, [['id', `in.(${garmentIds.join(',')})`]], dependencies.requestId);
  if (rows.error) return rows;
  if (rows.data.length !== garmentIds.length) return { error: failure(500, 'INTERNAL_ERROR', dependencies.requestId) };
  const assets = await loadAssets(client, rows.data, dependencies.env, dependencies.requestId, dependencies.now ?? (() => new Date()));
  if (assets.error) return assets;
  const byId = new Map(assets.data.map(item => [item.id.toLowerCase(), item]));
  const ordered = garmentIds.map(id => byId.get(id.toLowerCase()));
  return ordered.every(Boolean) ? { data: ordered } : { error: failure(500, 'INTERNAL_ERROR', dependencies.requestId) };
}

export async function listGarmentsResponse(req, dependencies) {
  const parsed = parseListQuery(req, dependencies.requestId);
  if (parsed.error) return parsed.error;
  const auth = await authenticatedUser(req, dependencies);
  if (auth.error) return auth.error;
  const filters = [];
  if (parsed.category) filters.push(['category', `eq.${parsed.category}`]);
  if (parsed.cursor) filters.push(['or', `(created_at.lt."${parsed.cursor.created_at}",and(created_at.eq."${parsed.cursor.created_at}",id.lt.${parsed.cursor.id}))`]);
  filters.push(['order', 'created_at.desc,id.desc'], ['limit', String(parsed.limit + 1)]);
  const rows = await readRows(auth.client, auth.user.id, filters, dependencies.requestId);
  if (rows.error) return rows.error;
  const hasMore = rows.data.length > parsed.limit;
  const page = rows.data.slice(0, parsed.limit);
  const assets = await loadAssets(auth.client, page, dependencies.env, dependencies.requestId, dependencies.now ?? (() => new Date()));
  if (assets.error) return assets.error;
  return { status: 200, headers: baseHeaders(dependencies.requestId), body: {
    items: assets.data,
    next_cursor: hasMore ? encodeCursor(page[page.length - 1], parsed.category) : null
  } };
}

export async function getGarmentResponse(req, dependencies) {
  const garmentId = pathId(req);
  if (!garmentId) return validation(dependencies.requestId);
  const auth = await authenticatedUser(req, dependencies);
  if (auth.error) return auth.error;
  const result = await readOne(auth.client, auth.user.id, garmentId, dependencies);
  if (result.error) return result.error;
  return { status: 200, headers: baseHeaders(dependencies.requestId), body: result.data };
}

export async function updateGarmentResponse(req, dependencies) {
  const garmentId = pathId(req);
  if (!garmentId) return validation(dependencies.requestId);
  const parsed = readJsonObject(req);
  if (parsed.error) return failure(400, parsed.error, dependencies.requestId);
  const body = parsed.data;
  if (!hasOnlyKeys(body, PATCH_KEYS) || Object.keys(body).length !== 2 || !Number.isInteger(body.expected_version) || body.expected_version < 1 ||
      !body.attributes || Array.isArray(body.attributes) || typeof body.attributes !== 'object' ||
      !hasOnlyKeys(body.attributes, ATTRIBUTE_KEYS) || Object.keys(body.attributes).length < 1) return validation(dependencies.requestId);
  const attributes = body.attributes;
  const setCategory = Object.hasOwn(attributes, 'category');
  const setSubcategory = Object.hasOwn(attributes, 'subcategory');
  const setMemo = Object.hasOwn(attributes, 'note');
  if (setCategory && !CATEGORIES.has(attributes.category)) return validation(dependencies.requestId);
  if (setSubcategory && attributes.subcategory !== null && (typeof attributes.subcategory !== 'string' ||
      codePoints(attributes.subcategory) > 80 || attributes.subcategory.includes('\u0000'))) return validation(dependencies.requestId);
  if (setMemo && attributes.note !== null && (typeof attributes.note !== 'string' || codePoints(attributes.note) > 1000 || attributes.note.includes('\u0000'))) {
    return validation(dependencies.requestId);
  }
  const auth = await authenticatedUser(req, dependencies);
  if (auth.error) return auth.error;
  const write = await auth.client.rpc('update_my_garment', {
    p_garment_id: garmentId, p_expected_version: body.expected_version,
    p_set_category: setCategory, p_category: setCategory ? attributes.category : null,
    p_set_subcategory: setSubcategory, p_subcategory: setSubcategory ? attributes.subcategory : null,
    p_set_memo: setMemo, p_memo: setMemo ? attributes.note : null
  });
  if (write.error) return write.error;
  const result = await readOne(auth.client, auth.user.id, garmentId, dependencies, 500);
  if (result.error) return result.error;
  return { status: 200, headers: baseHeaders(dependencies.requestId), body: result.data };
}

export async function deleteGarmentResponse(req, dependencies) {
  const garmentId = pathId(req);
  if (!garmentId) return validation(dependencies.requestId);
  const key = req.headers?.['idempotency-key'] ?? req.headers?.['Idempotency-Key'];
  if (typeof key !== 'string' || key.length < 8 || key.length > 128 || !/^[A-Za-z0-9._:-]+$/.test(key)) return validation(dependencies.requestId);
  const auth = await authenticatedUser(req, dependencies);
  if (auth.error) return auth.error;
  const write = await auth.client.rpc('delete_my_garment', { p_garment_id: garmentId, p_idempotency_key: key });
  if (write.error) return write.error;
  return { status: 202, headers: baseHeaders(dependencies.requestId), body: { id: garmentId, status: 'deletion_pending' } };
}
