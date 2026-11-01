import test from 'node:test';
import assert from 'node:assert/strict';
import worker, {Reports, reportTitle, readJSON} from './worker.mjs';
const env = {REPORT_MAINTAINER_ID:'524762496373096459',DISCORD_CLIENT_ID:'123', DISCORD_CLIENT_SECRET:'test', DISCORD_PRIVATE_WEBHOOK_URL:'https://discord.com/api/webhooks/456/privatefake', DISCORD_WEBHOOK_URL:'https://discord.com/api/webhooks/123/fake'};
const request = (path, body, token) => new Request('https://relay'+path, {method:'POST',headers:{'Content-Type':'application/json', ...(token ? {Authorization:token}: {})},body:JSON.stringify(body)});
test('OAuth uses fixed callback and PKCE, rejects invalid state', async () => {
  assert.equal((await worker.fetch(new Request('https://relay/auth/discord/start'),env)).status,400);
  const response=await worker.fetch(new Request('https://relay/auth/discord/start?state='+ 'a'.repeat(43)+'&code_challenge='+'b'.repeat(43)),env);
  const target=new URL(response.headers.get('location'));
  assert.equal(target.searchParams.get('code_challenge_method'),'S256');
  assert.equal(target.searchParams.get('scope'),'identify');
  assert.equal(target.searchParams.get('redirect_uri'),'https://starpilot-log-relay.nathan-g-hubbard.workers.dev/auth/discord/callback');
});
test('rejects invalid JSON and missing authentication',async()=>{
  assert.equal((await worker.fetch(request('/auth/discord/exchange',null),env)).status,400);
  assert.equal((await worker.fetch(request('/v1/logs',{}),env)).status,401);
});
test('rejects tokens issued to other applications',async()=>{
  const old=globalThis.fetch;
  globalThis.fetch=async()=>Response.json({application:{id:'456'},scopes:['identify'],user:{id:'789'}});
  try {assert.equal((await worker.fetch(request('/v1/logs',{},'Bearer test'),env)).status,403);} finally {globalThis.fetch=old;}
});
function storage(){
 let values=new Map(), pending=Promise.resolve();
 const store={
  transaction(f){const operation=pending.then(async()=>{const snapshot=new Map(values);try{return await f(store)}catch(e){values=snapshot;throw e}});pending=operation.catch(()=>{});return operation;},
  get:async k=>values.get(k), put:async(k,v)=>values.set(k,structuredClone(v)),setAlarm:async()=>{},
  list:async({prefix='',limit=Infinity}={})=>new Map([...values].filter(([k])=>k.startsWith(prefix)).sort(([a],[b])=>a.localeCompare(b)).slice(0,limit)),
  delete:async k=>values.delete(k)
 };return store;
}
const body={reference:'12345678-1234-1234-1234-123456789abc',description:'Bluetooth failed @everyone',logs:'synthetic diagnostics',user:{id:'789',username:'tester'}};
test('confirmed report retry returns same thread without another post',async()=>{
 const old=globalThis.fetch;let posts=0;
 globalThis.fetch=async(url,options)=>{
  assert.equal(options.redirect,'manual');
  if(options.method==='POST') {posts++;if(String(url).includes('/456/')) {assert.equal(await options.body.get('files[0]').text(),body.logs);return Response.json({id:'555',channel_id:'666'});} assert.equal(typeof options.body,'string'); assert.ok(!options.body.includes(body.logs)); const payload=JSON.parse(options.body); assert.ok(payload.content.includes('https://discord.com/channels/333/666/555'));assert.deepEqual(payload.allowed_mentions,{parse:[],users:['789','524762496373096459']});assert.ok(payload.content.includes('<@524762496373096459>'));return Response.json({id:'111',channel_id:'222'});}
  return Response.json({guild_id:'333',channel_id:String(url).includes('/456/')?'666':'777'});
 };
 const reports=new Reports({storage:storage(),blockConcurrencyWhile:f=>f()},env);
 try {
  const first=await (await reports.fetch(request('/submit',body))).json();
  const retry=await (await reports.fetch(request('/submit',body))).json();
  assert.deepEqual(first,retry);assert.equal(posts,2);assert.equal(first.threadURL,'https://discord.com/channels/333/222/111');
 }finally{globalThis.fetch=old;}
});
test('uncertain delivery is not automatically sent twice',async()=>{
 const old=globalThis.fetch;let posts=0;
 globalThis.fetch=async(url,options)=>{if(options.method==='POST'){posts++;throw new Error('network lost');}return Response.json({guild_id:'333',channel_id:String(url).includes('/456/')?'666':'777'});};
 const reports=new Reports({storage:storage(),blockConcurrencyWhile:f=>f()},env);
 try {assert.equal((await reports.fetch(request('/submit',body))).status,409);assert.equal((await reports.fetch(request('/submit',body))).status,409);assert.equal(posts,1);}finally{globalThis.fetch=old;}
});

