// 데모 전용: ../_key 메모에서 서버 환경변수를 프로세스 안으로만 읽는다. 값은 출력하지 않는다.
import fs from 'node:fs/promises';
import { createHmac } from 'node:crypto';
import { pathToFileURL } from 'node:url';

const keyDir = process.env.MAFICO_KEY_DIR
  ? pathToFileURL(process.env.MAFICO_KEY_DIR.replace(/[\\/]?$/, '/'))
  : new URL('../../../../_key/', import.meta.url);

async function read(name) {
  try { return await fs.readFile(new URL(name, keyDir), 'utf8'); } catch { return ''; }
}

function lines(text) { return text.split('\n').map(line => line.trim()); }

// 다음 줄의 값을 읽는다("End Point\n<값>" 형식).
function valueAfter(text, label) {
  const all = lines(text);
  const index = all.findIndex(line => line === label);
  return index >= 0 ? all.slice(index + 1).find(Boolean) ?? null : null;
}

export async function loadDemoEnv() {
  const settings = await read('supabase_project_settings.txt');
  const ref = settings.match(/project id\s*[:=]\s*([a-z0-9]{20})/i)?.[1];
  const publishable = settings.match(/sb_publishable_[A-Za-z0-9_-]+/)?.[0];
  const secret = settings.match(/sb_secret_[A-Za-z0-9_-]+/)?.[0];
  if (!ref || !publishable || !secret) throw Error('Supabase 설정 메모에서 필요한 값을 찾지 못했습니다(_key/supabase_project_settings.txt).');
  const weather = await read('weather_api.txt');
  const dbPassword = lines(await read('supabase_db_password.txt')).filter(Boolean).pop() ?? null;
  const region = settings.match(/region\s*[:=]\s*([a-z0-9-]+)/i)?.[1] ?? 'ap-southeast-1';
  return {
    projectRef: ref,
    // 데모 도구 전용 DB 접속(세션 pooler). 가짜 worker가 실제 worker가 못 하는 일을 대신할 때만 쓴다.
    db: dbPassword ? { host: `aws-0-${region}.pooler.supabase.com`, port: 5432, user: `postgres.${ref}`, password: dbPassword,
      database: 'postgres', ssl: { rejectUnauthorized: false } } : null,
    kma: { baseUrl: valueAfter(weather, 'End Point'), key: valueAfter(weather, '일반 인증키') },
    env: {
      SUPABASE_URL: `https://${ref}.supabase.co`,
      SUPABASE_PUBLISHABLE_KEY: publishable,
      SUPABASE_SECRET_KEY: secret,
      // 로컬 dev 서버와 가짜 worker가 같은 값을 계산한다. 배포용 비밀값이 아니다.
      AI_CALLBACK_HMAC_SECRET: createHmac('sha256', secret).update('mafico-demo-callback-v1').digest('hex')
    }
  };
}
