// Provision only public-project URL/publishable key via stdin, never print keys.
import fs from 'node:fs/promises';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
const config=await fs.readFile(new URL('../supabase/general setting.txt',import.meta.url),'utf8');
const ref=config.match(/project id\s*[:=]\s*([a-z0-9]{20})/i)?.[1];
const key=config.match(/sb_publishable_[A-Za-z0-9_-]+/)?.[0];
if(!ref||!key) throw Error('Required project fields missing');
for(const [name,value] of Object.entries({SUPABASE_URL:`https://${ref}.supabase.co`,SUPABASE_PUBLISHABLE_KEY:key})){
 const result=spawnSync('vercel.cmd',['env','add',name,'preview','--force'],{cwd:fileURLToPath(new URL('../backend/',import.meta.url)),input:value,encoding:'utf8',shell:true,timeout:30000});
 console.log(JSON.stringify({variable:name,configured:result.status===0}));
 if(result.status!==0)process.exit(1);
}
