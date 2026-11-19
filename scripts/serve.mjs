// Development static-file server only; no business API or PostgreSQL credentials.
import http from 'node:http';import {readFile} from 'node:fs/promises';
const files={'/':['index.html','text/html'],'/app.js':['app.js','text/javascript'],'/style.css':['style.css','text/css']};
http.createServer(async(req,res)=>{try{const f=files[new URL(req.url,'http://localhost').pathname];if(!f){res.writeHead(404);return res.end('Not found')}res.setHeader('Content-Type',f[1]+'; charset=utf-8');res.setHeader('X-Content-Type-Options','nosniff');res.end(await readFile('dist/'+f[0]))}catch{res.writeHead(503);res.end('Run npm run build first')}}).listen(5173,'0.0.0.0',()=>console.log('Local preview: http://localhost:5173'));