test('AI titles use only descriptions and fall back safely', async () => {
 let received;
 const ai = {run: async (model, input) => { received = {model, input}; return {response: 'Wi-Fi and tunnel failed; Bluetooth worked'}; }};
 const example = 'Didn’t connect on wifi or tunnel but did over Bluetooth';
 assert.equal(await reportTitle(ai, example), 'iOS — Wi-Fi and tunnel failed; Bluetooth worked');
 assert.equal(received.model, '@cf/meta/llama-3.1-8b-instruct-fp8');
 assert.equal(received.input.messages[1].content, example);
 assert.equal(await reportTitle({run: async () => {throw Error('unavailable')}}, example), 'iOS — ' + example);
});

test('follow-up requires a report owned by this account and posts to its thread', async () => {
 const old = globalThis.fetch; let posted;
 globalThis.fetch = async (url, options) => {
   if (options.method === 'POST') { if(String(url).includes('/456/')) return Response.json({id:'555',channel_id:'666'}); posted = {url: String(url), payload: JSON.parse(options.body)}; return Response.json({id:'444',channel_id:'222'}); }
   return Response.json({guild_id:'333',channel_id:String(url).includes('/456/')?'666':'777'});
 };
 const store=storage(); const reports=new Reports({storage:store},env);
 try {
   assert.equal((await reports.fetch(request('/submit',{...body,threadID:'222'}))).status,403);
   await reports.fetch(request('/submit',body));
   const update={...body, reference:'87654321-1234-1234-1234-123456789abc', threadID:'222'};
   const response=await reports.fetch(request('/submit',update));
   assert.equal(response.status,200);
   assert.equal(new URL(posted.url).searchParams.get('thread_id'),'222');
   assert.equal(posted.payload.thread_name,undefined);
   assert.equal(posted.payload.applied_tags,undefined);
   posted = null;
   assert.equal((await reports.fetch(request('/submit',update))).status,200);
   assert.equal(posted,null);
   const other=new Reports({storage:storage()},env);
   assert.equal((await other.fetch(request('/submit',update))).status,403);
 } finally {globalThis.fetch=old;}
});

for (const mode of ['private-malformed', 'public-network', 'public-malformed']) {
 test(`retry after ${mode} never repeats delivery, including after object recreation`, async () => {
  const old=globalThis.fetch; const posts=[]; const store=storage();
  globalThis.fetch=async(url,options)=>{
   const privateDestination=String(url).includes('/456/');
   if(options.method!=='POST') return Response.json({guild_id:'333',channel_id:privateDestination?'666':'777'});
   posts.push(privateDestination?'private':'public');
   if(mode==='private-http' && privateDestination || mode==='public-http' && !privateDestination) return new Response('',{status:429});
   if(mode==='public-network' && !privateDestination) throw Error('lost response');
   if(mode==='private-malformed' && privateDestination || mode==='public-malformed' && !privateDestination) return Response.json({});
   return Response.json({id:'555',channel_id:privateDestination?'666':'222'});
  };
  try {
   assert.equal((await new Reports({storage:store},env).fetch(request('/submit',body))).status,409);
   assert.equal((await new Reports({storage:store},env).fetch(request('/submit',body))).status,409);
   assert.deepEqual(posts,mode.startsWith('private')?['private']:['private','public']);
   assert.ok(!JSON.stringify([...await store.list()]).includes(body.logs));
  } finally {globalThis.fetch=old;}
 });
}
for (const destination of [undefined, 'http://discord.com/api/webhooks/456/privatefake', env.DISCORD_WEBHOOK_URL]) {
 test(`invalid private destination fails closed: ${destination === undefined ? 'missing' : destination.startsWith('http:') ? 'insecure' : 'same'}`,async()=>{
  const old=globalThis.fetch;globalThis.fetch=async()=>{throw Error('must not send');};
  try {assert.equal((await new Reports({storage:storage()},{...env,DISCORD_PRIVATE_WEBHOOK_URL:destination}).fetch(request('/submit',body))).status,503);}finally{globalThis.fetch=old;}
 });
}

 test('large diagnostics accepted within 16 MiB, auth retains 1 MiB bound', async () => {
  const large={logs:'x'.repeat(2*1024*1024)};
  assert.equal((await readJSON(request('/v1/logs',large),16*1024*1024)).logs.length,large.logs.length);
  await assert.rejects(readJSON(request('/auth/discord/exchange',large)), /too large/);
  await assert.rejects(readJSON(request('/v1/logs',{logs:'x'.repeat(16*1024*1024)}),16*1024*1024), /too large/);
 });

