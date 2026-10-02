import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

async function fixture(name) {
  return JSON.parse(await readFile(new URL(`./fixtures/${name}`, import.meta.url), 'utf8'));
}

test('getMe success fixture is visibly synthetic and matches the response allowlist', async () => {
  const value = await fixture('get-me.success.json');
  assert.match(value.fixture_id, /^fixture-/);
  assert.equal(value.operation_id, 'getMe');
  assert.equal(value.status, 200);
  assert.deepEqual(Object.keys(value.body).sort(), [
    'default_tpo', 'display_name', 'id', 'onboarding_completed', 'preferences', 'timezone'
  ]);
  assert.match(value.body.id, /^[0-9a-f-]{36}$/);
  assert.ok(value.body.preferences.length <= 3);
});

test('getMe error fixture uses the shared safe error envelope', async () => {
  const value = await fixture('get-me.auth-error.json');
  assert.match(value.fixture_id, /^fixture-/);
  assert.equal(value.operation_id, 'getMe');
  assert.equal(value.status, 401);
  assert.deepEqual(Object.keys(value.body.error).sort(), ['code', 'message', 'request_id', 'retryable']);
});

test('G1 fixtures remain synthetic and match the account response allowlists', async () => {
  const success = JSON.parse(await readFile(new URL('./fixtures/g1-account.success.json', import.meta.url), 'utf8'));
  const failure = JSON.parse(await readFile(new URL('./fixtures/g1-account.validation-error.json', import.meta.url), 'utf8'));
  assert.match(success.fixture_id, /^fixture-/);
  assert.deepEqual(Object.keys(success.profile).sort(), [
    'default_tpo', 'display_name', 'id', 'onboarding_completed', 'preferences', 'timezone'
  ]);
  assert.deepEqual(Object.keys(success.onboarding).sort(), ['completed', 'knows_aesthetic', 'tutorial_seen']);
  assert.match(failure.fixture_id, /^fixture-/);
  assert.equal(failure.status, 422);
  assert.deepEqual(Object.keys(failure.body.error).sort(), ['code', 'message', 'request_id', 'retryable']);
});

test('G2 garment fixture exposes only the public closet projection', async () => {
  const garment = JSON.parse(await readFile(new URL('./fixtures/g2-garment.success.json', import.meta.url), 'utf8'));
  assert.match(garment.fixture_id, /^fixture-/);
  assert.deepEqual(Object.keys(garment).sort(), [
    'attributes', 'created_at', 'fixture_id', 'id', 'image', 'original_image', 'updated_at', 'version'
  ]);
  assert.deepEqual(Object.keys(garment.attributes).sort(), ['category', 'note', 'subcategory']);
  assert.deepEqual(Object.keys(garment.image).sort(), ['expires_at', 'url']);
  assert.equal(JSON.stringify(garment).includes('object_key'), false);
  assert.equal(JSON.stringify(garment).includes('user_id'), false);
});

test('G3 batch fixture pins the signed upload method and public fields', async () => {
  const value = await fixture('g3-batch-created.success.json');
  assert.match(value.fixture_id, /^fixture-/);
  assert.deepEqual(Object.keys(value).sort(), ['batch', 'fixture_id', 'object_key', 'upload']);
  assert.deepEqual(Object.keys(value.batch).sort(), ['created_at', 'id', 'status']);
  assert.deepEqual(Object.keys(value.upload).sort(), ['expires_at', 'headers', 'method', 'url']);
  assert.equal(value.upload.method, 'PUT');
  assert.equal(value.upload.headers['Content-Type'], 'image/jpeg');
  assert.equal(JSON.stringify(value).includes('authorization'), false);
});

test('G4 analysis job fixture exposes only the safe polling projection', async () => {
  const value = await fixture('g4-analysis-job.success.json');
  assert.match(value.fixture_id, /^fixture-/);
  assert.deepEqual(Object.keys(value).sort(), [
    'attempt', 'batch_id', 'created_at', 'error', 'fixture_id', 'id', 'max_attempts',
    'progress', 'retryable', 'stage', 'status', 'updated_at'
  ]);
  assert.equal(JSON.stringify(value).includes('lease'), false);
  assert.equal(JSON.stringify(value).includes('result_payload'), false);
  assert.equal(JSON.stringify(value).includes('error_code'), false);
});

test('G5 recommendation fixture is template-grounded and hides internal payloads', async () => {
  const value = await fixture('g5-recommendation.success.json');
  assert.match(value.fixture_id, /^fixture-/);
  assert.equal(value.status, 'ready');
  assert.equal(value.outfits[0].explanation_source, 'template');
  assert.deepEqual(Object.keys(value.weather).sort(), [
    'air_quality', 'feels_like_c', 'fetched_at', 'grid_x', 'grid_y', 'humidity', 'id', 'is_stale',
    'issued_at', 'precipitation_probability', 'precipitation_type', 'source', 'temperature_c', 'valid_at'
  ]);
  assert.equal(JSON.stringify(value).includes('preference_snapshot'), false);
  assert.equal(JSON.stringify(value).includes('object_key'), false);
});
