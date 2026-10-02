import { failure } from './errors.js';

export function projectUrl(env) {
  if (!env.SUPABASE_URL || !env.SUPABASE_PUBLISHABLE_KEY) return null;
  try {
    const url = new URL(env.SUPABASE_URL);
    if (
      url.protocol !== 'https:' ||
      !/^[a-z0-9]{20}\.supabase\.co$/.test(url.hostname) ||
      url.username || url.password ||
      (url.pathname !== '/' && url.pathname !== '') ||
      url.search || url.hash
    ) return null;
    return url;
  } catch {
    return null;
  }
}

function retryAfter(response) {
  const value = response?.headers?.get?.('retry-after');
  return typeof value === 'string' && /^[1-9][0-9]*$/.test(value) ? value : '60';
}

export function upstreamFailure(response, requestId, source) {
  if ([400, 401, 403].includes(response.status) && source === 'auth') {
    return failure(401, 'INVALID_TOKEN', requestId, false, { 'WWW-Authenticate': 'Bearer' });
  }
  if (response.status === 401 && source === 'rest') {
    return failure(401, 'INVALID_TOKEN', requestId, false, { 'WWW-Authenticate': 'Bearer' });
  }
  if (response.status === 429) {
    return failure(429, 'RATE_LIMITED', requestId, true, { 'Retry-After': retryAfter(response) });
  }
  if (source === 'rest' && [403, 404].includes(response.status)) {
    return failure(503, 'DATABASE_SCHEMA_NOT_READY', requestId);
  }
  return failure(503, source === 'auth' ? 'AUTH_UNAVAILABLE' : 'SUPABASE_UNAVAILABLE', requestId, true);
}

const VALIDATION_MESSAGES = new Set([
  'empty_profile_patch', 'invalid_display_name', 'invalid_timezone', 'invalid_preferences',
  'invalid_preference_count', 'duplicate_aesthetic', 'invalid_preference_weight_sum',
  'inactive_or_unknown_aesthetic', 'invalid_onboarding_state', 'invalid_garment_patch',
  'invalid_garment_category', 'invalid_garment_subcategory', 'invalid_garment_memo',
  'invalid_garment_id', 'invalid_idempotency_key', 'invalid_batch_create', 'invalid_batch_id',
  'invalid_upload_outcome', 'invalid_recommendation', 'invalid_acceptance', 'recommendation_date_mismatch'
  , 'invalid_saved_outfit', 'invalid_saved_outfit_patch', 'invalid_title', 'invalid_note', 'invalid_ootd',
  'invalid_ootd_patch', 'invalid_ootd_delete', 'invalid_garment_ids', 'invalid_ootd_snapshot',
  'future_worn_not_allowed', 'recommendation_weather_mismatch', 'invalid_weather_snapshot', 'multiple_ootd_sources'
  , 'invalid_feed_post', 'invalid_feed_patch', 'invalid_caption', 'invalid_visibility', 'invalid_feed_media',
  'invalid_feed_media_completion', 'invalid_post_id', 'invalid_mimic_request'
]);

