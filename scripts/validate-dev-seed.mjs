import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const FORBIDDEN_KEYS = new Set([
  'password', 'access_token', 'refresh_token', 'authorization', 'secret', 'secret_key',
  'api_key', 'service_role_key', 'email', 'url', 'path', 'file_path'
]);
const SUSPICIOUS_VALUE = /(eyJ[A-Za-z0-9_-]{10,}\.|https:\/\/[a-z0-9]{20}\.supabase\.co|(?:sk|sb_secret)_[A-Za-z0-9_-]{8,})/i;

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function forbiddenKey(key) {
  const normalized = key.toLowerCase();
  return FORBIDDEN_KEYS.has(normalized) ||
    /(^|_)(password|secret|token|authorization|api_key|service_role_key)(_|$)/.test(normalized) ||
    /(^|_)(url|path)$/.test(normalized);
}

function inspectForSecrets(value, location = '$') {
  if (Array.isArray(value)) return value.forEach((item, index) => inspectForSecrets(item, `${location}[${index}]`));
  if (value && typeof value === 'object') {
    for (const [key, nested] of Object.entries(value)) {
      assert(!forbiddenKey(key), `forbidden key at ${location}.${key}`);
      inspectForSecrets(nested, `${location}.${key}`);
    }
    return;
  }
  if (typeof value === 'string') assert(!SUSPICIOUS_VALUE.test(value), `suspicious value at ${location}`);
}

function validTimezone(value) {
  try { new Intl.DateTimeFormat('en-US', { timeZone: value }).format(); return true; }
  catch { return false; }
}

export function validateManifest(manifest) {
  assert(manifest && typeof manifest === 'object' && !Array.isArray(manifest), 'manifest must be an object');
  inspectForSecrets(manifest);
  assert(manifest.schema_version === 1, 'unsupported schema_version');
  assert(/^fixture-/.test(manifest.fixture_id), 'fixture_id must start with fixture-');
  assert(manifest.environment === 'disposable-local-only', 'environment must be disposable-local-only');
  assert(manifest.taxonomy?.status === 'placeholder-not-final', 'taxonomy must be explicitly non-final');
  assert(/^fixture-/.test(manifest.taxonomy?.version), 'taxonomy version must start with fixture-');
  assert(Array.isArray(manifest.taxonomy?.items) && manifest.taxonomy.items.length === 5, 'exactly five fixture styles are required');

  const aestheticIds = new Set();
  const aestheticCodes = new Set();
  for (const item of manifest.taxonomy.items) {
    assert(UUID.test(item.id), 'invalid aesthetic fixture id');
    assert(/^fixture_style_0[1-5]$/.test(item.code), 'fixture style code must use the reserved pattern');
    assert(/^Fixture Style 0[1-5]$/.test(item.label), 'fixture style label must be visibly synthetic');
    assert(/not a product taxonomy decision/i.test(item.definition), 'fixture definition must disclaim taxonomy status');
    assert(!aestheticIds.has(item.id) && !aestheticCodes.has(item.code), 'duplicate fixture aesthetic');
    aestheticIds.add(item.id);
    aestheticCodes.add(item.code);
  }

  assert(Array.isArray(manifest.profiles) && manifest.profiles.length > 0, 'at least one fixture profile is required');
  const profileIds = new Set();
  for (const profile of manifest.profiles) {
    assert(UUID.test(profile.id) && !profileIds.has(profile.id), 'invalid or duplicate fixture profile id');
    profileIds.add(profile.id);
    assert(/^Fixture User /.test(profile.display_name), 'profile display name must be visibly synthetic');
    assert(validTimezone(profile.timezone), 'profile timezone must be a valid IANA timezone');
    assert(profile.onboarding && [true, false, null].includes(profile.onboarding.knows_aesthetic), 'invalid knows_aesthetic fixture');
    assert(typeof profile.onboarding.tutorial_seen === 'boolean' && typeof profile.onboarding.completed === 'boolean', 'invalid onboarding booleans');
    assert(Array.isArray(profile.preferences) && profile.preferences.length >= 1 && profile.preferences.length <= 3, 'fixture preferences must contain 1-3 items');
    const preferenceIds = new Set();
    let total = 0;
    for (const preference of profile.preferences) {
      assert(aestheticIds.has(preference.aesthetic_id) && !preferenceIds.has(preference.aesthetic_id), 'invalid or duplicate preference aesthetic');
      assert(typeof preference.weight === 'number' && preference.weight > 0 && preference.weight <= 1, 'invalid preference weight');
      preferenceIds.add(preference.aesthetic_id);
      total += preference.weight;
    }
    assert(Math.abs(total - 1) <= 0.0001, 'preference weights must sum to one');
  }

  assert(Array.isArray(manifest.permitted_image_metadata) && manifest.permitted_image_metadata.length > 0, 'permitted image metadata is required');
  const imageIds = new Set();
  for (const image of manifest.permitted_image_metadata) {
    assert(UUID.test(image.id) && !imageIds.has(image.id), 'invalid or duplicate image metadata id');
    imageIds.add(image.id);
    assert(profileIds.has(image.owner_profile_id), 'image metadata owner must be a fixture profile');
    assert(['synthetic', 'team-created'].includes(image.source_kind), 'unsupported image source_kind');
    assert(/^fixture-permission-/.test(image.permission_record), 'fixture permission record is required');
    assert(image.metadata_only === true && image.contains_person === false, 'only person-free metadata-only fixtures are allowed');
    assert(typeof image.inference_testing_allowed === 'boolean', 'inference testing permission must be explicit');
    assert(image.training_allowed === false && image.redistribution_allowed === false, 'training and redistribution must remain disabled');
  }

  return {
    fixture_id: manifest.fixture_id,
    taxonomy_items: aestheticIds.size,
    profiles: profileIds.size,
    permitted_image_metadata: imageIds.size,
    network_used: false,
    database_used: false,
    sql_emitted: false
  };
}

async function main() {
  const project = resolve(fileURLToPath(new URL('..', import.meta.url)));
  const manifest = JSON.parse(await readFile(resolve(project, 'fixtures/dev-seed.fixture.json'), 'utf8'));
  console.log(JSON.stringify(validateManifest(manifest), null, 2));
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main().catch(error => { console.error(error.message); process.exitCode = 1; });
}
