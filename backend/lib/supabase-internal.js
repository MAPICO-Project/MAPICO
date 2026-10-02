import { failure } from './errors.js';
import { projectUrl } from './supabase-user.js';

function headers(env) {
  const secret = env.SUPABASE_SECRET_KEY;
  if (typeof secret !== 'string' || secret.length < 20 || /\s/.test(secret)) return null;
  return { apikey: secret, Authorization: `Bearer ${secret}`, Accept: 'application/json' };
}

export function callbackSecret(env) {
  const value = env.AI_CALLBACK_HMAC_SECRET;
  return typeof value === 'string' && value.length >= 32 ? value : null;
}

export function createInternalClient({ env, request = fetch, requestId }) {
  const base = projectUrl(env); const internalHeaders = headers(env);
  if (!base || !internalHeaders) return { error: failure(503, 'INTERNAL_INTEGRATION_NOT_CONFIGURED', requestId) };
  async function call(url, options) {
    try { return await request(url, { ...options, redirect: 'error', signal: AbortSignal.timeout(5000) }); }
    catch { return null; }
  }
  async function internalRpc(name, args) {
    const allowed = new Set(['find_weather_snapshot', 'upsert_weather_snapshot', 'get_weather_snapshot', 'store_recommendation']);
    if (!allowed.has(name)) return { error: failure(500, 'INTERNAL_ERROR', requestId) };
    const url = new URL(`/rest/v1/rpc/${name}`, base);
    const response = await call(url, { method: 'POST', headers: { ...internalHeaders, 'Content-Type': 'application/json' }, body: JSON.stringify(args) });
    if (!response) return { error: failure(503, 'SUPABASE_UNAVAILABLE', requestId, true) };
    let payload; try { payload = await response.json(); } catch { payload = null; }
    if (response.status === 200 && payload === null && name === 'find_weather_snapshot') return { missing: true };
    if (response.status === 200 && payload && typeof payload === 'object') return { data: payload };
    const message = typeof payload?.message === 'string' ? payload.message : '';
    if (['weather_snapshot_not_found', 'weather_not_found', 'recommendation_not_found'].includes(message)) return { missing: true };
    if (message === 'idempotency_conflict') return { error: failure(409, 'IDEMPOTENCY_CONFLICT', requestId) };
    if (['inactive_garment', 'garment_unavailable', 'invalid_weather_slot', 'weather_snapshot_not_eligible',
        'recommendation_conflict', 'recommendation_not_finalizable'].includes(message)) {
      return { error: failure(409, 'RECOMMENDATION_CONFLICT', requestId) };
    }
    if (message.startsWith('invalid_')) return { error: failure(422, 'VALIDATION_ERROR', requestId) };
    return { error: failure(503, 'SUPABASE_UNAVAILABLE', requestId, true) };
  }
  return {
    findWeatherSnapshot(args) { return internalRpc('find_weather_snapshot', args); },
    upsertWeatherSnapshot(args) { return internalRpc('upsert_weather_snapshot', args); },
    getWeatherSnapshot(snapshotId) { return internalRpc('get_weather_snapshot', { p_snapshot_id: snapshotId }); },
    storeRecommendation(args) { return internalRpc('store_recommendation', args); },
    async projectFeedPosts(actorId, postIds) {
      if (typeof actorId !== 'string' || !Array.isArray(postIds) || postIds.length < 1 || postIds.length > 100) {
        return { error: failure(500, 'INTERNAL_ERROR', requestId) };
      }
      const url = new URL('/rest/v1/rpc/project_feed_posts', base);
      const response = await call(url, { method: 'POST', headers: { ...internalHeaders, 'Content-Type': 'application/json' },
        body: JSON.stringify({ p_actor_id: actorId, p_post_ids: postIds }) });
      if (!response) return { error: failure(503, 'SUPABASE_UNAVAILABLE', requestId, true) };
      try {
        const rows = await response.json();
        return response.status === 200 && Array.isArray(rows) ? { data: rows }
          : { error: failure(503, 'SUPABASE_UNAVAILABLE', requestId, true) };
      } catch { return { error: failure(503, 'SUPABASE_UNAVAILABLE', requestId, true) }; }
    },
    async getFeedMediaFence(actorId, postId, mediaId) {
      const url = new URL('/rest/v1/rpc/get_feed_media_fence', base);
      const response = await call(url, { method: 'POST', headers: { ...internalHeaders, 'Content-Type': 'application/json' },
        body: JSON.stringify({ p_actor_id: actorId, p_post_id: postId, p_media_id: mediaId }) });
      if (!response || response.status !== 200) return { error: failure(503, 'SUPABASE_UNAVAILABLE', requestId, true) };
      try {
        const data = await response.json(); return data === null ? { missing: true }
          : data && typeof data === 'object' ? { data } : { error: failure(503, 'SUPABASE_UNAVAILABLE', requestId, true) };
      } catch { return { error: failure(503, 'SUPABASE_UNAVAILABLE', requestId, true) }; }
    },
    async projectVisibleLikes(actorId, cursor, limit) {
      const url = new URL('/rest/v1/rpc/project_my_visible_likes', base);
      const response = await call(url, { method: 'POST', headers: { ...internalHeaders, 'Content-Type': 'application/json' }, body: JSON.stringify({
        p_actor_id: actorId, p_cursor_at: cursor?.at ?? null, p_cursor_post_id: cursor?.id ?? null, p_limit: limit
      }) });
      if (!response || response.status !== 200) return { error: failure(503, 'SUPABASE_UNAVAILABLE', requestId, true) };
      try { const data = await response.json(); return Array.isArray(data) ? { data } : { error: failure(503, 'SUPABASE_UNAVAILABLE', requestId, true) }; }
      catch { return { error: failure(503, 'SUPABASE_UNAVAILABLE', requestId, true) }; }
    },
    async signFeedStorage(paths, expiresIn = 300) {
      if (!Array.isArray(paths) || paths.length < 1 || paths.length > 100 ||
          paths.some(path => typeof path !== 'string' || !path || path.length > 1024)) {
        return { error: failure(500, 'INTERNAL_ERROR', requestId) };
      }
      const url = new URL('/storage/v1/object/sign/feed-private', base);
      const response = await call(url, { method: 'POST', headers: { ...internalHeaders, 'Content-Type': 'application/json' },
        body: JSON.stringify({ expiresIn, paths }) });
      if (!response || response.status !== 200) return { error: failure(503, 'STORAGE_UNAVAILABLE', requestId, true) };
      try {
        const data = await response.json();
        return Array.isArray(data) ? { data } : { error: failure(503, 'STORAGE_UNAVAILABLE', requestId, true) };
      } catch { return { error: failure(503, 'STORAGE_UNAVAILABLE', requestId, true) }; }
    },
    async inspectAnalysisCallback(args) {
      const url = new URL('/rest/v1/rpc/inspect_analysis_callback', base);
      const response = await call(url, { method: 'POST', headers: { ...internalHeaders, 'Content-Type': 'application/json' }, body: JSON.stringify(args) });
      if (!response) return { error: failure(503, 'SUPABASE_UNAVAILABLE', requestId, true) };
      let payload; try { payload = await response.json(); } catch { payload = null; }
      if (response.status === 200 && payload && typeof payload === 'object') return { data: payload };
      const message = typeof payload?.message === 'string' ? payload.message : '';
      if (message === 'job_not_found') return { error: failure(404, 'ANALYSIS_JOB_NOT_FOUND', requestId) };
      if (['callback_conflict', 'callback_in_progress', 'stale_lease', 'terminal_job', 'invalid_job_state'].includes(message)) {
        return { error: failure(409, 'ANALYSIS_CONFLICT', requestId) };
      }
      if (message.startsWith('invalid_')) return { error: failure(422, 'VALIDATION_ERROR', requestId) };
      return { error: failure(503, 'SUPABASE_UNAVAILABLE', requestId, true) };
    },
    async inspectMimicCallback(args) {
      const url = new URL('/rest/v1/rpc/inspect_mimic_callback', base);
      const response = await call(url, { method: 'POST', headers: { ...internalHeaders, 'Content-Type': 'application/json' }, body: JSON.stringify(args) });
      if (!response) return { error: failure(503, 'SUPABASE_UNAVAILABLE', requestId, true) };
      let payload; try { payload = await response.json(); } catch { payload = null; }
      if (response.status === 200 && payload && typeof payload === 'object') return { data: payload };
      const message = typeof payload?.message === 'string' ? payload.message : '';
      if (message === 'mimic_job_not_found') return { error: failure(404, 'MIMIC_JOB_NOT_FOUND', requestId) };
      if (['callback_conflict', 'callback_in_progress', 'stale_lease'].includes(message)) {
        return { error: failure(409, 'MIMIC_CONFLICT', requestId) };
      }
      if (message.startsWith('invalid_')) return { error: failure(422, 'VALIDATION_ERROR', requestId) };
      return { error: failure(503, 'SUPABASE_UNAVAILABLE', requestId, true) };
    },
    async getAnalysisCutoutFence(jobId, objectKey) {
      const url = new URL('/rest/v1/rpc/get_analysis_cutout_fence', base);
      const response = await call(url, { method: 'POST', headers: { ...internalHeaders, 'Content-Type': 'application/json' },
        body: JSON.stringify({ p_job_id: jobId, p_object_key: objectKey }) });
      if (!response) return { error: failure(503, 'SUPABASE_UNAVAILABLE', requestId, true) };
      let payload; try { payload = await response.json(); } catch { payload = null; }
      if (response.status === 200 && payload && typeof payload === 'object') return { data: payload };
      const message = typeof payload?.message === 'string' ? payload.message : '';
      if (message === 'job_not_found') return { error: failure(404, 'ANALYSIS_JOB_NOT_FOUND', requestId) };
      if (['cutout_not_found', 'cutout_asset_not_verified'].includes(message)) return { missing: true };
      if (message.startsWith('invalid_')) return { error: failure(422, 'VALIDATION_ERROR', requestId) };
      return { error: failure(503, 'SUPABASE_UNAVAILABLE', requestId, true) };
    },
    async getAnalysisJob(jobId) {
      const url = new URL('/rest/v1/analysis_jobs', base);
      url.searchParams.set('select', 'id,user_id,batch_id,status,attempt,lease_token,lease_expires_at');
      url.searchParams.set('id', `eq.${jobId}`);
      const response = await call(url, { headers: internalHeaders });
      if (!response) return { error: failure(503, 'SUPABASE_UNAVAILABLE', requestId, true) };
      if (response.status !== 200) return { error: failure(503, 'SUPABASE_UNAVAILABLE', requestId, true) };
      try {
        const rows = await response.json();
        if (!Array.isArray(rows)) throw Error('shape');
        if (rows.length === 0) return { error: failure(404, 'ANALYSIS_JOB_NOT_FOUND', requestId) };
        return rows.length === 1 ? { data: rows[0] } : { error: failure(500, 'INTERNAL_ERROR', requestId) };
      } catch { return { error: failure(503, 'SUPABASE_UNAVAILABLE', requestId, true) }; }
    },
    async readStoragePrefix(path, maxBytes = 65536) {
      if (typeof path !== 'string' || path.length < 1 || path.length > 1024 ||
          path.split('/').some(segment => !segment || segment === '.' || segment === '..')) {
        return { error: failure(500, 'INTERNAL_ERROR', requestId) };
      }
      const encoded = ['closet-private', ...path.split('/')].map(encodeURIComponent).join('/');
      const url = new URL(`/storage/v1/object/authenticated/${encoded}`, base);
      const response = await call(url, { method: 'GET', headers: { ...internalHeaders, Range: `bytes=0-${maxBytes - 1}` } });
      if (!response) return { error: failure(503, 'STORAGE_UNAVAILABLE', requestId, true) };
      if (response.status === 404) return { missing: true };
      if (![200, 206].includes(response.status)) return { error: failure(503, 'STORAGE_UNAVAILABLE', requestId, true) };
      const chunks = []; let length = 0;
      try {
        if (response.body?.getReader) {
          const reader = response.body.getReader();
          while (length < maxBytes) {
            const { done, value } = await reader.read(); if (done) break;
            const take = value.subarray(0, maxBytes - length); chunks.push(take); length += take.length;
            if (take.length < value.length || length === maxBytes) { await reader.cancel(); break; }
          }
        } else {
          const value = new Uint8Array(await response.arrayBuffer()); chunks.push(value.subarray(0, maxBytes)); length = Math.min(value.length, maxBytes);
        }
      } catch { return { error: failure(503, 'STORAGE_UNAVAILABLE', requestId, true) }; }
      const bytes = new Uint8Array(length); let offset = 0;
      for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
      return { data: { bytes, status: response.status, contentType: response.headers?.get?.('content-type') ?? null,
        contentRange: response.headers?.get?.('content-range') ?? null,
        contentLength: response.headers?.get?.('content-length') ?? null } };
    },
    async applyAnalysisResult(args) {
      const url = new URL('/rest/v1/rpc/apply_analysis_result', base);
      const response = await call(url, { method: 'POST', headers: { ...internalHeaders, 'Content-Type': 'application/json' }, body: JSON.stringify(args) });
      if (!response) return { error: failure(503, 'SUPABASE_UNAVAILABLE', requestId, true) };
      let payload; try { payload = await response.json(); } catch { payload = null; }
      if (response.status === 200) return payload && typeof payload === 'object' ? { data: payload }
        : { error: failure(503, 'SUPABASE_UNAVAILABLE', requestId, true) };
      const message = typeof payload?.message === 'string' ? payload.message : '';
      if (message === 'job_not_found') return { error: failure(404, 'ANALYSIS_JOB_NOT_FOUND', requestId) };
      if (['callback_conflict', 'stale_lease', 'terminal_job', 'invalid_job_state'].includes(message)) {
        return { error: failure(409, 'ANALYSIS_CONFLICT', requestId) };
      }
      if (message.startsWith('invalid_')) return { error: failure(422, 'VALIDATION_ERROR', requestId) };
      return { error: failure(503, 'SUPABASE_UNAVAILABLE', requestId, true) };
    },
    async applyMimicResult(args) {
      const url = new URL('/rest/v1/rpc/apply_mimic_result', base);
      const response = await call(url, { method: 'POST', headers: { ...internalHeaders, 'Content-Type': 'application/json' }, body: JSON.stringify(args) });
      if (!response) return { error: failure(503, 'SUPABASE_UNAVAILABLE', requestId, true) };
      let payload; try { payload = await response.json(); } catch { payload = null; }
      if (response.status === 200) return payload && typeof payload === 'object' ? { data: payload }
        : { error: failure(503, 'SUPABASE_UNAVAILABLE', requestId, true) };
      const message = typeof payload?.message === 'string' ? payload.message : '';
      if (message === 'mimic_job_not_found') return { error: failure(404, 'MIMIC_JOB_NOT_FOUND', requestId) };
      if (['callback_conflict', 'callback_in_progress', 'stale_lease', 'candidate_fence_changed'].includes(message)) {
        return { error: failure(409, 'MIMIC_CONFLICT', requestId) };
      }
      if (message.startsWith('invalid_')) return { error: failure(422, 'VALIDATION_ERROR', requestId) };
      return { error: failure(503, 'SUPABASE_UNAVAILABLE', requestId, true) };
    }
  };
}
