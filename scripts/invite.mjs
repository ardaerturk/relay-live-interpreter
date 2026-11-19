import {writeFile} from 'node:fs/promises';
import {issue, revoke, store} from '../lib/access.mjs';
import {origin} from '../lib/http.mjs';
const [action,label,path,priorDevice]=process.argv.slice(2);
if(action==='issue' && label && path) {
  const app=origin(); const db=store(); await db.createTable();
  const {invite,id}=await issue(label,db,priorDevice);
  try {
    await writeFile(path,app+'/#invite='+invite+'\n',{mode:0o600,flag:'wx'});
  } catch(e){await revoke(id,db); throw e;}
  console.log('Private invitation saved. Expires in 24 hours. Device ID:',id);
} else if(action==='revoke' && /^[0-9a-f]{64}$/.test(label || '')) {
  await revoke(label); console.log('Revoked.');
} else { console.error('Usage: npm run invite -- issue "device label" /private/new-file.txt [EXISTING_DEVICE_ID]  |  revoke DEVICE_ID');process.exitCode=1; }
