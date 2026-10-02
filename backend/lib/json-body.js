const JSON_TYPE = /^application\/json(?:\s*;\s*charset=[A-Za-z0-9._-]+)?$/i;

function header(req, name) {
  return req.headers?.[name] ?? req.headers?.[name.toLowerCase()] ?? req.headers?.[name.toUpperCase()];
}

export function readJsonObject(req, maxBytes = 16 * 1024) {
  const contentType = header(req, 'content-type');
  if (typeof contentType !== 'string' || !JSON_TYPE.test(contentType.trim())) return { error: 'INVALID_REQUEST_BODY' };

  let value = req.body;
  try {
    if (Buffer.isBuffer(value)) {
      if (value.byteLength > maxBytes) return { error: 'INVALID_REQUEST_BODY' };
      value = JSON.parse(value.toString('utf8'));
    } else if (typeof value === 'string') {
      if (Buffer.byteLength(value, 'utf8') > maxBytes) return { error: 'INVALID_REQUEST_BODY' };
      value = JSON.parse(value);
    } else {
      if (value === undefined || Buffer.byteLength(JSON.stringify(value), 'utf8') > maxBytes) {
        return { error: 'INVALID_REQUEST_BODY' };
      }
    }
  } catch {
    return { error: 'INVALID_REQUEST_BODY' };
  }
  if (value === null || Array.isArray(value) || typeof value !== 'object') return { error: 'INVALID_REQUEST_BODY' };
  const prototype = Object.getPrototypeOf(value);
  if (prototype !== Object.prototype && prototype !== null) return { error: 'INVALID_REQUEST_BODY' };
  return { data: value };
}

export function hasOnlyKeys(value, allowed) {
  return Object.keys(value).every(key => allowed.has(key));
}