async function rpcFailure(response, requestId) {
  let payload;
  try { payload = await response.json(); } catch { payload = null; }
  const code = typeof payload?.code === 'string' ? payload.code : '';
  const message = typeof payload?.message === 'string' ? payload.message : '';
  if (response.status === 401 || (code === '42501' && message === 'authentication_required')) {
    return failure(401, 'INVALID_TOKEN', requestId, false, { 'WWW-Authenticate': 'Bearer' });
  }
  if (response.status === 429) return upstreamFailure(response, requestId, 'rest');
  if (code === '22023' && VALIDATION_MESSAGES.has(message)) return failure(422, 'VALIDATION_ERROR', requestId);
  if (code === 'P0002' && message === 'profile_not_found') return failure(404, 'PROFILE_NOT_FOUND', requestId);
  if (code === 'P0002' && message === 'garment_not_found') return failure(404, 'GARMENT_NOT_FOUND', requestId);
  if (code === 'P0002' && ['batch_not_found', 'asset_not_found'].includes(message)) return failure(404, 'BATCH_NOT_FOUND', requestId);
  if (code === 'P0002' && message === 'job_not_found') return failure(404, 'ANALYSIS_JOB_NOT_FOUND', requestId);
  if (code === 'P0002' && message === 'draft_not_found') return failure(404, 'GARMENT_DRAFT_NOT_FOUND', requestId);
  if (code === 'P0002' && ['recommendation_not_found', 'outfit_not_found'].includes(message)) {
    return failure(404, 'RECOMMENDATION_NOT_FOUND', requestId);
  }
  if (code === 'P0002' && message === 'saved_outfit_not_found') return failure(404, 'SAVED_OUTFIT_NOT_FOUND', requestId);
  if (code === 'P0002' && message === 'ootd_not_found') return failure(404, 'OOTD_NOT_FOUND', requestId);
  if (code === 'P0002' && message === 'feed_post_not_found') return failure(404, 'FEED_POST_NOT_FOUND', requestId);
  if (code === 'P0002' && message === 'feed_media_not_found') return failure(404, 'FEED_MEDIA_NOT_FOUND', requestId);
  if (code === 'P0002' && message === 'mimic_job_not_found') return failure(404, 'MIMIC_JOB_NOT_FOUND', requestId);
  if (code === 'P0002' && message === 'aesthetic_not_found') return failure(422, 'VALIDATION_ERROR', requestId);
  if (code === 'P0001' && message === 'version_conflict') return failure(409, 'VERSION_CONFLICT', requestId);
  if (code === 'P0001' && message === 'idempotency_conflict') return failure(409, 'IDEMPOTENCY_CONFLICT', requestId);
  if (code === 'P0001' && message === 'too_many_open_batches') return failure(409, 'TOO_MANY_OPEN_BATCHES', requestId);
  if (code === 'P0001' && message === 'invalid_batch_state') return failure(409, 'INVALID_BATCH_STATE', requestId);
  if (code === 'P0001' && message === 'upload_not_found') return failure(409, 'UPLOAD_NOT_FOUND', requestId, true);
  if (code === 'P0001' && ['job_exists', 'analysis_job_exists', 'job_not_retryable', 'attempts_exhausted',
      'confirmation_conflict', 'batch_already_confirmed'].includes(message)) {
    return failure(409, 'ANALYSIS_CONFLICT', requestId);
  }
  if (code === 'P0001' && ['batch_not_uploaded', 'source_asset_not_ready', 'batch_not_reviewable',
      'analysis_not_reviewable', 'invalid_draft_state', 'draft_not_editable', 'asset_not_ready'].includes(message)) {
    return failure(409, 'INVALID_BATCH_STATE', requestId);
  }
  if (code === 'P0001' && message === 'ootd_date_conflict') return failure(409, 'OOTD_DATE_CONFLICT', requestId);
  if (code === 'P0001' && ['feed_media_required', 'invalid_feed_state', 'feed_media_limit', 'invalid_feed_media_state'].includes(message)) {
    return failure(409, 'FEED_CONFLICT', requestId);
  }
  if (code === 'P0001' && ['feed_media_unavailable', 'feed_media_changed'].includes(message)) {
    return failure(409, 'MIMIC_CONFLICT', requestId);
  }
  if (code === 'P0001' && message === 'mimic_open_limit') {
    return failure(429, 'RATE_LIMITED', requestId, true, { 'Retry-After': '60' });
  }
  if (code === 'P0001' && ['source_composition_mismatch', 'ootd_in_use', 'accepted_ootd_immutable', 'garment_unavailable'].includes(message)) {
    return failure(409, message === 'ootd_in_use' ? 'OOTD_IN_USE' : 'OUTFIT_CONFLICT', requestId);
  }
  if (code === 'P0002' && message === 'weather_not_found') return failure(422, 'VALIDATION_ERROR', requestId);
  if (code === 'P0001' && ['recommendation_not_ready', 'recommendation_expired', 'outfit_not_in_recommendation',
      'inactive_garment', 'outfit_items_unavailable', 'worn_on_mismatch'].includes(message)) {
    return failure(409, 'RECOMMENDATION_CONFLICT', requestId);
  }
  if (code === '22023' && ['invalid_draft_ids', 'invalid_draft_patch', 'empty_draft_patch', 'invalid_category',
      'invalid_subcategory', 'invalid_note', 'invalid_confirmation', 'invalid_job_id'].includes(message)) {
    return failure(422, 'VALIDATION_ERROR', requestId);
  }
  if (code === '22023' && ['invalid_recommendation_accept', 'invalid_worn_on'].includes(message)) {
    return failure(422, 'VALIDATION_ERROR', requestId);
  }
  if (['PGRST202', '42883', '42501'].includes(code) || [403, 404].includes(response.status)) {
    return failure(503, 'DATABASE_SCHEMA_NOT_READY', requestId);
  }
  return failure(503, 'SUPABASE_UNAVAILABLE', requestId, true);
}

