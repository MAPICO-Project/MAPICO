import { randomUUID } from 'node:crypto';
import { bearerToken } from './auth.js';
import { baseHeaders, failure } from './errors.js';
import { createUserClient } from './supabase-user.js';
import { signMediaReads } from './media.js';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const TPO_CODES = new Set([
  'daily_campus',
  'office_business',
  'date_social',
  'formal_event',
  'outdoor_active'
]);

export function validProfile(row) {
  if (!row || typeof row !== 'object' || !UUID.test(row.id)) return null;
    if (row.display_name !== null && (typeof row.display_name !== 'string' || [...row.display_name].length > 50)) return null;
  if (typeof row.timezone !== 'string' || row.timezone.trim() === '') return null;
  if (row.default_tpo !== null && !TPO_CODES.has(row.default_tpo)) return null;
  if (typeof row.onboarding_completed !== 'boolean' || !Array.isArray(row.preferences) || row.preferences.length > 3) return null;
  if (row.ai_notice_accepted_at !== null && (typeof row.ai_notice_accepted_at !== 'string' ||
      !Number.isFinite(Date.parse(row.ai_notice_accepted_at)))) return null;
  if (typeof row.training_consent !== 'boolean') return null;
  if (row.avatar_object_key !== null && (typeof row.avatar_object_key !== 'string' ||
      !row.avatar_object_key.startsWith(`${row.id.toLowerCase()}/avatar/`))) return null;
  const preferences = [];
  for (const preference of row.preferences) {
    if (
      !preference ||
      typeof preference !== 'object' ||
      !UUID.test(preference.aesthetic_id) ||
      typeof preference.weight !== 'number' ||
      !Number.isFinite(preference.weight) ||
      preference.weight <= 0 ||
      preference.weight > 1 ||
      !['main', 'sub'].includes(preference.role)
    ) return null;
    preferences.push({ aesthetic_id: preference.aesthetic_id, role: preference.role, weight: preference.weight });
  }
  // Role is canonical: a non-empty set has exactly one main (listed first) and at most two subs.
  if (preferences.length && preferences.filter(item => item.role === 'main').length !== 1) return null;
  preferences.sort((a, b) => (a.role === b.role ? 0 : a.role === 'main' ? -1 : 1));
  return {
    id: row.id,
    display_name: row.display_name,
    timezone: row.timezone,
    default_tpo: row.default_tpo,
    onboarding_completed: row.onboarding_completed,
    preferences,
    ai_notice_accepted_at: row.ai_notice_accepted_at,
    training_consent: row.training_consent,
    avatar_object_key: row.avatar_object_key
  };
}

export async function authenticatedUser(req, { env, request, requestId }) {
  const authorization = bearerToken(req);
  if (!authorization.token) {
    return { error: failure(401, authorization.code, requestId, false, { 'WWW-Authenticate': 'Bearer' }) };
  }
  const client = createUserClient({ env, token: authorization.token, request, requestId });
  if (client.error) return { error: client.error };
  const authResult = await client.getUser();
  if (authResult.error) return { error: authResult.error };
  const user = authResult.data;
  if (!user || typeof user !== 'object' || !UUID.test(user.id)) {
    return { error: failure(503, 'AUTH_UNAVAILABLE', requestId, true) };
  }
  return { client, user };
}

export async function readProfile(client, userId, dependencies, missingStatus = 404) {
  const { requestId } = dependencies;
  const profileResult = await client.select('profiles', [
    ['select', 'id,display_name,timezone,default_tpo,onboarding_completed,ai_notice_accepted_at,training_consent,avatar_object_key,preferences:user_aesthetic_preferences(aesthetic_id,role,weight)'],
    ['id', `eq.${userId}`],
    ['preferences.order', 'role.asc,aesthetic_id.asc']
  ]);
  if (profileResult.error) return profileResult;
  const rows = profileResult.data;
  if (!Array.isArray(rows) || rows.length !== 1) {
    return { error: rows?.length === 0 && missingStatus === 404
      ? failure(404, 'PROFILE_NOT_FOUND', requestId)
      : failure(500, 'INTERNAL_ERROR', requestId) };
  }
  const profile = validProfile(rows[0]);
  if (!profile) return { error: failure(500, 'INTERNAL_ERROR', requestId) };
  const { avatar_object_key: avatarKey, ...body } = profile;
  const signed = await signMediaReads(client, 'profile-media', [avatarKey], dependencies);
  if (signed.error) return signed;
  return { data: { ...body, avatar: avatarKey ? signed.data.get(avatarKey) ?? null : null } };
}

export async function getProfileResponse(req, {
  env = process.env,
  request = fetch,
  createRequestId = randomUUID,
  requestId = createRequestId(),
  now
} = {}) {
  if (!['GET', 'HEAD'].includes(req.method)) {
    return failure(405, 'METHOD_NOT_ALLOWED', requestId, false, { Allow: 'GET, HEAD' });
  }

  const auth = await authenticatedUser(req, { env, request, requestId });
  if (auth.error) return auth.error;
  const result = await readProfile(auth.client, auth.user.id, { env, requestId, now });
  if (result.error) return result.error;
  return { status: 200, headers: baseHeaders(requestId), body: result.data };
}
