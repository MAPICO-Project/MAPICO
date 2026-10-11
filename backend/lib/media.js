import { baseHeaders, failure } from './errors.js';
import { hasOnlyKeys, readJsonObject } from './json-body.js';
import { authenticatedUser } from './profile.js';
import { projectUrl, signedStorageUrl } from './supabase-user.js';

// Owner-only uploads for the profile image and the selected OOTD photo (media_uploads).
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const IDEMPOTENCY = /^[A-Za-z0-9._:-]{8,128}$/;
const CONTENT_TYPES = new Set(['image/jpeg', 'image/png', 'image/webp']);
const BUCKETS = { avatar: 'profile-media', ootd_photo: 'ootd-private' };
const UPLOAD_SELECT = 'id,purpose,bucket_id,object_key,content_type,byte_size,verified_at,attached_at,deleted_at';

const validation = (requestId, status = 422) => failure(status, status === 400 ? 'INVALID_REQUEST_BODY' : 'VALIDATION_ERROR', requestId);
const clock = d => (d.now ?? (() => new Date()))();

function idempotencyKey(req) {
  const value = req.headers?.['idempotency-key'] ?? req.headers?.['Idempotency-Key'];
  return typeof value === 'string' && IDEMPOTENCY.test(value) ? value : null;
}

function uploadRow(row, userId) {
  if (!row || typeof row !== 'object' || !UUID.test(row.id ?? '') || !Object.hasOwn(BUCKETS, row.purpose) ||
      row.bucket_id !== BUCKETS[row.purpose] || !CONTENT_TYPES.has(row.content_type) ||
      typeof row.object_key !== 'string' || !row.object_key.startsWith(`${userId}/${row.purpose}/${row.id.toLowerCase()}.`) ||
      !Number.isInteger(Number(row.byte_size)) || Number(row.byte_size) < 1 || Number(row.byte_size) > 20971520) return null;
  return { ...row, id: row.id.toLowerCase(), byte_size: Number(row.byte_size) };
}

async function readUpload(client, userId, id, requestId) {
  const result = await client.select('media_uploads', [['select', UPLOAD_SELECT], ['user_id', `eq.${userId}`], ['id', `eq.${id}`]]);
  if (result.error) return result;
  if (!Array.isArray(result.data) || result.data.length > 1) return { error: failure(500, 'INTERNAL_ERROR', requestId) };
  if (result.data.length === 0) return { missing: true };
  const row = uploadRow(result.data[0], userId.toLowerCase());
  return row ? { data: row } : { error: failure(500, 'INTERNAL_ERROR', requestId) };
}

// Short-lived signed reads with the user's JWT; Storage RLS limits them to the owner's live uploads.
export async function signMediaReads(client, bucket, paths, d) {
  const unique = [...new Set(paths.filter(Boolean))];
  const signed = new Map();
  if (!unique.length) return { data: signed };
  const base = projectUrl(d.env);
  if (!base) return { error: failure(503, 'SUPABASE_NOT_CONFIGURED', d.requestId) };
  const expiresAt = new Date(clock(d).getTime() + 300000).toISOString();
  for (let offset = 0; offset < unique.length; offset += 100) {
    const result = await client.signStorage(bucket, unique.slice(offset, offset + 100), 300);
    if (result.error) return result;
    for (const item of result.data) {
      if (!item || typeof item !== 'object' || typeof item.path !== 'string' || item.error ||
          typeof item.signedURL !== 'string' || item.signedURL.length < 1) continue;
      const url = signedStorageUrl(item.signedURL, base, bucket);
      if (!url) continue;
      signed.set(item.path, { url: String(url), expires_at: expiresAt });
    }
  }
  return { data: signed };
}