for (const failedStage of ['private', 'public']) {
 test(`definite ${failedStage} rejection resumes without duplicate private delivery`, async()=>{
  const old=globalThis.fetch,posts=[];let failed=false;
  globalThis.fetch=async(url,options)=>{
   const stage=String(url).includes('/456/')?'private':'public';
   if(options.method!=='POST')return Response.json({guild_id:'333',channel_id:stage==='private'?'666':'777'});
   posts.push(stage);
   if(stage===failedStage&&!failed){failed=true;return new Response('',{status:429});}
   return Response.json({id:'555',channel_id:stage==='private'?'666':'222'});
  };
  const store=storage();
  try{
   assert.equal((await new Reports({storage:store},env).fetch(request('/submit',body))).status,503);
   assert.equal((await new Reports({storage:store},env).fetch(request('/submit',{...body,logs:'changed'}))).status,409);
   const obj=new Reports({storage:store},env);
   assert.equal((await obj.fetch(request('/submit',body))).status,200);
   assert.equal((await obj.fetch(request('/submit',body))).status,200);
   assert.deepEqual(posts,failedStage==='private'?['private','private','public']:['private','public','public']);
   const listed=await(await obj.fetch(request('/list',{}))).json();assert.deepEqual(listed.reports.map(x=>x.id),['222']);
   assert.ok(!JSON.stringify([...await store.list()]).includes(body.logs));
  }finally{globalThis.fetch=old;}
 });
}
test('list returns newest 100 reports and excludes delivery records',async()=>{
 const store=storage();for(let i=0;i<105;i++)await store.put('thread:'+String(100000+i),{id:String(100000+i),title:'Report '+i,created:i});
 await store.put('report:any',{status:200});
 const list=await(await new Reports({storage:store},env).fetch(request('/list',{}))).json();
 assert.equal(list.reports.length,100);assert.equal(list.reports[0].id,'100104');assert.equal(list.reports[99].id,'100005');
});
test('final thread and delivery save rolls back together on storage failure',async()=>{
 const old=globalThis.fetch;let posts=0;
 globalThis.fetch=async(url,o)=>{const priv=String(url).includes('/456/');if(o.method==='POST'){posts++;return Response.json({id:'555',channel_id:priv?'666':'222'});}return Response.json({guild_id:'333',channel_id:priv?'666':'777'});};
 const store=storage(),put=store.put;store.put=async(k,v)=>{if(v.status===200)throw Error('storage failed');return put(k,v);};
 try{const obj=new Reports({storage:store},env);assert.equal((await obj.fetch(request('/submit',body))).status,409);assert.equal((await obj.fetch(request('/submit',body))).status,409);assert.equal(posts,2);assert.equal(await store.get('thread:222'),undefined);assert.equal((await store.get('report:'+body.reference)).status,409);}finally{globalThis.fetch=old;}
});
test('concurrent submissions reserve once',async()=>{
 const old=globalThis.fetch;let posts=0;
 globalThis.fetch=async(url,o)=>{const priv=String(url).includes('/456/');if(o.method==='POST'){posts++;return Response.json({id:'555',channel_id:priv?'666':'222'});}return Response.json({guild_id:'333',channel_id:priv?'666':'777'});};
 try{const obj=new Reports({storage:storage()},env);const results=await Promise.all([obj.fetch(request('/submit',body)),obj.fetch(request('/submit',body))]);assert.ok(results.some(r=>r.status===200));assert.equal(posts,2);}finally{globalThis.fetch=old;}
});

