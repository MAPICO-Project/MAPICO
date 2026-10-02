import { baseHeaders, failure } from './errors.js';
import { hasOnlyKeys, readJsonObject } from './json-body.js';
import { authenticatedUser } from './profile.js';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const KEY = /^[A-Za-z0-9._:-]{8,128}$/;
const MODEL = /^[A-Za-z0-9._:-]{1,100}$/;
const STATUSES = new Set(['queued', 'running', 'succeeded', 'no_match', 'failed']);
const FAILURE_CODES = new Set(['DEADLINE_EXCEEDED', 'ATTEMPTS_EXHAUSTED', 'SOURCE_UNAVAILABLE',
  'CANDIDATE_SNAPSHOT_CHANGED', 'MODEL_UNAVAILABLE', 'WORKER_TIMEOUT', 'MIMIC_FAILED']);
const RESULT_KEYS = new Set(['id', 'post_id', 'status', 'matches', 'model_version', 'coverage', 'error']);
const MATCH_KEYS = new Set(['source_item_key', 'garment_id', 'similarity', 'reason']);
const ERROR_KEYS = new Set(['code', 'message', 'retryable']);

function validation(requestId, status = 422) { return failure(status, 'VALIDATION_ERROR', requestId); }
function pathId(req) {
  const value = req.query?.jobId;
  return typeof value === 'string' && UUID.test(value) ? value.toLowerCase() : null;
}
function idempotencyKey(req) {
  const value = req.headers?.['idempotency-key'] ?? req.headers?.['Idempotency-Key'];
  return typeof value === 'string' && KEY.test(value) ? value : null;
}
function cleanText(value, max) {
  return typeof value === 'string' && [...value].length <= max && !/[\u0000-\u001f\u007f]/.test(value);
}
function exact(value, keys) {
  return value && typeof value === 'object' && !Array.isArray(value) && Object.keys(value).length === keys.size &&
    Object.keys(value).every(key => keys.has(key));
}
function resultDto(value, requestId) {
  if (!exact(value, RESULT_KEYS) || !UUID.test(value.id ?? '') || !UUID.test(value.post_id ?? '') ||
      !STATUSES.has(value.status) || !Array.isArray(value.matches) || value.matches.length > 10) return null;
  const waiting = value.status === 'queued' || value.status === 'running';
  const terminal = value.status === 'succeeded' || value.status === 'no_match';
  if (waiting && (value.matches.length !== 0 || value.model_version !== null || value.coverage !== null || value.error !== null)) return null;
  if (terminal && (value.matches.length < 1 || !MODEL.test(value.model_version ?? '') ||
      typeof value.coverage !== 'number' || !Number.isFinite(value.coverage) || value.coverage < 0 || value.coverage > 1 || value.error !== null)) return null;
  if (value.status === 'failed' && (value.matches.length !== 0 || value.model_version !== null || value.coverage !== null ||
      !exact(value.error, ERROR_KEYS) || !FAILURE_CODES.has(value.error.code) || !cleanText(value.error.message, 500) ||
      typeof value.error.retryable !== 'boolean')) return null;
  const matches = [];
  const rawKeys = new Set();
  for (const [index, item] of value.matches.entries()) {
    if (!exact(item, MATCH_KEYS) || typeof item.source_item_key !== 'string' || item.source_item_key.length < 1 ||
        rawKeys.has(item.source_item_key) || !cleanText(item.reason, 500)) return null;
    rawKeys.add(item.source_item_key);
    const unmatched = item.garment_id === null && item.similarity === null;
    const matched = UUID.test(item.garment_id ?? '') && typeof item.similarity === 'number' &&
      Number.isFinite(item.similarity) && item.similarity >= -1 && item.similarity <= 1;
    if (!unmatched && !matched) return null;
    matches.push({ source_item_key: `source-${index + 1}`, garment_id: matched ? item.garment_id.toLowerCase() : null,
      similarity: matched ? item.similarity : null,
      reason: matched ? '등록된 옷장에서 유사한 항목을 찾았습니다.' : '현재 옷장에서 적합한 항목을 찾지 못했습니다.' });
  }
  if (value.status === 'succeeded' && !matches.some(item => item.garment_id !== null)) return null;
  if (value.status === 'no_match' && (matches.some(item => item.garment_id !== null) || value.coverage !== 0)) return null;
  return { id: value.id.toLowerCase(), post_id: value.post_id.toLowerCase(), status: value.status, matches,
    model_version: value.model_version, coverage: value.coverage,
    error: value.status === 'failed' ? { ...value.error, request_id: requestId } : null };
}

export async function createMimicJobResponse(req, dependencies) {
  const parsed = readJsonObject(req); if (parsed.error) return failure(400, parsed.error, dependencies.requestId);
  const key = idempotencyKey(req); const body = parsed.data;
  if (!key || !hasOnlyKeys(body, new Set(['post_id'])) || Object.keys(body).length !== 1 ||
      typeof body.post_id !== 'string' || !UUID.test(body.post_id)) return validation(dependencies.requestId);
  const auth = await authenticatedUser(req, dependencies); if (auth.error) return auth.error;
  const result = await auth.client.rpc('create_my_mimic_job', { p_post_id: body.post_id.toLowerCase(), p_idempotency_key: key });
  if (result.error) return result.error;
  const dto = resultDto(result.data, dependencies.requestId);
  return dto ? { status: 202, headers: baseHeaders(dependencies.requestId), body: dto }
    : failure(500, 'INTERNAL_ERROR', dependencies.requestId);
}

export async function getMimicJobResponse(req, dependencies) {
  const jobId = pathId(req);
  if (!jobId || Object.keys(req.query ?? {}).some(key => key !== 'jobId') ||
      !(req.body === undefined || req.body === null || req.body === '')) return validation(dependencies.requestId, 400);
  const auth = await authenticatedUser(req, dependencies); if (auth.error) return auth.error;
  const result = await auth.client.rpc('get_my_mimic_job', { p_job_id: jobId }); if (result.error) return result.error;
  const dto = resultDto(result.data, dependencies.requestId);
  return dto ? { status: 200, headers: baseHeaders(dependencies.requestId), body: dto }
    : failure(500, 'INTERNAL_ERROR', dependencies.requestId);
}
