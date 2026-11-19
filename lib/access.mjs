import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import { TableClient } from '@azure/data-tables';

export const DAY = 86400_000;
const partition = 'device';
const random = () => randomBytes(32).toString('base64url');
const digest = value => createHash('sha256').update(value).digest('hex');
export function fail(status, message) { throw Object.assign(new Error(message), { status }); }
let cached;
export function store() {
  if (!process.env.AZURE_TABLE_CONNECTION_STRING) fail(503, 'Device access has not been configured.');
  return cached ??= TableClient.fromConnectionString(process.env.AZURE_TABLE_CONNECTION_STRING, 'RelayDevices');
}
async function get(id, db) {
  try { return await db.getEntity(partition, id); }
  catch (e) { if (e.statusCode !== 404) throw e; }
}
async function update(db, row, patch, conflictMessage) {
  try { await db.updateEntity({ partitionKey: partition, rowKey: row.rowKey, ...patch }, 'Merge', { etag: row.etag }); }
  catch (e) { if ([404, 412].includes(e.statusCode)) fail(409, conflictMessage); throw e; }
}
export async function issue(label, db=store(), sameAccountDeviceId) {
  const invite = random(), id = digest(invite);
  let accountId=id;
  if(sameAccountDeviceId!==undefined){
    if(!/^[a-f0-9]{64}$/.test(sameAccountDeviceId))fail(400,'Invalid existing device ID.');
    const prior=await get(sameAccountDeviceId,db);if(!prior)fail(404,'Existing device not found.');
    accountId=prior.accountId||prior.rowKey;
  }
  await db.createEntity({ partitionKey: partition, rowKey:id, accountId, label, inviteExpiry:Date.now()+DAY, redeemed:false, revoked:false });
  return { invite, id };
}
export async function redeem(invite, db=store()) {
  const invalid = () => fail(403, 'This invite has expired or has already been used. Request a fresh invite.');
  if (typeof invite !== 'string' || !/^[\w-]{43}$/.test(invite)) invalid();
  const id = digest(invite), row = await get(id, db), now=Date.now();
  if (!row || row.revoked || row.redeemed || Number(row.inviteExpiry)<=now) invalid();
  const secret=random();
  await update(db,row,{redeemed:true,sessionHash:digest(secret),sessionExpiry:now+30*DAY},'This invite has already been used.');
  return id+'.'+secret;
}
export async function authenticate(cookie, db) {
  const match=/^([a-f0-9]{64})\.([\w-]{43})$/.exec(cookie || '');
  if (!match) return null;
  const row=await get(match[1],db ?? store());
  if (!row?.redeemed || row.revoked || Number(row.sessionExpiry)<=Date.now() || !/^[a-f0-9]{64}$/.test(row.sessionHash)) return null;
  return timingSafeEqual(Buffer.from(row.sessionHash,'hex'),Buffer.from(digest(match[2]),'hex')) ? row : null;
}
export async function reserveStart(row,db=store(),now=Date.now()) {
  const day=new Date(now).toISOString().slice(0,10), starts=row.day===day ? Number(row.starts) : 0;
  if (starts>=20) fail(429,'This device has reached its 20 session starts for today (UTC).');
  if (now-Number(row.lastStart || 0)<6000) fail(429,'Wait a few seconds before starting again.');
  await update(db,row,{day,starts:starts+1,lastStart:now},'Another request changed this session. Try again.');
}
export async function revoke(id,db=store()) {
  const row=await get(id,db); if (!row) fail(404,'Device not found.');
  await update(db,row,{revoked:true},'Device changed; retry revocation.');
}
