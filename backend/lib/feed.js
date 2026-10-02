import { baseHeaders, failure } from './errors.js';
import { readJsonObject, hasOnlyKeys } from './json-body.js';
import { authenticatedUser } from './profile.js';
import { createInternalClient } from './supabase-internal.js';
import { projectUrl } from './supabase-user.js';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const IDEMPOTENCY = /^[A-Za-z0-9._:-]{8,128}$/;
const CONTENT_TYPES = new Set(['image/jpeg', 'image/png', 'image/webp']);
const WEATHER = new Set(['clear', 'cloudy', 'rain', 'snow', 'unknown']);
const LIST_KEYS = new Set(['cursor', 'limit', 'aesthetic_id', 'weather_code', 'temperature_min', 'temperature_max']);
const SIMPLE_LIST_KEYS = new Set(['cursor', 'limit']);

function validation(requestId, status = 422) { return failure(status, 'VALIDATION_ERROR', requestId); }
function scalar(value) { return Array.isArray(value) ? null : value; }
function pathId(req, name) { const value = scalar(req.query?.[name]); return typeof value === 'string' && UUID.test(value) ? value.toLowerCase() : null; }
function idempotencyKey(req) {
  const value = req.headers?.['idempotency-key'] ?? req.headers?.['Idempotency-Key'];
  return typeof value === 'string' && IDEMPOTENCY.test(value) ? value : null;
}
function finite(value) {
  if (typeof value !== 'string' || !/^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?$/.test(value)) return null;
  const number = Number(value); return Number.isFinite(number) ? number : null;
}
function cursorPayload(kind, row, filters = {}) {
  const created = new Date(row.created_at);
  return Buffer.from(JSON.stringify({ v: 1, kind, at: created.toISOString(), id: (row.post_id ?? row.id).toLowerCase(), ...filters })).toString('base64url');
}
function decodeCursor(value, kind, filters) {
  if (typeof value !== 'string' || value.length < 1 || value.length > 1024 || !/^[A-Za-z0-9_-]+$/.test(value)) return null;
  try {
    const parsed = JSON.parse(Buffer.from(value, 'base64url').toString('utf8'));
    const expected = new Set(['v', 'kind', 'at', 'id', ...Object.keys(filters)]);
    if (!parsed || Array.isArray(parsed) || typeof parsed !== 'object' || Object.keys(parsed).length !== expected.size ||
        Object.keys(parsed).some(key => !expected.has(key)) || parsed.v !== 1 || parsed.kind !== kind || !UUID.test(parsed.id) ||
        typeof parsed.at !== 'string' || new Date(parsed.at).toISOString() !== parsed.at ||
        Object.entries(filters).some(([key, item]) => parsed[key] !== item)) return null;
    return { at: parsed.at, id: parsed.id.toLowerCase() };
  } catch { return null; }
}
function listParams(req, requestId, kind) {
  const query = req.query ?? {}; const allowed = kind === 'feed' ? LIST_KEYS : SIMPLE_LIST_KEYS;
  if (Object.keys(query).some(key => !allowed.has(key))) return { error: validation(requestId, 400) };
  const rawLimit = query.limit === undefined ? '20' : scalar(query.limit);
  if (typeof rawLimit !== 'string' || !/^(?:[1-9]|[1-9][0-9]|100)$/.test(rawLimit)) return { error: validation(requestId, 400) };
  const filters = {};
  if (kind === 'feed') {
    const aesthetic = query.aesthetic_id === undefined ? null : scalar(query.aesthetic_id);
    const weather = query.weather_code === undefined ? null : scalar(query.weather_code);
    const min = query.temperature_min === undefined ? null : finite(scalar(query.temperature_min));
    const max = query.temperature_max === undefined ? null : finite(scalar(query.temperature_max));
    if (aesthetic !== null && (typeof aesthetic !== 'string' || !UUID.test(aesthetic)) ||
        weather !== null && !WEATHER.has(weather) || query.temperature_min !== undefined && min === null ||
        query.temperature_max !== undefined && max === null || min !== null && (min < -90 || min > 60) ||
        max !== null && (max < -90 || max > 60) || min !== null && max !== null && min >= max) return { error: validation(requestId, 400) };
    Object.assign(filters, { aesthetic: aesthetic?.toLowerCase() ?? null, weather, min, max });
  }
  const cursor = query.cursor === undefined ? null : decodeCursor(scalar(query.cursor), kind, filters);
  if (query.cursor !== undefined && !cursor) return { error: validation(requestId, 400) };
  return { limit: Number(rawLimit), cursor, filters };
}
function validMedia(value) {
  return value && typeof value === 'object' && value.bucket_id === 'feed-private' &&
    typeof value.object_key === 'string' && value.object_key.length > 0 && value.object_key.length <= 1024 &&
    Number.isInteger(value.position) && value.position >= 0;
}
function validPost(value) {
  return value && typeof value === 'object' && UUID.test(value.id ?? '') && UUID.test(value.author?.id ?? '') &&
    (value.author.display_name === null || typeof value.author.display_name === 'string') &&
    typeof value.caption === 'string' && value.caption.length <= 2000 && UUID.test(value.aesthetic_id ?? '') &&
    WEATHER.has(value.weather_code) && (value.temperature_c === null || Number.isFinite(Number(value.temperature_c)) && Number(value.temperature_c) >= -90 && Number(value.temperature_c) <= 60) &&
    ['private', 'public'].includes(value.visibility) && typeof value.liked_by_me === 'boolean' &&
    Number.isInteger(Number(value.like_count)) && Number(value.like_count) >= 0 && Number.isFinite(Date.parse(value.created_at)) &&
    Array.isArray(value.media) && value.media.every(validMedia);
}
function rawFingerprint(rows) {
  return JSON.stringify(rows.map(row => ({ id: row.id, visibility: row.visibility,
    media: row.media.map(item => [item.object_key, item.position]) })));
}
async function projectAndSign(actorId, postIds, d) {
  if (!postIds.length) return { data: [] };
  const internal = createInternalClient(d); if (internal.error) return internal;
  const first = await internal.projectFeedPosts(actorId, postIds); if (first.error) return first;
  if (!Array.isArray(first.data) || first.data.some(row => !validPost(row)) ||
      first.data.some(row => row.visibility === 'public' && row.media.length === 0)) return { error: failure(500, 'INTERNAL_ERROR', d.requestId) };
  const paths = first.data.flatMap(row => row.media.map(item => item.object_key));
  const signed = new Map();
  if (paths.length) {
    const result = await internal.signFeedStorage(paths, 300); if (result.error) return result;
    const base = projectUrl(d.env); const expiresAt = new Date((d.now ?? (() => new Date()))().getTime() + 300000).toISOString();
    for (const item of result.data) {
      if (!item || item.error || typeof item.path !== 'string' || typeof item.signedURL !== 'string') continue;
      let url; try { url = new URL(item.signedURL, base); } catch { continue; }
      const expectedPath = `/storage/v1/object/sign/feed-private/${item.path.split('/').map(encodeURIComponent).join('/')}`;
      if (url.protocol === 'https:' && url.hostname === base.hostname && !url.port && !url.username && !url.password && !url.hash &&
          url.pathname === expectedPath && [...url.searchParams.keys()].length === 1 && url.searchParams.has('token') && url.searchParams.get('token')) {
        signed.set(item.path, { url: String(url), expires_at: expiresAt });
      }
    }
    if (signed.size !== new Set(paths).size) return { error: failure(503, 'STORAGE_UNAVAILABLE', d.requestId, true) };
  }
  const fence = await internal.projectFeedPosts(actorId, postIds); if (fence.error) return fence;
  if (!Array.isArray(fence.data) || rawFingerprint(first.data) !== rawFingerprint(fence.data)) {
    return { error: failure(409, 'FEED_CONFLICT', d.requestId, true) };
  }
  return { data: first.data.map(row => ({ id: row.id.toLowerCase(), author: { id: row.author.id.toLowerCase(), display_name: row.author.display_name },
    caption: row.caption, aesthetic_id: row.aesthetic_id.toLowerCase(), weather_code: row.weather_code,
    temperature_c: row.temperature_c === null ? null : Number(row.temperature_c), visibility: row.visibility,
    media: row.media.map(item => signed.get(item.object_key)), liked_by_me: row.liked_by_me,
    like_count: Number(row.like_count), created_at: row.created_at })) };
}
async function projectOne(auth, id, d, status) {
  const result = await projectAndSign(auth.user.id, [id], d); if (result.error) return result;
  return result.data.length === 1 ? { data: result.data[0] } : { error: failure(status, 'FEED_POST_NOT_FOUND', d.requestId) };
}
async function idsPage(auth, parsed, kind, d) {
  const filters = [];
  if (kind === 'feed') {
    filters.push(['visibility', 'eq.public'], ['deleted_at', 'is.null']);
    if (parsed.filters.aesthetic) filters.push(['aesthetic_id', `eq.${parsed.filters.aesthetic}`]);
    if (parsed.filters.weather) filters.push(['weather_code', `eq.${parsed.filters.weather}`]);
    if (parsed.filters.min !== null) filters.push(['temperature_c', `gte.${parsed.filters.min}`]);
    if (parsed.filters.max !== null) filters.push(['temperature_c', `lt.${parsed.filters.max}`]);
  } else if (kind === 'mine') filters.push(['user_id', `eq.${auth.user.id}`], ['deleted_at', 'is.null']);
  if (kind === 'likes') {
    const internal = createInternalClient(d); if (internal.error) return internal;
    const result = await internal.projectVisibleLikes(auth.user.id, parsed.cursor, parsed.limit + 1);
    return result.error ? result : { data: result.data, idField: 'post_id' };
  }
  if (parsed.cursor) filters.push(['or', `(created_at.lt."${parsed.cursor.at}",and(created_at.eq."${parsed.cursor.at}",id.lt.${parsed.cursor.id}))`]);
  filters.push(['select', 'id,created_at'], ['order', 'created_at.desc,id.desc'], ['limit', String(parsed.limit + 1)]);
  const result = await auth.client.select('feed_posts', filters); return result.error ? result : { data: result.data, idField: 'id' };
}
async function listResponse(req, d, kind) {
  const parsed = listParams(req, d.requestId, kind); if (parsed.error) return parsed.error;
  const auth = await authenticatedUser(req, d); if (auth.error) return auth.error;
  const rows = await idsPage(auth, parsed, kind, d); if (rows.error) return rows;
  if (!Array.isArray(rows.data) || rows.data.some(row => !UUID.test(row?.[rows.idField] ?? '') || !Number.isFinite(Date.parse(row.created_at)))) return failure(500, 'INTERNAL_ERROR', d.requestId);
  const rawPage = rows.data.slice(0, parsed.limit); const projected = await projectAndSign(auth.user.id, rawPage.map(row => row[rows.idField]), d);
  if (projected.error) return projected.error;
  return { status: 200, headers: baseHeaders(d.requestId), body: { items: projected.data,
    next_cursor: rows.data.length > parsed.limit ? cursorPayload(kind, rawPage.at(-1), parsed.filters) : null } };
}

