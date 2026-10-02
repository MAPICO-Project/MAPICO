import { baseHeaders, failure, MESSAGES } from './errors.js';
import { hasOnlyKeys, readJsonObject } from './json-body.js';
import { readGarmentsByIds } from './garments.js';
import { authenticatedUser } from './profile.js';
import { projectUrl } from './supabase-user.js';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const TIMESTAMP = /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,6})?(?:Z|[+-][0-9]{2}:[0-9]{2})$/;
const JOB_STATUSES = new Set(['queued', 'running', 'succeeded', 'partial_failed', 'failed', 'cancelled']);
const RETRYABLE_ANALYSIS_ERRORS = new Set([
  'WORKER_TIMEOUT', 'MODEL_UNAVAILABLE', 'STORAGE_UNAVAILABLE', 'INTERNAL_ERROR', 'CALLBACK_TIMEOUT'
]);
const DRAFT_STATUSES = new Set(['predicted', 'edited', 'confirmed', 'rejected']);
const CATEGORIES = new Set(['top', 'bottom', 'outerwear', 'dress', 'shoes', 'bag', 'accessory', 'other']);
const PATCH_KEYS = new Set(['expected_version', 'attributes']);
const ATTRIBUTE_KEYS = new Set(['category', 'subcategory', 'note']);
const CONFIRM_KEYS = new Set(['draft_ids', 'draft_versions']);

