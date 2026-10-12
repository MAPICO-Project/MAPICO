// 데모 전용: 데모 계정을 만들고, 실제 API(로컬 dev 서버)로 유저플로우를 끝까지 한 번 실행해 시연용 데이터를 채운다.
// 같은 실행이 백엔드 E2E 점검도 겸한다. 샘플 이미지는 도형 그림이며 실제 사용자 데이터가 아니다.
// 사용: (dev-server 실행 중) node backend/tools/demo-seed.mjs --password <데모 비밀번호> [--api http://localhost:3000] [--only users]
// 계정: new@mafico.dev(신규 — 온보딩 시연), demo@mafico.dev(준비된 옷장·기록), friend@mafico.dev(피드 작성자)
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { loadDemoEnv } from './lib/demo-env.mjs';

const argv = process.argv.slice(2);
const opt = (name, fallback) => { const i = argv.indexOf(`--${name}`); return i >= 0 ? argv[i + 1] : fallback; };
const password = opt('password');
const api = `${opt('api', 'http://localhost:3000')}/api/v1`;
if (!password || password.length < 8) { console.error('--password <8자 이상> 이 필요합니다.'); process.exit(1); }
const demo = await loadDemoEnv();
const { SUPABASE_URL: base, SUPABASE_PUBLISHABLE_KEY: publishable, SUPABASE_SECRET_KEY: secret } = demo.env;
const tools = fileURLToPath(new URL('.', import.meta.url));
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'mafico-seed-'));

const USERS = {
  new: { email: 'new@mafico.dev' },
  demo: { email: 'demo@mafico.dev', name: '데모 사용자', main: 'minimal', sub: ['casual'] },
  friend: { email: 'friend@mafico.dev', name: '패션친구', main: 'casual', sub: ['y2k', 'grunge'] }
};

