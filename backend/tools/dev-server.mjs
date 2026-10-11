// 데모 전용 로컬 서버: backend/api/** 핸들러를 Vercel 파일 경로 규칙대로 띄운다. 배포용이 아니다.
// 사용: node backend/tools/dev-server.mjs [--port 3000] [--origin http://localhost:5173] [--weather kma|fake|down]
// 키는 ../_key에서 이 프로세스 환경으로만 읽고 출력하지 않는다. DB·Auth·Storage는 원격 Supabase를 쓴다.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { loadDemoEnv } from './lib/demo-env.mjs';

const args = Object.fromEntries(process.argv.slice(2).join(' ').split('--').filter(Boolean)
  .map(part => part.trim().split(/\s+/)).map(([k, v]) => [k, v ?? 'true']));
const port = Number(args.port ?? 3000);
const origins = (args.origin ?? 'http://localhost:5173').split(',');
let weatherMode = args.weather ?? 'kma';

const apiRoot = fileURLToPath(new URL('../api/', import.meta.url));
const workerModeFile = fileURLToPath(new URL('.fake-worker-mode', import.meta.url));
const demo = await loadDemoEnv();
// 백엔드는 날씨 제공자를 "정규화 JSON을 주는 HTTPS 어댑터"로 기대한다(계약 문제 기록 참고).
// 데모에서는 이 가상 주소로 오는 요청을 아래 KMA 어댑터가 받아 처리한다.
const WEATHER_ADAPTER = 'https://weather-adapter.demo.invalid/current';
const env = { ...process.env, ...demo.env, CORS_ALLOWED_ORIGINS: origins.join(','),
  WEATHER_PROVIDER_BASE_URL: WEATHER_ADAPTER, WEATHER_PROVIDER_API_KEY: 'demo-adapter-key' };
Object.assign(process.env, env); // process.env를 직접 읽는 모듈도 같은 값을 보게 한다(이 프로세스 안에서만)

// ---- KMA 초단기실황 어댑터 ----
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
async function weatherAdapter(url) {
  const lat = Number(url.searchParams.get('lat')); const lon = Number(url.searchParams.get('lon'));
  const validAt = url.searchParams.get('valid_at');
  const json = (status, body) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });
  if (weatherMode === 'down') return json(503, { error: 'demo_weather_down' });
  if (weatherMode === 'fake') {
    return json(200, { issued_at: new Date(Date.now() - 60000).toISOString(), valid_at: validAt, temperature_c: 18.5,
      feels_like_c: null, precipitation_probability: null, precipitation_type: 'none', humidity: 55, air_quality: null });
  }
  if (!demo.kma.baseUrl || !demo.kma.key) return json(503, { error: 'kma_not_configured' });
  // 초단기실황은 매시 40분 이후 제공 → 45분 전이면 한 시간 전 자료를 쓴다(KST).
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
    if (!Array.isArray(items)) return json(502, { error: 'kma_bad_response' });
    const value = Object.fromEntries(items.map(item => [item.category, Number(item.obsrValue)]));
    if (!Number.isFinite(value.T1H)) return json(502, { error: 'kma_missing_temperature' });
    const issued = new Date(Date.UTC(+baseDate.slice(0, 4), +baseDate.slice(4, 6) - 1, +baseDate.slice(6, 8), +baseTime.slice(0, 2) - 9));
    return json(200, { issued_at: issued.toISOString(), valid_at: validAt, temperature_c: value.T1H, feels_like_c: null,
      precipitation_probability: null, precipitation_type: PTY[value.PTY] ?? 'unknown',
      humidity: Number.isFinite(value.REH) ? value.REH : null, air_quality: null });
  } catch { return json(502, { error: 'kma_unreachable' }); }
}
const request = (input, init) => {
  const url = new URL(typeof input === 'string' || input instanceof URL ? input : input.url);
  if (url.origin + url.pathname === WEATHER_ADAPTER) {
    return weatherAdapter(url).then(async response => {
      console.log(`  ↳ weather adapter(${weatherMode}) ${response.status} ${(await response.clone().text()).slice(0, 160)}`);
      return response;
    });
  }
  return fetch(input, init).then(async response => {
    // 진단용: Supabase가 실패를 돌려주면 경로·코드·메시지만 로그에 남긴다(토큰·본문 값은 남기지 않음).
    if (!response.ok && response.status !== 404 && response.status !== 416) {
      const text = await response.clone().text().catch(() => '');
      let info = text.slice(0, 200); try { const j = JSON.parse(text); info = `${j.code ?? ''} ${j.message ?? j.error ?? ''}`; } catch { /* 원문 일부 */ }
      console.log(`  ↳ upstream ${response.status} ${init?.method ?? 'GET'} ${url.pathname} ${info}`);
    }
    return response;
  }, error => { console.log(`  ↳ upstream error ${url.pathname} ${error.message}`); throw error; });
};