export async function createMediaUploadResponse(req, d) {
  const parsed = readJsonObject(req);
  if (parsed.error) return failure(400, parsed.error, d.requestId);
  const b = parsed.data; const key = idempotencyKey(req);
  if (!key || !hasOnlyKeys(b, new Set(['purpose', 'content_type', 'file_size'])) || Object.keys(b).length !== 3 ||
      !Object.hasOwn(BUCKETS, b.purpose) || !CONTENT_TYPES.has(b.content_type) ||
      !Number.isInteger(b.file_size) || b.file_size < 1 || b.file_size > 20971520) return validation(d.requestId);
  const auth = await authenticatedUser(req, d);
  if (auth.error) return auth.error;
  const write = await auth.client.rpc('create_my_media_upload', {
    p_purpose: b.purpose, p_content_type: b.content_type, p_file_size: b.file_size, p_idempotency_key: key
  });
  if (write.error) return write.error;
  const id = write.data?.upload_id;
  if (!UUID.test(id ?? '')) return failure(500, 'INTERNAL_ERROR', d.requestId);
  const row = await readUpload(auth.client, auth.user.id, id.toLowerCase(), d.requestId);
  if (row.error) return row.error;
  if (row.missing || row.data.purpose !== b.purpose) return failure(500, 'INTERNAL_ERROR', d.requestId);
  if (row.data.verified_at !== null || row.data.deleted_at !== null) return failure(409, 'MEDIA_UPLOAD_CONFLICT', d.requestId);
  const signed = await auth.client.createSignedUpload(row.data.bucket_id, row.data.object_key);
  if (signed.error) return signed.error;
  return { status: 201, headers: baseHeaders(d.requestId), body: { id: row.data.id, purpose: row.data.purpose, upload: {
    url: signed.data.url, method: 'PUT', headers: { 'Content-Type': row.data.content_type },
    expires_at: new Date(clock(d).getTime() + 110 * 60 * 1000).toISOString() } } };
}

function hasMagic(bytes, type) {
  if (!(bytes instanceof Uint8Array)) return false;
  if (type === 'image/jpeg') return bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
  if (type === 'image/png') return bytes.length >= 8 && [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a].every((v, i) => bytes[i] === v);
  return bytes.length >= 12 && String.fromCharCode(...bytes.subarray(0, 4)) === 'RIFF' && String.fromCharCode(...bytes.subarray(8, 12)) === 'WEBP';
}

function uploadValid(download, upload) {
  if (download.contentType?.split(';', 1)[0]?.trim().toLowerCase() !== upload.content_type || !hasMagic(download.bytes, upload.content_type)) return false;
  if (download.status === 206) {
    const match = /^bytes 0-([0-9]+)\/([0-9]+)$/.exec(download.contentRange ?? '');
    return Boolean(match && Number(match[2]) === upload.byte_size && Number(match[1]) + 1 === download.bytes.length);
  }
  return download.status === 200;
}

export async function completeMediaUploadResponse(req, d) {
  const raw = req.query?.uploadId;
  const id = typeof raw === 'string' && UUID.test(raw) ? raw.toLowerCase() : null;
  if (!id) return validation(d.requestId);
  if (req.body !== undefined && req.body !== null && req.body !== '') return validation(d.requestId, 400);
  const auth = await authenticatedUser(req, d);
  if (auth.error) return auth.error;
  const row = await readUpload(auth.client, auth.user.id, id, d.requestId);
  if (row.error) return row.error;
  if (row.missing) return failure(404, 'MEDIA_UPLOAD_NOT_FOUND', d.requestId);
  if (row.data.deleted_at !== null) return failure(409, 'MEDIA_UPLOAD_CONFLICT', d.requestId);
  let outcome = 'valid';
  if (row.data.verified_at === null) {
    const read = await auth.client.readStoragePrefix(row.data.bucket_id, row.data.object_key, 65536);
    if (read.error) return read.error;
    if (read.missing) return failure(409, 'UPLOAD_NOT_FOUND', d.requestId, true);
    outcome = uploadValid(read.data, row.data) ? 'valid' : 'invalid';
  }
  const result = await auth.client.rpc('complete_my_media_upload', { p_upload_id: id, p_outcome: outcome });
  if (result.error) return result.error;
  if (result.data?.upload_id?.toLowerCase?.() !== id || typeof result.data.invalid !== 'boolean') return failure(500, 'INTERNAL_ERROR', d.requestId);
  if (result.data.invalid) return validation(d.requestId);
  return { status: 200, headers: baseHeaders(d.requestId), body: { id, purpose: row.data.purpose, status: 'verified' } };
}
