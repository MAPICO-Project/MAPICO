import fs from 'node:fs/promises';
import path from 'node:path';
import { createRequire } from 'node:module';
const require = createRequire(new URL('../package.json', import.meta.url));
const { PGlite } = require('@electric-sql/pglite');
const SwaggerParser = require('@apidevtools/swagger-parser');
const YAML = require('yaml');
// Paths may contain Unicode; fileURLToPath handles encoded directory names.
const { fileURLToPath } = await import('node:url');
const project = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const spec = YAML.parse(await fs.readFile(path.join(project, 'docs/openapi.yaml'), 'utf8'));
await SwaggerParser.validate(structuredClone(spec));
console.log(`OpenAPI schema validated: ${Object.keys(spec.paths).length} paths`);
// Static scan of `<client>.select('table', [...])` in lib/*.js. Select lists are exact (String objects marked
// precise); filter/order keys are collected per file (they may be built in a separate `filters` array) and only
// checked when the table has such a column.
const SPECIAL = new Set(['select', 'order', 'limit', 'offset', 'or', 'and', 'not']);
function selectColumns(text, table, out) {
  let depth = 0, token = '', embedded = null;
  const flush = () => {
    const raw = token.trim(); token = '';
    if (!raw || raw === '*') return;
    const name = raw.includes(':') ? raw.split(':').pop() : raw;
    const column = Object.assign(new String(name.replace(/::.*$/, '').trim()), { precise: true });
    out.push({ table, column });
  };
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (ch === '(' ) {
      if (depth === 0) { const head = token.trim(); token = ''; const name = head.includes(':') ? head.split(':').pop() : head; embedded = { name, start: i + 1 }; }
      depth++; continue;
    }
    if (ch === ')') { depth--; if (depth === 0 && embedded) { selectColumns(text.slice(embedded.start, i), embedded.name, out); embedded = null; token = ''; } continue; }
    if (depth > 0) continue;
    if (ch === ',') { flush(); continue; }
    token += ch;
  }
  flush();
}
async function libColumnUsage(dir) {
  const result = [];
  for (const file of (await fs.readdir(dir)).filter(name => name.endsWith('.js')).sort()) {
    if (['supabase-internal.js', 'supabase.js', 'catalog.js'].includes(file)) continue; // secret-key or anon catalogue paths
    const source = await fs.readFile(path.join(dir, file), 'utf8');
    const constants = new Map([...source.matchAll(/const\s+([A-Z_]+)\s*=\s*'([^']*)'/g)].map(m => [m[1], m[2]]));
    const fileKeys = new Set();
    for (const m of source.matchAll(/\[\s*'([a-z_][a-z0-9_.]*)'\s*,\s*([`'][^`']*[`']|[A-Z_]+|String\()/g)) {
      const key = m[1]; const value = m[2];
      if (key === 'order' || key.endsWith('.order') || key === 'or') {
        for (const c of value.matchAll(/([a-z_][a-z0-9_]*)\.(?:asc|desc|lt|gt|eq|lte|gte|is|in|neq)/g)) fileKeys.add(c[1]);
      } else if (!SPECIAL.has(key) && !key.includes('.') && /^[`'](?:eq|neq|gt|gte|lt|lte|is|in|not|like|ilike)\./.test(value)) fileKeys.add(key);
    }
    for (const m of source.matchAll(/\.select\(\s*'([a-z_][a-z0-9_]*)'\s*,\s*(\[|[A-Za-z_]+)/g)) {
      const table = m[1]; const columns = [];
      // Literal array: its own ['select', ...]. Identifier (e.g. `filters`): the nearest preceding push.
      const pattern = /\[\s*'select'\s*,\s*(?:'([^']*)'|([A-Z_]+))\s*\]/g;
      let list = null;
      if (m[2] === '[') list = new RegExp(pattern.source).exec(source.slice(m.index, m.index + 600));
      else for (const found of source.slice(Math.max(0, m.index - 1200), m.index).matchAll(pattern)) list = found;
      if (!list) throw new Error(`${file}: cannot resolve select list for ${table}`);
      const text = list[1] ?? constants.get(list[2]);
      if (text === undefined) throw new Error(`${file}: unknown select constant ${list[2]}`);
      const out = []; selectColumns(text, table, out);
      for (const item of out) {
        if (item.table === table) columns.push(item.column);
        else result.push({ file, table: item.table, columns: [item.column] });
      }
      for (const key of fileKeys) columns.push(key);
      result.push({ file, table, columns });
    }
  }
  return result;
}
const db = new PGlite();
await db.exec(`
  create role anon; create role authenticated; create role service_role bypassrls;
  create schema auth; create schema storage;
  create table auth.users(id uuid primary key);
  create function auth.uid() returns uuid language sql stable as
  $$select nullif(current_setting('request.jwt.claim.sub', true),'')::uuid$$;
  grant usage on schema public,auth,storage to anon,authenticated,service_role;
  create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
  create table storage.objects(id uuid default gen_random_uuid(),bucket_id text,name text,owner_id text,metadata jsonb default '{}',updated_at timestamptz not null default now());
  alter table storage.objects enable row level security;
  grant select on storage.objects to authenticated;
`);
try {
  for (const name of (await fs.readdir(path.join(project, 'supabase/migrations'))).filter(x => x.endsWith('.sql')).sort()) {
    let sql = await fs.readFile(path.join(project, 'supabase/migrations', name), 'utf8');
    // PGlite has core gen_random_uuid but not this Supabase-installed extension.
    sql = sql.replace(/create extension if not exists pgcrypto;/gi, '');
    await db.exec(sql);
    console.log(`Migration executed: ${name}`);
  }
  const tests = path.join(project, 'supabase/tests');
  for (const name of (await fs.readdir(tests)).filter(x => x.endsWith('.sql')).sort()) {
    await db.exec(await fs.readFile(path.join(tests, name), 'utf8'));
    console.log(`SQL assertions passed: ${name}`);
  }
  // Hosted PostgREST rejects (403/42501) any select or filter on a column the role cannot SELECT.
  // The SQL tests call RPCs, so check every user-JWT read in lib/*.js against the migrated grants.
  const usage = await libColumnUsage(path.join(project, 'lib'));
  const missing = [];
  for (const { file, table, columns } of usage) {
    for (const column of columns) {
      const exists = await db.query(`select 1 from information_schema.columns where table_schema='public' and table_name=$1 and column_name=$2`, [table, String(column)]);
      if (!exists.rows.length) { if (column.precise) missing.push(`${file}: ${table}.${column} does not exist`); continue; }
      const granted = await db.query(`select has_column_privilege('authenticated',$1,$2,'SELECT') as ok`, [`public.${table}`, String(column)]);
      if (!granted.rows[0].ok) missing.push(`${file}: authenticated cannot SELECT ${table}.${column}`);
    }
  }
  if (missing.length) throw new Error(`Column grants missing for user-JWT reads:\n${missing.join('\n')}`);
  console.log(`Column grants cover ${usage.length} user-JWT selects in lib/*.js`);
  console.log('Embedded PostgreSQL passed. Supabase Auth/Storage are stubs; hosted platform integration NOT tested.');
} finally { await db.close(); }
