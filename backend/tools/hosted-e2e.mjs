// hosted 1차 실측 도구: backend/api/** 핸들러를 로컬 Node 안에서 직접 호출해 원격 Supabase(Auth·RLS·Storage·Admin API)에 붙인다.
// 사용: node backend/tools/hosted-e2e.mjs [--json <결과 파일>]   (기준: backend/worklogs/2026-10-11_hosted_1차실측_기준.md)
// - 키는 ../_key(또는 MAFICO_KEY_DIR)에서 이 프로세스 환경으로만 읽는다. 키·비밀번호·JWT·서명 URL은 출력·저장하지 않는다.
// - 스키마를 바꾸지 않는다. DB 쓰기는 이 실행이 만든 테스트 사용자 범위만 한다. 끝나면(실패해도) 테스트 사용자·행·Storage 객체를 지운다.
// - AI_CALLBACK_HMAC_SECRET은 실행마다 임의 생성해 핸들러와 가짜 worker가 공유한다.
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { createHmac, randomBytes, randomUUID } from 'node:crypto';
import { createRequire } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { loadDemoEnv } from './lib/demo-env.mjs';

const require = createRequire(import.meta.url);
const { Client } = require('pg');
const argv = process.argv.slice(2);
const jsonOut = argv.includes('--json') ? argv[argv.indexOf('--json') + 1] : null;

// ---------- 환경 ----------
const demo = await loadDemoEnv();
const HMAC = randomBytes(32).toString('hex');
const WEATHER_ADAPTER = 'https://weather-adapter.e2e.invalid/current';
const env = { ...demo.env, AI_CALLBACK_HMAC_SECRET: HMAC, CORS_ALLOWED_ORIGINS: '',
  WEATHER_PROVIDER_BASE_URL: WEATHER_ADAPTER, WEATHER_PROVIDER_API_KEY: randomBytes(12).toString('hex') };
Object.assign(process.env, env);
const BASE = env.SUPABASE_URL;
const SECRET_VALUES = [env.SUPABASE_SECRET_KEY, env.SUPABASE_PUBLISHABLE_KEY, HMAC, demo.db?.password, demo.kma.key, demo.projectRef].filter(Boolean);
const service = { apikey: env.SUPABASE_SECRET_KEY, Authorization: `Bearer ${env.SUPABASE_SECRET_KEY}` };

// 출력 직전 마스킹: 알려진 비밀값, JWT, 서명 토큰, 프로젝트 ref.
function redact(text) {
  let out = String(text);
  for (const value of SECRET_VALUES) out = out.split(value).join('***');
  return out.replace(/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/g, '<jwt>')
    .replace(/token=[^&\s"']+/g, 'token=<redacted>').replace(/sb_(secret|publishable)_[A-Za-z0-9_-]+/g, '<key>');
}
const log = (...parts) => console.log(redact(parts.join(' ')));
const short = id => (typeof id === 'string' ? id.slice(0, 8) : String(id));

// ---------- KMA 정규화 어댑터(dev-server.mjs와 같은 규칙, 프로세스 안에서만) ----------
let weatherMode = 'kma';
function kmaGrid(lat, lon) {
  const RE = 6371.00877 / 5.0, DEG = Math.PI / 180, slat1 = 30 * DEG, slat2 = 60 * DEG, olon = 126 * DEG, olat = 38 * DEG;
  let sn = Math.tan(Math.PI * 0.25 + slat2 * 0.5) / Math.tan(Math.PI * 0.25 + slat1 * 0.5);
  sn = Math.log(Math.cos(slat1) / Math.cos(slat2)) / Math.log(sn);
  let sf = Math.tan(Math.PI * 0.25 + slat1 * 0.5); sf = Math.pow(sf, sn) * Math.cos(slat1) / sn;
  let ro = Math.tan(Math.PI * 0.25 + olat * 0.5); ro = RE * sf / Math.pow(ro, sn);
  let ra = Math.tan(Math.PI * 0.25 + lat * DEG * 0.5); ra = RE * sf / Math.pow(ra, sn);
  let theta = lon * DEG - olon; if (theta > Math.PI) theta -= 2 * Math.PI; if (theta < -Math.PI) theta += 2 * Math.PI; theta *= sn;
  return { nx: Math.floor(ra * Math.sin(theta) + 43 + 0.5), ny: Math.floor(ro - ra * Math.cos(theta) + 136 + 0.5) };
}
const PTY = { 0: 'none', 1: 'rain', 2: 'mixed', 3: 'snow', 5: 'rain', 6: 'mixed', 7: 'snow' };
const weatherNotes = [];
async function weatherAdapter(url) {
  const json = (status, body) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });
  const lat = Number(url.searchParams.get('lat')); const lon = Number(url.searchParams.get('lon')); const validAt = url.searchParams.get('valid_at');
  if (weatherMode === 'fake') return json(200, { issued_at: validAt, valid_at: validAt, temperature_c: 18.5,
    feels_like_c: null, precipitation_probability: null, precipitation_type: 'none', humidity: 55, air_quality: null });
  const kst = new Date(Date.now() + 9 * 3600000 - 45 * 60000);
  const baseDate = kst.toISOString().slice(0, 10).replaceAll('-', ''); const baseTime = `${String(kst.getUTCHours()).padStart(2, '0')}00`;
  const { nx, ny } = kmaGrid(lat, lon);
  const target = new URL(`${demo.kma.baseUrl.replace(/\/$/, '')}/getUltraSrtNcst`);
  for (const [k, v] of Object.entries({ serviceKey: demo.kma.key, pageNo: '1', numOfRows: '20', dataType: 'JSON',
    base_date: baseDate, base_time: baseTime, nx: String(nx), ny: String(ny) })) target.searchParams.set(k, v);
  try {
    const response = await fetch(target, { signal: AbortSignal.timeout(3500) });
    const body = await response.json();
    const items = body?.response?.body?.items?.item;
    if (!Array.isArray(items)) { weatherNotes.push(`kma_bad_response(${response.status})`); return json(502, { error: 'kma_bad_response' }); }
    const value = Object.fromEntries(items.map(item => [item.category, Number(item.obsrValue)]));
    if (!Number.isFinite(value.T1H)) { weatherNotes.push('kma_missing_temperature'); return json(502, { error: 'kma_missing_temperature' }); }
    const issued = new Date(Date.UTC(+baseDate.slice(0, 4), +baseDate.slice(4, 6) - 1, +baseDate.slice(6, 8), +baseTime.slice(0, 2) - 9));
    weatherNotes.push(`kma_ok T1H=${value.T1H}`);
    return json(200, { issued_at: issued.toISOString(), valid_at: validAt, temperature_c: value.T1H, feels_like_c: null,
      precipitation_probability: null, precipitation_type: PTY[value.PTY] ?? 'unknown', humidity: Number.isFinite(value.REH) ? value.REH : null, air_quality: null });
  } catch (error) { weatherNotes.push(`kma_unreachable(${error.name})`); return json(502, { error: 'kma_unreachable' }); }
}
// 진단: 핸들러가 받은 Supabase 4xx/5xx의 경로·코드·메시지(값 없는 스키마 오류 문구)만 모은다.
const upstreamErrors = [];
// shim: 원인을 확인한 결함을 우회해 뒤 단계를 계속 검증하기 위한 응답 정규화(제품 코드·DB는 그대로). 켜진 뒤의 결과는 RESULT에 shim 표시.
const shims = { validAtZ: false, signedUrlPrefix: false };
const signShapes = new Set();
const request = async (input, init) => {
  const url = new URL(typeof input === 'string' || input instanceof URL ? input : input.url);
  if (url.origin + url.pathname === WEATHER_ADAPTER) return weatherAdapter(url);
  let response = await fetch(input, init);
  if (url.origin === BASE && response.status === 200 && /^\/rest\/v1\/rpc\/(find|upsert|get)_weather_snapshot$/.test(url.pathname)) {
    const text = await response.text(); let body = null; try { body = JSON.parse(text); } catch { /* keep */ }
    if (body && typeof body.valid_at === 'string') signShapes.add(`weather.valid_at 형식=${body.valid_at.replace(/\d/g, 'n')}`);
    if (shims.validAtZ && body && typeof body.valid_at === 'string') body.valid_at = new Date(body.valid_at).toISOString();
    response = new Response(body ? JSON.stringify(body) : text, { status: 200, headers: response.headers });
  }
  if (url.origin === BASE && response.status === 200 && /^\/storage\/v1\/object\/sign\/[^/]+$/.test(url.pathname)) {
    const items = await response.json().catch(() => null);
    if (Array.isArray(items)) {
      const first = items.find(item => typeof item?.signedURL === 'string');
      signShapes.add(`sign 응답 signedURL 접두=${first ? first.signedURL.split('?')[0].split('/').slice(0, 4).join('/') : '(none)'} errors=${items.filter(i => i?.error).length}/${items.length}`);
      if (shims.signedUrlPrefix) for (const item of items) if (typeof item?.signedURL === 'string' && item.signedURL.startsWith('/object/')) item.signedURL = `/storage/v1${item.signedURL}`;
    }
    response = new Response(JSON.stringify(items), { status: 200, headers: { 'content-type': 'application/json' } });
  }
  if (response.status >= 400 && url.origin === BASE) {
    let info = '';
    try { const body = await response.clone().json(); info = `${body?.code ?? body?.error ?? ''} ${String(body?.message ?? body?.msg ?? '').slice(0, 160)} ${String(body?.details ?? '').slice(0, 120)} ${String(body?.hint ?? '').slice(0, 80)}`; }
    catch { info = '(non-json)'; }
    upstreamErrors.push(`${init?.method ?? 'GET'} ${url.pathname.replace(/[0-9a-f]{8}-[0-9a-f-]{27}/gi, m => `${m.slice(0, 8)}…`)} → ${response.status} ${info.trim()}`);
  }
  return response;
};
function flushUpstream() { const items = upstreamErrors.splice(0); for (const item of items) note(`upstream: ${item}`); for (const s of signShapes) note(`shape: ${s}`); signShapes.clear(); }