function validation(requestId, status = 422) { return failure(status, status === 400 ? 'INVALID_REQUEST_BODY' : 'VALIDATION_ERROR', requestId); }
function codePoints(value) { return [...value].length; }
function pathId(req, name) { const value = req.query?.[name]; return typeof value === 'string' && UUID.test(value) ? value.toLowerCase() : null; }
function idempotencyKey(req) {
  const value = req.headers?.['idempotency-key'] ?? req.headers?.['Idempotency-Key'];
  return typeof value === 'string' && value.length >= 8 && value.length <= 128 && /^[A-Za-z0-9._:-]+$/.test(value) ? value : null;
}
function noBody(req, requestId) {
  return req.body === undefined || req.body === null || req.body === '' ? null : validation(requestId, 400);
}
function jobDto(row, requestId) {
  if (!row || typeof row !== 'object' || !UUID.test(row.id) || !UUID.test(row.batch_id) || !JOB_STATUSES.has(row.status) ||
      !Number.isInteger(row.attempt) || row.attempt < 0 || !Number.isInteger(row.max_attempts) || row.max_attempts < 1 ||
      (row.stage !== null && !['detecting', 'segmenting', 'tagging'].includes(row.stage)) ||
      !Number.isInteger(row.progress) || row.progress < 0 || row.progress > 100 ||
      (row.error_code !== null && (typeof row.error_code !== 'string' || row.error_code.length > 100)) ||
      !TIMESTAMP.test(row.created_at) || !TIMESTAMP.test(row.updated_at)) return null;
  const retryable = row.status === 'failed' && row.attempt < row.max_attempts && RETRYABLE_ANALYSIS_ERRORS.has(row.error_code);
  return { id: row.id.toLowerCase(), batch_id: row.batch_id.toLowerCase(), status: row.status, attempt: row.attempt,
    max_attempts: row.max_attempts, stage: row.stage, progress: row.progress, retryable,
    error: row.error_code === null ? null : { code: 'ANALYSIS_FAILED', message: MESSAGES.ANALYSIS_FAILED,
      retryable, request_id: requestId }, created_at: row.created_at, updated_at: row.updated_at };
}
function rpcJob(value, requestId) { return jobDto(value?.job ?? value, requestId); }
async function readJob(client, userId, jobId, requestId) {
  const result = await client.select('analysis_jobs', [['select', 'id,batch_id,status,attempt,max_attempts,stage,progress,error_code,created_at,updated_at'],
    ['user_id', `eq.${userId}`], ['id', `eq.${jobId}`]]);
  if (result.error) return result;
  if (!Array.isArray(result.data) || result.data.length > 1) return { error: failure(500, 'INTERNAL_ERROR', requestId) };
  if (result.data.length === 0) return { error: failure(404, 'ANALYSIS_JOB_NOT_FOUND', requestId) };
  const job = jobDto(result.data[0], requestId);
  return job ? { data: job } : { error: failure(500, 'INTERNAL_ERROR', requestId) };
}
function safeAttributes(value, requireNote) {
  if (!value || typeof value !== 'object' || Array.isArray(value) || !CATEGORIES.has(value.category) ||
      (value.subcategory !== null && (typeof value.subcategory !== 'string' || codePoints(value.subcategory) > 80)) ||
      (requireNote && value.note !== null && (typeof value.note !== 'string' || codePoints(value.note) > 1000))) return null;
  return requireNote ? { category: value.category, subcategory: value.subcategory, note: value.note }
    : { category: value.category, subcategory: value.subcategory };
}
function draftDto(row) {
  const predicted = safeAttributes(row?.predicted_attributes, false);
  const current = safeAttributes(row?.current_attributes, true);
  if (!row || !UUID.test(row.id) || !UUID.test(row.batch_id) || !UUID.test(row.asset_id) ||
      !Number.isInteger(row.item_index) || row.item_index < 0 || row.item_index > 5 || !DRAFT_STATUSES.has(row.status) ||
      !predicted || !current || (row.prediction_confidence !== null && (typeof row.prediction_confidence !== 'number' ||
      !Number.isFinite(row.prediction_confidence) || row.prediction_confidence < 0 || row.prediction_confidence > 1)) ||
      !Number.isInteger(row.version) || row.version < 1) return null;
  return { id: row.id.toLowerCase(), batch_id: row.batch_id.toLowerCase(), client_item_key: `item-${row.item_index}`,
    status: row.status, predicted_attributes: predicted, current_attributes: current,
    prediction_confidence: row.prediction_confidence, image: null, version: row.version, _asset_id: row.asset_id.toLowerCase() };
}
async function attachDraftImages(client, drafts, env, requestId, now) {
  const ids = drafts.map(item => item._asset_id);
  const result = await client.select('garment_assets', [['select', 'id,bucket_id,object_key,verified_at,deleted_at'],
    ['id', `in.(${ids.join(',')})`], ['kind', 'eq.cutout'], ['verified_at', 'not.is.null'], ['deleted_at', 'is.null']]);
  if (result.error) return result;
  if (!Array.isArray(result.data)) return { error: failure(500, 'INTERNAL_ERROR', requestId) };
  const paths = new Map();
  for (const row of result.data) if (row && UUID.test(row.id) && row.bucket_id === 'closet-private' && typeof row.object_key === 'string') {
    paths.set(row.id.toLowerCase(), row.object_key);
  }
  const base = projectUrl(env);
  if (!base) return { error: failure(503, 'SUPABASE_NOT_CONFIGURED', requestId) };
  const signed = new Map();
  if (paths.size) {
    const signResult = await client.signStorage('closet-private', [...paths.values()], 300);
    if (signResult.error) return signResult;
    const expiresAt = new Date(now().getTime() + 300000).toISOString();
    for (const item of signResult.data) {
      if (!item || item.error || typeof item.path !== 'string' || typeof item.signedURL !== 'string') continue;
      let url; try { url = new URL(item.signedURL, base); } catch { continue; }
      if (url.protocol === 'https:' && url.hostname === base.hostname && url.pathname.startsWith('/storage/v1/object/sign/closet-private/')) {
        signed.set(item.path, { url: String(url), expires_at: expiresAt });
      }
    }
  }
  for (const draft of drafts) { const path = paths.get(draft._asset_id); draft.image = path ? signed.get(path) ?? null : null; delete draft._asset_id; }
  return { data: drafts };
}
function parseDraftPayload(value, requestId) {
  const items = Array.isArray(value?.items) ? value.items : null;
  if (!items || items.length > 6) return { error: failure(500, 'INTERNAL_ERROR', requestId) };
  const drafts = [];
  for (const item of items) { const draft = draftDto(item); if (!draft) return { error: failure(500, 'INTERNAL_ERROR', requestId) }; drafts.push(draft); }
  return { data: drafts };
}

