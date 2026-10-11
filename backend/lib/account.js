import { baseHeaders, failure } from './errors.js';
import { hasOnlyKeys, readJsonObject } from './json-body.js';
import { authenticatedUser, readProfile } from './profile.js';
import { createInternalClient } from './supabase-internal.js';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const PROFILE_PATCH_FIELDS = new Set(['display_name', 'timezone', 'avatar_upload_id', 'ai_notice_accepted', 'training_consent']);

function validation(requestId, code = 'VALIDATION_ERROR') {
  return failure(422, code, requestId);
}

function bodyContext(req, dependencies) {
  const body = readJsonObject(req);
  if (body.error) return { error: failure(400, body.error, dependencies.requestId) };
  return { body: body.data };
}

export async function updateProfileResponse(req, dependencies) {
  const bodyResult = readJsonObject(req);
  if (bodyResult.error) return failure(400, bodyResult.error, dependencies.requestId);
  const body = bodyResult.data;
  if (Object.hasOwn(body, 'avatar_asset_id')) return validation(dependencies.requestId, 'UNSUPPORTED_FIELD');
  if (!hasOnlyKeys(body, PROFILE_PATCH_FIELDS) || Object.keys(body).length === 0) {
    return validation(dependencies.requestId);
  }
  const setDisplayName = Object.hasOwn(body, 'display_name');
  const setTimezone = Object.hasOwn(body, 'timezone');
  const setAvatar = Object.hasOwn(body, 'avatar_upload_id');
  const acceptNotice = Object.hasOwn(body, 'ai_notice_accepted');
  const setTraining = Object.hasOwn(body, 'training_consent');
  if (setAvatar && body.avatar_upload_id !== null && (typeof body.avatar_upload_id !== 'string' || !UUID.test(body.avatar_upload_id))) {
    return validation(dependencies.requestId);
  }
  if (setDisplayName && body.display_name !== null && (
    typeof body.display_name !== 'string' || [...body.display_name].length < 1 ||
    [...body.display_name].length > 50 || body.display_name.includes('\u0000')
  )) return validation(dependencies.requestId);
  if (setTimezone && (typeof body.timezone !== 'string' || body.timezone.length < 1 || body.timezone.length > 255 || body.timezone.includes('\u0000'))) {
    return validation(dependencies.requestId);
  }
  // The external-AI notice is required and cannot be withdrawn through the API: only `true` is accepted.
  if (acceptNotice && body.ai_notice_accepted !== true) return validation(dependencies.requestId);
  if (setTraining && typeof body.training_consent !== 'boolean') return validation(dependencies.requestId);
  const auth = await authenticatedUser(req, dependencies);
  if (auth.error) return auth.error;
  const write = await auth.client.rpc('update_my_profile_settings', {
    p_set_display_name: setDisplayName,
    p_display_name: setDisplayName ? body.display_name : null,
    p_set_timezone: setTimezone,
    p_timezone: setTimezone ? body.timezone : null,
    p_set_avatar: setAvatar,
    p_avatar_upload_id: setAvatar && body.avatar_upload_id !== null ? body.avatar_upload_id.toLowerCase() : null,
    p_accept_ai_notice: acceptNotice,
    p_set_training_consent: setTraining,
    p_training_consent: setTraining ? body.training_consent : null
  });
  if (write.error) return write.error;
  const profile = await readProfile(auth.client, auth.user.id, dependencies, 500);
  if (profile.error) return profile.error;
  return { status: 200, headers: baseHeaders(dependencies.requestId), body: profile.data };
}

// DELETE /me (2026-10-10 decision: delete everything). Order: verify the user JWT -> purge every
// public row and queue Storage objects (service RPC) -> delete the auth user (Admin API).
// Every step is idempotent, so the client retries the same request after any retryable 5xx.
export async function deleteAccountResponse(req, dependencies) {
  const { requestId } = dependencies;
  if (req.query && typeof req.query === 'object' && Object.keys(req.query).length) return failure(400, 'INVALID_REQUEST_BODY', requestId);
  const key = req.headers?.['idempotency-key'] ?? req.headers?.['Idempotency-Key'];
  if (typeof key !== 'string' || key.length < 8 || key.length > 128 || !/^[A-Za-z0-9._:-]+$/.test(key)) return validation(requestId);
  const auth = await authenticatedUser(req, dependencies);
  if (auth.error) return auth.error;
  const admin = createInternalClient({ env: dependencies.env, request: dependencies.request, requestId });
  if (admin.error) return admin.error;
  const userId = auth.user.id.toLowerCase();
  const purged = await admin.purgeAccountData(userId);
  if (purged.error) return purged.error;
  const removed = await admin.deleteAuthUser(userId);
  if (removed.error) return removed.error;
  return { status: 202, headers: baseHeaders(requestId), body: { id: userId, status: 'deletion_pending' } };
}