export const listFeedResponse = (req, d) => listResponse(req, d, 'feed');
export const listMyPostsResponse = (req, d) => listResponse(req, d, 'mine');
export const listLikedPostsResponse = (req, d) => listResponse(req, d, 'likes');

export async function getFeedPostResponse(req, d) {
  const id = pathId(req, 'postId'); if (!id) return validation(d.requestId);
  const auth = await authenticatedUser(req, d); if (auth.error) return auth.error;
  const visible = await auth.client.select('feed_posts', [['select', 'id'], ['id', `eq.${id}`]]); if (visible.error) return visible.error;
  if (!Array.isArray(visible.data) || visible.data.length !== 1) return failure(404, 'FEED_POST_NOT_FOUND', d.requestId);
  const post = await projectOne(auth, id, d, 404); return post.error ?? { status: 200, headers: baseHeaders(d.requestId), body: post.data };
}
function postBody(req, requestId, patch) {
  const parsed = readJsonObject(req); if (parsed.error) return { error: failure(400, parsed.error, requestId) }; const b = parsed.data;
  const allowed = patch ? new Set(['caption', 'aesthetic_id', 'visibility']) : new Set(['source_ootd_id', 'caption', 'aesthetic_id', 'weather_code', 'temperature_c', 'visibility']);
  if (!hasOnlyKeys(b, allowed) || patch && Object.keys(b).length < 1 || !patch &&
      (!Object.hasOwn(b, 'caption') || !Object.hasOwn(b, 'aesthetic_id') || b.visibility !== 'private')) return { error: validation(requestId) };
  if (Object.hasOwn(b, 'caption') && (typeof b.caption !== 'string' || b.caption.length > 2000 || b.caption.includes('\0')) ||
      Object.hasOwn(b, 'aesthetic_id') && (typeof b.aesthetic_id !== 'string' || !UUID.test(b.aesthetic_id)) ||
      Object.hasOwn(b, 'source_ootd_id') && !(b.source_ootd_id === null || typeof b.source_ootd_id === 'string' && UUID.test(b.source_ootd_id)) ||
      Object.hasOwn(b, 'weather_code') && (typeof b.weather_code !== 'string' || !WEATHER.has(b.weather_code)) ||
      Object.hasOwn(b, 'temperature_c') && !(b.temperature_c === null || Number.isFinite(b.temperature_c) && b.temperature_c >= -90 && b.temperature_c <= 60) ||
      Object.hasOwn(b, 'visibility') && !['private', 'public'].includes(b.visibility)) return { error: validation(requestId) };
  return { data: b };
}
export async function createFeedPostResponse(req, d) {
  const parsed = postBody(req, d.requestId, false); if (parsed.error) return parsed.error; const key = idempotencyKey(req); if (!key) return validation(d.requestId);
  const auth = await authenticatedUser(req, d); if (auth.error) return auth.error; const b = parsed.data;
  const write = await auth.client.rpc('create_my_feed_post', { p_source_ootd_id: b.source_ootd_id ?? null, p_caption: b.caption,
    p_aesthetic_id: b.aesthetic_id.toLowerCase(), p_weather_code: b.weather_code ?? null, p_temperature_c: b.temperature_c ?? null, p_idempotency_key: key });
  if (write.error) return write.error; const id = write.data?.post_id; if (!UUID.test(id ?? '')) return failure(500, 'INTERNAL_ERROR', d.requestId);
  const post = await projectOne(auth, id, d, 500); return post.error ?? { status: 201, headers: baseHeaders(d.requestId), body: post.data };
}
export async function updateFeedPostResponse(req, d) {
  const id = pathId(req, 'postId'); if (!id) return validation(d.requestId); const parsed = postBody(req, d.requestId, true); if (parsed.error) return parsed.error;
  const auth = await authenticatedUser(req, d); if (auth.error) return auth.error; const b = parsed.data;
  const write = await auth.client.rpc('update_my_feed_post', { p_post_id: id, p_has_caption: Object.hasOwn(b, 'caption'), p_caption: b.caption ?? null,
    p_has_aesthetic_id: Object.hasOwn(b, 'aesthetic_id'), p_aesthetic_id: b.aesthetic_id ?? null,
    p_has_visibility: Object.hasOwn(b, 'visibility'), p_visibility: b.visibility ?? null }); if (write.error) return write.error;
  const post = await projectOne(auth, id, d, 500); return post.error ?? { status: 200, headers: baseHeaders(d.requestId), body: post.data };
}
export async function deleteFeedPostResponse(req, d) {
  const id = pathId(req, 'postId'); if (!id) return validation(d.requestId); const auth = await authenticatedUser(req, d); if (auth.error) return auth.error;
  const result = await auth.client.rpc('delete_my_feed_post', { p_post_id: id }); if (result.error) return result.error;
  return result.data?.id === id && result.data?.status === 'deletion_pending'
    ? { status: 202, headers: baseHeaders(d.requestId), body: { id, status: 'deletion_pending' } } : failure(500, 'INTERNAL_ERROR', d.requestId);
}
function sameFence(a, b) {
  return a?.post?.id === b?.post?.id && a.post.visibility === b.post.visibility && a.post.deleted_at === b.post.deleted_at &&
    a.post.updated_at === b.post.updated_at && a.media.id === b.media.id && a.media.object_key === b.media.object_key &&
    a.media.verified_at === b.media.verified_at && a.media.deleted_at === b.media.deleted_at &&
    (a.storage?.id ?? null) === (b.storage?.id ?? null) && (a.storage?.updated_at ?? null) === (b.storage?.updated_at ?? null);
}
function usableFence(value, requireUnverified = false) {
  const p = value?.post; const m = value?.media;
  return p && m && p.visibility === 'private' && p.deleted_at === null && m.bucket_id === 'feed-private' && m.deleted_at === null &&
    (!requireUnverified || m.verified_at === null) && typeof m.object_key === 'string' && m.object_key.startsWith(`${p.user_id}/${p.id}/${m.id}.`) &&
    CONTENT_TYPES.has(m.content_type) && Number.isInteger(Number(m.byte_size)) && Number(m.byte_size) >= 1 && Number(m.byte_size) <= 20971520;
}
export async function createFeedMediaResponse(req, d) {
  const id = pathId(req, 'postId'); if (!id) return validation(d.requestId); const parsed = readJsonObject(req);
  if (parsed.error) return failure(400, parsed.error, d.requestId); const b = parsed.data; const key = idempotencyKey(req);
  if (!key || !hasOnlyKeys(b, new Set(['content_type', 'file_size'])) || Object.keys(b).length !== 2 || !CONTENT_TYPES.has(b.content_type) ||
      !Number.isInteger(b.file_size) || b.file_size < 1 || b.file_size > 20971520) return validation(d.requestId);
  const auth = await authenticatedUser(req, d); if (auth.error) return auth.error;
  const write = await auth.client.rpc('create_my_feed_media', { p_post_id: id, p_content_type: b.content_type, p_file_size: b.file_size, p_idempotency_key: key });
  if (write.error) return write.error; const mediaId = write.data?.media_id; if (!UUID.test(mediaId ?? '')) return failure(500, 'INTERNAL_ERROR', d.requestId);
  const internal = createInternalClient(d); if (internal.error) return internal.error;
  const before = await internal.getFeedMediaFence(auth.user.id, id, mediaId); if (before.error) return before.error;
  if (before.missing || !usableFence(before.data, true)) return failure(409, 'FEED_CONFLICT', d.requestId);
  const signed = await auth.client.createSignedUpload('feed-private', before.data.media.object_key); if (signed.error) return signed.error;
  const after = await internal.getFeedMediaFence(auth.user.id, id, mediaId); if (after.error) return after.error;
  if (after.missing || !usableFence(after.data, true) || !sameFence(before.data, after.data)) return failure(409, 'FEED_CONFLICT', d.requestId, true);
  const expiresAt = new Date((d.now ?? (() => new Date()))().getTime() + 110 * 60 * 1000).toISOString();
  return { status: 201, headers: baseHeaders(d.requestId), body: { media_id: mediaId.toLowerCase(), upload: {
    url: signed.data.url, method: 'PUT', headers: { 'Content-Type': b.content_type }, expires_at: expiresAt } } };
}
function hasMagic(bytes, type) {
  if (!(bytes instanceof Uint8Array)) return false;
  if (type === 'image/jpeg') return bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
  if (type === 'image/png') return bytes.length >= 8 && [0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a].every((v, i) => bytes[i] === v);
  return bytes.length >= 12 && String.fromCharCode(...bytes.subarray(0, 4)) === 'RIFF' && String.fromCharCode(...bytes.subarray(8, 12)) === 'WEBP';
}
function uploadValid(download, media) {
  if (download.contentType?.split(';', 1)[0]?.trim().toLowerCase() !== media.content_type || !hasMagic(download.bytes, media.content_type)) return false;
  if (download.status === 206) {
    const match = /^bytes 0-([0-9]+)\/([0-9]+)$/.exec(download.contentRange ?? '');
    return Boolean(match && Number(match[2]) === Number(media.byte_size) && Number(match[1]) + 1 === download.bytes.length);
  }
  return download.status === 200;
}
export async function completeFeedMediaResponse(req, d) {
  const postId = pathId(req, 'postId'); const mediaId = pathId(req, 'mediaId'); const key = idempotencyKey(req);
  if (!postId || !mediaId || !key) return validation(d.requestId);
  if (req.body !== undefined && req.body !== null && req.body !== '') return validation(d.requestId, 400);
  const auth = await authenticatedUser(req, d); if (auth.error) return auth.error; const internal = createInternalClient(d); if (internal.error) return internal.error;
  const fence = await internal.getFeedMediaFence(auth.user.id, postId, mediaId); if (fence.error) return fence.error;
  if (fence.missing) return failure(404, 'FEED_MEDIA_NOT_FOUND', d.requestId);
  if (!fence.data.storage?.id || typeof fence.data.storage.updated_at !== 'string') return failure(409, 'UPLOAD_NOT_FOUND', d.requestId, true);
  const storageArgs = { p_storage_id: fence.data.storage.id, p_storage_updated_at: fence.data.storage.updated_at };
  if (!usableFence(fence.data) && fence.data.media?.deleted_at !== null) {
    const replay = await auth.client.rpc('complete_my_feed_media', { p_post_id: postId, p_media_id: mediaId, p_idempotency_key: key, p_outcome: 'invalid', ...storageArgs });
    if (replay.error) return replay.error;
    return replay.data?.invalid === true ? validation(d.requestId) : failure(409, 'FEED_CONFLICT', d.requestId);
  }
  if (!usableFence(fence.data)) return failure(404, 'FEED_MEDIA_NOT_FOUND', d.requestId);
  let outcome = 'valid';
  if (fence.data.media.verified_at === null) {
    const read = await auth.client.readStoragePrefix('feed-private', fence.data.media.object_key, 65536);
    if (read.error) return read.error; if (read.missing) return failure(409, 'UPLOAD_NOT_FOUND', d.requestId, true);
    outcome = uploadValid(read.data, fence.data.media) ? 'valid' : 'invalid';
  }
  const result = await auth.client.rpc('complete_my_feed_media', { p_post_id: postId, p_media_id: mediaId, p_idempotency_key: key, p_outcome: outcome, ...storageArgs });
  if (result.error) return result.error; if (result.data?.invalid === true) return validation(d.requestId);
  const post = await projectOne(auth, postId, d, 500); return post.error ?? { status: 200, headers: baseHeaders(d.requestId), body: post.data };
}
export async function likeFeedPostResponse(req, d) {
  const id = pathId(req, 'postId'); if (!id) return validation(d.requestId); const auth = await authenticatedUser(req, d); if (auth.error) return auth.error;
  const result = await auth.client.rpc('like_my_feed_post', { p_post_id: id }); if (result.error) return result.error;
  return { status: 204, headers: baseHeaders(d.requestId), body: null };
}
export async function unlikeFeedPostResponse(req, d) {
  const id = pathId(req, 'postId'); if (!id) return validation(d.requestId); const auth = await authenticatedUser(req, d); if (auth.error) return auth.error;
  const result = await auth.client.rpc('unlike_my_feed_post', { p_post_id: id }); if (result.error) return result.error;
  return { status: 204, headers: baseHeaders(d.requestId), body: null };
}
