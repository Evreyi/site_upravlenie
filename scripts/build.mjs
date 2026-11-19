import {build} from 'esbuild';
import {mkdir,readFile,writeFile,copyFile} from 'node:fs/promises';
let env={};try{for(const line of (await readFile('.env','utf8')).split('\n')){const m=line.match(/^([A-Z_]+)=(.*)$/);if(m)env[m[1]]=m[2].trim()}}catch{}
const url=process.env.SUPABASE_URL||env.SUPABASE_URL||'',key=process.env.SUPABASE_PUBLISHABLE_KEY||env.SUPABASE_PUBLISHABLE_KEY||'';
if(url&&!/^https:\/\/[a-z0-9.-]+(?::\d+)?$/.test(url))throw Error('SUPABASE_URL must be an HTTPS origin');
if(key&&!key.startsWith('sb_publishable_'))throw Error('Use only sb_publishable_ key, never a database password or service_role key');
if(!url||!key)console.warn('Supabase is not configured: building the setup screen. Set the two public variables before deployment.');
await mkdir('dist',{recursive:true});await build({entryPoints:['src/app.js'],bundle:true,outfile:'dist/app.js',format:'esm',target:'es2022',minify:true,define:{SUPABASE_URL:JSON.stringify(url),SUPABASE_KEY:JSON.stringify(key)}});await copyFile('src/style.css','dist/style.css');await copyFile('src/index.html','dist/index.html');await writeFile('dist/.nojekyll','');console.log('Built dist/');
