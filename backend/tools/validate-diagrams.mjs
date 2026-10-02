import {createServer} from 'node:http';
import fs from 'node:fs/promises';
import path from 'node:path';
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';
const require=createRequire(new URL('../.artifacts/design-validation/package.json',import.meta.url));
const {chromium}=require('@playwright/test');
const dist=fileURLToPath(new URL('../.artifacts/design-validation/node_modules/mermaid/dist/',import.meta.url));
const server=createServer(async(req,res)=>{
 try{
  if(req.url==='/'){res.setHeader('Content-Type','text/html');res.end('<html><body></body></html>');return;}
  const file=path.resolve(dist,'.'+decodeURIComponent(req.url.split('?')[0]));
  if(!file.startsWith(dist)){res.writeHead(403).end();return;}
  res.setHeader('Content-Type','text/javascript');res.end(await fs.readFile(file));
 }catch{res.writeHead(404).end();}
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
let browser;
try{
 browser=await chromium.launch({channel:'msedge',headless:true});
 const page=await browser.newPage();await page.goto(`http://127.0.0.1:${server.address().port}`);
 await page.evaluate(async()=>{window.mermaid=(await import('/mermaid.esm.min.mjs')).default;window.mermaid.initialize({startOnLoad:false});});
 for(const file of ['docs/ERD.md','docs/design/USER_FLOWS.md','docs/design/DIAGRAM_STARTER.md','docs/AI_ARCHITECTURE.md','docs/product/ROADMAP.md']){
  const content=await fs.readFile(new URL('../'+file,import.meta.url),'utf8');
  const blocks=[...content.matchAll(/```mermaid\s*\n([\s\S]*?)```/g)];
  for(const block of blocks)await page.evaluate(async source=>await window.mermaid.parse(source),block[1]);
  console.log(`${file}: ${blocks.length} Mermaid blocks validated in browser`);
 }
}finally{await browser?.close();await new Promise(resolve=>server.close(resolve));}
