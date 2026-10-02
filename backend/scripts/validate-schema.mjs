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
const db = new PGlite();
await db.exec(`
  create role anon; create role authenticated; create role service_role bypassrls;
  create schema auth; create schema storage;
  create table auth.users(id uuid primary key);
  create function auth.uid() returns uuid language sql stable as
  $$select nullif(current_setting('request.jwt.claim.sub', true),'')::uuid$$;
  grant usage on schema public,auth,storage to anon,authenticated,service_role;
  create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
  create table storage.objects(id uuid default gen_random_uuid(),bucket_id text,name text,owner_id uuid,metadata jsonb default '{}',updated_at timestamptz not null default now());
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
  console.log('Embedded PostgreSQL passed. Supabase Auth/Storage are stubs; hosted platform integration NOT tested.');
} finally { await db.close(); }
