// 데모 전용 가짜 AI worker. 실제 모델이 아니다. 개발 환경에서만 쓴다.
// 대기 중인 분석 job을 claim → 원본을 격자로 잘라 cutout 업로드 → HMAC 서명 callback을 로컬 dev 서버로 보낸다.
//
// 사용: node backend/tools/fake-ai-worker.mjs [--watch] [--mode success|partial|fail] [--items 3]
//        [--labels top,bottom,shoes] [--api http://localhost:3000] [--delay 2500]
//  - success: items개 모두 성공. labels에 6종 밖 라벨(예: dress)을 넣으면 category=null 초안이 된다.
//  - partial: 마지막 한 벌을 실패로 보고(partial_failed).
//  - fail: MODEL_UNAVAILABLE로 실패 → 앱에서 "다시 시도"가 가능해진다.
//  모드는 실행 중에도 backend/tools/.fake-worker-mode 파일(한 줄: success|partial|fail [items] [labels])로 바꿀 수 있다.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { createHmac, randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { loadDemoEnv } from './lib/demo-env.mjs';

const argv = process.argv.slice(2);
const opt = (name, fallback) => { const i = argv.indexOf(`--${name}`); return i >= 0 && argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[i + 1] : fallback; };
const watch = argv.includes('--watch');
const api = opt('api', 'http://localhost:3000');
const delay = Number(opt('delay', '2500'));
const modeFile = fileURLToPath(new URL('.fake-worker-mode', import.meta.url));
const cropScript = fileURLToPath(new URL('lib/crop.py', import.meta.url));
const ROTATION = ['top', 'bottom', 'shoes', 'outerwear', 'bag', 'accessory'];

const demo = await loadDemoEnv();
const { SUPABASE_URL: base, SUPABASE_SECRET_KEY: secret, AI_CALLBACK_HMAC_SECRET: hmac } = demo.env;
const service = { apikey: secret, Authorization: `Bearer ${secret}` };

function currentMode() {
  let line = '';
  try { line = fs.readFileSync(modeFile, 'utf8').trim(); } catch { /* 파일 없으면 인자 사용 */ }
  const [mode, items, labels] = line ? line.split(/\s+/) : [];
  return {
    mode: mode || opt('mode', 'success'),
    items: Math.min(6, Math.max(1, Number(items || opt('items', '3')))),
    labels: (labels || opt('labels', '')).split(',').filter(Boolean)
  };
}

