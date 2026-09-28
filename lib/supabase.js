export async function fetchAesthetics(env = process.env, request = fetch) {
  if (!env.SUPABASE_URL || !env.SUPABASE_PUBLISHABLE_KEY) return { status: 503, body: { error: { code: 'SUPABASE_NOT_CONFIGURED' } } };
  try {
    const base = new URL(env.SUPABASE_URL);
    if (base.protocol !== 'https:' || !/^[a-z0-9]{20}\.supabase\.co$/.test(base.hostname) || base.username || base.password) throw Error('Invalid project URL');
    const result = await request(new URL('/rest/v1/aesthetics?select=id,code,label&active=eq.true&order=code.asc', base), {
      headers: { apikey: env.SUPABASE_PUBLISHABLE_KEY }, signal: AbortSignal.timeout(5000)
    });
    if (!result.ok) return { status: 503, body: { error: { code: result.status === 404 ? 'DATABASE_SCHEMA_NOT_READY' : 'SUPABASE_UNAVAILABLE' } } };
    const data = await result.json();
    if (!Array.isArray(data) || data.some(row => !['id','code','label'].every(key => typeof row[key] === 'string'))) throw Error('Invalid catalogue');
    return { status: 200, body: { data: data.map(({ id, code, label }) => ({ id, code, label })), source: 'supabase' } };
  } catch { return { status: 503, body: { error: { code: 'SUPABASE_UNAVAILABLE' } } }; }
}
