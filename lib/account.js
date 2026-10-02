import { baseHeaders, failure } from './errors.js';
import { hasOnlyKeys, readJsonObject } from './json-body.js';
import { authenticatedUser, readProfile } from './profile.js';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

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
  if (!hasOnlyKeys(body, new Set(['display_name', 'timezone'])) || Object.keys(body).length === 0) {
    return validation(dependencies.requestId);
  }
  const setDisplayName = Object.hasOwn(body, 'display_name');
  const setTimezone = Object.hasOwn(body, 'timezone');
  if (setDisplayName && body.display_name !== null && (
    typeof body.display_name !== 'string' || [...body.display_name].length < 1 ||
    [...body.display_name].length > 50 || body.display_name.includes('\u0000')
  )) return validation(dependencies.requestId);
  if (setTimezone && (typeof body.timezone !== 'string' || body.timezone.length < 1 || body.timezone.length > 255 || body.timezone.includes('\u0000'))) {
    return validation(dependencies.requestId);
  }
  const auth = await authenticatedUser(req, dependencies);
  if (auth.error) return auth.error;
  const write = await auth.client.rpc('update_my_profile', {
    p_set_display_name: setDisplayName,
    p_display_name: setDisplayName ? body.display_name : null,
    p_set_timezone: setTimezone,
    p_timezone: setTimezone ? body.timezone : null
  });
  if (write.error) return write.error;
  const profile = await readProfile(auth.client, auth.user.id, dependencies.requestId, 500);
  if (profile.error) return profile.error;
  return { status: 200, headers: baseHeaders(dependencies.requestId), body: profile.data };
}

export async function replacePreferencesResponse(req, dependencies) {
  const current = bodyContext(req, dependencies);
  if (current.error) return current.error;
  if (!hasOnlyKeys(current.body, new Set(['preferences'])) || !Array.isArray(current.body.preferences) ||
      current.body.preferences.length < 1 || current.body.preferences.length > 3) {
    return validation(dependencies.requestId);
  }
  const preferences = [];
  const ids = new Set();
  for (const value of current.body.preferences) {
    if (!value || Array.isArray(value) || typeof value !== 'object' ||
        !hasOnlyKeys(value, new Set(['aesthetic_id', 'weight'])) || Object.keys(value).length !== 2 ||
        typeof value.aesthetic_id !== 'string' || !UUID.test(value.aesthetic_id) ||
        typeof value.weight !== 'number' || !Number.isFinite(value.weight) || value.weight <= 0 || value.weight > 1) {
      return validation(dependencies.requestId);
    }
    const aestheticId = value.aesthetic_id.toLowerCase();
    if (ids.has(aestheticId)) return validation(dependencies.requestId);
    ids.add(aestheticId);
    preferences.push({ aesthetic_id: aestheticId, weight: value.weight });
  }
  const sum = preferences.reduce((total, item) => total + item.weight, 0);
  if (Math.abs(sum - 1) > 0.0001) return validation(dependencies.requestId);
  const auth = await authenticatedUser(req, dependencies);
  if (auth.error) return auth.error;
  const write = await auth.client.rpc('replace_my_aesthetic_preferences', { p_preferences: preferences });
  if (write.error) return write.error;
  const read = await auth.client.select('user_aesthetic_preferences', [
    ['select', 'aesthetic_id,weight'], ['user_id', `eq.${auth.user.id}`], ['order', 'aesthetic_id.asc']
  ]);
  if (read.error) return read.error;
  if (!Array.isArray(read.data) || read.data.length < 1 || read.data.length > 3) return failure(500, 'INTERNAL_ERROR', dependencies.requestId);
  const projected = [];
  for (const item of read.data) {
    if (!item || !UUID.test(item.aesthetic_id) || typeof item.weight !== 'number' || !Number.isFinite(item.weight)) {
      return failure(500, 'INTERNAL_ERROR', dependencies.requestId);
    }
    projected.push({ aesthetic_id: item.aesthetic_id, weight: item.weight });
  }
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
