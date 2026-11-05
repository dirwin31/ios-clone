import {readFile, writeFile, mkdir, chmod} from 'node:fs/promises';
import {homedir} from 'node:os';
import {dirname, join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {randomBytes} from 'node:crypto';
import {existsSync} from 'node:fs';

export const defaultRegistry = fileURLToPath(new URL('../../../private-handoff/contacts.json', import.meta.url));
const workspaceKeyFile=fileURLToPath(new URL('../../../private-handoff/release-keys/ios.json', import.meta.url));
export const defaultKeyFile = existsSync(workspaceKeyFile) ? workspaceKeyFile : join(homedir(), '.config', 'starpilot-notify', 'ios.json');
export async function setupKey(path) {
  await mkdir(dirname(path), {recursive:true, mode:0o700});
  // Never silently replace a key already configured in Cloudflare.
  await writeFile(path, JSON.stringify({key:randomBytes(32).toString('hex')})+'\n', {flag:'wx', mode:0o600});
  if (process.platform !== 'win32') await chmod(path, 0o600);
}
export async function loadKey(path) {
  if (process.env.IOS_RELEASE_KEY) return process.env.IOS_RELEASE_KEY;
  try { return JSON.parse(await readFile(path,'utf8')).key; }
  catch { throw Error('No saved key. Run --setup once, or set IOS_RELEASE_KEY.'); }
}
export function resolveReport(text, explicitUser, registry) {
  const refs=[...new Set((text.match(/\b[\da-f]{8}-[\da-f]{4}-[\da-f]{4}-[\da-f]{4}-[\da-f]{12}\b/gi)||[]).map(s=>s.toUpperCase()))];
  if(refs.length!==1) throw Error('Provide exactly one report reference or one copied report.');
  const reference=refs[0], users=new Set();
  if(explicitUser) users.add(explicitUser);
  for(const match of text.matchAll(/Report from\s+<@!?(\d{1,20})>/gi)) users.add(match[1]);
  for(const person of registry?.people || []) {
    if(person.platform && person.platform!=='ios') continue;
    if((person.reports||[]).some(r=>typeof r==='string' && r.toUpperCase()===reference) && person.discord_user_id) users.add(person.discord_user_id);
  }
  if(users.size!==1 || !/^\d{1,20}$/.test([...users][0])) throw Error(users.size>1?'Conflicting reporter identities; nothing sent.':'Reporter not found. Paste the original report containing its Discord mention, or use --user once.');
  return {reference,userID:[...users][0]};
}
export async function loadRegistry(path) {
  try {return JSON.parse(await readFile(path,'utf8'));}
  catch(error) {if(error.code==='ENOENT') return null;throw Error('Cannot read the support registry.');}
}
