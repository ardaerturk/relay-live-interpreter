import { fail } from './access.mjs';
export const MODEL='gpt-realtime-translate';
export function validateOffer(body) {
  if(!['en','de'].includes(body.target)) fail(400,'Choose English or German.');
  if(typeof body.sdp!=='string' || !body.sdp.startsWith('v=0') || !/^m=audio /m.test(body.sdp) || /^m=video /m.test(body.sdp)) fail(400,'Invalid audio offer.');
}
export async function negotiate({target,sdp}, send=fetch) {
  const endpoint=process.env.AZURE_OPENAI_ENDPOINT, key=process.env.RELAY_AZURE_OPENAI_API_KEY;
  if(!/^https:\/\/[a-z0-9-]+\.openai\.azure\.com\/?$/.test(endpoint||'') || !key) fail(503,'The Azure interpreter has not been configured.');
  const base=endpoint.replace(/\/$/,'')+'/openai/v1/realtime/translations';
  const check=r=>{
    if(r.status===429) fail(429,'The interpreter is busy. Try again in a moment.');
    if(!r.ok) { console.error('Translation service returned HTTP',r.status); fail(502,'The interpreter could not connect. Try again.'); }
  };
  const minted=await send(base+'/client_secrets',{method:'POST',signal:AbortSignal.timeout(12000),headers:{'api-key':key,'content-type':'application/json'},body:JSON.stringify({session:{model:MODEL,audio:{output:{language:target}}}})});
  check(minted);
  const {value,session}=await minted.json();
  if(!value || (session?.model && session.model!==MODEL)) fail(502,'Azure did not open a translation session.');
  const answer=await send(base+'/calls',{method:'POST',signal:AbortSignal.timeout(15000),headers:{authorization:'Bearer '+value,'content-type':'application/sdp'},body:sdp});
  check(answer);
  const remote=await answer.text(); if(!remote.startsWith('v=0')) fail(502,'Azure returned an invalid call.');
  return {sdp:remote};
}