// ---------- 핸들러 라우팅(파일 경로 = URL) ----------
const apiRoot = fileURLToPath(new URL('../api/', import.meta.url));
function scan(dir, prefix = []) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.isDirectory()) out.push(...scan(path.join(dir, entry.name), [...prefix, entry.name]));
    else if (entry.name.endsWith('.js')) {
      const base = entry.name.slice(0, -3);
      out.push({ file: path.join(dir, entry.name), segments: base === 'index' ? prefix : [...prefix, base] });
    }
  }
  return out;
}
const routes = scan(apiRoot).map(route => {
  const names = [];
  const pattern = route.segments.map(segment => {
    const match = /^\[(\w+)\]$/.exec(segment); if (match) { names.push(match[1]); return '([^/]+)'; }
    return segment.replace(/[.*+?^${}()|\\]/g, '\\$&');
  }).join('/');
  return { ...route, names, regex: new RegExp(`^/api/${pattern}/?$`), dynamic: names.length };
}).sort((a, b) => a.dynamic - b.dynamic || b.segments.length - a.segments.length);
const handlers = new Map();
async function handlerFor(route) {
  if (!handlers.has(route.file)) {
    const mod = await import(pathToFileURL(route.file).href);
    handlers.set(route.file, typeof mod.createHandler === 'function' ? mod.createHandler({ env, request }) : mod.default);
  }
  return handlers.get(route.file);
}

const calls = [];
// 핸들러 직접 호출. 반환: { status, body, headers }. 본문은 메모리에만 두고 출력하지 않는다.
async function api(method, urlPath, { token, body, key, headers = {}, raw } = {}) {
  const url = new URL(urlPath, 'http://local');
  const route = routes.find(item => item.regex.test(url.pathname));
  if (!route) throw Error(`no route ${url.pathname}`);
  const match = route.regex.exec(url.pathname);
  const query = Object.fromEntries(url.searchParams);
  route.names.forEach((name, i) => { query[name] = decodeURIComponent(match[i + 1]); });
  const reqHeaders = { ...Object.fromEntries(Object.entries(headers).map(([k, v]) => [k.toLowerCase(), v])) };
  if (token) reqHeaders.authorization = `Bearer ${token}`;
  if (key) reqHeaders['idempotency-key'] = key;
  let req;
  if (raw) {
    req = { method, headers: reqHeaders, query, async *[Symbol.asyncIterator]() { yield raw; } };
  } else {
    if (body !== undefined) reqHeaders['content-type'] = 'application/json';
    req = { method, headers: reqHeaders, query, body: body === undefined ? undefined : JSON.stringify(body) };
  }
  const result = { status: 0, headers: {}, body: undefined };
  const res = {
    setHeader(name, value) { result.headers[name.toLowerCase()] = value; },
    getHeader(name) { return result.headers[name.toLowerCase()]; },
    status(code) { result.status = code; return res; },
    json(value) { result.body = value; return res; },
    end() { return res; }
  };
  const started = Date.now();
  await (await handlerFor(route))(req, res);
  calls.push({ method, path: url.pathname.replace(/[0-9a-f]{8}-[0-9a-f-]{27}/gi, m => `${short(m)}…`), status: result.status, ms: Date.now() - started,
    code: result.body?.error?.code });
  return result;
}

// ---------- 공통 도구 ----------
const results = [];
let current = null;
function section(id, title) { current = { id, title, checks: [], started: Date.now(), ms: 0, notes: [] }; results.push(current); log(`\n== ${id} ${title}`); }
function check(name, ok, detail = '') {
  if (!ok) flushUpstream(); else { upstreamErrors.splice(0); signShapes.clear(); }
  current.checks.push({ name, ok: Boolean(ok), detail: redact(detail) });
  log(`  [${ok ? 'PASS' : 'FAIL'}] ${name}${detail ? ` — ${detail}` : ''}`);
  return Boolean(ok);
}
function note(text) { current.notes.push(redact(text)); log(`  (note) ${text}`); }
function done() { current.ms = Date.now() - current.started; log(`  -- ${current.id} ${current.ms}ms`); }
const errCode = r => r.body?.error?.code ?? '';
const keyOf = label => `e2e-${label}-${randomUUID()}`;
const todayKst = () => new Date(Date.now() + 9 * 3600000).toISOString().slice(0, 10);

// 실제 PNG(8x8 단색) 생성.
function png(r, g, b, size = 8) {
  const crc = buf => { const v = zlib.crc32(buf); const out = Buffer.alloc(4); out.writeUInt32BE(v >>> 0); return out; };
  const chunk = (type, data) => { const len = Buffer.alloc(4); len.writeUInt32BE(data.length); const td = Buffer.concat([Buffer.from(type), data]); return Buffer.concat([len, td, crc(td)]); };
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(size, 0); ihdr.writeUInt32BE(size, 4); ihdr[8] = 8; ihdr[9] = 2; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
  const rows = []; for (let y = 0; y < size; y++) { rows.push(0); for (let x = 0; x < size; x++) rows.push(r, g, b); }
  return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(Buffer.from(rows))), chunk('IEND', Buffer.alloc(0))]);
}
async function putSigned(upload, bytes) {
  const response = await fetch(upload.url, { method: 'PUT', headers: { 'Content-Type': upload.headers?.['Content-Type'] ?? 'image/png' }, body: bytes });
  await response.arrayBuffer().catch(() => null);
  return response.status;
}

let db = null;
async function sql(text, params = []) {
  if (!db) { db = new Client({ ...demo.db, connectionTimeoutMillis: 15000 }); await db.connect(); }
  return (await db.query(text, params)).rows;
}

// ---------- Auth Admin ----------
const users = {}; // label -> { id, email, password, token }
async function createUser(label) {
  const email = `mafico-e2e-${Date.now().toString(36)}-${label}-${randomBytes(3).toString('hex')}@example.com`;
  const password = randomBytes(18).toString('base64url');
  const response = await fetch(`${BASE}/auth/v1/admin/users`, { method: 'POST', headers: { ...service, 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password, email_confirm: true }) });
  const body = await response.json().catch(() => null);
  if (response.ok && body?.id) users[label] = { id: body.id, email, password };
  return { status: response.status, id: body?.id };
}
async function login(label) {
  const u = users[label];
  const response = await fetch(`${BASE}/auth/v1/token?grant_type=password`, { method: 'POST',
    headers: { apikey: env.SUPABASE_PUBLISHABLE_KEY, 'Content-Type': 'application/json' }, body: JSON.stringify({ email: u.email, password: u.password }) });
  const body = await response.json().catch(() => null);
  if (response.ok && typeof body?.access_token === 'string') u.token = body.access_token;
  return response.status;
}
async function adminGetUser(id) {
  const response = await fetch(`${BASE}/auth/v1/admin/users/${id}`, { headers: service }); await response.arrayBuffer().catch(() => null); return response.status;
}
async function adminDeleteUser(id) {
  const response = await fetch(`${BASE}/auth/v1/admin/users/${id}`, { method: 'DELETE', headers: service }); await response.arrayBuffer().catch(() => null); return response.status;
}

