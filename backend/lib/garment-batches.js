import { baseHeaders, failure } from './errors.js';
import { hasOnlyKeys, readJsonObject } from './json-body.js';
import { authenticatedUser } from './profile.js';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const TIMESTAMP = /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,6})?(?:Z|[+-][0-9]{2}:[0-9]{2})$/;
const CONTENT_TYPES = new Set(['image/jpeg', 'image/png', 'image/webp']);
const STATUSES = new Set(['awaiting_upload', 'uploaded', 'processing', 'review', 'confirmed', 'failed']);
const CREATE_KEYS = new Set(['content_type', 'file_size']);
const BATCH_SELECT = 'id,status,created_at';
const ASSET_SELECT = 'id,batch_id,kind,bucket_id,object_key,content_type,byte_size,verified_at,deleted_at';

function validation(requestId, status = 422) {
  return failure(status, status === 400 ? 'INVALID_REQUEST_BODY' : 'VALIDATION_ERROR', requestId);
}
function idempotencyKey(req) {
  const value = req.headers?.['idempotency-key'] ?? req.headers?.['Idempotency-Key'];
  return typeof value === 'string' && value.length >= 8 && value.length <= 128 && /^[A-Za-z0-9._:-]+$/.test(value) ? value : null;
}
function pathId(req) {
  const value = req.query?.batchId;
  return typeof value === 'string' && UUID.test(value) ? value.toLowerCase() : null;
}
function batchDto(row) {
  return row && typeof row === 'object' && UUID.test(row.id) && STATUSES.has(row.status) && TIMESTAMP.test(row.created_at)
    ? { id: row.id.toLowerCase(), status: row.status, created_at: row.created_at } : null;
}
function sourceAsset(row, batchId) {
  return row && typeof row === 'object' && UUID.test(row.id) && row.batch_id?.toLowerCase() === batchId && row.kind === 'source' &&
    row.bucket_id === 'closet-private' && typeof row.object_key === 'string' && row.object_key.length <= 1024 &&
    CONTENT_TYPES.has(row.content_type) && Number.isInteger(Number(row.byte_size)) && Number(row.byte_size) >= 1 &&
    Number(row.byte_size) <= 20971520 && row.deleted_at === null ? { ...row, byte_size: Number(row.byte_size) } : null;
}
async function readBatch(client, userId, batchId, requestId) {
  const result = await client.select('garment_batches', [['select', BATCH_SELECT], ['user_id', `eq.${userId}`], ['id', `eq.${batchId}`]]);
  if (result.error) return result;
  if (!Array.isArray(result.data) || result.data.length > 1) return { error: failure(500, 'INTERNAL_ERROR', requestId) };
  if (result.data.length === 0) return { error: failure(404, 'BATCH_NOT_FOUND', requestId) };
  const batch = batchDto(result.data[0]);
  return batch ? { data: batch } : { error: failure(500, 'INTERNAL_ERROR', requestId) };
}
async function readSource(client, userId, batchId, requestId) {
  const result = await client.select('garment_assets', [['select', ASSET_SELECT], ['user_id', `eq.${userId}`],
    ['batch_id', `eq.${batchId}`], ['kind', 'eq.source'], ['deleted_at', 'is.null']]);
  if (result.error) return result;
  if (!Array.isArray(result.data) || result.data.length !== 1) return { error: failure(500, 'INTERNAL_ERROR', requestId) };
  const asset = sourceAsset(result.data[0], batchId);
  return asset ? { data: asset } : { error: failure(500, 'INTERNAL_ERROR', requestId) };
}
function signedUpload(data, contentType, now) {
  return { url: data.url, method: 'PUT', headers: { 'Content-Type': contentType },
    expires_at: new Date(now.getTime() + 110 * 60 * 1000).toISOString() };
}
async function sign(client, asset, dependencies) {
  const result = await client.createSignedUpload('closet-private', asset.object_key);
  if (result.error) return result;
  return { data: signedUpload(result.data, asset.content_type, (dependencies.now ?? (() => new Date()))()) };
}
function validRpcCreate(value) {
  const batch = batchDto(value?.batch);
  return batch && typeof value.object_key === 'string' && value.object_key.length > 0 && value.object_key.length <= 1024
    ? { batch, object_key: value.object_key } : null;
}
function validRpcComplete(value) {
  const batch = batchDto(value?.batch);
  return batch && typeof value.invalid === 'boolean' ? { batch, invalid: value.invalid } : null;
}
function hasMagic(bytes, contentType) {
  if (!(bytes instanceof Uint8Array)) return false;
  if (contentType === 'image/jpeg') return bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
  if (contentType === 'image/png') return bytes.length >= 8 && [0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a].every((v, i) => bytes[i] === v);
  return bytes.length >= 12 && String.fromCharCode(...bytes.subarray(0, 4)) === 'RIFF' &&
    String.fromCharCode(...bytes.subarray(8, 12)) === 'WEBP';
}
function uploadLooksValid(download, asset) {
  const type = download.contentType?.split(';', 1)[0]?.trim().toLowerCase();
  if (type !== asset.content_type || !hasMagic(download.bytes, asset.content_type)) return false;
  if (download.status === 206) {
    const match = /^bytes 0-([0-9]+)\/([0-9]+)$/.exec(download.contentRange ?? '');
    if (!match || Number(match[2]) !== asset.byte_size || Number(match[1]) + 1 !== download.bytes.length) return false;
  }
  return true;
}

