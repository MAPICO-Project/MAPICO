import test from 'node:test';
import assert from 'node:assert/strict';
import { createHandler as createJobHandler } from '../api/v1/garment-batches/[batchId]/analysis-jobs.js';
import { createHandler as getJobHandler } from '../api/v1/analysis-jobs/[jobId].js';
import { createHandler as retryJobHandler } from '../api/v1/analysis-jobs/[jobId]/retry.js';
import { createHandler as listDraftsHandler } from '../api/v1/garment-batches/[batchId]/drafts.js';
import { createHandler as updateDraftHandler } from '../api/v1/garment-drafts/[draftId].js';
import { createHandler as confirmHandler } from '../api/v1/garment-batches/[batchId]/confirm.js';

const requestId = '11111111-1111-4111-8111-111111111111';
const userId = '22222222-2222-4222-8222-222222222222';
const batchId = '33333333-3333-4333-8333-333333333333';
const jobId = '44444444-4444-4444-8444-444444444444';
const draftId = '55555555-5555-4555-8555-555555555555';
const assetId = '66666666-6666-4666-8666-666666666666';
const garmentId = '77777777-7777-4777-8777-777777777777';
const createdAt = '2026-10-01T01:02:03.123456+00:00';
const updatedAt = '2026-10-01T02:03:04.123456+00:00';
const env = { SUPABASE_URL: 'https://abcdefghijklmnopqrst.supabase.co', SUPABASE_PUBLISHABLE_KEY: 'publishable-test' };

function response(status, body, headers = {}) { return { status, headers: { get: name => headers[name.toLowerCase()] ?? null },
  async json() { if (body === undefined) throw Error('no body'); return body; } }; }
function invoke(createHandler, options = {}) {
  const result = { headers: {}, statusCode: 200 }; const headers = { authorization: 'Bearer header.payload.signature', ...(options.headers ?? {}) };
  if (options.body !== undefined && !headers['content-type']) headers['content-type'] = 'application/json';
  const req = { method: options.method ?? 'GET', headers, query: options.query ?? {}, body: options.body };
  const res = { setHeader(k, v) { result.headers[k] = v; }, status(v) { result.statusCode = v; return this; },
    json(v) { result.body = v; return result; }, end() { return result; } };
  return createHandler({ env, request: options.request, createRequestId: () => requestId,
    now: () => new Date('2026-10-01T03:00:00.000Z') })(req, res);
}
function job(status = 'queued', overrides = {}) { return { id: jobId, batch_id: batchId, status, attempt: 0, max_attempts: 3,
  stage: null, progress: 0, error_code: null, created_at: createdAt, updated_at: updatedAt, ...overrides }; }
function draft(overrides = {}) { return { id: draftId, batch_id: batchId, item_index: 0, asset_id: assetId, status: 'predicted',
  predicted_attributes: { category: 'top', subcategory: null }, current_attributes: { category: 'top', subcategory: null, note: null },
  prediction_confidence: 0.9, version: 1, ...overrides }; }
function auth(url) { return String(url).includes('/auth/v1/user'); }

test('create and retry analysis jobs use exact idempotent RPC arguments and safe DTOs', async () => {
  for (const [handler, path, rpcName, key] of [[createJobHandler, { batchId }, 'create_my_analysis_job', 'create-job-one'],
    [retryJobHandler, { jobId }, 'retry_my_analysis_job', 'retry-job-one']]) {
    const calls = [];
    const result = await invoke(handler, { method: 'POST', query: path, headers: { 'idempotency-key': key }, request: async (url, options) => {
      calls.push({ url: String(url), options }); return auth(url) ? response(200, { id: userId }) : response(200, job());
    } });
    assert.equal(result.statusCode, 202); assert.equal(result.body.id, jobId); assert.equal(result.body.retryable, false);
    assert.equal(JSON.stringify(result).includes('lease'), false); assert.equal(JSON.stringify(result).includes('result'), false);
    assert.match(calls[1].url, new RegExp(`/rpc/${rpcName}$`));
    assert.equal(JSON.parse(calls[1].options.body).p_idempotency_key, key);
  }
});

test('job GET is owner filtered and maps retryability without exposing raw error codes', async () => {
  const result = await invoke(getJobHandler, { query: { jobId }, request: async url => auth(url) ? response(200, { id: userId })
    : response(200, [job('failed', { attempt: 1, error_code: 'MODEL_UNAVAILABLE' })]) });
  assert.equal(result.statusCode, 200); assert.equal(result.body.retryable, true); assert.equal(result.body.error.code, 'ANALYSIS_FAILED');
  assert.equal(JSON.stringify(result).includes('MODEL_UNAVAILABLE'), false);
  const permanent = await invoke(getJobHandler, { query: { jobId }, request: async url => auth(url) ? response(200, { id: userId })
    : response(200, [job('failed', { attempt: 1, error_code: 'INVALID_INPUT' })]) });
  assert.equal(permanent.statusCode, 200); assert.equal(permanent.body.retryable, false);
  const missing = await invoke(getJobHandler, { query: { jobId }, request: async url => auth(url) ? response(200, { id: userId }) : response(200, []) });
  assert.equal(missing.statusCode, 404);
});