// ---------- 가짜 AI worker ----------
// 전역 claim RPC는 다른 사용자의 대기 job도 집을 수 있으므로, 테스트 사용자 밖에 집힐 job이 있으면 RPC 대신 이 job만 SQL로 점유한다.
async function claimJob(jobId, testIds) {
  const others = await sql(`select count(*)::int n from public.analysis_jobs where not (user_id = any($1::uuid[])) and (
    (attempt<max_attempts and ((status='queued' and available_at<=now()) or (status='running' and lease_expires_at<now())))
    or (status='running' and lease_expires_at<now() and attempt>=max_attempts))`, [testIds]);
  if (others[0].n === 0) {
    const response = await fetch(`${BASE}/rest/v1/rpc/claim_analysis_job`, { method: 'POST', headers: { ...service, 'Content-Type': 'application/json' },
      body: JSON.stringify({ p_lease_seconds: 120 }) });
    const rows = await response.json().catch(() => null);
    if (!response.ok || !Array.isArray(rows)) return { error: `claim rpc ${response.status}` };
    const job = rows.find(row => row.id === jobId);
    if (!job) return { error: `claim rpc returned ${rows.length} job(s), not ours` };
    return { job, via: 'rpc' };
  }
  const rows = await sql(`update public.analysis_jobs set status='running',attempt=attempt+1,lease_token=gen_random_uuid(),
    lease_expires_at=now()+make_interval(secs=>120),progress=0 where id=$1 and status='queued' returning *`, [jobId]);
  return rows[0] ? { job: { ...rows[0], id: rows[0].id }, via: `sql(다른 사용자 대기 job ${others[0].n}건 → 전역 RPC 회피)` } : { error: 'sql claim 0 rows' };
}
async function serviceUpload(bucket, key, bytes, type = 'image/png') {
  const response = await fetch(`${BASE}/storage/v1/object/${bucket}/${key}`, { method: 'POST', headers: { ...service, 'Content-Type': type, 'x-upsert': 'true' }, body: bytes });
  await response.arrayBuffer().catch(() => null); return response.status;
}
async function sendCallback(job, payload) {
  const raw = Buffer.from(JSON.stringify(payload)); const ts = String(Math.floor(Date.now() / 1000));
  const signature = createHmac('sha256', HMAC).update(ts).update('.').update(raw).digest('hex');
  return api('POST', `/api/internal/analysis-jobs/${job.id}/result`, { raw, headers: { 'X-Worker-Timestamp': ts, 'X-Worker-Signature': signature, 'Content-Type': 'application/json' } });
}
const COLORS = { top: [30, 60, 200], bottom: [40, 40, 40], dress: [200, 40, 120], shoes: [240, 240, 240], outerwear: [120, 90, 60] };

