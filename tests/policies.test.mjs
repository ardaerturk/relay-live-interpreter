import test from 'node:test';
import assert from 'node:assert/strict';
import {issue,redeem,authenticate,reserveStart,revoke,DAY} from '../lib/access.mjs';
import {negotiate,validateOffer,MODEL} from '../lib/translator.mjs';
import access from '../api/access.js';
import connect from '../api/connect.js';
class FakeTable{
  rows=new Map();
  async createEntity(x){this.rows.set(x.rowKey,{...x,etag:1});}
  async getEntity(p,k){const x=this.rows.get(k);if(!x)throw {statusCode:404};return {...x};}
  async updateEntity(x,_m,{etag}){const prev=this.rows.get(x.rowKey);if(etag!==prev.etag)throw {statusCode:412};this.rows.set(x.rowKey,{...prev,...x,etag:etag+1});}
}
test('an invite yields only one device cookie, including simultaneous claims; revocation and expiry apply to paid calls',async()=>{
  const db=new FakeTable(),{invite,id}=await issue('phone',db);
  const claims=await Promise.allSettled([redeem(invite,db),redeem(invite,db)]);
  const [ok]=claims.filter(x=>x.status==='fulfilled');assert.equal(claims.filter(x=>x.status==='fulfilled').length,1);
  assert.equal((await authenticate(ok.value,db)).rowKey,id);assert.equal(await authenticate(id+'.'+'X'.repeat(43),db),null);
  await assert.rejects(()=>redeem(invite,db),{status:403});await revoke(id,db);assert.equal(await authenticate(ok.value,db),null);
  const stale=await issue('expired',db);db.rows.get(stale.id).inviteExpiry=Date.now()-1;
  await assert.rejects(()=>redeem(stale.invite,db),{status:403});
  const exp=await issue('session expiry',db);const cookie=await redeem(exp.invite,db);
  db.rows.get(exp.id).sessionExpiry=Date.now()-1;assert.equal(await authenticate(cookie,db),null);
});
test('starts are shared and bounded, and reset on a new UTC day',async()=>{
  const db=new FakeTable(),{invite}=await issue('test',db);const cookie=await redeem(invite,db);const row=()=>authenticate(cookie,db);
  const day=Date.UTC(2026,10,19,1);
  await reserveStart(await row(),db,day);const current=await row();
  await assert.rejects(()=>reserveStart(current,db,day+100),{status:429});
  for(let i=1;i<20;i++)await reserveStart(await row(),db,day+i*10000);
  await assert.rejects(async()=>reserveStart(await row(),db,day+300000),{status:429});
  await reserveStart(await row(),db,day+DAY);assert.equal((await row()).starts,1);
});
test('negotiation uses only the dedicated Azure translation model and returns only the SDP',async()=>{
  process.env.AZURE_OPENAI_ENDPOINT='https://test.openai.azure.com';process.env.RELAY_AZURE_OPENAI_API_KEY='test-only';
  const sdp='v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111', calls=[];const mock=async(url,opt)=>{
    calls.push([url,opt]);return calls.length===1?Response.json({value:'temporary',session:{model:MODEL}}):new Response(sdp);
  };
  assert.deepEqual(await negotiate({target:'de',sdp},mock),{sdp});
  assert.match(calls[0][0],/\/translations\/client_secrets$/);assert.deepEqual(JSON.parse(calls[0][1].body).session,{model:'gpt-realtime-translate',audio:{output:{language:'de'}}});
  assert.equal(calls[1][1].headers.authorization,'Bearer temporary');assert.match(calls[1][0],/\/translations\/calls$/);
  assert.throws(()=>validateOffer({target:'tr',sdp}),{status:400});assert.throws(()=>validateOffer({target:'de',sdp:sdp+'\r\nm=video 0 RTP/AVP 96'}),{status:400});
});
test('cross-origin and anonymous starts cannot mint Azure sessions',async()=>{
  process.env.APP_ORIGIN='http://localhost:4173';
  const req=async(fn,method,origin,body={})=>{let result;const res={setHeader(){},end(x){result=JSON.parse(x);}};await fn({method,headers:{origin,'content-type':'application/json'},body},res);return {status:res.statusCode,result};};
  assert.equal((await req(connect,'POST','http://unrelated.example')).status,403);
  assert.equal((await req(connect,'POST',process.env.APP_ORIGIN)).status,401);
  assert.deepEqual((await req(access,'GET',null)).result,{unlocked:false});
});