// ---- Vercel 파일 경로 라우팅 ----
function scan(dir, prefix = []) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.isDirectory()) out.push(...scan(path.join(dir, entry.name), [...prefix, entry.name]));
    else if (entry.name.endsWith('.js')) {
      const base = entry.name.slice(0, -3); const segments = base === 'index' ? prefix : [...prefix, base];
      out.push({ file: path.join(dir, entry.name), segments });
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
async function load(route) {
  if (!handlers.has(route.file)) {
    const mod = await import(pathToFileURL(route.file).href);
    const handler = typeof mod.createHandler === 'function' ? mod.createHandler({ env, request }) : mod.default;
    handlers.set(route.file, { handler, rawBody: mod.config?.api?.bodyParser === false });
  }
  return handlers.get(route.file);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = []; req.on('data', c => chunks.push(c)); req.on('end', () => resolve(Buffer.concat(chunks))); req.on('error', reject);
  });
}

const server = http.createServer(async (req, res) => {
  const started = Date.now(); const url = new URL(req.url, `http://localhost:${port}`);
  res.status = code => { res.statusCode = code; return res; };
  res.json = body => { if (!res.getHeader('content-type')) res.setHeader('content-type', 'application/json; charset=utf-8'); res.end(JSON.stringify(body)); return res; };
  // 데모 제어: 날씨 장애 재현 등(로컬 전용)
  // 가짜 AI worker 모드(success|partial|fail [items] [labels]) — fake-ai-worker가 이 파일을 매 job마다 읽는다.
  if (url.pathname === '/__demo/worker-mode') {
    res.setHeader('Access-Control-Allow-Origin', origins[0]);
    const mode = url.searchParams.get('mode');
    if (mode && /^(success|partial|fail)( [1-6])?( [a-z,]+)?$/.test(mode)) fs.writeFileSync(workerModeFile, mode);
    let current = 'success 3'; try { current = fs.readFileSync(workerModeFile, 'utf8').trim(); } catch { /* 기본값 */ }
    return res.status(200).json({ mode: current });
  }
  if (url.pathname === '/__demo/weather') {
    res.setHeader('Access-Control-Allow-Origin', origins[0]); weatherMode = url.searchParams.get('mode') ?? weatherMode; return res.status(200).json({ weather: weatherMode }); }
  const route = routes.find(item => item.regex.test(url.pathname));
  if (!route) return res.status(404).json({ error: { code: 'NOT_FOUND' } });
  const match = route.regex.exec(url.pathname);
  req.query = Object.fromEntries(url.searchParams);
  route.names.forEach((name, i) => { req.query[name] = decodeURIComponent(match[i + 1]); });
  try {
    const { handler, rawBody } = await load(route);
    if (!rawBody) { const buf = await readBody(req); req.body = buf.length ? buf.toString('utf8') : undefined; }
    // 계약 문제 기록 #1: 백엔드 preflight가 Idempotency-Key 헤더를 허용하지 않아 브라우저에서 생성 요청이 막힌다.
    // 데모 서버에서만 허용 헤더에 추가한다.
    const setHeader = res.setHeader.bind(res);
    res.setHeader = (name, value) => setHeader(name, name.toLowerCase() === 'access-control-allow-headers' ? `${value}, Idempotency-Key` : value);
    await handler(req, res);
  } catch (error) {
    console.error('handler error', route.file, error?.message);
    if (!res.headersSent) res.status(500).json({ error: { code: 'DEV_SERVER_ERROR' } });
  } finally {
    console.log(`${req.method} ${url.pathname} → ${res.statusCode} (${Date.now() - started}ms)`);
  }
});
server.listen(port, () => console.log(`MAFICO dev server http://localhost:${port}  routes=${routes.length}  origin=${origins.join(',')}  weather=${weatherMode}`));
