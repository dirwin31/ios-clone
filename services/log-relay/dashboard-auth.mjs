const authJSON=(body,status=200)=>Response.json(body,{status,headers:{'Cache-Control':'no-store'}});
const authToken=()=>Array.from(crypto.getRandomValues(new Uint8Array(32)),b=>b.toString(16).padStart(2,'0')).join('');
const authDigest=async value=>Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(value))),b=>b.toString(16).padStart(2,'0')).join('');
async function passwordHash(password,salt){
 const material=await crypto.subtle.importKey('raw',new TextEncoder().encode(password),'PBKDF2',false,['deriveBits']);
 const bytes=await crypto.subtle.deriveBits({name:'PBKDF2',hash:'SHA-256',salt:new TextEncoder().encode(salt),iterations:100000},material,256);
 return Array.from(new Uint8Array(bytes),b=>b.toString(16).padStart(2,'0')).join('');
}
function sameHash(a,b){if(typeof a!=='string'||typeof b!=='string'||a.length!==b.length)return false;let d=0;for(let i=0;i<a.length;i++)d|=a.charCodeAt(i)^b.charCodeAt(i);return d===0;}
export async function dashboardAuth(storage,path,body){
 const now=Date.now();
 if(path==='/auth-state')return authJSON({configured:!!await storage.get('auth:password')});
 if(path==='/auth-invite'){
  if(await storage.get('auth:password'))return authJSON({error:'A password has already been created.'},409);
  const invite=authToken();await storage.put('auth:invite',{hash:await authDigest(invite),expires:now+7*86400000});return authJSON({invite});
 }
 if(path==='/auth-verify'||path==='/auth-logout'){
  if(!/^[a-f0-9]{64}$/.test(body.token||''))return authJSON({error:'Sign in again.'},401);
  const name='auth:session:'+await authDigest(body.token),session=await storage.get(name);
  if(path==='/auth-logout'){await storage.delete(name);return authJSON({signedOut:true});}
  if(!session||session.expires<=now)return authJSON({error:'Your session expired. Sign in again.'},401);
  return authJSON({authorized:true});
 }
 if(!['/auth-setup','/auth-login'].includes(path))return authJSON({error:'Not found'},404);
 const bucket='auth:attempt:'+await authDigest(String(body.ip||'unknown'));
 const limited=await storage.transaction(async s=>{let b=await s.get(bucket);if(!b||b.expires<=now)b={count:0,expires:now+600000};if(b.count>=10)return true;b.count++;await s.put(bucket,b);return false;});
 await storage.setAlarm(now+86400000);
 if(limited)return authJSON({error:'Too many attempts. Try again in 10 minutes.'},429);
 if(typeof body.password!=='string'||body.password.length<8||body.password.length>128)return authJSON({error:'Use a password between 8 and 128 characters.'},400);
 if(path==='/auth-setup'){
  const invite=await storage.get('auth:invite');
  if(!invite||invite.expires<=now||!sameHash(await authDigest(String(body.invite||'')),invite.hash))return authJSON({error:'Open your password setup link to create your password.'},403);
  const salt=authToken(),hash=await passwordHash(body.password,salt);
  const saved=await storage.transaction(async s=>{const current=await s.get('auth:invite');if(await s.get('auth:password'))return false;if(!current||current.expires<=Date.now()||current.hash!==invite.hash)return false;await s.put('auth:password',{salt,hash});await s.delete('auth:invite');return true;});
  if(!saved)return authJSON({error:'A password has already been created. Sign in instead.'},409);
 }else{
  const password=await storage.get('auth:password');
  if(!password||!sameHash(await passwordHash(body.password,password.salt),password.hash))return authJSON({error:'Incorrect password.'},401);
 }
 const token=authToken();await storage.put('auth:session:'+await authDigest(token),{expires:now+8*3600000});
 await storage.delete(bucket);return authJSON({token,expires:now+8*3600000});
}
