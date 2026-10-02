import { createHash, createHmac, randomUUID, timingSafeEqual } from 'node:crypto';
import { baseHeaders, failure } from './errors.js';
import { callbackSecret, createInternalClient } from './supabase-internal.js';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const KEYS = new Set(['event_id', 'attempt', 'status', 'model_versions', 'items', 'errors', 'job_id', 'lease_token']);
const ITEM_KEYS = new Set(['client_item_key', 'bbox', 'mask_object_key', 'attributes', 'confidence', 'item_index']);
const ATTRIBUTE_KEYS = new Set(['category', 'color_hex', 'pattern', 'formality', 'activity', 'warmth', 'aesthetic_scores']);
const ERROR_KEYS = new Set(['code', 'message', 'client_item_key']);
const CATEGORIES = new Set(['top', 'bottom', 'outerwear', 'dress', 'shoes', 'bag', 'accessory', 'other']);
const CONTENT_TYPES = new Set(['image/jpeg', 'image/png', 'image/webp']);
const MAX_BODY = 262144;

function only(value, keys) { return value && typeof value === 'object' && !Array.isArray(value) && Object.keys(value).every(key => keys.has(key)); }
async function rawBody(req, supplied) {
  if (supplied !== undefined) return Buffer.isBuffer(supplied) ? supplied : Buffer.from(supplied);
  const chunks = []; let length = 0;
  for await (const chunk of req) {
    const value = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk); length += value.length;
    if (length > MAX_BODY) return null; chunks.push(value);
  }
  return Buffer.concat(chunks);
}
function validAttributes(value) {
  if (!only(value, ATTRIBUTE_KEYS) || !CATEGORIES.has(value.category)) return false;
  if (value.color_hex !== undefined && value.color_hex !== null && (typeof value.color_hex !== 'string' || !/^#[0-9A-Fa-f]{6}$/.test(value.color_hex))) return false;
  if (value.pattern !== undefined && value.pattern !== null && (typeof value.pattern !== 'string' || [...value.pattern].length > 40)) return false;
  for (const key of ['formality', 'activity', 'warmth']) if (value[key] !== undefined && value[key] !== null &&
      (typeof value[key] !== 'number' || !Number.isFinite(value[key]) || value[key] < 0 || value[key] > 1)) return false;
  if (value.aesthetic_scores !== undefined && (!Array.isArray(value.aesthetic_scores) || value.aesthetic_scores.length > 15 ||
      value.aesthetic_scores.some(score => !only(score, new Set(['aesthetic_id', 'score'])) || !UUID.test(score.aesthetic_id) ||
      typeof score.score !== 'number' || !Number.isFinite(score.score) || score.score < 0 || score.score > 1))) return false;
  return true;
}
function validatePayload(value, pathJobId) {
  if (!only(value, KEYS) || Object.keys(value).length !== KEYS.size || !UUID.test(value.event_id) ||
      !UUID.test(value.job_id) || value.job_id.toLowerCase() !== pathJobId || !UUID.test(value.lease_token) ||
      !Number.isInteger(value.attempt) || value.attempt < 1 || !['succeeded', 'partial_failed', 'failed'].includes(value.status) ||
      !only(value.model_versions, new Set(Object.keys(value.model_versions ?? {}))) || Object.keys(value.model_versions).length < 1 ||
      Object.entries(value.model_versions).some(([key, version]) => !/^[A-Za-z0-9._:-]{1,80}$/.test(key) || typeof version !== 'string' || version.length < 1 || version.length > 100) ||
      !Array.isArray(value.items) || value.items.length > 6 || !Array.isArray(value.errors)) return null;
  if ((value.status === 'succeeded' && (value.items.length < 1 || value.errors.length !== 0)) ||
      (value.status === 'partial_failed' && (value.items.length < 1 || value.errors.length < 1)) ||
      (value.status === 'failed' && (value.items.length !== 0 || value.errors.length < 1))) return null;
  const indexes = new Set(); const clientKeys = new Set(); const paths = new Set();
  for (const item of value.items) {
    if (!only(item, ITEM_KEYS) || Object.keys(item).length !== ITEM_KEYS.size || typeof item.client_item_key !== 'string' ||
        item.client_item_key.length < 1 || item.client_item_key.length > 80 || !Number.isInteger(item.item_index) || item.item_index < 0 || item.item_index > 5 ||
        !Array.isArray(item.bbox) || item.bbox.length !== 4 || item.bbox.some(n => typeof n !== 'number' || !Number.isFinite(n) || n < 0 || n > 1) ||
        item.bbox[0] >= item.bbox[2] || item.bbox[1] >= item.bbox[3] || typeof item.mask_object_key !== 'string' || item.mask_object_key.length > 1024 ||
        !validAttributes(item.attributes) || (item.confidence !== null && (typeof item.confidence !== 'number' || !Number.isFinite(item.confidence) || item.confidence < 0 || item.confidence > 1)) ||
        indexes.has(item.item_index) || clientKeys.has(item.client_item_key) || paths.has(item.mask_object_key)) return null;
    indexes.add(item.item_index); clientKeys.add(item.client_item_key); paths.add(item.mask_object_key);
  }
  for (const error of value.errors) if (!only(error, ERROR_KEYS) || Object.keys(error).length !== ERROR_KEYS.size ||
      typeof error.code !== 'string' || error.code.length < 1 || error.code.length > 100 || typeof error.message !== 'string' || error.message.length > 1000 ||
      (error.client_item_key !== null && (typeof error.client_item_key !== 'string' || error.client_item_key.length > 80))) return null;
  return value;
}
function imageMetadata(download) {
  const type = download.contentType?.split(';', 1)[0]?.trim().toLowerCase(); if (!CONTENT_TYPES.has(type)) return null;
  let size = null;
  if (download.status === 206) {
    const match = /^bytes 0-([0-9]+)\/([0-9]+)$/.exec(download.contentRange ?? '');
    if (!match || Number(match[1]) + 1 !== download.bytes.length) return null; size = Number(match[2]);
  } else if (/^[1-9][0-9]*$/.test(download.contentLength ?? '')) size = Number(download.contentLength);
  if (!Number.isInteger(size) || size < 1 || size > 20971520) return null;
  const b = download.bytes;
  const magic = type === 'image/jpeg' ? b.length >= 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff
    : type === 'image/png' ? b.length >= 8 && [0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a].every((v, i) => b[i] === v)
      : b.length >= 12 && String.fromCharCode(...b.subarray(0, 4)) === 'RIFF' && String.fromCharCode(...b.subarray(8, 12)) === 'WEBP';
  return magic ? { content_type: type, byte_size: size } : null;
}
function jobRow(value, jobId) {
  return value && UUID.test(value.id) && value.id.toLowerCase() === jobId && UUID.test(value.user_id) && UUID.test(value.batch_id) &&
    typeof value.status === 'string' && Number.isInteger(value.attempt) &&
    (value.lease_token === null || UUID.test(value.lease_token)) &&
    (value.lease_expires_at === null || typeof value.lease_expires_at === 'string') ? value : null;
}

export function createAnalysisCallbackHandler(dependencies = {}) {
  return async function handler(req, res) {
    const requestId = (dependencies.createRequestId ?? randomUUID)(); const env = dependencies.env ?? process.env;
    let result;
    try {
      if (req.method !== 'POST') result = failure(405, 'METHOD_NOT_ALLOWED', requestId, false, { Allow: 'POST' });
      else {
        const jobIdValue = req.query?.jobId; const jobId = typeof jobIdValue === 'string' && UUID.test(jobIdValue) ? jobIdValue.toLowerCase() : null;
        const timestamp = req.headers?.['x-worker-timestamp']; const signature = req.headers?.['x-worker-signature']; const secret = callbackSecret(env);
        const now = (dependencies.now ?? (() => new Date()))();
        if (!jobId || typeof timestamp !== 'string' || !/^[1-9][0-9]{0,12}$/.test(timestamp) ||
            Math.abs(Math.floor(now.getTime() / 1000) - Number(timestamp)) > 300 || typeof signature !== 'string' || !/^[0-9a-fA-F]{64}$/.test(signature) || !secret) {
          result = failure(secret ? 401 : 503, secret ? 'INVALID_WORKER_SIGNATURE' : 'INTERNAL_INTEGRATION_NOT_CONFIGURED', requestId);
        } else {
          const raw = await rawBody(req, dependencies.rawBody);
          if (!raw || raw.length < 2 || raw.length > MAX_BODY) result = failure(400, 'INVALID_REQUEST_BODY', requestId);
          else {
            const expected = createHmac('sha256', secret).update(timestamp).update('.').update(raw).digest();
            const supplied = Buffer.from(signature, 'hex');
            if (!timingSafeEqual(expected, supplied)) result = failure(401, 'INVALID_WORKER_SIGNATURE', requestId);
            else {
              let parsed; try { parsed = JSON.parse(raw.toString('utf8')); } catch { parsed = null; }
              const body = validatePayload(parsed, jobId);
              if (!body) result = validationResult(requestId);
              else {
                const client = createInternalClient({ env, request: dependencies.request, requestId });
                if (client.error) result = client.error;
                else {
                  const payloadHash = createHash('sha256').update(raw).digest('hex');
                  const inspection = await client.inspectAnalysisCallback({ p_event_id: body.event_id, p_job_id: jobId,
                    p_attempt: body.attempt, p_payload_hash: payloadHash });
                  if (inspection.error) result = inspection.error;
                  else if (inspection.data?.replayed === true) result = { status: 200, headers: baseHeaders(requestId),
                    body: { job_id: jobId, event_id: body.event_id.toLowerCase(), applied: false } };
                  else {
                    const job = jobRow(inspection.data?.job, jobId);
                    if (!job || job.status !== 'running' || job.attempt !== body.attempt ||
                        job.lease_token?.toLowerCase() !== body.lease_token.toLowerCase() ||
                        Date.parse(job.lease_expires_at) <= now.getTime()) {
                      result = failure(409, 'ANALYSIS_CONFLICT', requestId);
                    } else {
                      const modelVersion = JSON.stringify(Object.fromEntries(Object.entries(body.model_versions).sort(([a], [b]) => a.localeCompare(b))));
                      const items = []; let storageError = null;
                      for (const item of body.items) {
                        const match = new RegExp(`^${job.user_id}/${job.batch_id}/cutouts/item-${item.item_index}\\.(jpg|png|webp)$`, 'i').exec(item.mask_object_key);
                        if (!match) { storageError = validationResult(requestId); break; }
                        const fence = await client.getAnalysisCutoutFence(jobId, item.mask_object_key);
                        if (fence.error) { storageError = fence.error; break; }
                        if (fence.missing || !UUID.test(fence.data?.object_id) ||
                            typeof fence.data?.object_updated_at !== 'string' || !Number.isFinite(Date.parse(fence.data.object_updated_at))) {
                          storageError = validationResult(requestId); break;
                        }
                        const read = await client.readStoragePrefix(item.mask_object_key);
                        if (read.error) { storageError = read.error; break; }
                        const metadata = read.missing ? null : imageMetadata(read.data);
                        if (!metadata) { storageError = validationResult(requestId); break; }
                        items.push({ mask_object_key: item.mask_object_key, storage_object_id: fence.data.object_id.toLowerCase(),
                          storage_updated_at: fence.data.object_updated_at,
                          ...metadata, item_index: item.item_index, client_item_key: item.client_item_key, bbox: item.bbox,
                          attributes: item.attributes, confidence: item.confidence, model_version: modelVersion });
                      }
                      if (storageError) result = storageError;
                      else {
                        const applied = await client.applyAnalysisResult({ p_event_id: body.event_id, p_job_id: jobId,
                          p_attempt: body.attempt, p_lease_token: body.lease_token,
                          p_payload_hash: payloadHash, p_status: body.status,
                          p_model_versions: body.model_versions, p_items: items, p_errors: body.errors });
                        if (applied.error) result = applied.error;
                        else if (typeof applied.data.applied !== 'boolean') result = failure(500, 'INTERNAL_ERROR', requestId);
                        else result = { status: 200, headers: baseHeaders(requestId), body: { job_id: jobId,
                          event_id: body.event_id.toLowerCase(), applied: applied.data.applied } };
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    } catch { result = failure(500, 'INTERNAL_ERROR', requestId); }
    for (const [name, value] of Object.entries(result.headers ?? {})) res.setHeader(name, value);
    return res.status(result.status).json(result.body);
  };
}

function validationResult(requestId) { return failure(422, 'VALIDATION_ERROR', requestId); }
