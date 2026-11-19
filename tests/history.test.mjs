import test from 'node:test';
import assert from 'node:assert/strict';
import {randomBytes,randomUUID} from 'node:crypto';
import {pack,unpack,save,read,remove,accountOf} from '../lib/history.mjs';
import {issue} from '../lib/access.mjs';
import history from '../api/history.js';
process.env.RELAY_HISTORY_KEY=randomBytes(32).toString('base64');
const startedAt=Date.now();
const record={id:startedAt+'.'+randomUUID(),target:'de',startedAt,seconds:38,text:'Zwei Stimmen – Grüße aus Köln. '};
class Table {
  rows=new Map();
  k(p,r){return p+'/'+r;}
  async createEntity(v){const k=this.k(v.partitionKey,v.rowKey);if(this.rows.has(k))throw {statusCode:409};this.rows.set(k,v);}
  async getEntity(p,r){const v=this.rows.get(this.k(p,r));if(!v)throw {statusCode:404};return v;}
  async deleteEntity(p,r){if(!this.rows.delete(this.k(p,r)))throw {statusCode:404};}
}
test('linked invites inherit legacy and new accounts; devices never choose their partition over HTTP',async()=>{
  const db=new Table();const old='a'.repeat(64);await db.createEntity({partitionKey:'device',rowKey:old});
  const child=await issue('other device',db,old);const d=await db.getEntity('device',child.id);assert.equal(accountOf(d),old);
  const newAcct=await issue('independent',db);assert.equal(accountOf(await db.getEntity('device',newAcct.id)),newAcct.id);
  await assert.rejects(()=>issue('unknown',db,'b'.repeat(64)),{status:404});
});
test('saved words are encrypted and bound to the account and metadata, including multi-property entries',()=>{
  const text=randomBytes(150000).toString('base64')+' İstanbul.';
  const row=pack('account',{...record,text});assert(row.count>1);
  assert.equal(unpack(row).text,text);assert(!JSON.stringify(row).includes('İstanbul'));
  assert.throws(()=>unpack({...row,partitionKey:'other'}));assert.throws(()=>unpack({...row,target:'en'}));
  assert.throws(()=>pack('account',{...record,text:'ü'.repeat(131073)}),{status:400});
});
test('independent accounts cannot read or delete a saved transcript; retry is idempotent',async()=>{
  const db=new Table(),a={rowKey:'phone'},b={rowKey:'second',accountId:'phone'},outsider={rowKey:'other'};
  await save(a,record,db);await save(b,record,db);await assert.rejects(()=>save(b,{...record,text:'replacement'},db),{status:409});
  await assert.rejects(()=>read(outsider,record.id,db),{status:404});await remove(outsider,record.id,db);
  assert.deepEqual(await read(b,record.id,db),record);await remove(b,record.id,db);await assert.rejects(()=>read(a,record.id,db),{status:404});
});
test('anonymous and foreign-origin history requests are rejected before storage',async()=>{
  process.env.APP_ORIGIN='https://relay.example';
  for(const [method,origin,status] of [['GET',undefined,401],['POST','https://relay.example',401],['DELETE','https://other.example',403]]){
    const res={setHeader(){},end(){}};
    await history({method,headers:{origin},url:'/api/history'},res);assert.equal(res.statusCode,status);
  }
});