export async function createAnalysisJobResponse(req, dependencies) {
  const batchId = pathId(req, 'batchId'); const key = idempotencyKey(req); const bodyError = noBody(req, dependencies.requestId);
  if (!batchId || !key) return validation(dependencies.requestId); if (bodyError) return bodyError;
  const auth = await authenticatedUser(req, dependencies); if (auth.error) return auth.error;
  const result = await auth.client.rpc('create_my_analysis_job', { p_batch_id: batchId, p_idempotency_key: key });
  if (result.error) return result.error; const job = rpcJob(result.data, dependencies.requestId);
  return job ? { status: 202, headers: baseHeaders(dependencies.requestId), body: job } : failure(500, 'INTERNAL_ERROR', dependencies.requestId);
}
export async function getAnalysisJobResponse(req, dependencies) {
  const jobId = pathId(req, 'jobId'); if (!jobId) return validation(dependencies.requestId);
  const auth = await authenticatedUser(req, dependencies); if (auth.error) return auth.error;
  const result = await readJob(auth.client, auth.user.id, jobId, dependencies.requestId);
  return result.error ? result.error : { status: 200, headers: baseHeaders(dependencies.requestId), body: result.data };
}
export async function retryAnalysisJobResponse(req, dependencies) {
  const jobId = pathId(req, 'jobId'); const key = idempotencyKey(req); const bodyError = noBody(req, dependencies.requestId);
  if (!jobId || !key) return validation(dependencies.requestId); if (bodyError) return bodyError;
  const auth = await authenticatedUser(req, dependencies); if (auth.error) return auth.error;
  const result = await auth.client.rpc('retry_my_analysis_job', { p_job_id: jobId, p_idempotency_key: key });
  if (result.error) return result.error; const job = rpcJob(result.data, dependencies.requestId);
  return job ? { status: 202, headers: baseHeaders(dependencies.requestId), body: job } : failure(500, 'INTERNAL_ERROR', dependencies.requestId);
}
export async function listGarmentDraftsResponse(req, dependencies) {
  const batchId = pathId(req, 'batchId'); if (!batchId) return validation(dependencies.requestId);
  const auth = await authenticatedUser(req, dependencies); if (auth.error) return auth.error;
  const result = await auth.client.rpc('list_my_garment_drafts', { p_batch_id: batchId }); if (result.error) return result.error;
  const parsed = parseDraftPayload(result.data, dependencies.requestId); if (parsed.error) return parsed.error;
  const images = await attachDraftImages(auth.client, parsed.data, dependencies.env, dependencies.requestId, dependencies.now ?? (() => new Date()));
  return images.error ? images.error : { status: 200, headers: baseHeaders(dependencies.requestId), body: { items: images.data } };
}
export async function updateGarmentDraftResponse(req, dependencies) {
  const draftId = pathId(req, 'draftId'); if (!draftId) return validation(dependencies.requestId);
  const parsed = readJsonObject(req); if (parsed.error) return failure(400, parsed.error, dependencies.requestId); const body = parsed.data;
  if (!hasOnlyKeys(body, PATCH_KEYS) || Object.keys(body).length !== 2 || !Number.isInteger(body.expected_version) || body.expected_version < 1 ||
      !body.attributes || typeof body.attributes !== 'object' || Array.isArray(body.attributes) ||
      !hasOnlyKeys(body.attributes, ATTRIBUTE_KEYS) || Object.keys(body.attributes).length < 1) return validation(dependencies.requestId);
  const attrs = body.attributes; const setCategory = Object.hasOwn(attrs, 'category'); const setSubcategory = Object.hasOwn(attrs, 'subcategory');
  const setNote = Object.hasOwn(attrs, 'note');
  if (setCategory && !CATEGORIES.has(attrs.category)) return validation(dependencies.requestId);
  if (setSubcategory && attrs.subcategory !== null && (typeof attrs.subcategory !== 'string' || codePoints(attrs.subcategory) > 80 || attrs.subcategory.includes('\0'))) return validation(dependencies.requestId);
  if (setNote && attrs.note !== null && (typeof attrs.note !== 'string' || codePoints(attrs.note) > 1000 || attrs.note.includes('\0'))) return validation(dependencies.requestId);
  const auth = await authenticatedUser(req, dependencies); if (auth.error) return auth.error;
  const result = await auth.client.rpc('update_my_garment_draft', { p_draft_id: draftId, p_expected_version: body.expected_version,
    p_has_category: setCategory, p_category: setCategory ? attrs.category : null,
    p_has_subcategory: setSubcategory, p_subcategory: setSubcategory ? attrs.subcategory : null,
    p_has_note: setNote, p_note: setNote ? attrs.note : null });
  if (result.error) return result.error; const projected = draftDto(result.data?.draft ?? result.data);
  if (!projected) return failure(500, 'INTERNAL_ERROR', dependencies.requestId);
  const images = await attachDraftImages(auth.client, [projected], dependencies.env, dependencies.requestId, dependencies.now ?? (() => new Date()));
  return images.error ? images.error : { status: 200, headers: baseHeaders(dependencies.requestId), body: images.data[0] };
}
export async function confirmGarmentBatchResponse(req, dependencies) {
  const batchId = pathId(req, 'batchId'); const key = idempotencyKey(req); if (!batchId || !key) return validation(dependencies.requestId);
  const parsed = readJsonObject(req); if (parsed.error) return failure(400, parsed.error, dependencies.requestId); const body = parsed.data;
  if (!hasOnlyKeys(body, CONFIRM_KEYS) || Object.keys(body).length !== 2 || !Array.isArray(body.draft_ids) ||
      body.draft_ids.length < 1 || body.draft_ids.length > 6 || new Set(body.draft_ids.map(id => typeof id === 'string' ? id.toLowerCase() : id)).size !== body.draft_ids.length ||
      body.draft_ids.some(id => typeof id !== 'string' || !UUID.test(id)) || !body.draft_versions || typeof body.draft_versions !== 'object' ||
      Array.isArray(body.draft_versions) || Object.keys(body.draft_versions).length !== body.draft_ids.length) return validation(dependencies.requestId);
  const ids = body.draft_ids.map(id => id.toLowerCase()); const versions = {};
  for (const [id, version] of Object.entries(body.draft_versions)) {
    if (!UUID.test(id) || !ids.includes(id.toLowerCase()) || !Number.isInteger(version) || version < 1 || Object.hasOwn(versions, id.toLowerCase())) return validation(dependencies.requestId);
    versions[id.toLowerCase()] = version;
  }
  if (Object.keys(versions).length !== ids.length) return validation(dependencies.requestId);
  const auth = await authenticatedUser(req, dependencies); if (auth.error) return auth.error;
  const result = await auth.client.rpc('confirm_my_garment_batch', { p_batch_id: batchId, p_draft_ids: ids,
    p_versions: versions, p_idempotency_key: key }); if (result.error) return result.error;
  const garmentIds = result.data?.garment_ids;
  if (!Array.isArray(garmentIds) || garmentIds.length !== ids.length || garmentIds.some(id => !UUID.test(id))) return failure(500, 'INTERNAL_ERROR', dependencies.requestId);
  const garments = await readGarmentsByIds(auth.client, auth.user.id, garmentIds, dependencies); if (garments.error) return garments.error;
  return { status: 201, headers: baseHeaders(dependencies.requestId), body: { batch_id: batchId, garments: garments.data } };
}
