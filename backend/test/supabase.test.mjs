import test from 'node:test';
import assert from 'node:assert/strict';
import {fetchAesthetics} from '../lib/supabase.js';
const env={SUPABASE_URL:'https://abcdefghijklmnopqrst.supabase.co',SUPABASE_PUBLISHABLE_KEY:'test'};
test('missing configuration fails closed',async()=>{assert.equal((await fetchAesthetics({})).body.error.code,'SUPABASE_NOT_CONFIGURED');});
test('absent schema is not a fake catalogue',async()=>{const r=await fetchAesthetics(env,async()=>({ok:false,status:404}));assert.equal(r.body.error.code,'DATABASE_SCHEMA_NOT_READY');});
test('successful catalogue projects public fields only',async()=>{const r=await fetchAesthetics(env,async()=>({ok:true,json:async()=>[{id:'id',code:'casual',label:'캐주얼',private:'never return'}]}));assert.deepEqual(r.body.data,[{id:'id',code:'casual',label:'캐주얼'}]);});
test('network errors do not leak exception data',async()=>{const r=await fetchAesthetics(env,async()=>{throw Error('secret');});assert.equal(JSON.stringify(r).includes('secret'),false);assert.equal(r.status,503);});
test('invalid destination blocked before network',async()=>{let called=false;const r=await fetchAesthetics({...env,SUPABASE_URL:'http://localhost'},async()=>{called=true;});assert.equal(called,false);assert.equal(r.status,503);});
