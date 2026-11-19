import {createCipheriv,createDecipheriv,randomBytes} from 'node:crypto';
import {gzipSync,gunzipSync} from 'node:zlib';
import {TableClient,odata} from '@azure/data-tables';
import {fail} from './access.mjs';

const MAX_BYTES=256*1024, CHUNK=24000, ID=/^(\d{13})\.([0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})$/;
let client;
export function historyStore(){
  const conn=process.env.RELAY_HISTORY_CONNECTION_STRING;
  if(!conn)fail(503,'Transcript history is not configured.');
  return client??=TableClient.fromConnectionString(conn,'RelayHistory');
}
// Old device records keep a stable account identity without migrating any existing invite or cookie.
export function accountOf(device){return device.accountId||device.rowKey;}
function key(){
  const bytes=Buffer.from(process.env.RELAY_HISTORY_KEY||'','base64');
  if(bytes.length!==32)fail(503,'Transcript history is not configured.');
  return bytes;
}
function checked(id){if(typeof id!=='string'||!ID.test(id))fail(400,'Invalid transcript ID.');return id;}
function recordKey(id){
  const [stamp,uuid]=checked(id).split('.');
  return 't_'+String(9999999999999-Number(stamp)).padStart(13,'0')+'_'+uuid;
}
function assertMeta(row){
  if(!['de','en'].includes(row.target)||!Number.isSafeInteger(row.startedAt)||row.startedAt<=0||row.startedAt>Date.now()+300000||!Number.isInteger(row.seconds)||row.seconds<0||row.seconds>86400)fail(400,'Invalid transcript details.');
}
export function pack(account,row){
  assertMeta(row);checked(row.id);if(Number(row.id.split('.')[0])!==row.startedAt)fail(400,'Transcript ID and start time differ.');
  if(typeof row.text!=='string'||!row.text.trim()||Buffer.byteLength(row.text)>MAX_BYTES)fail(400,'A transcript must contain text and fit within 256 KiB.');
  const iv=randomBytes(12),c=createCipheriv('aes-256-gcm',key(),iv);
  c.setAAD(Buffer.from([account,row.id,row.target,row.startedAt,row.seconds].join('|')));
  const payload=Buffer.concat([c.update(gzipSync(row.text)),c.final()]).toString('base64');
  const chunks=payload.match(new RegExp('.{1,'+CHUNK+'}','g'));
  return {partitionKey:account,rowKey:recordKey(row.id),target:row.target,startedAt:row.startedAt,seconds:row.seconds,iv:iv.toString('base64'),tag:c.getAuthTag().toString('base64'),count:chunks.length,...Object.fromEntries(chunks.map((s,i)=>['c'+i,s]))};
}
function meta(row){return {id:String(row.startedAt)+'.'+row.rowKey.split('_')[2],target:row.target,startedAt:Number(row.startedAt),seconds:Number(row.seconds)};}
export function unpack(row){
  const m=meta(row),d=createDecipheriv('aes-256-gcm',key(),Buffer.from(row.iv,'base64'));
  d.setAAD(Buffer.from([row.partitionKey,m.id,m.target,m.startedAt,m.seconds].join('|')));
  d.setAuthTag(Buffer.from(row.tag,'base64'));
  const payload=Buffer.from(Array.from({length:row.count},(_,i)=>row['c'+i]).join(''),'base64');
  return {...m,text:gunzipSync(Buffer.concat([d.update(payload),d.final()]),{maxOutputLength:MAX_BYTES}).toString()};
}
export async function save(device,input,db=historyStore()){
  const account=accountOf(device),entity=pack(account,input);
  try{await db.createEntity(entity);}catch(e){
    // Safe retry if the first response was lost; never overwrite an existing transcript.
    if(e.statusCode!==409)throw e;
    const old=await read(device,input.id,db);
    if(old.text!==input.text||old.startedAt!==input.startedAt||old.seconds!==input.seconds||old.target!==input.target)fail(409,'A different transcript already has that ID.');
  }
  return {id:input.id};
}
export async function list(device,after=null,db=historyStore()){
  const owner=accountOf(device),rows=[];
  const filter=after===null?odata`PartitionKey eq ${owner}`:odata`PartitionKey eq ${owner} and RowKey gt ${recordKey(after)}`;
  const pages=db.listEntities({queryOptions:{filter,select:['rowKey','target','startedAt','seconds']}}).byPage({maxPageSize:31});
  for await(const page of pages){for(const row of page){rows.push(meta(row));if(rows.length===31)break;}if(rows.length===31)break;}
  return {items:rows.slice(0,30),next:rows.length>30?rows[29].id:null};
}
export async function read(device,id,db=historyStore()){
  try{return unpack(await db.getEntity(accountOf(device),recordKey(id)));}
  catch(e){if(e.statusCode===404)fail(404,'Transcript not found.');throw e;}
}
export async function remove(device,id,db=historyStore()){
  try{await db.deleteEntity(accountOf(device),recordKey(id));}catch(e){if(e.statusCode!==404)throw e;}
  return {deleted:true};
}