export function createUserClient({ env, token, request = fetch, requestId }) {
  const base = projectUrl(env);
  if (!base) return { error: failure(503, 'SUPABASE_NOT_CONFIGURED', requestId) };
  const headers = {
    apikey: env.SUPABASE_PUBLISHABLE_KEY,
    Authorization: `Bearer ${token}`,
    Accept: 'application/json'
  };

  async function call(path, source, searchParams, options = {}) {
    const url = new URL(path, base);
    for (const [name, value] of searchParams ?? []) url.searchParams.set(name, value);
    let response;
    try {
      response = await request(url, {
        method: options.method ?? 'GET',
        headers: options.body === undefined ? headers : { ...headers, 'Content-Type': 'application/json' },
        body: options.body === undefined ? undefined : JSON.stringify(options.body),
        redirect: 'error', signal: AbortSignal.timeout(5000)
      });
    } catch {
      return { error: failure(503, source === 'auth' ? 'AUTH_UNAVAILABLE' : 'SUPABASE_UNAVAILABLE', requestId, true) };
    }
    if (options.rpc) {
      if (response.status === 204) return { data: null };
      if (response.status === 200) {
        try { return { data: await response.json() }; }
        catch { return { error: failure(503, 'SUPABASE_UNAVAILABLE', requestId, true) }; }
      }
      return { error: await rpcFailure(response, requestId) };
    }
    if (response.status !== 200) return { error: upstreamFailure(response, requestId, source) };
    try {
      return { data: await response.json() };
    } catch {
      return { error: failure(503, source === 'auth' ? 'AUTH_UNAVAILABLE' : 'SUPABASE_UNAVAILABLE', requestId, true) };
    }
  }

  return {
    getUser() { return call('/auth/v1/user', 'auth'); },
    select(table, searchParams) {
      if (!/^[a-z][a-z0-9_]*$/.test(table)) {
        return Promise.resolve({ error: failure(500, 'INTERNAL_ERROR', requestId) });
      }
      return call(`/rest/v1/${table}`, 'rest', searchParams);
    },
    rpc(name, args) {
      if (![
        'update_my_profile', 'replace_my_aesthetic_preferences', 'save_my_onboarding_state',
        'update_my_garment', 'delete_my_garment', 'create_my_garment_batch', 'complete_my_garment_upload',
        'create_my_analysis_job', 'retry_my_analysis_job', 'list_my_garment_drafts',
        'update_my_garment_draft', 'confirm_my_garment_batch', 'begin_my_recommendation', 'accept_my_recommendation',
        'create_my_saved_outfit', 'update_my_saved_outfit', 'delete_my_saved_outfit',
        'create_my_ootd', 'update_my_ootd', 'delete_my_ootd', 'get_my_closet_statistics',
        'create_my_feed_post', 'update_my_feed_post', 'delete_my_feed_post', 'create_my_feed_media',
        'complete_my_feed_media', 'like_my_feed_post', 'unlike_my_feed_post',
        'create_my_mimic_job', 'get_my_mimic_job'
      ].includes(name)) {
        return Promise.resolve({ error: failure(500, 'INTERNAL_ERROR', requestId) });
      }
      return call(`/rest/v1/rpc/${name}`, 'rest', undefined, { method: 'POST', body: args, rpc: true });
    },
    async signStorage(bucket, paths, expiresIn = 300) {
      if (!['closet-private', 'feed-private'].includes(bucket) || !Array.isArray(paths) || paths.length < 1 || paths.length > 100 ||
          paths.some(path => typeof path !== 'string' || path.length < 1 || path.length > 1024) ||
          !Number.isInteger(expiresIn) || expiresIn < 60 || expiresIn > 3600) {
        return { error: failure(500, 'INTERNAL_ERROR', requestId) };
      }
      const url = new URL(`/storage/v1/object/sign/${bucket}`, base);
      let response;
      try {
        response = await request(url, {
          method: 'POST',
          headers: { ...headers, 'Content-Type': 'application/json' },
          body: JSON.stringify({ expiresIn, paths }),
          redirect: 'error', signal: AbortSignal.timeout(5000)
        });
      } catch {
        return { error: failure(503, 'STORAGE_UNAVAILABLE', requestId, true) };
      }
      if (response.status === 429) return { error: upstreamFailure(response, requestId, 'rest') };
      if (response.status !== 200) return { error: failure(503, 'STORAGE_UNAVAILABLE', requestId, true) };
      try {
        const data = await response.json();
        return Array.isArray(data) ? { data } : { error: failure(503, 'STORAGE_UNAVAILABLE', requestId, true) };
      } catch {
        return { error: failure(503, 'STORAGE_UNAVAILABLE', requestId, true) };
      }
    },
    async createSignedUpload(bucket, path) {
      if (!['closet-private', 'feed-private'].includes(bucket) || typeof path !== 'string' || path.length < 1 || path.length > 1024 ||
          path.split('/').some(segment => segment.length < 1 || segment === '.' || segment === '..')) {
        return { error: failure(500, 'INTERNAL_ERROR', requestId) };
      }
      const encoded = [bucket, ...path.split('/')].map(encodeURIComponent).join('/');
      const signUrl = new URL(`/storage/v1/object/upload/sign/${encoded}`, base);
      let response;
      try {
        response = await request(signUrl, { method: 'POST', headers: { ...headers, 'Content-Type': 'application/json' },
          body: '{}', redirect: 'error', signal: AbortSignal.timeout(5000) });
      } catch { return { error: failure(503, 'STORAGE_UNAVAILABLE', requestId, true) }; }
      if (response.status === 429) return { error: upstreamFailure(response, requestId, 'rest') };
      if (response.status !== 200) return { error: failure(503, 'STORAGE_UNAVAILABLE', requestId, true) };
      let payload;
      try { payload = await response.json(); } catch { return { error: failure(503, 'STORAGE_UNAVAILABLE', requestId, true) }; }
      if (!payload || typeof payload.url !== 'string') return { error: failure(503, 'STORAGE_UNAVAILABLE', requestId, true) };
      let signed;
      try {
        signed = payload.url.startsWith('/object/')
          ? new URL(`/storage/v1${payload.url}`, base)
          : new URL(payload.url, base);
      } catch { return { error: failure(503, 'STORAGE_UNAVAILABLE', requestId, true) }; }
      const expectedPath = `/storage/v1/object/upload/sign/${encoded}`;
      if (signed.protocol !== 'https:' || signed.hostname !== base.hostname || signed.port || signed.username || signed.password ||
          signed.pathname !== expectedPath || [...signed.searchParams.keys()].length !== 1 ||
          !signed.searchParams.has('token') || !signed.searchParams.get('token')) {
        return { error: failure(503, 'STORAGE_UNAVAILABLE', requestId, true) };
      }
      return { data: { url: String(signed), method: 'PUT' } };
    },
    async readStoragePrefix(bucket, path, maxBytes = 65536) {
      if (!['closet-private', 'feed-private'].includes(bucket) || typeof path !== 'string' || path.length < 1 || path.length > 1024 ||
          !Number.isInteger(maxBytes) || maxBytes < 16 || maxBytes > 65536) {
        return { error: failure(500, 'INTERNAL_ERROR', requestId) };
      }
      const encoded = [bucket, ...path.split('/')].map(encodeURIComponent).join('/');
      const url = new URL(`/storage/v1/object/authenticated/${encoded}`, base);
      let response;
      try {
        response = await request(url, { method: 'GET', headers: { ...headers, Range: `bytes=0-${maxBytes - 1}` },
          redirect: 'error', signal: AbortSignal.timeout(5000) });
      } catch { return { error: failure(503, 'STORAGE_UNAVAILABLE', requestId, true) }; }
      if (response.status === 404) return { missing: true };
      if (response.status === 429) return { error: upstreamFailure(response, requestId, 'rest') };
      if (![200, 206].includes(response.status)) return { error: failure(503, 'STORAGE_UNAVAILABLE', requestId, true) };
      const chunks = []; let length = 0;
      try {
        if (response.body?.getReader) {
          const reader = response.body.getReader();
          while (length < maxBytes) {
            const { done, value } = await reader.read();
            if (done) break;
            const take = value.subarray(0, maxBytes - length); chunks.push(take); length += take.length;
            if (take.length < value.length || length === maxBytes) { await reader.cancel(); break; }
          }
        } else {
          const bytes = new Uint8Array(await response.arrayBuffer());
          chunks.push(bytes.subarray(0, maxBytes)); length = Math.min(bytes.length, maxBytes);
        }
      } catch { return { error: failure(503, 'STORAGE_UNAVAILABLE', requestId, true) }; }
      const bytes = new Uint8Array(length); let offset = 0;
      for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
      return { data: { bytes, status: response.status, contentRange: response.headers?.get?.('content-range') ?? null,
        contentType: response.headers?.get?.('content-type') ?? null } };
    }
  };
}