export async function createGarmentBatchResponse(req, dependencies) {
  const parsed = readJsonObject(req);
  if (parsed.error) return failure(400, parsed.error, dependencies.requestId);
  const body = parsed.data;
  const key = idempotencyKey(req);
  if (!key || !hasOnlyKeys(body, CREATE_KEYS) || Object.keys(body).length !== 2 || !CONTENT_TYPES.has(body.content_type) ||
      !Number.isInteger(body.file_size) || body.file_size < 1 || body.file_size > 20971520) return validation(dependencies.requestId);
  const auth = await authenticatedUser(req, dependencies);
  if (auth.error) return auth.error;
  const write = await auth.client.rpc('create_my_garment_batch', {
    p_content_type: body.content_type, p_file_size: body.file_size, p_idempotency_key: key
  });
  if (write.error) return write.error;
  const created = validRpcCreate(write.data);
  if (!created || !created.object_key.startsWith(`${auth.user.id.toLowerCase()}/${created.batch.id}/`)) {
    return failure(500, 'INTERNAL_ERROR', dependencies.requestId);
  }
  const asset = { object_key: created.object_key, content_type: body.content_type };
  const upload = await sign(auth.client, asset, dependencies);
  if (upload.error) return upload.error;
  return { status: 201, headers: baseHeaders(dependencies.requestId), body: { batch: created.batch, upload: upload.data,
    object_key: created.object_key } };
}

export async function getGarmentBatchResponse(req, dependencies) {
  const batchId = pathId(req);
  if (!batchId) return validation(dependencies.requestId);
  const auth = await authenticatedUser(req, dependencies);
  if (auth.error) return auth.error;
  const result = await readBatch(auth.client, auth.user.id, batchId, dependencies.requestId);
  if (result.error) return result.error;
  return { status: 200, headers: baseHeaders(dependencies.requestId), body: result.data };
}

export async function refreshUploadUrlResponse(req, dependencies) {
  const batchId = pathId(req);
  if (!batchId) return validation(dependencies.requestId);
  if (req.body !== undefined && req.body !== null && req.body !== '') return validation(dependencies.requestId, 400);
  const auth = await authenticatedUser(req, dependencies);
  if (auth.error) return auth.error;
  const batch = await readBatch(auth.client, auth.user.id, batchId, dependencies.requestId);
  if (batch.error) return batch.error;
  if (batch.data.status !== 'awaiting_upload') return failure(409, 'INVALID_BATCH_STATE', dependencies.requestId);
  const asset = await readSource(auth.client, auth.user.id, batchId, dependencies.requestId);
  if (asset.error) return asset.error;
  if (asset.data.verified_at !== null) return failure(409, 'INVALID_BATCH_STATE', dependencies.requestId);
  const existing = await auth.client.readStoragePrefix('closet-private', asset.data.object_key, 16);
  if (existing.error) return existing.error;
  if (!existing.missing) return failure(409, 'INVALID_BATCH_STATE', dependencies.requestId);
  const upload = await sign(auth.client, asset.data, dependencies);
  if (upload.error) return upload.error;
  return { status: 200, headers: baseHeaders(dependencies.requestId), body: upload.data };
}

export async function completeGarmentUploadResponse(req, dependencies) {
  const batchId = pathId(req);
  const key = idempotencyKey(req);
  if (!batchId || !key) return validation(dependencies.requestId);
  if (req.body !== undefined && req.body !== null && req.body !== '') return validation(dependencies.requestId, 400);
  const auth = await authenticatedUser(req, dependencies);
  if (auth.error) return auth.error;
  const batch = await readBatch(auth.client, auth.user.id, batchId, dependencies.requestId);
  if (batch.error) return batch.error;
  if (batch.data.status !== 'awaiting_upload') {
    if (['uploaded', 'processing', 'review', 'confirmed'].includes(batch.data.status)) {
      const replay = await auth.client.rpc('complete_my_garment_upload', {
        p_batch_id: batchId, p_idempotency_key: key, p_outcome: 'valid'
      });
      if (replay.error) return replay.error;
      const completed = validRpcComplete(replay.data);
      if (!completed || completed.invalid) return failure(500, 'INTERNAL_ERROR', dependencies.requestId);
      return { status: 200, headers: baseHeaders(dependencies.requestId), body: completed.batch };
    }
    return failure(409, 'INVALID_BATCH_STATE', dependencies.requestId);
  }
  const asset = await readSource(auth.client, auth.user.id, batchId, dependencies.requestId);
  if (asset.error) return asset.error;
  const downloaded = await auth.client.readStoragePrefix('closet-private', asset.data.object_key);
  if (downloaded.error) return downloaded.error;
  if (downloaded.missing) return failure(409, 'UPLOAD_NOT_FOUND', dependencies.requestId, true);
  const outcome = uploadLooksValid(downloaded.data, asset.data) ? 'valid' : 'invalid';
  const write = await auth.client.rpc('complete_my_garment_upload', {
    p_batch_id: batchId, p_idempotency_key: key, p_outcome: outcome
  });
  if (write.error) return write.error;
  const completed = validRpcComplete(write.data);
  if (!completed) return failure(500, 'INTERNAL_ERROR', dependencies.requestId);
  if (completed.invalid) return validation(dependencies.requestId);
  return { status: 200, headers: baseHeaders(dependencies.requestId), body: completed.batch };
}
