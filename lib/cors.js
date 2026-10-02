function configuredOrigins(env) {
  const raw = env.CORS_ALLOWED_ORIGINS;
  if (typeof raw !== 'string' || raw.trim() === '' || raw.includes('*')) return new Set();
  const origins = new Set();
  for (const candidate of raw.split(',').map(value => value.trim()).filter(Boolean)) {
    if (candidate === 'null') continue;
    try {
      const url = new URL(candidate);
      if (
        ['https:', 'http:'].includes(url.protocol) &&
        !url.username && !url.password &&
        url.origin === candidate &&
        url.pathname === '/' && !url.search && !url.hash
      ) origins.add(candidate);
    } catch {
      // Invalid entries fail closed.
    }
  }
  return origins;
}
function requestOrigin(req) {
  const value = req.headers?.origin ?? req.headers?.Origin;
  return typeof value === 'string' ? value : null;
}

export function corsHeaders(req, env = process.env) {
  const headers = { Vary: 'Origin' };
  const origin = requestOrigin(req);
  if (origin && configuredOrigins(env).has(origin)) {
    headers['Access-Control-Allow-Origin'] = origin;
    headers['Access-Control-Expose-Headers'] = 'X-Request-Id, Retry-After';
  }
  return headers;
}

export function preflight(req, env, methods, requestId) {
  const headers = {
    'Cache-Control': 'no-store',
    'X-Request-Id': requestId,
    ...corsHeaders(req, env),
    Vary: 'Origin, Access-Control-Request-Method, Access-Control-Request-Headers'
  };
  if (headers['Access-Control-Allow-Origin']) {
    headers['Access-Control-Allow-Methods'] = methods.join(', ');
    headers['Access-Control-Allow-Headers'] = 'Authorization, Content-Type';
    headers['Access-Control-Max-Age'] = '600';
  }
  return { status: 204, headers };
}