test('draft list consumes only the safe RPC projection and signs verified cutouts', async () => {
  const objectKey = `${userId}/${batchId}/cutouts/item-0.png`;
  const result = await invoke(listDraftsHandler, { query: { batchId }, request: async (url, options) => {
    const value = String(url); if (auth(url)) return response(200, { id: userId });
    if (value.includes('/rpc/list_my_garment_drafts')) return response(200, { items: [draft()] });
    if (value.includes('/rest/v1/garment_assets')) return response(200, [{ id: assetId, bucket_id: 'closet-private', object_key: objectKey,
      verified_at: createdAt, deleted_at: null }]);
    if (value.includes('/storage/v1/object/sign/')) return response(200, [{ path: objectKey,
      signedURL: `/storage/v1/object/sign/closet-private/${objectKey}?token=fixture` }]);
    assert.fail(`unexpected ${value}`);
  } });
  assert.equal(result.statusCode, 200); assert.equal(result.body.items[0].client_item_key, 'item-0');
  assert.equal(result.body.items[0].image.expires_at, '2026-10-01T03:05:00.000Z');
  assert.equal(JSON.stringify(result).includes('asset_id'), false); assert.equal(JSON.stringify(result).includes('raw_prediction'), false);
});

test('draft PATCH validates fields and sends presence-aware optimistic arguments', async () => {
  const calls = [];
  const result = await invoke(updateDraftHandler, { method: 'PATCH', query: { draftId },
    body: { expected_version: 1, attributes: { subcategory: 'tee', note: null } }, request: async (url, options) => {
      calls.push({ url: String(url), options }); const value = String(url);
      if (auth(url)) return response(200, { id: userId });
      if (value.includes('/rpc/update_my_garment_draft')) return response(200, draft({ status: 'edited', version: 2,
        current_attributes: { category: 'top', subcategory: 'tee', note: null } }));
      if (value.includes('/rest/v1/garment_assets')) return response(200, []);
      assert.fail(`unexpected ${value}`);
    } });
  assert.equal(result.statusCode, 200); assert.equal(result.body.version, 2); assert.equal(result.body.image, null);
  assert.deepEqual(JSON.parse(calls[1].options.body), { p_draft_id: draftId, p_expected_version: 1,
    p_has_category: false, p_category: null, p_has_subcategory: true, p_subcategory: 'tee', p_has_note: true, p_note: null });
  const invalid = await invoke(updateDraftHandler, { method: 'PATCH', query: { draftId }, body: { expected_version: 1, attributes: {} },
    request: async () => assert.fail('network called') });
  assert.equal(invalid.statusCode, 422);
});

test('confirm enforces the exact version key set and rereads safe garment projections', async () => {
  const objectKey = `${userId}/${batchId}/cutouts/item-0.png`;
  const body = { draft_ids: [draftId], draft_versions: { [draftId]: 2 } }; const calls = [];
  const result = await invoke(confirmHandler, { method: 'POST', query: { batchId }, headers: { 'idempotency-key': 'confirm-key-one' }, body,
    request: async (url, options) => { calls.push({ url: String(url), options }); const value = String(url);
      if (auth(url)) return response(200, { id: userId });
      if (value.includes('/rpc/confirm_my_garment_batch')) return response(200, { batch_id: batchId, garment_ids: [garmentId] });
      if (value.includes('/rest/v1/garments')) return response(200, [{ id: garmentId, asset_id: assetId, category: 'top',
        attributes: { subcategory: 'tee', hidden: true }, memo: null, version: 1, created_at: createdAt, updated_at: updatedAt }]);
      if (value.includes('/rest/v1/garment_assets')) {
        const kind = new URL(value).searchParams.get('kind'); return kind === 'eq.cutout'
          ? response(200, [{ id: assetId, batch_id: batchId, kind: 'cutout', bucket_id: 'closet-private', object_key: objectKey, verified_at: createdAt, deleted_at: null }])
          : response(200, []);
      }
      if (value.includes('/storage/v1/object/sign/')) return response(200, [{ path: objectKey, signedURL: `/storage/v1/object/sign/closet-private/${objectKey}?token=fixture` }]);
      assert.fail(`unexpected ${value}`);
    } });
  assert.equal(result.statusCode, 201); assert.equal(result.body.batch_id, batchId); assert.equal(result.body.garments[0].attributes.subcategory, 'tee');
  assert.equal(JSON.stringify(result).includes('hidden'), false);
  assert.deepEqual(JSON.parse(calls[1].options.body), { p_batch_id: batchId, p_draft_ids: [draftId],
    p_versions: { [draftId]: 2 }, p_idempotency_key: 'confirm-key-one' });
  const invalid = await invoke(confirmHandler, { method: 'POST', query: { batchId }, headers: { 'idempotency-key': 'confirm-key-one' },
    body: { draft_ids: [draftId], draft_versions: { [draftId]: 2, [assetId]: 1 } }, request: async () => assert.fail('network called') });
  assert.equal(invalid.statusCode, 422);
});

test('G4 path/body/idempotency validation happens before authentication', async () => {
  for (const [handler, options] of [[createJobHandler, { method: 'POST', query: { batchId } }],
    [getJobHandler, { query: { jobId: 'bad' } }], [retryJobHandler, { method: 'POST', query: { jobId }, headers: { 'idempotency-key': 'short' } }]]) {
    const result = await invoke(handler, { ...options, request: async () => assert.fail('network called') }); assert.equal(result.statusCode, 422);
  }
});
