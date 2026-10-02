import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { validateManifest } from '../scripts/validate-dev-seed.mjs';

async function manifest() {
  return JSON.parse(await readFile(new URL('../fixtures/dev-seed.fixture.json', import.meta.url), 'utf8'));
}

test('development seed manifest is offline, synthetic and internally consistent', async () => {
  const result = validateManifest(await manifest());
  assert.deepEqual(result, {
    fixture_id: 'fixture-dev-seed-v1',
    taxonomy_items: 5,
    profiles: 1,
    permitted_image_metadata: 1,
    network_used: false,
    database_used: false,
    sql_emitted: false
  });
});

test('development seed validator rejects credential-shaped fields and final-looking taxonomy', async () => {
  const withSecret = structuredClone(await manifest());
  withSecret.profiles[0].access_token = 'not-even-a-real-token';
  assert.throws(() => validateManifest(withSecret), /forbidden key/);

  const withPath = structuredClone(await manifest());
  withPath.permitted_image_metadata[0].local_path = 'private/image.png';
  assert.throws(() => validateManifest(withPath), /forbidden key/);

  const withUrl = structuredClone(await manifest());
  withUrl.permitted_image_metadata[0].source_url = 'https://example.invalid/image.png';
  assert.throws(() => validateManifest(withUrl), /forbidden key/);

  const finalLooking = structuredClone(await manifest());
  finalLooking.taxonomy.status = 'final';
  assert.throws(() => validateManifest(finalLooking), /explicitly non-final/);
});
