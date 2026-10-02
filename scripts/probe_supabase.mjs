// Read-only connection probe. Never print credentials or raw exceptions.
import fs from 'node:fs/promises';
import {createRequire} from 'node:module';
const require=createRequire(new URL('../artifacts/design-validation/package.json',import.meta.url));
const {Client}=require('pg');
const root=new URL('../supabase/',import.meta.url);
const config=await fs.readFile(new URL('general setting.txt',root),'utf8');
const ref=config.match(/project id\s*[:=]\s*([a-z0-9]{20})/i)?.[1];
const key=config.match(/sb_publishable_[A-Za-z0-9_-]+/)?.[0];
if(!ref||!key){console.log(JSON.stringify({parsed:false,projectRef:!!ref,publishable:!!key}));process.exit(1);}
const url=`https://${ref}.supabase.co`;
try{
 const res=await fetch(`${url}/rest/v1/aesthetics?select=code,display_name&limit=5`,{headers:{apikey:key},signal:AbortSignal.timeout(12000)});
 const data=await res.json();
 console.log(JSON.stringify({restStatus:res.status,code:!res.ok?data.code:undefined,rows:Array.isArray(data)?data.length:undefined}));
}catch(e){console.log(JSON.stringify({restError:e.name}));}
const password=(await fs.readFile(new URL('supabse_db_security.txt',root),'utf8')).trim();
const client=new Client({host:`db.${ref}.supabase.co`,port:5432,user:'postgres',password,database:'postgres',ssl:{rejectUnauthorized:true},connectionTimeoutMillis:10000});
try{
 await client.connect();
 const result=await client.query("select tablename from pg_tables where schemaname='public' order by tablename");
 console.log(JSON.stringify({directDbConnected:true,publicTables:result.rows.map(r=>r.tablename)}));
}catch(e){console.log(JSON.stringify({directDbConnected:false,errorCode:e.code||e.name,message:String(e.message).replaceAll(password,'[REDACTED]').replaceAll(ref,'[PROJECT]')}));}
finally{await client.end().catch(()=>{});}
