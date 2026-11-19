// Operator only. Keeps the encryption key stable on reruns. All secrets go via stdin, never argv.
import {randomBytes} from 'node:crypto';
import {appendFile,chmod} from 'node:fs/promises';
import {spawnSync} from 'node:child_process';
import {AzureNamedKeyCredential,generateTableSas,TableClient} from '@azure/data-tables';
const scope=process.argv[2],conn=process.env.AZURE_TABLE_CONNECTION_STRING||'';
if(scope&&!/^[a-z0-9-]+$/.test(scope))throw Error('Invalid Vercel scope.');
const name=conn.match(/(?:^|;)AccountName=([^;]+)/)?.[1],shared=conn.match(/(?:^|;)AccountKey=([^;]+)/)?.[1];
if(!name||!shared)throw Error('Run with the private operator connection string in .env.local.');
const table=TableClient.fromConnectionString(conn,'RelayHistory');
await table.createTable();
if(!process.env.RELAY_HISTORY_KEY && !(await table.listEntities({queryOptions:{select:['rowKey']}})[Symbol.asyncIterator]().next()).done)throw Error('History exists. Restore the original encryption key before continuing.');
const expiresOn=new Date(Date.now()+365*86400000);
const sig=generateTableSas('RelayHistory',new AzureNamedKeyCredential(name,shared),{protocol:'https',permissions:{query:true,add:true,delete:true},expiresOn});
const limited='TableEndpoint=https://'+name+'.table.core.windows.net;SharedAccessSignature='+sig;
const key=process.env.RELAY_HISTORY_KEY||randomBytes(32).toString('base64');
if(Buffer.from(key,'base64').length!==32)throw Error('Invalid existing encryption key.');
if(!process.env.RELAY_HISTORY_KEY)await appendFile('.env.local','\nRELAY_HISTORY_KEY='+key+'\n',{mode:0o600});
if(!process.env.RELAY_HISTORY_CONNECTION_STRING)await appendFile('.env.local','RELAY_HISTORY_CONNECTION_STRING='+conn+'\n',{mode:0o600});
await chmod('.env.local',0o600);
if(scope)for(const [label,value] of Object.entries({RELAY_HISTORY_CONNECTION_STRING:limited,RELAY_HISTORY_KEY:key})){
  const r=spawnSync('npx',['--yes','vercel@66.2.0','env','add',label,'--environment','production','--sensitive','--yes','--force','--scope',scope],{input:value,encoding:'utf8'});
  if(r.status!==0)throw Error('Could not configure '+label+'.');
}
console.log(scope?'History configured for production. Renew the table grant before '+expiresOn.toISOString().slice(0,10)+'.':'Local history configured.');