test('private forum creates a thread and resumes rejected public delivery without duplicating diagnostics', async () => {
 const old=globalThis.fetch, posts=[]; let rejectPublic=true;
 globalThis.fetch=async(url,options)=>{
  const privateDestination=String(url).includes('/456/');
  if(options.method!=='POST') return Response.json({guild_id:'333',channel_id:privateDestination?'666':'777'});
  posts.push(privateDestination?'private':'public');
  if(privateDestination) {
   const payload=JSON.parse(options.body.get('payload_json'));
   assert.ok(payload.thread_name.startsWith('iOS — '));
   assert.deepEqual(payload.allowed_mentions,{parse:[]});
   assert.equal(await options.body.get('files[0]').text(),body.logs);
   return Response.json({id:'555',channel_id:'888'});
  }
  const payload=JSON.parse(options.body);
  assert.ok(payload.content.includes('https://discord.com/channels/333/888/555'));
  assert.ok(!options.body.includes(body.logs));
  if(rejectPublic){rejectPublic=false;return Response.json({code:50013},{status:403});}
  return Response.json({id:'111',channel_id:'222'});
 };
 const store=storage(), configured={...env,DISCORD_PRIVATE_FORUM:'true'};
 try {
  assert.equal((await new Reports({storage:store},configured).fetch(request('/submit',body))).status,503);
  assert.equal((await new Reports({storage:store},configured).fetch(request('/submit',body))).status,200);
  assert.deepEqual(posts,['private','public','public']);
  assert.ok(!JSON.stringify([...await store.list()]).includes(body.logs));
 }finally{globalThis.fetch=old;}
});