async function ensureUser(email) {
  const response = await fetch(`${base}/auth/v1/admin/users`, { method: 'POST',
    headers: { apikey: secret, Authorization: `Bearer ${secret}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password, email_confirm: true }) });
  if (response.ok) return 'created';
  const text = await response.text();
  if (/already|exists|registered/i.test(text)) return 'exists';
  throw Error(`create ${email} ${response.status} ${text.slice(0, 160)}`);
}
async function signIn(email) {
  const response = await fetch(`${base}/auth/v1/token?grant_type=password`, { method: 'POST',
    headers: { apikey: publishable, 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password }) });
  const body = await response.json();
  if (!response.ok) throw Error(`login ${email} ${response.status} ${body.error_description ?? body.msg ?? ''}`);
  return body.access_token;
}

function client(token) {
  return async function call(method, url, body, { idem = false, expect } = {}) {
    const headers = { Authorization: `Bearer ${token}` };
    if (body !== undefined) headers['Content-Type'] = 'application/json';
    if (idem) headers['Idempotency-Key'] = `seed-${randomUUID()}`;
    const response = await fetch(`${api}${url}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
    const data = response.status === 204 ? null : await response.json().catch(() => null);
    if (expect ? response.status !== expect : !response.ok) throw Error(`${method} ${url} → ${response.status} ${JSON.stringify(data?.error ?? data).slice(0, 300)}`);
    return data;
  };
}
async function putSigned(upload, file) {
  const bytes = fs.readFileSync(file);
  const response = await fetch(upload.url, { method: upload.method, headers: upload.headers, body: bytes });
  if (!response.ok) throw Error(`signed upload ${response.status} ${(await response.text()).slice(0, 200)}`);
}
function image(args, name) {
  const out = path.join(tmp, name);
  const result = spawnSync('python', ['-I', path.join(tools, 'lib/sample-image.py'), args[0], out, ...args.slice(1)], { encoding: 'utf8' });
  if (result.status !== 0) throw Error(result.stderr);
  return out;
}
function runWorker(labels) {
  fs.writeFileSync(path.join(tools, '.fake-worker-mode'), `success ${labels.length} ${labels.join(',')}`);
  const result = spawnSync('node', [path.join(tools, 'fake-ai-worker.mjs'), '--delay', '0', '--api', api.replace(/\/api\/v1$/, '')], { encoding: 'utf8' });
  fs.rmSync(path.join(tools, '.fake-worker-mode'), { force: true });
  process.stdout.write(result.stdout.split('\n').filter(l => l.includes('[job')).map(l => `    worker ${l}\n`).join(''));
  if (result.status !== 0) throw Error(result.stderr);
}

async function registerCloset(call, items) {
  const file = image(['flatlay', items.map(([k, c]) => `${k}:${c}`).join(',')], `flatlay-${randomUUID()}.jpg`);
  const created = await call('POST', '/garment-batches', { content_type: 'image/jpeg', file_size: fs.statSync(file).size }, { idem: true });
  await putSigned(created.upload, file);
  await call('POST', `/garment-batches/${created.batch.id}/complete-upload`, undefined, { idem: true });
  const job = await call('POST', `/garment-batches/${created.batch.id}/analysis-jobs`, undefined, { idem: true, expect: 202 });
  // 상주 worker(--watch)가 있으면 그쪽이 처리한다. 5초 안에 시작되지 않으면 한 번 실행용 worker를 직접 돌린다.
  fs.writeFileSync(path.join(tools, '.fake-worker-mode'), `success ${items.length} ${items.map(([k]) => k).join(',')}`);
  let after = job;
  for (let i = 0; i < 40 && ['queued', 'running'].includes(after.status); i++) {
    if (i === 10 && after.status === 'queued') runWorker(items.map(([k]) => k));
    await new Promise(r => setTimeout(r, 500));
    after = await call('GET', `/analysis-jobs/${job.id}`);
  }
  fs.rmSync(path.join(tools, '.fake-worker-mode'), { force: true });
  if (!['succeeded', 'partial_failed'].includes(after.status)) throw Error(`analysis ended ${after.status}`);
  const drafts = (await call('GET', `/garment-batches/${created.batch.id}/drafts`)).items;
  const confirmed = await call('POST', `/garment-batches/${created.batch.id}/confirm`, {
    draft_ids: drafts.map(d => d.id), draft_versions: Object.fromEntries(drafts.map(d => [d.id, d.version])) }, { idem: true });
  return confirmed.garments;
}

async function setupProfile(call, user, aesthetics) {
  await call('PATCH', '/me', { display_name: user.name, ai_notice_accepted: true });
  const id = code => aesthetics.find(a => a.code === code).id;
  await call('PUT', '/me/aesthetics', { preferences: [{ aesthetic_id: id(user.main), role: 'main' }, ...user.sub.map(c => ({ aesthetic_id: id(c), role: 'sub' }))] });
  await call('PUT', '/me/onboarding', { knows_aesthetic: true, tutorial_seen: true, completed: true });
}

async function ootdPhoto(call, colors) {
  const file = image(['look', ...colors], `look-${randomUUID()}.jpg`);
  const created = await call('POST', '/media-uploads', { purpose: 'ootd_photo', content_type: 'image/jpeg', file_size: fs.statSync(file).size }, { idem: true });
  await putSigned(created.upload, file);
  await call('POST', `/media-uploads/${created.id}/complete-upload`);
  return { id: created.id, file };
}
function day(offset) { const d = new Date(Date.now() + 9 * 3600000); d.setUTCDate(d.getUTCDate() + offset); return d.toISOString().slice(0, 10); }

const step = msg => console.log(`• ${msg}`);
for (const user of Object.values(USERS)) step(`${user.email}: ${await ensureUser(user.email)}`);
if (opt('only') === 'users') process.exit(0);

const aesthetics = (await (await fetch(`${api}/aesthetics`)).json()).items;
const id = code => aesthetics.find(a => a.code === code).id;

// ---- friend: 옷장 → OOTD(사진) → 피드 공개 2건 ----
{
  const call = client(await signIn(USERS.friend.email));
  if ((await call('GET', '/garments')).items.length) step('friend: 이미 옷장이 있어 건너뜀');
  else {
    await setupProfile(call, USERS.friend, aesthetics); step('friend: 프로필·추구미·온보딩');
    const garments = await registerCloset(call, [['top', '#f2f2f2'], ['bottom', '#2f4f7f'], ['shoes', '#ffffff'], ['outerwear', '#556b2f'], ['bag', '#222222'], ['accessory', '#c0392b']]);
    step(`friend: 옷 ${garments.length}벌 등록`);
    const byCat = Object.fromEntries(garments.map(g => [g.attributes.category, g.id]));
    const posts = [
      { look: ['#f2f2f2', '#2f4f7f', '#dfe8f0'], items: ['top', 'bottom', 'shoes'], caption: '가을 첫 출근룩, 청바지에 흰 티', aesthetic: 'casual', weather: 'clear', temp: 19, offset: -1 },
      { look: ['#556b2f', '#222222', '#e8e0d0'], items: ['outerwear', 'bottom', 'bag', 'accessory'], caption: '바람 부는 날 카키 재킷', aesthetic: 'grunge', weather: 'wind', temp: 14, offset: 0 }
    ];
    for (const p of posts) {
      const photo = await ootdPhoto(call, p.look);
      const ootd = await call('POST', '/ootd', { worn_on: day(p.offset), garment_ids: p.items.map(c => byCat[c]), rating: 4, note: p.caption, photo_upload_id: photo.id }, { idem: true });
      const post = await call('POST', '/feed', { source_ootd_id: ootd.id, caption: p.caption, aesthetic_id: id(p.aesthetic), weather_code: p.weather, temperature_c: p.temp, visibility: 'private' }, { idem: true });
      const media = await call('POST', `/feed/${post.id}/media`, { content_type: 'image/jpeg', file_size: fs.statSync(photo.file).size }, { idem: true });
      await putSigned(media.upload, photo.file);
      await call('POST', `/feed/${post.id}/media/${media.media_id}/complete-upload`, undefined, { idem: true });
      await call('PATCH', `/feed/${post.id}`, { visibility: 'public' });
      step(`friend: 피드 공개 "${p.caption}"`);
    }
  }
}

// ---- demo: 준비된 옷장·OOTD 기록·보관함 ----
{
  const call = client(await signIn(USERS.demo.email));
  if ((await call('GET', '/garments')).items.length) step('demo: 이미 옷장이 있어 건너뜀');
  else {
    await setupProfile(call, USERS.demo, aesthetics); step('demo: 프로필·추구미·온보딩');
    const a = await registerCloset(call, [['top', '#1c1c1c'], ['bottom', '#d8cfc0'], ['shoes', '#3b2a1a']]);
    const b = await registerCloset(call, [['top', '#e6e6fa'], ['bottom', '#2b2b2b'], ['outerwear', '#8b7355']]);
    const garments = [...a, ...b]; step(`demo: 옷 ${garments.length}벌 등록`);
    const g = c => garments.filter(x => x.attributes.category === c).map(x => x.id);
    const photo = await ootdPhoto(call, ['#1c1c1c', '#d8cfc0', '#efeae4']);
    await call('POST', '/ootd', { worn_on: day(-2), garment_ids: [g('top')[0], g('bottom')[0], g('shoes')[0]], rating: 5, note: '미니멀 블랙&베이지', photo_upload_id: photo.id }, { idem: true });
    await call('POST', '/ootd', { worn_on: day(-5), garment_ids: [g('top')[1], g('bottom')[1]], rating: 3, note: null }, { idem: true });
    await call('POST', '/ootd', { worn_on: day(-9), garment_ids: [g('outerwear')[0], g('top')[0], g('bottom')[1]], rating: 4, note: '트렌치 첫 개시' }, { idem: true });
    step('demo: OOTD 3건(사진 1)');
    await call('POST', '/saved-outfits', { title: '주말 브런치', note: '라벤더 니트 + 블랙 슬랙스', garment_ids: [g('top')[1], g('bottom')[1], g('shoes')[0]] }, { idem: true });
    step('demo: 코디 보관함 1건');
    const feed = await call('GET', '/feed').then(r => r.items).catch(e => { step(`demo: 피드 조회 실패(계약 문제 기록 #5) ${e.message.slice(0, 80)}`); return []; });
    if (feed[0]) { await call('PUT', `/feed/${feed[0].id}/like`, undefined, { expect: 204 }); step('demo: 피드 좋아요 1건'); }
  }
}
fs.rmSync(tmp, { recursive: true, force: true });
console.log('완료');
