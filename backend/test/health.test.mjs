import test from 'node:test';
import assert from 'node:assert/strict';
import health from '../api/health.js';
import readiness from '../api/readiness.js';
import catalog from '../api/catalog.js';

function invoke(fn, method = 'GET') {
  const result = { headers: {}, statusCode: 200 };
  const res = {
    setHeader(k, v) { result.headers[k] = v; },
    status(n) { result.statusCode = n; return this; },
    json(body) { result.body = body; return result; },
    end() { return result; }
  };
  return fn({ method }, res);
}
test('health does not claim product readiness', () => {
  const result = invoke(health);
  assert.equal(result.statusCode, 200);
  assert.equal(result.body.projectName, '마피코');
  assert.equal(result.body.productApiImplemented, false);
});
test('unimplemented integration is unavailable, not mock success', () => {
  assert.equal(invoke(readiness).statusCode, 503);
  assert.equal(invoke(readiness).body.ready, false);
});
test('catalog has exactly 5 styles and marks no persistence', () => {
  const result = invoke(catalog);
  assert.equal(result.body.aesthetics.length, 5);
  assert.equal(result.body.persistence, 'none');
});
test('all endpoints reject writes', () => {
  for (const fn of [health, readiness, catalog]) {
    const result = invoke(fn, 'POST');
    assert.equal(result.statusCode, 405);
    assert.equal(result.headers.Allow, 'GET, HEAD');
  }
});
test('HEAD omits body and keeps readiness status', () => {
  assert.equal(invoke(health, 'HEAD').body, undefined);
  assert.equal(invoke(readiness, 'HEAD').statusCode, 503);
});
