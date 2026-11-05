import test from 'node:test';import assert from 'node:assert/strict';
import worker,{Reports} from './worker.mjs';import {dashboardHTML} from './dashboard-ui.mjs';
const ref='12345678-1234-1234-1234-123456789ABC';
function storage(){const data=new Map();let pending=Promise.resolve();return {get:async k=>data.get(k),put:async(k,v)=>data.set(k,structuredClone(v)),delete:async k=>data.delete(k),setAlarm:async()=>{},list:async({prefix='',limit=Infinity,startAfter}={})=>new Map([...data].filter(([k])=>k.startsWith(prefix)&&(!startAfter||k>startAfter)).sort(([a],[b])=>a.localeCompare(b)).slice(0,limit)),transaction(f){const p=pending.then(()=>f(this));pending=p.catch(()=>{});return p;}};}
function environment(){const objects=new Map();const env={IOS_RELEASE_KEY:'i'.repeat(43),ANDROID_RELEASE_KEY:'a'.repeat(43),REPORT_MAINTAINER_ID:'999',DISCORD_WEBHOOK_URL:'https://discord.com/api/webhooks/123/fake',DISCORD_PRIVATE_WEBHOOK_URL:'https://discord.com/api/webhooks/456/privatefake'};env.REPORTS={idFromName:n=>n,get:n=>({fetch:(url,options)=>get(n).fetch(new Request(url,options))})};const get=n=>{if(!objects.has(n))objects.set(n,new Reports({storage:storage()},env));return objects.get(n);};return {env,get};}
const req=(path,body={},key='i'.repeat(43))=>new Request('https://relay/v1/'+path,{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer '+key},body:JSON.stringify(body)});
const internal=(object,path,body)=>object.fetch(new Request('https://reports/'+path,{method:'POST',body:JSON.stringify(body)}));
test('dashboard metadata requires platform key and never crosses namespaces',async()=>{
 const {env,get}=environment();const record={platform:'ios',userID:'123',reference:ref,title:'Tunnel issue',reporter:'Test person',created:100,threadURL:'https://discord.com/channels/1/2/3'};
 await internal(get('dashboard:ios'),'dashboard-put',{platform:'ios',record});
 assert.equal((await worker.fetch(req('ios/dashboard/reports',{},'a'.repeat(43)),env)).status,401);
 assert.equal((await worker.fetch(req('android/dashboard/reports'),env)).status,401);
 assert.equal((await (await worker.fetch(req('android/dashboard/reports',{},'a'.repeat(43)),env)).json()).reports.length,0);
 const result=await (await worker.fetch(req('ios/dashboard/reports'),env)).json();assert.equal(result.reports[0].reference,ref);assert.ok(!JSON.stringify(result).includes('RELEASE_KEY'));
});
test('index upserts and paginates without duplicate entries',async()=>{
 const {get}=environment(),index=get('dashboard:ios');
 for(let i=0;i<102;i++)await internal(index,'dashboard-put',{platform:'ios',record:{platform:'ios',userID:String(i+1),reference:ref,created:i,title:'Report'}});
 await internal(index,'dashboard-put',{platform:'ios',record:{platform:'ios',userID:'1',reference:ref,created:999,title:'Updated'}});
 const first=await (await internal(index,'dashboard-list',{platform:'ios'})).json();assert.equal(first.reports.length,100);assert.ok(first.cursor);
 const second=await (await internal(index,'dashboard-list',{platform:'ios',cursor:first.cursor})).json();assert.equal(second.reports.length,2);assert.equal(second.cursor,null);
 assert.equal([...first.reports,...second.reports].filter(r=>r.userID==='1').length,1);
});
test('legacy backfill validates actual stored reference and platform',async()=>{
 const {env,get}=environment(),owner=get('123');
 await owner.ctx.storage.put('reference:'+ref,{threadURL:'https://discord.com/channels/1/2/3'});await owner.ctx.storage.put('thread:2',{id:'2',title:'Stored title',created:100});
 const response=await worker.fetch(req('ios/dashboard/import',{userID:'123',reference:ref,title:'Forged',threadURL:'https://evil.test'}),env);
 assert.equal(response.status,200);const record=(await response.json()).report;assert.equal(record.title,'Stored title');assert.equal(record.threadURL,'https://discord.com/channels/1/2/3');
 assert.equal((await worker.fetch(req('android/dashboard/import',{userID:'123',reference:ref},'a'.repeat(43)),env)).status,404);
 assert.equal((await worker.fetch(req('ios/dashboard/import',{userID:'456',reference:ref}),env)).status,404);
 await owner.ctx.storage.put('reference:android:'+ref,{threadURL:'https://discord.com/channels/1/8/9'});
 await owner.ctx.storage.put('thread:8',{id:'8',platform:'android',title:'Android title',created:101});
 const history=await (await worker.fetch(req('ios/dashboard/import',{userID:'123',syncHistory:true,reporter:'Known tester'}),env)).json();
 assert.equal(history.imported,1);
 const indexed=await (await worker.fetch(req('ios/dashboard/reports'),env)).json();assert.equal(indexed.reports.length,1);assert.equal(indexed.reports[0].reporter,'Known tester');
});
test('successful reports enqueue metadata only, retry index failure without resending Discord',async()=>{
 const {env,get}=environment(),old=globalThis.fetch;let posts=0,fail=true;
 const original=env.REPORTS.get;env.REPORTS.get=n=>n.startsWith('dashboard:')&&fail?{fetch:async()=>{throw Error('offline')}}:original(n);
 globalThis.fetch=async(url,options)=>{if(options.method==='POST'){posts++;return Response.json({id:'3',channel_id:String(url).includes('/456/')?'6':'2'});}return Response.json({guild_id:'1',channel_id:String(url).includes('/456/')?'6':'7'});};
 const owner=get('123'),body={platform:'ios',reference:ref,description:'Tunnel issue',logs:'PRIVATE DIAGNOSTICS',user:{id:'123',username:'Tester'}};
 try {
  assert.equal((await internal(owner,'submit',body)).status,200);assert.equal(posts,2);
  const pending=await owner.ctx.storage.list({prefix:'dashboard-pending:'});assert.equal(pending.size,1);assert.ok(!JSON.stringify([...pending.values()]).includes('PRIVATE DIAGNOSTICS'));
  fail=false;await owner.alarm();assert.equal((await owner.ctx.storage.list({prefix:'dashboard-pending:'})).size,0);
  const rows=await (await worker.fetch(req('ios/dashboard/reports'),env)).json();assert.equal(rows.reports[0].reporter,'Tester');
  await internal(owner,'submit',body);assert.equal(posts,2);
 }finally{globalThis.fetch=old;}
});
test('GitHub uses only configured platform branches and sanitizes output fields',async()=>{
 const {env}=environment(),old=globalThis.fetch,urls=[];
 globalThis.fetch=async (url,options)=>{assert.equal(options.redirect,'manual');urls.push(String(url));return Response.json([{sha:'a'.repeat(40),html_url:'https://evil.test',commit:{message:'Fix tunnel\nprivate trailing text',committer:{date:'2026-11-05T00:00:00Z'}}}]);};
 try {for(const p of ['ios','android']){const result=await (await worker.fetch(req(p+'/dashboard/commits',{repo:'evil/repo'},p==='ios'?env.IOS_RELEASE_KEY:env.ANDROID_RELEASE_KEY),env)).json();assert.ok(result.commits[0].url.startsWith('https://github.com/'));assert.equal(result.commits[0].title,'Fix tunnel');}
 assert.ok(urls[0].includes('natehuby76/ios-clone/commits?sha=integrated-latest'));assert.ok(urls[1].includes('dirwin31/StarPilotAndroid/commits?sha=Play-Dev'));
 }finally{globalThis.fetch=old;}
});
test('dashboard shell has no embedded secrets, no persistent browser key storage, and valid JS',async()=>{
 const response=await worker.fetch(new Request('https://relay/dashboard'),{});assert.equal(response.status,200);assert.ok(response.headers.get('Content-Security-Policy').includes("frame-ancestors 'none'"));
 const html=await response.text();assert.ok(!html.includes('{{nonce}}'));assert.ok(!/localStorage|sessionStorage|innerHTML/.test(html));
 new Function(dashboardHTML.match(/<script nonce="\{\{nonce\}\}">([\s\S]*?)<\/script>/)[1]);
});

test('GitHub connection errors return JSON rather than escaping Worker handler',async()=>{const {env}=environment(),old=globalThis.fetch;globalThis.fetch=async()=>{throw new TypeError('network unavailable');};try{const r=await worker.fetch(req('ios/dashboard/commits'),env);assert.equal(r.status,503);assert.match((await r.json()).error,/GitHub connection failed/);}finally{globalThis.fetch=old;}});
