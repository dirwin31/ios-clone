// Produce a single module for Cloudflare's browser editor, without dependencies.
import {readFile,writeFile,mkdir} from 'node:fs/promises';
const base=new URL('.',import.meta.url);
const modules=['dashboard-ui.mjs','dashboard.mjs','worker.mjs'];
const chunks=[];
for(const name of modules){let source=await readFile(new URL(name,base),'utf8');source=source.replace(/^import .* from '\.\/dashboard(?:-ui)?\.mjs';\r?\n/gm,'');if(name!=='worker.mjs')source=source.replace(/^export /gm,'');chunks.push(source);}
await mkdir(new URL('dist/',base),{recursive:true});
await writeFile(new URL('dist/worker.mjs',base),chunks.join('\n'));
console.log('Built dist/worker.mjs');