async function rpc(name, body) {
  const response = await fetch(`${base}/rest/v1/rpc/${name}`, { method: 'POST', headers: { ...service, 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  if (!response.ok) throw Error(`${name} ${response.status} ${(await response.text()).slice(0, 200)}`);
  return response.json();
}

async function sourceAsset(batchId) {
  const url = new URL(`${base}/rest/v1/garment_assets`);
  url.searchParams.set('select', 'object_key,content_type'); url.searchParams.set('batch_id', `eq.${batchId}`); url.searchParams.set('kind', 'eq.source');
  const rows = await (await fetch(url, { headers: service })).json();
  if (!Array.isArray(rows) || !rows[0]) throw Error('source asset not found');
  return rows[0];
}

async function upload(key, bytes) {
  const response = await fetch(`${base}/storage/v1/object/closet-private/${key}`, { method: 'POST',
    headers: { ...service, 'Content-Type': 'image/jpeg', 'x-upsert': 'true' }, body: bytes });
  if (!response.ok) throw Error(`upload ${response.status} ${(await response.text()).slice(0, 200)}`);
}

// 추구미 점수(N4, 10-11): 옷마다 한 추구미를 높게 준다. 확정 시 garment_aesthetic_scores로 저장돼 추천·통계에 쓰인다.
// 실제 모델 점수가 아니라 데모용 값이다.
let aestheticIds = null;
async function aestheticScores(seed) {
  if (!aestheticIds) {
    const rows = await (await fetch(`${base}/rest/v1/aesthetics?select=id&active=eq.true&order=code`, { headers: service })).json();
    aestheticIds = Array.isArray(rows) ? rows.map(row => row.id) : [];
  }
  return aestheticIds.map((id, i) => ({ aesthetic_id: id, score: i === seed % aestheticIds.length ? 0.85 : 0.2 }));
}

async function callback(job, payload) {
  const raw = Buffer.from(JSON.stringify(payload)); const ts = String(Math.floor(Date.now() / 1000));
  const signature = createHmac('sha256', hmac).update(ts).update('.').update(raw).digest('hex');
  const response = await fetch(`${api}/api/internal/analysis-jobs/${job.id}/result`, { method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-Worker-Timestamp': ts, 'X-Worker-Signature': signature }, body: raw });
  return { status: response.status, body: await response.json().catch(() => null) };
}

async function process1(job) {
  const { mode, items: count, labels } = currentMode();
  console.log(`[job ${job.id.slice(0, 8)}] claim attempt=${job.attempt} mode=${mode} items=${count}`);
  const common = { event_id: randomUUID(), attempt: job.attempt, model_versions: { 'fake-worker': 'demo-0' }, job_id: job.id, lease_token: job.lease_token };
  if (delay) await new Promise(resolve => setTimeout(resolve, delay));
  if (mode === 'fail') {
    const result = await callback(job, { ...common, status: 'failed', items: [], errors: [{ code: 'MODEL_UNAVAILABLE', message: '데모: 모델 사용 불가를 흉내 냅니다.', client_item_key: null }] });
    return console.log(`[job ${job.id.slice(0, 8)}] failed callback → ${result.status}`);
  }
  const source = await sourceAsset(job.batch_id);
  const download = await fetch(`${base}/storage/v1/object/closet-private/${source.object_key}`, { headers: service });
  if (!download.ok) throw Error(`download ${download.status}`);
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mafico-worker-'));
  const srcPath = path.join(dir, 'source'); fs.writeFileSync(srcPath, Buffer.from(await download.arrayBuffer()));
  const crop = spawnSync('python', ['-I', cropScript, srcPath, dir, String(count)], { encoding: 'utf8' });
  if (crop.status !== 0) throw Error(`crop failed: ${crop.stderr.slice(0, 300)}`);
  const boxes = JSON.parse(crop.stdout);
  const failIndex = mode === 'partial' && count > 1 ? count - 1 : -1;
  const items = [];
  for (let i = 0; i < count; i++) {
    if (i === failIndex) continue;
    const key = `${job.user_id}/${job.batch_id}/cutouts/item-${i}.jpg`;
    await upload(key, fs.readFileSync(path.join(dir, `item-${i}.jpg`)));
    items.push({ client_item_key: `item-${i}`, item_index: i, bbox: boxes[i].bbox, mask_object_key: key,
      attributes: { category: labels[i] ?? ROTATION[i % ROTATION.length], color_hex: boxes[i].color_hex, pattern: null,
        aesthetic_scores: await aestheticScores(parseInt(job.batch_id.slice(0, 4), 16) + i) },
      confidence: Math.round((0.72 + 0.05 * (i % 4)) * 100) / 100 });
  }
  const errors = failIndex >= 0 ? [{ code: 'SEGMENTATION_FAILED', message: '데모: 한 벌 분리에 실패했다고 보고합니다.', client_item_key: `item-${failIndex}` }] : [];
  const result = await callback(job, { ...common, status: errors.length ? 'partial_failed' : 'succeeded', items, errors });
  fs.rmSync(dir, { recursive: true, force: true });
  console.log(`[job ${job.id.slice(0, 8)}] ${errors.length ? 'partial_failed' : 'succeeded'} items=${items.length} callback → ${result.status}${result.status !== 200 ? ' ' + JSON.stringify(result.body) : ''}`);
}

async function tick() {
  const jobs = await rpc('claim_analysis_job', { p_lease_seconds: 120 });
  for (const job of jobs) {
    try { await process1(job); } catch (error) { console.error(`[job ${job.id.slice(0, 8)}] error: ${error.message}`); }
  }
  return jobs.length;
}

console.log(`fake-ai-worker ${watch ? 'watching' : 'once'} → callback ${api}  mode=${JSON.stringify(currentMode())}`);
if (!watch) { const n = await tick(); console.log(`processed ${n}`); }
else for (;;) { try { await tick(); } catch (error) { console.error('claim error:', error.message); } await new Promise(r => setTimeout(r, 2000)); }
