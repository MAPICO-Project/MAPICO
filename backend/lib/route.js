import { randomUUID } from 'node:crypto';
import { corsHeaders, preflight } from './cors.js';
import { failure } from './errors.js';

export function createRoute({ methods, run }) {
  const allowed = Object.freeze([...methods]);
  return function createHandler(dependencies = {}) {
    return async function handler(req, res) {
      const env = dependencies.env ?? process.env;
      const requestId = (dependencies.createRequestId ?? randomUUID)();
      let result;
      if (req.method === 'OPTIONS') {
        result = preflight(req, env, allowed, requestId);
      } else if (!allowed.includes(req.method)) {
        result = failure(405, 'METHOD_NOT_ALLOWED', requestId, false, { Allow: allowed.join(', ') });
        result.headers = { ...result.headers, ...corsHeaders(req, env) };
      } else {
        try {
          result = await run(req, { ...dependencies, env, requestId });
        } catch {
          result = failure(500, 'INTERNAL_ERROR', requestId);
        }
        result.headers = { ...result.headers, ...corsHeaders(req, env) };
      }
      for (const [name, value] of Object.entries(result.headers ?? {})) res.setHeader(name, value);
      if (req.method === 'HEAD' || req.method === 'OPTIONS' || result.status === 204) return res.status(result.status).end();
      return res.status(result.status).json(result.body);
    };
  };
}
