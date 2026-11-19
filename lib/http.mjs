import { fail } from './access.mjs';
export function origin() {
  const specified=process.env.APP_ORIGIN || (process.env.VERCEL_PROJECT_PRODUCTION_URL ? 'https://'+process.env.VERCEL_PROJECT_PRODUCTION_URL : undefined);
  if(!specified || !/^https:\/\/|^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(specified)) fail(503,'App origin has not been configured.');
  return new URL(specified).origin;
}
export function deviceCookie(req) {
  const name = origin().startsWith('https:')?'__Host-relay':'relay-local';
  return (req.headers.cookie || '').split(';').map(x=>x.trim()).find(x=>x.startsWith(name+'='))?.slice(name.length+1);
}
export function setDevice(res,value) {
  const secure=origin().startsWith('https:');
  res.setHeader('Set-Cookie',(secure?'__Host-relay':'relay-local')+'='+value+'; Path=/; HttpOnly; SameSite=Strict; Max-Age='+(value?2592000:0)+(secure?'; Secure':''));
}
export function route(run) {
  return async(req,res)=>{
    res.setHeader('Cache-Control','private, no-store');
    res.setHeader('Content-Type','application/json; charset=utf-8');
    res.setHeader('X-Content-Type-Options','nosniff');
    try {
      if (req.method!=='GET' && req.headers.origin!==origin()) fail(403,'Open Relay on its original address.');
      const result=await run(req,res); res.statusCode=200; res.end(JSON.stringify(result));
    } catch (e) {
      const code=e.status || 503;
      if(!e.status) console.error('Relay request failed:',e.name,e.statusCode || 'internal');
      res.statusCode=code; res.end(JSON.stringify({error:e.status?e.message:'Relay could not reach its service. Please try again.'}));
    }
  };
}
export async function readBody(req,limit) {
  if (!/^application\/json(?:\s*;|$)/i.test(req.headers['content-type'] || '')) fail(415,'Expected JSON.');
  if (Number(req.headers['content-length'])>limit) fail(413,'Request is too large.');
  let value=req.body;
  if(value===undefined) {
    let chunks=[],size=0;
    for await (const part of req) { size+=Buffer.byteLength(part); if(size>limit) fail(413,'Request is too large.'); chunks.push(Buffer.from(part)); }
    value=Buffer.concat(chunks).toString();
  }
  if(Buffer.byteLength(typeof value==='string'?value:JSON.stringify(value))>limit) fail(413,'Request is too large.');
  if(typeof value==='string') {try{value=JSON.parse(value)} catch {fail(400,'Invalid JSON.');}}
  if(!value || typeof value!=='object' || Array.isArray(value)) fail(400,'Invalid request.');
  return value;
}
