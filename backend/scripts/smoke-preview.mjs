const args = process.argv.slice(2);
const execute = args.includes('--execute');

function option(name) {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : undefined;
}

const plan = [
  { name: 'health', path: '/api/health', auth: false, expected: 200 },
  { name: 'aesthetics', path: '/api/aesthetics', auth: false, expected: 200 },
  { name: 'me', path: '/api/v1/me', auth: true, expected: 200 }
];

if (!execute) {
  console.log(JSON.stringify({
    mode: 'dry-run',
    network_used: false,
    checks: plan,
    execute_with: 'node scripts/smoke-preview.mjs --execute --base-url <https-preview-root>',
    token_source: 'MAFICO_SMOKE_TOKEN environment variable (never printed)'
  }, null, 2));
  process.exit(0);
}

const rawBase = option('--base-url');
let base;
try {
  base = new URL(rawBase);
  if (base.protocol !== 'https:' || base.username || base.password || base.search || base.hash) throw Error();
} catch {
  console.error('A credential-free HTTPS --base-url is required.');
  process.exit(2);
}
const token = process.env.MAFICO_SMOKE_TOKEN;
if (!token) {
  console.error('MAFICO_SMOKE_TOKEN must be set for the authenticated smoke check.');
  process.exit(2);
}

let failed = false;
for (const check of plan) {
  let response;
  try {
    response = await fetch(new URL(check.path, base), {
      method: 'GET',
      headers: check.auth ? { Authorization: `Bearer ${token}` } : {},
      redirect: 'error',
      signal: AbortSignal.timeout(8000)
    });
  } catch {
    console.log(JSON.stringify({ check: check.name, ok: false, error: 'NETWORK_OR_REDIRECT_ERROR' }));
    failed = true;
    continue;
  }
  const ok = response.status === check.expected;
  console.log(JSON.stringify({ check: check.name, ok, status: response.status, request_id_present: response.headers.has('x-request-id') }));
  if (!ok) failed = true;
}
if (failed) process.exitCode = 1;
