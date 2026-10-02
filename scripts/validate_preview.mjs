import {createServer} from 'node:http';
import {readFile,mkdir} from 'node:fs/promises';
import {createRequire} from 'node:module';
import assert from 'node:assert/strict';
import {fileURLToPath} from 'node:url';
const require=createRequire(new URL('../artifacts/design-validation/package.json',import.meta.url));
const {chromium}=require('@playwright/test');
const files=new URL('../apps/frontend-preview/public/',import.meta.url);
const server=createServer(async(req,res)=>{
 const name={'/':'index.html','/style.css':'style.css','/app.js':'app.js'}[req.url];
 if(!name){res.writeHead(404).end();return;}
 const type=name.endsWith('.css')?'text/css':name.endsWith('.js')?'text/javascript':'text/html';
 res.writeHead(200,{'Content-Type':type+'; charset=utf-8'});res.end(await readFile(new URL(name,files)));
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
let browser;
try{
 browser=await chromium.launch({channel:'msedge',headless:true});
 const page=await browser.newPage({viewport:{width:390,height:844}});
 const errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.goto(`http://127.0.0.1:${server.address().port}`);
 await page.locator('[data-mood="Y2K"]').click();assert.equal(await page.locator('#selected-mood').innerText(),'Y2K 무드');
 await page.locator('#save-look').click();
 await page.locator('.mobile-nav [data-page="studio"]').click();assert.match(await page.locator('#saved-looks').innerText(),/Y2K/);
 await page.locator('.mobile-nav [data-page="closet"]').click();await page.locator('[data-category="상의"]').click();assert.equal(await page.locator('#closet-items .item').count(),1);
 await page.locator('#upload-guide').click();assert.equal(await page.locator('dialog').isVisible(),true);await page.keyboard.press('Escape');
 await page.locator('.mobile-nav [data-page="feed"]').click();await page.locator('.like').first().click();assert.equal(await page.locator('.like').first().getAttribute('aria-pressed'),'true');
 await page.locator('.mobile-nav [data-page="home"]').click();await page.locator('#wear-look').click();
 await page.locator('.mobile-nav [data-page="studio"]').click();assert.match(await page.locator('#worn-look').innerText(),/Y2K/);
 await page.reload();assert.equal(await page.locator('#saved-looks .saved-row').count(),0);
 await page.locator('.mobile-nav [data-page="home"]').click();
 assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);
 await mkdir(new URL('../artifacts/ui-review/',import.meta.url),{recursive:true});
 await page.screenshot({path:fileURLToPath(new URL('../artifacts/ui-review/mobile.png',import.meta.url)),fullPage:true});
 await page.setViewportSize({width:1440,height:1000});
 await page.screenshot({path:fileURLToPath(new URL('../artifacts/ui-review/desktop.png',import.meta.url)),fullPage:true});
 assert.deepEqual(errors,[]);
 console.log('PASS: mood, save, wardrobe filter, modal/Escape, like, wear, reload reset, 390px overflow, no JS errors. Screenshots captured.');
}finally{await browser?.close();await new Promise(resolve=>server.close(resolve));}
