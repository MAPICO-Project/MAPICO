const JWT = /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/;

export function bearerToken(req) {
  const value = req.headers?.authorization ?? req.headers?.Authorization;
  if (value === undefined) return { code: 'AUTH_REQUIRED' };
  if (typeof value !== 'string' || value.length > 4096) return { code: 'INVALID_TOKEN' };
  const match = /^Bearer (.+)$/i.exec(value);
  if (!match || !JWT.test(match[1])) return { code: 'INVALID_TOKEN' };
  return { token: match[1] };
}
