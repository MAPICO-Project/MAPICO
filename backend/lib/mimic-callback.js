import { createHash, createHmac, randomUUID, timingSafeEqual } from 'node:crypto';
import { baseHeaders, failure } from './errors.js';
import { callbackSecret, createInternalClient } from './supabase-internal.js';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const KEYS = new Set(['event_id', 'job_id', 'attempt', 'lease_token', 'status', 'model_version', 'matches', 'coverage', 'error_code']);
const MATCH_KEYS = new Set(['source_item_key', 'garment_id', 'similarity', 'reason']);
const FAILURE_CODES = new Set(['MODEL_UNAVAILABLE', 'WORKER_TIMEOUT', 'INTERNAL_ERROR']);
const MAX_BODY = 131072;

function only(value, keys) {
  return value && typeof value === 'object' && !Array.isArray(value) && Object.keys(value).every(key => keys.has(key));
}

async function rawBody(req, supplied) {
  if (supplied !== undefined) return Buffer.isBuffer(supplied) ? supplied : Buffer.from(supplied);
  const chunks = []; let length = 0;
  for await (const chunk of req) {
    const value = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk); length += value.length;
    if (length > MAX_BODY) return null; chunks.push(value);
  }
  return Buffer.concat(chunks);
}

function validateMatch(item) {
  if (!only(item, MATCH_KEYS) || Object.keys(item).length !== MATCH_KEYS.size ||
      typeof item.source_item_key !== 'string' || item.source_item_key.length < 1 || item.source_item_key.length > 50 ||
      typeof item.reason !== 'string' || [...item.reason].length > 500 || /[\u0000-\u001f\u007f]/.test(item.reason)) return false;
  if (item.garment_id === null) return item.similarity === null;
  return typeof item.garment_id === 'string' && UUID.test(item.garment_id) &&
    typeof item.similarity === 'number' && Number.isFinite(item.similarity) && item.similarity >= -1 && item.similarity <= 1;
}

function validatePayload(value, pathJobId) {
  if (!only(value, KEYS) || Object.keys(value).length !== KEYS.size || !UUID.test(value.event_id) ||
      !UUID.test(value.job_id) || value.job_id.toLowerCase() !== pathJobId || !UUID.test(value.lease_token) ||
      !Number.isInteger(value.attempt) || value.attempt < 1 || !['succeeded', 'no_match', 'failed'].includes(value.status) ||
      !Array.isArray(value.matches) || value.matches.length > 10 || value.matches.some(item => !validateMatch(item))) return null;
  const sourceKeys = value.matches.map(item => item.source_item_key);
  if (new Set(sourceKeys).size !== sourceKeys.length) return null;
  const matched = value.matches.filter(item => item.garment_id !== null).length;
  if (value.status === 'failed') {
    if (value.matches.length !== 0 || value.model_version !== null || value.coverage !== null || !FAILURE_CODES.has(value.error_code)) return null;
  } else {
    if (value.matches.length < 1 || typeof value.model_version !== 'string' || !/^[A-Za-z0-9._:-]{1,100}$/.test(value.model_version) ||
        typeof value.coverage !== 'number' || !Number.isFinite(value.coverage) || value.coverage < 0 || value.coverage > 1 ||
        value.error_code !== null || (value.status === 'succeeded' && matched < 1) || (value.status === 'no_match' && matched !== 0)) return null;
  }
  return value;
}

function jobRow(value, jobId) {
  return value && UUID.test(value.id ?? '') && value.id.toLowerCase() === jobId && UUID.test(value.user_id ?? '') &&
    UUID.test(value.post_id ?? '') && typeof value.status === 'string' && Number.isInteger(value.attempt) &&
    (value.lease_token === null || UUID.test(value.lease_token)) &&
    (value.lease_expires_at === null || typeof value.lease_expires_at === 'string') &&
    typeof value.absolute_deadline === 'string' ? value : null;
}

function validationResult(requestId) { return failure(422, 'VALIDATION_ERROR', requestId); }

export function createMimicCallbackHandler(dependencies = {}) {
  return async function handler(req, res) {
    const requestId = (dependencies.createRequestId ?? randomUUID)(); const env = dependencies.env ?? process.env;
    let result;
    try {
      if (req.method !== 'POST') result = failure(405, 'METHOD_NOT_ALLOWED', requestId, false, { Allow: 'POST' });
      else {
        const jobIdValue = req.query?.jobId;
        const jobId = typeof jobIdValue === 'string' && UUID.test(jobIdValue) ? jobIdValue.toLowerCase() : null;
        const timestamp = req.headers?.['x-worker-timestamp']; const signature = req.headers?.['x-worker-signature'];
        const secret = callbackSecret(env); const now = (dependencies.now ?? (() => new Date()))();
        if (!jobId || typeof timestamp !== 'string' || !/^[1-9][0-9]{0,12}$/.test(timestamp) ||
            Math.abs(Math.floor(now.getTime() / 1000) - Number(timestamp)) > 300 ||
            typeof signature !== 'string' || !/^[0-9a-fA-F]{64}$/.test(signature) || !secret) {
          result = failure(secret ? 401 : 503, secret ? 'INVALID_WORKER_SIGNATURE' : 'INTERNAL_INTEGRATION_NOT_CONFIGURED', requestId);
        } else {
          const raw = await rawBody(req, dependencies.rawBody);
          if (!raw || raw.length < 2 || raw.length > MAX_BODY) result = failure(400, 'INVALID_REQUEST_BODY', requestId);
          else {
            const expected = createHmac('sha256', secret).update('mimic.v1').update('.').update(timestamp).update('.').update(raw).digest();
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
                  const inspection = await client.inspectMimicCallback({ p_event_id: body.event_id, p_job_id: jobId,
                    p_attempt: body.attempt, p_payload_hash: payloadHash });
                  if (inspection.error) result = inspection.error;
                  else if (inspection.data?.replayed === true) result = { status: 200, headers: baseHeaders(requestId),
                    body: { job_id: jobId, event_id: body.event_id.toLowerCase(), applied: false } };
                  else {
                    const job = jobRow(inspection.data?.job, jobId);
                    if (!job || job.status !== 'running' || job.attempt !== body.attempt ||
                        job.lease_token?.toLowerCase() !== body.lease_token.toLowerCase() ||
                        !Number.isFinite(Date.parse(job.lease_expires_at)) || Date.parse(job.lease_expires_at) <= now.getTime() ||
                        !Number.isFinite(Date.parse(job.absolute_deadline)) || Date.parse(job.absolute_deadline) <= now.getTime()) {
                      result = failure(409, 'MIMIC_CONFLICT', requestId);
                    } else {
                      const applied = await client.applyMimicResult({ p_event_id: body.event_id, p_job_id: jobId,
                        p_attempt: body.attempt, p_lease_token: body.lease_token, p_payload_hash: payloadHash,
                        p_status: body.status, p_model_version: body.model_version, p_matches: body.matches,
                        p_coverage: body.coverage, p_error_code: body.error_code });
                      if (applied.error) result = applied.error;
                      else if (typeof applied.data?.applied !== 'boolean') result = failure(500, 'INTERNAL_ERROR', requestId);
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
    } catch { result = failure(500, 'INTERNAL_ERROR', requestId); }
    for (const [name, value] of Object.entries(result.headers ?? {})) res.setHeader(name, value);
    return res.status(result.status).json(result.body);
  };
}