// 사용자 한 명의 옷 등록 흐름: 배치 → 업로드 → complete → (고지 확인) → job → worker 콜백 → drafts
async function registerGarments(label, labels, { expectNoticeBlock = false, aestheticIds = [] } = {}) {
  const u = users[label]; const out = {};
  const image = png(90, 120, 160, 16);
  const batch = await api('POST', '/api/v1/garment-batches', { token: u.token, key: keyOf('batch'), body: { content_type: 'image/png', file_size: image.length } });
  check(`${label}: 배치 생성 201`, batch.status === 201, `status=${batch.status} ${errCode(batch)} batch=${short(batch.body?.batch?.id)}`);
  if (batch.status !== 201) return out;
  out.batchId = batch.body.batch.id; out.sourceKey = batch.body.object_key;
  if (label === 'A') {
    const early = await api('POST', `/api/v1/garment-batches/${out.batchId}/complete-upload`, { token: u.token, key: keyOf('complete') });
    check('H3-4 업로드 전 complete → 409 UPLOAD_NOT_FOUND', early.status === 409 && errCode(early) === 'UPLOAD_NOT_FOUND', `status=${early.status} ${errCode(early)}`);
    const refresh = await api('POST', `/api/v1/garment-batches/${out.batchId}/upload-url`, { token: u.token });
    check('H3-4 업로드 URL 재발급 200', refresh.status === 200 && typeof refresh.body?.url === 'string', `status=${refresh.status} ${errCode(refresh)}`);
  }
  const put = await putSigned(batch.body.upload, image);
  check(`${label}: 서명 URL로 원본 PUT`, put >= 200 && put < 300, `status=${put}`);
  const complete = await api('POST', `/api/v1/garment-batches/${out.batchId}/complete-upload`, { token: u.token, key: keyOf('complete') });
  check(`${label}: complete-upload 200 uploaded`, complete.status === 200 && complete.body?.status === 'uploaded', `status=${complete.status} ${errCode(complete)} batch.status=${complete.body?.status}`);
  if (expectNoticeBlock) {
    const blocked = await api('POST', `/api/v1/garment-batches/${out.batchId}/analysis-jobs`, { token: u.token, key: keyOf('job') });
    out.noticeBlock = check(`${label}: 고지 미동의 분석 403 AI_NOTICE_REQUIRED`, blocked.status === 403 && errCode(blocked) === 'AI_NOTICE_REQUIRED', `status=${blocked.status} ${errCode(blocked)}`);
    const accept = await api('PATCH', '/api/v1/me', { token: u.token, body: { ai_notice_accepted: true, training_consent: false } });
    check(`${label}: 고지 동의·학습 동의 false 저장`, accept.status === 200 && typeof accept.body?.ai_notice_accepted_at === 'string' && accept.body?.training_consent === false,
      `status=${accept.status} ${errCode(accept)} notice_at=${Boolean(accept.body?.ai_notice_accepted_at)} training=${accept.body?.training_consent}`);
  }
  const job = await api('POST', `/api/v1/garment-batches/${out.batchId}/analysis-jobs`, { token: u.token, key: keyOf('job') });
  check(`${label}: 분석 job 202`, job.status === 202, `status=${job.status} ${errCode(job)} job=${short(job.body?.id)} state=${job.body?.status}`);
  if (job.status !== 202) return out;
  out.jobId = job.body.id;
  // worker 점유
  const claimed = await claimJob(out.jobId, Object.values(users).map(item => item.id));
  check(`${label}: worker job 점유`, Boolean(claimed.job), claimed.error ?? `via=${claimed.via} attempt=${claimed.job?.attempt}`);
  if (!claimed.job) return out;
  const jobRow = claimed.job;
  // cutout 업로드(서버 키) — 실제 worker가 할 수 있는 방식
  const items = []; const keys = [];
  for (const [index, category] of labels.entries()) {
    const key = `${u.id}/${out.batchId}/cutouts/item-${index}.png`;
    const status = await serviceUpload('closet-private', key, png(...(COLORS[category] ?? [100, 100, 100])));
    if (status !== 200) { check(`${label}: cutout ${index} 업로드`, false, `status=${status}`); return out; }
    keys.push(key);
    const hex = '#' + (COLORS[category] ?? [100, 100, 100]).map(v => v.toString(16).padStart(2, '0')).join('').toUpperCase();
    items.push({ client_item_key: `item-${index}`, item_index: index, bbox: [0.1 * index, 0.1, 0.1 * index + 0.3, 0.9], mask_object_key: key,
      attributes: { category, color_hex: hex, pattern: null, ...(aestheticIds.length ? { aesthetic_scores: aestheticIds.map((id, i) => ({ aesthetic_id: id, score: i === 0 ? 0.9 : 0.4 })) } : {}) },
      confidence: 0.8 });
  }
  out.cutoutKeys = keys;
  const payload = eventId => ({ event_id: eventId, attempt: jobRow.attempt, status: 'succeeded', model_versions: { 'hosted-e2e-fake': 'v0' },
    items, errors: [], job_id: out.jobId, lease_token: jobRow.lease_token });
  // 1차: 서버 키로 올린 cutout 그대로(실제 worker 조건) 콜백
  const first = await sendCallback(jobRow, payload(randomUUID()));
  out.firstCallback = { status: first.status, code: errCode(first) };
  const ownerRows = await sql(`select count(*) filter (where owner_id is null)::int null_owner, count(*)::int n from storage.objects where bucket_id='closet-private' and name = any($1::text[])`, [keys]);
  note(`${label}: 서버 키 업로드 cutout owner_id null ${ownerRows[0].null_owner}/${ownerRows[0].n}, 1차 콜백 status=${first.status} ${errCode(first)}`);
  let final = first;
  if (first.status !== 200) {
    // 우회: 이 실행이 올린 테스트 사용자 cutout 경로만 owner를 사용자로 맞춘다(데모 fake-ai-worker와 같은 우회).
    await sql(`update storage.objects set owner=$1::uuid, owner_id=$1::text where bucket_id='closet-private' and name = any($2::text[])`, [u.id, keys]);
    final = await sendCallback(jobRow, payload(randomUUID()));
    note(`${label}: owner 우회 후 2차 콜백 status=${final.status} ${errCode(final)}`);
  }
  out.callbackOk = check(`${label}: HMAC 콜백 200 applied`, final.status === 200 && final.body?.applied === true, `status=${final.status} ${errCode(final)} applied=${final.body?.applied}`);
  if (!out.callbackOk) {
    // 우회(테스트 사용자 범위 데이터만): apply_analysis_result와 같은 쓰기를 owner 비교만 빼고 SQL로 재현해 이후 흐름을 계속 검증한다.
    await sql('begin');
    try {
      for (const item of items) {
        const size = Number((await sql(`select metadata->>'size' s from storage.objects where bucket_id='closet-private' and name=$1`, [item.mask_object_key]))[0]?.s);
        const asset = await sql(`insert into public.garment_assets(user_id,batch_id,kind,object_key,content_type,byte_size,verified_at)
          values($1,$2,'cutout',$3,'image/png',$4,now()) returning id`, [u.id, out.batchId, item.mask_object_key, size]);
        const six = ['outerwear', 'top', 'bottom', 'shoes', 'bag', 'accessory'].includes(item.attributes.category)
          ? item.attributes : { ...item.attributes, category: null, ai_category: item.attributes.category };
        const attrs = { ...six, client_item_key: item.client_item_key, bbox: item.bbox, confidence: item.confidence };
        await sql(`insert into public.garment_drafts(user_id,batch_id,job_id,item_index,asset_id,raw_prediction,model_version) values($1,$2,$3,$4,$5,$6::jsonb,'hosted-e2e-fake')`,
          [u.id, out.batchId, out.jobId, item.item_index, asset[0].id, JSON.stringify(attrs)]);
      }
      await sql(`update public.analysis_jobs set status='succeeded',progress=100,stage=null,result=$2::jsonb,error_code=null,lease_token=null,lease_expires_at=null,completed_at=now() where id=$1 and user_id=$3`,
        [out.jobId, JSON.stringify({ status: 'succeeded', item_count: items.length, model_versions: { 'hosted-e2e-fake': 'v0' }, errors: [] }), u.id]);
      await sql(`update public.garment_batches set status='review' where id=$1 and user_id=$2`, [out.batchId, u.id]);
      await sql('commit');
      out.emulated = true;
      note(`${label}: 콜백 실패로 apply_analysis_result 결과를 SQL로 재현(테스트 사용자 범위, owner 비교 제외) — 이후 단계는 우회 위에서 검증`);
    } catch (error) { await sql('rollback'); note(`${label}: 우회 실패 ${error.message}`); return out; }
  }
  // 잘못된 서명 거부
  const bad = await api('POST', `/api/internal/analysis-jobs/${out.jobId}/result`, { raw: Buffer.from('{}'), headers: { 'X-Worker-Timestamp': String(Math.floor(Date.now() / 1000)), 'X-Worker-Signature': '0'.repeat(64) } });
  check(`${label}: 잘못된 서명 401`, bad.status === 401, `status=${bad.status} ${errCode(bad)}`);
  const jobAfter = await api('GET', `/api/v1/analysis-jobs/${out.jobId}`, { token: u.token });
  check(`${label}: GET /analysis-jobs/{id} 200 succeeded`, jobAfter.status === 200 && jobAfter.body?.status === 'succeeded', `status=${jobAfter.status} ${errCode(jobAfter)} state=${jobAfter.body?.status}`);
  out.drafts = [];
  const drafts = await api('GET', `/api/v1/garment-batches/${out.batchId}/drafts`, { token: u.token });
  out.drafts = drafts.body?.items ?? [];
  check(`${label}: drafts ${labels.length}개 + 서명 이미지`, drafts.status === 200 && out.drafts.length === labels.length && out.drafts.every(d => d.image?.url),
    `status=${drafts.status} n=${out.drafts.length} images=${out.drafts.filter(d => d.image?.url).length}`);
  if (drafts.status === 200 && out.drafts.some(d => !d.image?.url) && !shims.signedUrlPrefix) {
    shims.signedUrlPrefix = true;
    note('shim S2 켬: Storage sign 응답 signedURL의 /object/ 상대경로 앞에 /storage/v1 붙임(제품 코드 수정 제안과 같은 효과)');
    const again = await api('GET', `/api/v1/garment-batches/${out.batchId}/drafts`, { token: u.token });
    out.drafts = again.body?.items ?? out.drafts;
    check(`${label}: drafts 서명 이미지 (shim S2)`, again.status === 200 && out.drafts.every(d => d.image?.url), `status=${again.status} images=${out.drafts.filter(d => d.image?.url).length}/${out.drafts.length}`);
  }
  return out;
}

// 서명 업로드 URL 발급이 Storage RLS로 막힐 때의 확인용 우회: 이미 만들어진 업로드 행의 경로로 사용자 JWT 직접 업로드.
async function directUserUpload(token, bucket, key, bytes) {
  const response = await fetch(`${BASE}/storage/v1/object/${bucket}/${key}`, { method: 'POST',
    headers: { apikey: env.SUPABASE_PUBLISHABLE_KEY, Authorization: `Bearer ${token}`, 'Content-Type': 'image/png' }, body: bytes });
  let info = ''; if (!response.ok) { const body = await response.json().catch(() => null); info = ` ${body?.error ?? ''} ${String(body?.message ?? '').slice(0, 100)}`; }
  return `${response.status}${info}`;
}

async function confirmAll(label, drafts, batchId) {
  const u = users[label];
  const versions = Object.fromEntries(drafts.map(d => [d.id, d.version]));
  return api('POST', `/api/v1/garment-batches/${batchId}/confirm`, { token: u.token, key: keyOf('confirm'), body: { draft_ids: drafts.map(d => d.id), draft_versions: versions } });
}

async function mediaUpload(label, purpose, bytes) {
  const u = users[label];
  const created = await api('POST', '/api/v1/media-uploads', { token: u.token, key: keyOf('media'), body: { purpose, content_type: 'image/png', file_size: bytes.length } });
  if (created.status !== 201) {
    flushUpstream();
    const row = (await sql(`select id, bucket_id, object_key from public.media_uploads where user_id=$1 and purpose=$2 and verified_at is null order by created_at desc limit 1`, [u.id, purpose]))[0];
    if (!row) return { created };
    const direct = await directUserUpload(u.token, row.bucket_id, row.object_key, bytes);
    let how = `사용자 JWT 직접 업로드=${direct}`;
    if (!direct.startsWith('200')) {
      // 2차 우회: 서버 키로 올리고 테스트 사용자 객체의 owner만 SQL로 맞춘다.
      const st = await serviceUpload(row.bucket_id, row.object_key, bytes);
      await sql(`update storage.objects set owner=$1::uuid, owner_id=$1::text where bucket_id=$2 and name=$3`, [u.id, row.bucket_id, row.object_key]);
      how += `, 서버 키 업로드+owner SQL=${st}`;
    }
    const complete = await api('POST', `/api/v1/media-uploads/${row.id}/complete-upload`, { token: u.token });
    note(`${label}: ${purpose} 서명 URL 발급 실패 → 우회(${how}), complete=${complete.status} ${errCode(complete)}`);
    return { created, workaround: true, direct, complete, id: complete.status === 200 ? row.id : null };
  }
  const put = await putSigned(created.body.upload, bytes);
  const complete = await api('POST', `/api/v1/media-uploads/${created.body.id}/complete-upload`, { token: u.token });
  return { created, put, complete, id: created.body.id };
}