const notice={userID:'789',reference:body.reference,version:'1.0.3',build:'79',ready:true,message:'Please test Bluetooth and cellular again. @everyone'};
async function noticeStore(){const s=storage();await s.put('thread:222',{id:'222'});await s.put('report:'+body.reference,{status:200,result:{sent:true,threadURL:'https://discord.com/channels/333/222/111'}});return s;}
test('build notice selects one owned thread, mentions reporter and maintainer, and deduplicates concurrent sends',async()=>{
 const old=globalThis.fetch;let posts=0;const s=await noticeStore();const reports=new Reports({storage:s},env);
 globalThis.fetch=async(url,options)=>{
  if(options.method!=='POST')return Response.json({guild_id:'333'});
  posts++;assert.equal(new URL(url).searchParams.get('thread_id'),'222');assert.equal(new URL(url).searchParams.get('wait'),'true');
  const p=JSON.parse(options.body);assert.deepEqual(p.allowed_mentions,{parse:[],users:['789',env.REPORT_MAINTAINER_ID]});assert.equal(p.thread_name,undefined);assert.equal(p.files,undefined);assert.ok(p.content.includes('build 79'));return Response.json({id:'888',channel_id:'222'});
 };
 try{
  assert.equal((await (await reports.fetch(request('/build-notice-status',notice))).json()).state,'pending');assert.equal(posts,0);
  await Promise.all([reports.fetch(request('/build-notice',notice)),reports.fetch(request('/build-notice',notice))]);
  const restarted=new Reports({storage:s},env);
  assert.equal((await (await restarted.fetch(request('/build-notice',notice))).json()).state,'sent');assert.equal(posts,1);
  await s.delete('report:'+body.reference);
  assert.equal((await (await restarted.fetch(request('/build-notice-status',notice))).json()).state,'sent');
 }finally{globalThis.fetch=old;}
});
test('wrong account, not-ready build, and unconfigured maintainer cannot post notices',async()=>{
 const old=globalThis.fetch;globalThis.fetch=async()=>{assert.fail('No network calls expected')};
 try{
  const empty=new Reports({storage:storage()},env);
  assert.equal((await (await empty.fetch(request('/build-notice',notice))).json()).state,'report_not_found');
  const reports=new Reports({storage:await noticeStore()},env);
  assert.equal((await (await reports.fetch(request('/build-notice',{...notice,ready:false}))).json()).state,'not_ready');
  const missing=new Reports({storage:await noticeStore()},{...env,REPORT_MAINTAINER_ID:''});
  assert.equal((await (await missing.fetch(request('/build-notice',notice))).json()).state,'maintainer_not_configured');
  assert.equal((await worker.fetch(request('/build-notice',notice),env)).status,404);
 }finally{globalThis.fetch=old;}
});
for(const outcome of ['timeout','500','malformed','wrong-thread','403']){
 test(`build notification ${outcome} never duplicates on restart`,async()=>{
  const old=globalThis.fetch;let posts=0;const s=await noticeStore();
  globalThis.fetch=async(url,options)=>{
   if(options.method!=='POST')return Response.json({guild_id:'333'});posts++;
   if(outcome==='timeout')throw Error('lost');
   if(outcome==='500'||outcome==='403')return new Response('',{status:Number(outcome)});
   return Response.json(outcome==='malformed'?{}:{id:'888',channel_id:'999'});
  };
  try{
   await new Reports({storage:s},env).fetch(request('/build-notice',notice));
   const result=await(await new Reports({storage:s},env).fetch(request('/build-notice',notice))).json();
   assert.equal(result.state,outcome==='403'?'rejected':'unconfirmed');assert.equal(posts,1);
  }finally{globalThis.fetch=old;}
 });
}
test('rate-limited notification respects delay then retries only the selected thread',async()=>{
 const old=globalThis.fetch;let posts=0;const s=await noticeStore();const reports=new Reports({storage:s},env);
 globalThis.fetch=async(url,options)=>{if(options.method!=='POST')return Response.json({guild_id:'333'});posts++;return posts===1?Response.json({retry_after:10},{status:429}):Response.json({id:'888',channel_id:'222'});};
 try{
  await reports.fetch(request('/build-notice',notice));await reports.fetch(request('/build-notice',notice));assert.equal(posts,1);
  await s.put('build-notice:1.0.3:79:222',{state:'rate_limited',retryAt:0});
  assert.equal((await(await reports.fetch(request('/build-notice',notice))).json()).state,'sent');assert.equal(posts,2);
 }finally{globalThis.fetch=old;}
});
test('scheduler visits only explicitly selected ready reporters; public status never sends or reveals identities',async()=>{
 const visits=[];const e={...env,BUILD_NOTIFICATIONS:JSON.stringify([notice,{...notice,userID:'456',ready:false}]),REPORTS:{idFromName:id=>id,get:id=>({fetch:async(url)=>{visits.push([id,url]);return Response.json({state:'sent'})}})}};
 await worker.scheduled({},e);assert.deepEqual(visits,[['789','https://reports/build-notice']]);visits.length=0;
 const status=await(await worker.fetch(new Request('https://relay/release-status'),e)).json();
 assert.equal(visits.length,2);assert.ok(visits.every(v=>v[1].endsWith('/build-notice-status')));assert.equal(JSON.stringify(status).includes('789'),false);assert.equal(JSON.stringify(status).includes(body.reference),false);
 visits.length=0;await worker.scheduled({},{...e,BUILD_NOTIFICATIONS:'[]'});assert.equal(visits.length,0);
 await worker.scheduled({},{...e,BUILD_NOTIFICATIONS:JSON.stringify([{...notice,userID:'all'}])});assert.equal(visits.length,0);
});

test('archive notice does not claim TestFlight access',async()=>{
 const old=globalThis.fetch;let posted=false;
 globalThis.fetch=async(url,options)=>{
  if(options.method!=='POST')return Response.json({guild_id:'333'});
  const p=JSON.parse(options.body);assert.ok(p.content.includes('has archived successfully'));assert.ok(p.content.includes('testing-group assignment'));assert.ok(!p.content.includes('is ready in TestFlight'));posted=true;
  return Response.json({id:'888',channel_id:'222'});
 };
 try{const r=new Reports({storage:await noticeStore()},env);assert.equal((await (await r.fetch(request('/build-notice',{...notice,stage:'archived'}))).json()).state,'sent');assert.ok(posted);}finally{globalThis.fetch=old;}
});