export async function replacePreferencesResponse(req, dependencies) {
  const current = bodyContext(req, dependencies);
  if (current.error) return current.error;
  if (!hasOnlyKeys(current.body, new Set(['preferences'])) || !Array.isArray(current.body.preferences) ||
      current.body.preferences.length < 1 || current.body.preferences.length > 3) {
    return validation(dependencies.requestId);
  }
  // role is canonical (exactly one main, 0..2 sub). weight is optional but all-or-none; omitted -> server 1/n.
  const preferences = [];
  const ids = new Set();
  for (const value of current.body.preferences) {
    if (!value || Array.isArray(value) || typeof value !== 'object' ||
        !hasOnlyKeys(value, new Set(['aesthetic_id', 'role', 'weight'])) ||
        typeof value.aesthetic_id !== 'string' || !UUID.test(value.aesthetic_id) || !['main', 'sub'].includes(value.role) ||
        (Object.hasOwn(value, 'weight') && (typeof value.weight !== 'number' || !Number.isFinite(value.weight) ||
          value.weight <= 0 || value.weight > 1))) {
      return validation(dependencies.requestId);
    }
    const aestheticId = value.aesthetic_id.toLowerCase();
    if (ids.has(aestheticId)) return validation(dependencies.requestId);
    ids.add(aestheticId);
    preferences.push(Object.hasOwn(value, 'weight')
      ? { aesthetic_id: aestheticId, role: value.role, weight: value.weight }
      : { aesthetic_id: aestheticId, role: value.role });
  }
  const main = preferences.filter(item => item.role === 'main');
  if (main.length !== 1) return validation(dependencies.requestId);
  const weighted = preferences.filter(item => Object.hasOwn(item, 'weight'));
  if (weighted.length !== 0 && weighted.length !== preferences.length) return validation(dependencies.requestId);
  if (weighted.length) {
    const sum = preferences.reduce((total, item) => total + item.weight, 0);
    if (Math.abs(sum - 1) > 0.0001 || preferences.some(item => item.weight > main[0].weight)) return validation(dependencies.requestId);
  }
  const auth = await authenticatedUser(req, dependencies);
  if (auth.error) return auth.error;
  const write = await auth.client.rpc('replace_my_aesthetic_preferences', { p_preferences: preferences });
  if (write.error) return write.error;
  const read = await auth.client.select('user_aesthetic_preferences', [
    ['select', 'aesthetic_id,role,weight'], ['user_id', `eq.${auth.user.id}`], ['order', 'role.asc,aesthetic_id.asc']
  ]);
  if (read.error) return read.error;
  if (!Array.isArray(read.data) || read.data.length < 1 || read.data.length > 3) return failure(500, 'INTERNAL_ERROR', dependencies.requestId);
  const projected = [];
  for (const item of read.data) {
    if (!item || !UUID.test(item.aesthetic_id) || !['main', 'sub'].includes(item.role) ||
        typeof item.weight !== 'number' || !Number.isFinite(item.weight)) {
      return failure(500, 'INTERNAL_ERROR', dependencies.requestId);
    }
    projected.push({ aesthetic_id: item.aesthetic_id, role: item.role, weight: item.weight });
  }
  if (projected.filter(item => item.role === 'main').length !== 1) return failure(500, 'INTERNAL_ERROR', dependencies.requestId);
  return { status: 200, headers: baseHeaders(dependencies.requestId), body: { preferences: projected } };
}

export async function saveOnboardingResponse(req, dependencies) {
  const current = bodyContext(req, dependencies);
  if (current.error) return current.error;
  const keys = new Set(['knows_aesthetic', 'tutorial_seen', 'completed']);
  if (!hasOnlyKeys(current.body, keys) || Object.keys(current.body).length !== 3 ||
      !Object.hasOwn(current.body, 'knows_aesthetic') || !Object.hasOwn(current.body, 'tutorial_seen') ||
      !Object.hasOwn(current.body, 'completed') ||
      (current.body.knows_aesthetic !== null && typeof current.body.knows_aesthetic !== 'boolean') ||
      typeof current.body.tutorial_seen !== 'boolean' || typeof current.body.completed !== 'boolean') {
    return validation(dependencies.requestId);
  }
  const auth = await authenticatedUser(req, dependencies);
  if (auth.error) return auth.error;
  const write = await auth.client.rpc('save_my_onboarding_state', {
    p_knows_aesthetic: current.body.knows_aesthetic,
    p_tutorial_seen: current.body.tutorial_seen,
    p_completed: current.body.completed
  });
  if (write.error) return write.error;
  const read = await auth.client.select('profiles', [
    ['select', 'knows_aesthetic,tutorial_seen,onboarding_completed'], ['id', `eq.${auth.user.id}`]
  ]);
  if (read.error) return read.error;
  if (!Array.isArray(read.data) || read.data.length !== 1) return failure(500, 'INTERNAL_ERROR', dependencies.requestId);
  const row = read.data[0];
  if ((row.knows_aesthetic !== null && typeof row.knows_aesthetic !== 'boolean') ||
      typeof row.tutorial_seen !== 'boolean' || typeof row.onboarding_completed !== 'boolean') {
    return failure(500, 'INTERNAL_ERROR', dependencies.requestId);
  }
  return { status: 200, headers: baseHeaders(dependencies.requestId), body: {
    knows_aesthetic: row.knows_aesthetic,
    tutorial_seen: row.tutorial_seen,
    completed: row.onboarding_completed
  } };
}
