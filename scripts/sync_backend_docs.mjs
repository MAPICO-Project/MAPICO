// Mechanical export of approved deliverables into the standalone backend repo.
import fs from 'node:fs/promises';
import {createHash} from 'node:crypto';
const files=['openapi.yaml','API_DESIGN.md','DB_DESIGN.md','ERD.md'];
await fs.mkdir(new URL('../backend/docs/',import.meta.url),{recursive:true});
const manifest={source:'deliverables/backend',files:{}};
for(const name of files){
 const data=await fs.readFile(new URL('../deliverables/backend/'+name,import.meta.url));
 await fs.writeFile(new URL('../backend/docs/'+name,import.meta.url),data);
 manifest.files[name]=createHash('sha256').update(data).digest('hex');
}
await fs.writeFile(new URL('../backend/docs/export-manifest.json',import.meta.url),JSON.stringify(manifest,null,2)+'\n');
console.log('Exported 4 backend document snapshots with SHA-256 manifest.');
