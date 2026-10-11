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
// 날씨: kma(기본) = 백엔드 lib의 내장 KMA(WEATHER_PROVIDER=kma, 10-11 수정분).
// fake/down = 이 서버의 가상 어댑터로 고정 날씨·장애를 재현한다(시연용). /__demo/weather?mode= 로 실행 중 전환.
const WEATHER_ADAPTER = 'https://weather-adapter.demo.invalid/current';
const env = { ...process.env, ...demo.env, CORS_ALLOWED_ORIGINS: origins.join(',') };
function applyWeatherMode() {
  if (weatherMode === 'kma') Object.assign(env, { WEATHER_PROVIDER: 'kma', WEATHER_PROVIDER_BASE_URL: demo.kma.baseUrl ?? '', WEATHER_PROVIDER_API_KEY: demo.kma.key ?? '' });
  else Object.assign(env, { WEATHER_PROVIDER: 'adapter', WEATHER_PROVIDER_BASE_URL: WEATHER_ADAPTER, WEATHER_PROVIDER_API_KEY: 'demo-adapter-key' });
}
applyWeatherMode();
Object.assign(process.env, env); // process.env를 직접 읽는 모듈도 같은 값을 보게 한다(이 프로세스 안에서만)

// ---- 가상 날씨 어댑터(fake/down) ----
async function weatherAdapter(url) {
  const json = (status, body) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });
  if (weatherMode === 'down') return json(503, { error: 'demo_weather_down' });
  return json(200, { issued_at: new Date(Date.now() - 60000).toISOString(), valid_at: url.searchParams.get('valid_at'), temperature_c: 18.5,
    feels_like_c: null, precipitation_probability: null, precipitation_type: 'none', humidity: 55, air_quality: null });
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
    res.setHeader('Access-Control-Allow-Origin', origins[0]); const m = url.searchParams.get('mode'); if (['kma', 'fake', 'down'].includes(m)) { weatherMode = m; applyWeatherMode(); } return res.status(200).json({ weather: weatherMode }); }
  const route = routes.find(item => item.regex.test(url.pathname));
  if (!route) return res.status(404).json({ error: { code: 'NOT_FOUND' } });
  const match = route.regex.exec(url.pathname);
  req.query = Object.fromEntries(url.searchParams);
  route.names.forEach((name, i) => { req.query[name] = decodeURIComponent(match[i + 1]); });
  try {
    const { handler, rawBody } = await load(route);
    if (!rawBody) { const buf = await readBody(req); req.body = buf.length ? buf.toString('utf8') : undefined; }
    await handler(req, res);
  } catch (error) {
    console.error('handler error', route.file, error?.message);
    // 핸들러가 던지면 CORS 헤더 없이 끝나 브라우저에는 네트워크 오류로 보인다 → 허용 origin이면 붙여서 오류 봉투를 보여 준다.
    if (!res.headersSent) {
      if (origins.includes(req.headers.origin)) res.setHeader('Access-Control-Allow-Origin', req.headers.origin);
      res.status(500).json({ error: { code: 'DEV_SERVER_ERROR', message: `백엔드 핸들러 오류: ${error?.message ?? ''}`.slice(0, 200), retryable: false } });
    }
  } finally {
    console.log(`${req.method} ${url.pathname} → ${res.statusCode} (${Date.now() - started}ms)`);
  }
});
server.listen(port, () => console.log(`MAFICO dev server http://localhost:${port}  routes=${routes.length}  origin=${origins.join(',')}  weather=${weatherMode}`));
