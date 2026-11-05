import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,readFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {resolveReport,setupKey} from './notify-support.mjs';
const reference='12345678-1234-1234-1234-123456789abc';
test('resolves UUID from registry or pasted report without guessing',()=>{
 const registry={people:[{discord_user_id:'123',reports:[reference]}]};
 assert.equal(resolveReport(reference,undefined,registry).userID,'123');
 assert.equal(resolveReport('Report from <@123>\nFor <@999>\nReference: '+reference,undefined,null).userID,'123');
 assert.throws(()=>resolveReport(reference,undefined,null),/not found/);
 assert.throws(()=>resolveReport(reference,'456',registry),/Conflicting/);
 assert.throws(()=>resolveReport(reference+' 22345678-1234-1234-1234-123456789abc',undefined,registry),/exactly one/);
 assert.throws(()=>resolveReport(reference,undefined,{people:[{...registry.people[0],platform:'android'}]}),/not found/);
});
test('key setup generates a valid key and refuses to overwrite it',async()=>{
 const folder=await mkdtemp(join(tmpdir(),'notify-key-'));
 try {
  const path=join(folder,'ios.json');await setupKey(path);
  const saved=await readFile(path,'utf8');assert.match(JSON.parse(saved).key,/^[a-f0-9]{64}$/);
  await assert.rejects(setupKey(path),{code:'EEXIST'});
  assert.equal(await readFile(path,'utf8'),saved);
 }finally{await rm(folder,{recursive:true,force:true});}
});
