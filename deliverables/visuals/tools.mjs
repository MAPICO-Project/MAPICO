import path from 'node:path';
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';
const here=path.dirname(fileURLToPath(import.meta.url));
let require=createRequire(new URL('./package.json',import.meta.url));
try {require.resolve('mermaid/package.json');}
catch {require=createRequire(path.resolve(here,'../../backend/.artifacts/design-validation/package.json'));}
export {require};
export async function launchBrowser(){
 const {chromium}=require('@playwright/test');
 try{return await chromium.launch({channel:'msedge',headless:true});}
 catch{return await chromium.launch({headless:true});}
}