// JSON 안에서 숫자 점수처럼 보이는 키 찾기
function scoreKeys(value, found = [], prefix = '') {
  if (Array.isArray(value)) value.forEach((item, i) => scoreKeys(item, found, `${prefix}[${i}]`));
  else if (value && typeof value === 'object') for (const [k, v] of Object.entries(value)) {
    if (/score|similar|percent|ratio/i.test(k) && typeof v === 'number') found.push(`${prefix}.${k}`);
    scoreKeys(v, found, `${prefix}.${k}`);
  }
  return found;
}

// ---------- 실행 ----------
const state = {};
const runStarted = Date.now();
try {
  // H1 스키마
  section('H1', '스키마(읽기 전용 SQL)');
  {
    const local = fs.readdirSync(fileURLToPath(new URL('../supabase/migrations/', import.meta.url))).filter(f => f.endsWith('.sql')).map(f => f.split('_')[0]).sort();
    const remote = (await sql('select version from supabase_migrations.schema_migrations order by version')).map(r => r.version);
    check('H1-1 원격 migration이 로컬과 일치', remote.length > 0 && JSON.stringify(remote) === JSON.stringify(local), `remote=${remote.length} local=${local.length} same=${JSON.stringify(remote) === JSON.stringify(local)}`);
    const tables = await sql(`select c.relname, c.relrowsecurity from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind in ('r','p') order by 1`);
    state.tables = tables.map(t => t.relname);
    check('H1-2 public 테이블 28개', tables.length === 28, `n=${tables.length}`);
    const noRls = tables.filter(t => !t.relrowsecurity).map(t => t.relname);
    check('H1-3 모든 public 테이블 RLS', noRls.length === 0, noRls.length ? `RLS 꺼짐: ${noRls.join(',')}` : 'all on');
    const buckets = await sql(`select id, public from storage.buckets where id = any($1) order by id`, [['closet-private', 'feed-private', 'profile-media', 'ootd-private']]);
    check('H1-4 버킷 4개 비공개', buckets.length === 4 && buckets.every(b => b.public === false), buckets.map(b => `${b.id}:${b.public ? 'public' : 'private'}`).join(','));
    const dup = await sql(`select p.proname, count(*)::int n from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' group by 1 having count(*)>1 order by 1`);
    const begin = await sql(`select pg_get_function_identity_arguments(p.oid) args from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='begin_my_recommendation'`);
    const ownerType = await sql(`select column_name, data_type from information_schema.columns where table_schema='storage' and table_name='objects' and column_name in ('owner','owner_id') order by 1`);
    note(`storage.objects 열 타입: ${ownerType.map(c => `${c.column_name}=${c.data_type}`).join(', ')}`);
    const grants = await sql(`select string_agg(column_name, ',' order by column_name) cols from information_schema.column_privileges where table_schema='public' and table_name='analysis_jobs' and grantee='authenticated' and privilege_type='SELECT'`);
    note(`authenticated의 analysis_jobs SELECT 허용 열: ${grants[0]?.cols}`);
    check('H1-5 함수 이름 중복 없음·begin_my_recommendation 1개', dup.length === 0 && begin.length === 1,
      `dup=${dup.map(d => `${d.proname}x${d.n}`).join(',') || 'none'} begin=${begin.length} args=${begin[0]?.args.split(',').length}`);
  }
  done();

  // H2 인증
  section('H2', '인증(Admin API·비밀번호 로그인·비로그인 차단)');
  {
    const a = await createUser('A'); const b = await createUser('B');
    check('H2-1 Admin API 사용자 2명 생성', Boolean(users.A && users.B), `A=${a.status}/${short(a.id)} B=${b.status}/${short(b.id)}`);
    if (!users.A || !users.B) throw Error('사용자 생성 실패');
    const la = await login('A'); const lb = await login('B');
    check('H2-2 비밀번호 로그인 JWT 획득', Boolean(users.A.token && users.B.token), `A=${la} B=${lb}`);
    const meA = await api('GET', '/api/v1/me', { token: users.A.token });
    check('H2-2 GET /me 200(프로필 자동 생성)', meA.status === 200 && meA.body?.id === users.A.id, `status=${meA.status} ${errCode(meA)} notice=${meA.body?.ai_notice_accepted_at} training=${meA.body?.training_consent}`);
    const anonMe = await api('GET', '/api/v1/me'); const anonG = await api('GET', '/api/v1/garments');
    const forged = await api('GET', '/api/v1/me', { token: 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.invalidsignature' });
    check('H2-3 비로그인·위조 토큰 401', anonMe.status === 401 && anonG.status === 401 && forged.status === 401, `me=${anonMe.status} garments=${anonG.status} forged=${forged.status}`);
  }
  done();

  // H3 사용자 A 유저플로우
  section('H3', '유저플로우 E2E(사용자 A)');
  {
    const A = users.A;
    const aes = await api('GET', '/api/v1/aesthetics');
    const list = aes.body?.items ?? aes.body?.aesthetics ?? (Array.isArray(aes.body) ? aes.body : []);
    state.aesthetics = list;
    check('H3-3 추구미 5종 조회', aes.status === 200 && list.length === 5, `status=${aes.status} n=${list.length}`);
    const [main, sub] = list;
    const pref = await api('PUT', '/api/v1/me/aesthetics', { token: A.token, body: { preferences: [{ aesthetic_id: main.id, role: 'main' }, { aesthetic_id: sub.id, role: 'sub' }] } });
    check('H3-3 메인1+보조1 저장', pref.status === 200 && pref.body?.preferences?.length === 2, `status=${pref.status} ${errCode(pref)} roles=${pref.body?.preferences?.map(p => `${p.role}:${p.weight}`).join(',')}`);
    state.main = main.id; state.sub = sub.id;

    const reg = await registerGarments('A', ['top', 'bottom', 'dress'], { expectNoticeBlock: true, aestheticIds: [main.id, sub.id] });
    state.A = reg;
    if (!reg.callbackOk && !reg.emulated) throw Error('A 분석 콜백 실패 — 이후 단계 미실행');
    const nullDraft = reg.drafts.find(d => d.current_attributes.category === null);
    check('H3-5 6종 밖 라벨(dress) → category null', Boolean(nullDraft) && reg.drafts.filter(d => d.current_attributes.category === null).length === 1,
      `categories=${reg.drafts.map(d => d.current_attributes.category).join(',')}`);
    const early = await confirmAll('A', reg.drafts, reg.batchId);
    check('H3-6 category null 상태 confirm 422', early.status === 422, `status=${early.status} ${errCode(early)}`);
    const patched = await api('PATCH', `/api/v1/garment-drafts/${nullDraft.id}`, { token: A.token, body: { expected_version: nullDraft.version, attributes: { category: 'shoes', note: 'e2e' } } });
    check('H3-6 draft 수정(shoes) 200', patched.status === 200 && patched.body?.current_attributes?.category === 'shoes', `status=${patched.status} ${errCode(patched)} v=${patched.body?.version}`);
    const drafts2 = reg.drafts.map(d => (d.id === nullDraft.id ? { ...d, version: patched.body?.version ?? d.version } : d));
    const confirmed = await confirmAll('A', drafts2, reg.batchId);
    state.Agarments = confirmed.body?.garments ?? [];
    check('H3-6 확정 201 garments 3벌', confirmed.status === 201 && state.Agarments.length === 3, `status=${confirmed.status} ${errCode(confirmed)} n=${state.Agarments.length} cats=${state.Agarments.map(g => g.category ?? g.attributes?.category).join(',')}`);
    const closet = await api('GET', '/api/v1/garments', { token: A.token });
    check('H3-6 옷장 조회 3벌·서명 이미지', closet.status === 200 && closet.body?.items?.length === 3, `status=${closet.status} n=${closet.body?.items?.length} images=${closet.body?.items?.filter(g => g.image?.url || g.images?.cutout?.url).length}`);
    const catOf = id => { const g = state.Agarments.find(x => x.id === id); return g?.attributes?.category ?? g?.category; };
    state.Atop = state.Agarments.find(g => catOf(g.id) === 'top')?.id; state.Abottom = state.Agarments.find(g => catOf(g.id) === 'bottom')?.id;

    // 날씨 + 추천
    const weather = await api('GET', '/api/v1/weather/current?region_code=seoul', { token: A.token });
    check('H3-7 날씨(region_code=seoul)', weather.status === 200, `status=${weather.status} ${errCode(weather)} temp=${weather.body?.temperature_c} stale=${weather.body?.is_stale} kma=${weatherNotes.at(-1) ?? '-'}`);
    if (weather.status !== 200) {
      if (!weatherNotes.some(n => n.startsWith('kma_ok'))) { note(`KMA 실패(${weatherNotes.join(';')}) → 가짜 날씨로 전환`); weatherMode = 'fake'; }
      shims.validAtZ = true;
      note('shim S1 켬: weather RPC 응답 valid_at을 toISOString() 형식으로 정규화(제품 코드 수정 제안과 같은 효과)');
      const again = await api('GET', '/api/v1/weather/current?region_code=seoul', { token: A.token });
      check('H3-7 날씨 (shim S1)', again.status === 200, `status=${again.status} ${errCode(again)} temp=${again.body?.temperature_c} stale=${again.body?.is_stale} source=${again.body?.source}`);
    }
    let reco = await api('POST', '/api/v1/recommendations', { token: A.token, key: keyOf('reco'), body: { location: { region_code: 'seoul' }, aesthetic_id: sub.id } });
    check('H3-7 추천 201·Chip=보조', reco.status === 201 && reco.body?.selected_aesthetic_id === sub.id && reco.body?.outfits?.length >= 1,
      `status=${reco.status} ${errCode(reco)} outfits=${reco.body?.outfits?.length} selected=${reco.body?.selected_aesthetic_id === sub.id ? 'sub' : short(reco.body?.selected_aesthetic_id)} shortfall=${(reco.body?.shortfall_reasons ?? []).join('|')} weather_stale=${reco.body?.weather?.is_stale}`);
    const badChip = await api('POST', '/api/v1/recommendations', { token: A.token, key: keyOf('reco'), body: { location: { region_code: 'seoul' }, aesthetic_id: list[4].id } });
    check('H3-7 선호에 없는 Chip 422', badChip.status === 422, `status=${badChip.status} ${errCode(badChip)}`);
    state.reco = reco.body;
    const outfit = reco.body?.outfits?.[0];
    const today = todayKst();
    if (outfit) {
      const accepted = await api('POST', `/api/v1/recommendations/${reco.body.id}/accept`, { token: A.token, key: keyOf('accept'), body: { outfit_id: outfit.id, worn_on: today } });
      state.ootd1 = accepted.body?.id;
      check('H3-8 추천 채택 → OOTD 201', accepted.status === 201 && accepted.body?.worn_on === today, `status=${accepted.status} ${errCode(accepted)} ootd=${short(accepted.body?.id)}`);
    } else check('H3-8 추천 채택', false, '추천 결과 없음(선행 실패)');

    const photo = await mediaUpload('A', 'ootd_photo', png(10, 200, 10, 12));
    check('H3-9 OOTD 사진 업로드·검증', photo.created?.status === 201 && photo.put >= 200 && photo.put < 300 && photo.complete?.status === 200,
      `create=${photo.created?.status} ${errCode(photo.created ?? {})} put=${photo.put} complete=${photo.complete?.status} ${errCode(photo.complete ?? {})}`);
    const ootd2 = await api('POST', '/api/v1/ootd', { token: A.token, key: keyOf('ootd'), body: { worn_on: today, garment_ids: [state.Atop, state.Abottom].filter(Boolean), rating: 4, note: 'e2e', photo_upload_id: photo.id } });
    state.ootd2 = ootd2.body?.id;
    check('H3-9 같은 날 두 번째 OOTD 201 + photo', ootd2.status === 201 && Boolean(ootd2.body?.photo?.url), `status=${ootd2.status} ${errCode(ootd2)} photo=${Boolean(ootd2.body?.photo?.url)}`);
    const cal = await api('GET', `/api/v1/ootd/calendar?from=${today}&to=${today}`, { token: A.token });
    const day = cal.body?.days?.find(d => d.date === today);
    check('H3-10 캘린더 오늘 count=2·대표 사진', cal.status === 200 && day?.count === 2 && Boolean(day?.photo?.url) && day?.representative_ootd_id === state.ootd2,
      `status=${cal.status} ${errCode(cal)} count=${day?.count} photo=${Boolean(day?.photo?.url)} rep=${day?.representative_ootd_id === state.ootd2 ? 'photo-entry' : short(day?.representative_ootd_id)}`);
    const saved = await api('POST', '/api/v1/saved-outfits', { token: A.token, key: keyOf('saved'), body: { title: 'e2e 보관', garment_ids: outfit?.garment_ids ?? [state.Atop, state.Abottom], source_recommendation_id: outfit?.id ?? null } });
    check('H3-11 보관함 저장 201', saved.status === 201, `status=${saved.status} ${errCode(saved)}`);

    // 피드
    const empty = await api('POST', '/api/v1/feed', { token: A.token, key: keyOf('post'), body: { caption: 'e2e', aesthetic_id: main.id, weather_code: 'clear', temperature_c: 18, visibility: 'private', garment_ids: [] } });
    check('H3-12 garment_ids 0개 422', empty.status === 422, `status=${empty.status} ${errCode(empty)}`);
    const post = await api('POST', '/api/v1/feed', { token: A.token, key: keyOf('post'), body: { caption: 'e2e 포스트', aesthetic_id: main.id, weather_code: 'clear', temperature_c: 18, visibility: 'private', garment_ids: [state.Atop, state.Abottom].filter(Boolean) } });
    state.post = post.body?.id;
    check('H3-12 포스트 생성 201(private, linked 2)', post.status === 201 && post.body?.linked_items?.length === 2, `status=${post.status} ${errCode(post)} linked=${post.body?.linked_items?.length}`);
    if (state.post) {
      const img = png(250, 200, 0, 12);
      const media = await api('POST', `/api/v1/feed/${state.post}/media`, { token: A.token, key: keyOf('fmedia'), body: { content_type: 'image/png', file_size: img.length } });
      const put = media.status === 201 ? await putSigned(media.body.upload, img) : 0;
      const fin = media.status === 201 ? await api('POST', `/api/v1/feed/${state.post}/media/${media.body.media_id}/complete-upload`, { token: A.token, key: keyOf('fcomplete') }) : { status: 0 };
      check('H3-12 피드 미디어 업로드·검증', media.status === 201 && put >= 200 && put < 300 && fin.status === 200, `create=${media.status} ${errCode(media)} put=${put} complete=${fin.status} ${errCode(fin)}`);
      if (media.status !== 201) {
        const row = (await sql('select id, object_key from public.feed_media where post_id=$1 and user_id=$2 and verified_at is null order by position desc limit 1', [state.post, A.id]))[0];
        if (row) {
          let direct = await directUserUpload(A.token, 'feed-private', row.object_key, img);
          if (!direct.startsWith('200')) {
            const st = await serviceUpload('feed-private', row.object_key, img);
            await sql(`update storage.objects set owner=$1::uuid, owner_id=$1::text where bucket_id='feed-private' and name=$2`, [A.id, row.object_key]);
            direct += `, 서버 키 업로드+owner SQL=${st}`;
          }
          const fin2 = await api('POST', `/api/v1/feed/${state.post}/media/${row.id}/complete-upload`, { token: A.token, key: keyOf('fcomplete') });
          note(`피드 미디어 서명 URL 발급 실패 → 우회(사용자 JWT 직접 업로드)=${direct}, complete=${fin2.status} ${errCode(fin2)}`);
          if (fin2.status !== 200) flushUpstream();
        }
      }
      const pub = await api('PATCH', `/api/v1/feed/${state.post}`, { token: A.token, body: { visibility: 'public' } });
      check('H3-12 공개 전환 200', pub.status === 200 && pub.body?.visibility === 'public', `status=${pub.status} ${errCode(pub)} visibility=${pub.body?.visibility}`);
    }
    const stats = await api('GET', '/api/v1/closet/statistics', { token: A.token });
    const topCount = stats.body?.wear_counts?.find(w => w.garment_id === state.Atop)?.count;
    check('H3-13 통계 200·착용 횟수 반영', stats.status === 200 && topCount >= 1, `status=${stats.status} ${errCode(stats)} top_wear=${topCount} unworn=${stats.body?.unworn_30_days?.length}`);
    check('H3-13 top_aesthetic 값 존재', stats.status === 200 && stats.body?.top_aesthetic !== null, `top_aesthetic=${stats.body?.top_aesthetic ? stats.body.top_aesthetic.code : 'null'} totals=${stats.body?.aesthetic_totals?.length}`);
    if (stats.body?.top_aesthetic === null) {
      // 보조 확인: 점수 행을 테스트 사용자 옷에 직접 넣으면 hosted SQL 집계가 동작하는지
      const scoreCount = await sql('select count(*)::int n from public.garment_aesthetic_scores where user_id=$1', [A.id]);
      note(`A의 garment_aesthetic_scores 행 ${scoreCount[0].n}개(콜백 aesthetic_scores를 보냈지만 확정 시 저장 경로 없음)`);
      await sql(`insert into public.garment_aesthetic_scores(user_id,garment_id,aesthetic_id,score,model_version)
        select $1::uuid, g.id, $2::uuid, 0.9, 'hosted-e2e' from public.garments g where g.user_id=$1 on conflict do nothing`, [A.id, main.id]);
      const stats2 = await api('GET', '/api/v1/closet/statistics', { token: A.token });
      note(`보조 확인: 점수 행 직접 삽입 후 top_aesthetic=${stats2.body?.top_aesthetic?.aesthetic_id === main.id ? 'main' : stats2.body?.top_aesthetic ? 'other' : 'null'} status=${stats2.status}`);
    }
  }
  done();

  // H4 사용자 B
  section('H4', '사용자 B(격리·공개 피드·좋아요·따라입기)');
  {
    const A = users.A; const B = users.B;
    // 격리: API
    const g = await api('GET', `/api/v1/garments/${state.Atop}`, { token: B.token });
    const d = await api('GET', `/api/v1/garment-batches/${state.A.batchId}/drafts`, { token: B.token });
    const bt = await api('GET', `/api/v1/garment-batches/${state.A.batchId}`, { token: B.token });
    const o = await api('GET', `/api/v1/ootd/${state.ootd2}`, { token: B.token });
    const j = await api('GET', `/api/v1/analysis-jobs/${state.A.jobId}`, { token: B.token });
    const r = await api('GET', `/api/v1/recommendations/${state.reco?.id}`, { token: B.token });
    check('H4-1 B→A API 조회 차단', [g, d, bt, o, j, r].every(x => x.status >= 400 && x.status < 500),
      `garment=${g.status} drafts=${d.status} batch=${bt.status} ootd=${o.status} job=${j.status} reco=${r.status}`);
    // 격리: PostgREST 직접
    const direct = {};
    for (const [table, col, id] of [['garments', 'id', state.Atop], ['garment_drafts', 'batch_id', state.A.batchId], ['ootd_entries', 'id', state.ootd2],
      ['media_uploads', 'user_id', A.id], ['garment_assets', 'user_id', A.id], ['profiles', 'id', A.id], ['saved_outfits', 'user_id', A.id]]) {
      const response = await fetch(`${BASE}/rest/v1/${table}?select=*&${col}=eq.${id}`, { headers: { apikey: env.SUPABASE_PUBLISHABLE_KEY, Authorization: `Bearer ${B.token}` } });
      const rows = await response.json().catch(() => null);
      direct[table] = Array.isArray(rows) ? rows.length : `${response.status}`;
    }
    check('H4-1 B→A PostgREST 직접 select 0행', Object.values(direct).every(v => v === 0 || (typeof v === 'string' && v.startsWith('4'))), JSON.stringify(direct));
    // 격리: Storage 직접
    const photoKey = (await sql('select photo_object_key k from public.ootd_entries where id=$1', [state.ootd2]))[0]?.k;
    const storage = {};
    for (const [bucket, key] of [['ootd-private', photoKey], ['closet-private', state.A.sourceKey], ['closet-private', state.A.cutoutKeys?.[0]]]) {
      if (!key) { storage[bucket] = 'nokey'; continue; }
      const response = await fetch(`${BASE}/storage/v1/object/authenticated/${bucket}/${key}`, { headers: { apikey: env.SUPABASE_PUBLISHABLE_KEY, Authorization: `Bearer ${B.token}` } });
      await response.arrayBuffer().catch(() => null);
      const sign = await fetch(`${BASE}/storage/v1/object/sign/${bucket}/${key}`, { method: 'POST', headers: { apikey: env.SUPABASE_PUBLISHABLE_KEY, Authorization: `Bearer ${B.token}`, 'Content-Type': 'application/json' }, body: '{"expiresIn":60}' });
      await sign.arrayBuffer().catch(() => null);
      storage[`${bucket}:${key === photoKey ? 'photo' : key === state.A.sourceKey ? 'source' : 'cutout'}`] = `get=${response.status},sign=${sign.status}`;
    }
    check('H4-1 B→A Storage 직접 읽기·서명 차단', Object.values(storage).every(v => /get=4\d\d,sign=4\d\d/.test(v)), JSON.stringify(storage));
    // 소유자 A는 자기 사진을 읽을 수 있는지(대조군)
    const own = await fetch(`${BASE}/storage/v1/object/authenticated/ootd-private/${photoKey}`, { headers: { apikey: env.SUPABASE_PUBLISHABLE_KEY, Authorization: `Bearer ${A.token}` } });
    await own.arrayBuffer().catch(() => null);
    note(`대조군: A 본인 OOTD 사진 직접 GET=${own.status}`);

    // 공개 피드
    const feed = await api('GET', '/api/v1/feed?limit=50', { token: B.token });
    const seen = feed.body?.items?.find(p => p.id === state.post);
    check('H4-2 B 공개 피드에 A 포스트', feed.status === 200 && Boolean(seen), `status=${feed.status} ${errCode(feed)} items=${feed.body?.items?.length} found=${Boolean(seen)}`);
    const detail = await api('GET', `/api/v1/feed/${state.post}`, { token: B.token });
    const keys = [...new Set((detail.body?.linked_items ?? []).flatMap(item => Object.keys(item)))].sort();
    const leak = [state.Atop, state.Abottom, state.A.batchId, state.A.sourceKey].filter(v => v && JSON.stringify(detail.body ?? {}).includes(v));
    check('H4-2 linked_items는 id·position·category만, A 옷 id·경로 비노출', detail.status === 200 && JSON.stringify(keys) === JSON.stringify(['category', 'id', 'position']) && leak.length === 0,
      `status=${detail.status} keys=${keys.join(',')} cats=${detail.body?.linked_items?.map(i => i.category).join(',')} leaks=${leak.length} media=${detail.body?.media?.length}`);
    const like = await api('PUT', `/api/v1/feed/${state.post}/like`, { token: B.token });
    const like2 = await api('PUT', `/api/v1/feed/${state.post}/like`, { token: B.token });
    const likes = await api('GET', '/api/v1/me/likes', { token: B.token });
    const after = await api('GET', `/api/v1/feed/${state.post}`, { token: B.token });
    check('H4-3 좋아요 204(멱등)·아카이브·like_count 1', like.status === 204 && like2.status === 204 && likes.body?.items?.some(p => p.id === state.post) && after.body?.like_count === 1 && after.body?.liked_by_me === true,
      `put=${like.status}/${like2.status} likes=${likes.status}:${likes.body?.items?.length} count=${after.body?.like_count} mine=${after.body?.liked_by_me}`);

    // B 옷 등록 → 따라입기
    const pref = await api('PUT', '/api/v1/me/aesthetics', { token: B.token, body: { preferences: [{ aesthetic_id: state.main, role: 'main' }] } });
    note(`B 추구미 저장 ${pref.status}`);
    const notice = await api('PATCH', '/api/v1/me', { token: B.token, body: { ai_notice_accepted: true } });
    note(`B 고지 동의 ${notice.status}`);
    const regB = await registerGarments('B', ['top', 'bottom'], { aestheticIds: [state.main] });
    state.B = regB;
    if (regB.callbackOk || regB.emulated) {
      const conf = await confirmAll('B', regB.drafts, regB.batchId);
      state.Bgarments = conf.body?.garments ?? [];
      check('H4-4 B 옷 2벌 확정', conf.status === 201 && state.Bgarments.length === 2, `status=${conf.status} ${errCode(conf)}`);
    }
    const mimic = await api('POST', '/api/v1/mimic-jobs', { token: B.token, key: keyOf('mimic'), body: { post_id: state.post } });
    check('H4-4 따라입기 생성 202', mimic.status === 202, `status=${mimic.status} ${errCode(mimic)} state=${mimic.body?.status}`);
    if (mimic.body?.id) {
      const res = await api('GET', `/api/v1/mimic-jobs/${mimic.body.id}`, { token: B.token });
      const numeric = scoreKeys(res.body);
      const matched = (res.body?.matches ?? []).filter(m => m.garment_id);
      check('H4-4 결과 등급만(숫자 점수 없음)', res.status === 200 && ['succeeded', 'no_match'].includes(res.body?.status) && numeric.length === 0 &&
        (res.body?.status !== 'succeeded' || ['high', 'medium', 'low'].includes(res.body?.grade)),
        `status=${res.status} state=${res.body?.status} grade=${res.body?.grade} item_grades=${(res.body?.matches ?? []).map(m => m.grade).join(',')} matched=${matched.length} numeric_keys=${numeric.join(',') || 'none'} coverage=${typeof res.body?.coverage}`);
      if (matched.length) {
        const save = await api('POST', '/api/v1/saved-outfits', { token: B.token, key: keyOf('saved'), body: { title: 'e2e 따라입기', garment_ids: matched.map(m => m.garment_id) } });
        check('H4-5 따라입기 결과 보관함 저장 201', save.status === 201, `status=${save.status} ${errCode(save)} n=${matched.length}`);
      } else check('H4-5 따라입기 결과 보관함 저장', false, '매칭 없음');
    }
  }
  done();

  // H5 탈퇴
  section('H5', '탈퇴(DELETE /me)');
  {
    const ids = [users.A.id, users.B.id];
    const before = await sql(`select count(*)::int n from storage.objects where split_part(name,'/',1) = any($1::text[])`, [ids]);
    state.objectsBefore = before[0].n;
    for (const label of ['A', 'B']) {
      const res = await api('DELETE', '/api/v1/me', { token: users[label].token, key: keyOf('delete') });
      check(`H5-1 ${label} DELETE /me 202`, res.status === 202 && res.body?.status === 'deletion_pending', `status=${res.status} ${errCode(res)}`);
    }
    const counts = await countRows(ids);
    const nonzero = Object.entries(counts).filter(([, n]) => n > 0);
    check('H5-2 public 관련 행 0', nonzero.length === 0, nonzero.length ? JSON.stringify(Object.fromEntries(nonzero)) : `검사 테이블 ${Object.keys(counts).length}개 모두 0`);
    const queue = await sql(`select count(*)::int n from public.storage_cleanup_queue where split_part(object_key,'/',1) = any($1::text[])`, [ids]);
    check('H5-3 Storage 정리 대기열 적재', queue[0].n >= state.objectsBefore && queue[0].n > 0, `queue=${queue[0].n} storage_objects=${state.objectsBefore}`);
    const authRows = await sql('select count(*)::int n from auth.users where id = any($1::uuid[])', [ids]);
    const ga = await adminGetUser(ids[0]); const gb = await adminGetUser(ids[1]);
    check('H5-4 auth 사용자 삭제', authRows[0].n === 0 && ga === 404 && gb === 404, `auth.users=${authRows[0].n} admin_get=${ga}/${gb}`);
    const reuse = await api('GET', '/api/v1/me', { token: users.A.token });
    note(`탈퇴 후 남은 A 토큰으로 GET /me=${reuse.status} ${errCode(reuse)}`);
  }
  done();
} catch (error) {
  if (current) { check('예외', false, error?.message ?? String(error)); done(); }
  else log('예외', error?.message);
} finally {
  await cleanup();
}

async function countRows(ids) {
  const columns = await sql(`select table_name, column_name from information_schema.columns where table_schema='public' and column_name in ('user_id','id','job_id','post_id','batch_id','author_id','actor_id','owner_id')`);
  const jobIds = [state.A?.jobId, state.B?.jobId].filter(Boolean); const postIds = [state.post].filter(Boolean); const batchIds = [state.A?.batchId, state.B?.batchId].filter(Boolean);
  const out = {};
  const byTable = new Map(); for (const c of columns) { if (!byTable.has(c.table_name)) byTable.set(c.table_name, new Set()); byTable.get(c.table_name).add(c.column_name); }
  for (const [table, cols] of byTable) {
    const where = []; const params = [];
    const add = (col, values) => { if (values.length) { params.push(values); where.push(`${col}::text = any($${params.length}::text[])`); } };
    for (const col of ['user_id', 'author_id', 'actor_id', 'owner_id']) if (cols.has(col)) add(col, ids);
    if (table === 'profiles') add('id', ids);
    if (cols.has('job_id')) add('job_id', jobIds);
    if (cols.has('post_id')) add('post_id', postIds);
    if (cols.has('batch_id')) add('batch_id', batchIds);
    if (!where.length) continue;
    out[table] = (await sql(`select count(*)::int n from public.${table} where ${where.join(' or ')}`, params))[0].n;
  }
  return out;
}

async function cleanup() {
  section('H6', '정리(테스트 사용자·행·Storage 객체)');
  const ids = Object.values(users).map(u => u.id).filter(Boolean);
  try {
    if (!ids.length) { check('H6 정리 대상 없음', true); return; }
    // 남은 사용자: 데이터 purge 후 auth 삭제
    for (const id of ids) {
      const exists = (await sql('select count(*)::int n from public.profiles where id=$1', [id]))[0].n;
      if (exists) {
        const response = await fetch(`${BASE}/rest/v1/rpc/purge_account_data`, { method: 'POST', headers: { ...service, 'Content-Type': 'application/json' }, body: JSON.stringify({ p_user_id: id }) });
        await response.arrayBuffer().catch(() => null); note(`잔여 프로필 ${short(id)} purge=${response.status}`);
      }
      const status = await adminGetUser(id);
      if (status !== 404) note(`잔여 auth ${short(id)} 삭제=${await adminDeleteUser(id)}`);
    }
    // Storage 객체 삭제(Storage API, 서버 키). 정리 worker가 아직 없으므로 테스트 경로만 직접 지운다.
    const objects = await sql(`select bucket_id, name from storage.objects where split_part(name,'/',1) = any($1::text[])`, [ids]);
    const byBucket = new Map(); for (const o of objects) { if (!byBucket.has(o.bucket_id)) byBucket.set(o.bucket_id, []); byBucket.get(o.bucket_id).push(o.name); }
    for (const [bucket, names] of byBucket) {
      const response = await fetch(`${BASE}/storage/v1/object/${bucket}`, { method: 'DELETE', headers: { ...service, 'Content-Type': 'application/json' }, body: JSON.stringify({ prefixes: names }) });
      await response.arrayBuffer().catch(() => null); note(`Storage ${bucket} 객체 ${names.length}개 삭제=${response.status}`);
    }
    const queue = await sql(`delete from public.storage_cleanup_queue where split_part(object_key,'/',1) = any($1::text[]) returning id`, [ids]);
    note(`대기열 행 ${queue.length}개 삭제(테스트 경로만)`);
    // 확인
    const left = await countRows(ids);
    const nonzero = Object.entries(left).filter(([, n]) => n > 0);
    const objs = (await sql(`select count(*)::int n from storage.objects where split_part(name,'/',1) = any($1::text[])`, [ids]))[0].n;
    const q = (await sql(`select count(*)::int n from public.storage_cleanup_queue where split_part(object_key,'/',1) = any($1::text[])`, [ids]))[0].n;
    const au = (await sql('select count(*)::int n from auth.users where id = any($1::uuid[])', [ids]))[0].n;
    check('H6 남은 데이터 0', nonzero.length === 0 && objs === 0 && q === 0 && au === 0,
      `public=${nonzero.length ? JSON.stringify(Object.fromEntries(nonzero)) : 0} storage=${objs} queue=${q} auth=${au}`);
  } catch (error) {
    check('H6 정리 예외', false, error?.message ?? String(error));
  } finally {
    done();
    await db?.end().catch(() => {});
    const summary = { started_at: new Date(runStarted).toISOString(), total_ms: Date.now() - runStarted, weather: weatherNotes,
      sections: results.map(s => ({ id: s.id, title: s.title, ms: s.ms, pass: s.checks.every(c => c.ok), checks: s.checks, notes: s.notes })),
      calls };
    if (jsonOut) fs.writeFileSync(jsonOut, redact(JSON.stringify(summary, null, 2)));
    log(`\n총 ${summary.total_ms}ms, 섹션: ${summary.sections.map(s => `${s.id}=${s.pass ? 'PASS' : 'FAIL'}(${s.ms}ms)`).join(' ')}`);
  }
}
