// Requires a linked Vercel project and explicit Vercel scope. Secrets travel only over stdin.
import {AzureNamedKeyCredential,generateTableSas,TableClient} from '@azure/data-tables';
import {spawnSync} from 'node:child_process';
const [scope,...args]=process.argv.slice(2);
if(!scope || !/^[a-z0-9-]+$/.test(scope) || args.some(x=>x!=='--rotate'))throw Error('Usage: node --env-file=.env.local scripts/hosting-env.mjs VERCEL_SCOPE [--rotate]');
const conn=process.env.AZURE_TABLE_CONNECTION_STRING || '';
const name=conn.match(/(?:^|;)AccountName=([^;]+)/)?.[1],key=conn.match(/(?:^|;)AccountKey=([^;]+)/)?.[1];
if(!name || !key)throw Error('Use the private operator connection string.');
const expiresOn=new Date(Date.now()+365*86400000);
const sas=generateTableSas('RelayDevices',new AzureNamedKeyCredential(name,key),{protocol:'https',permissions:{query:true,update:true},expiresOn,startPartitionKey:'device',endPartitionKey:'device'});
const scoped='TableEndpoint=https://'+name+'.table.core.windows.net;SharedAccessSignature='+sas;
const db=TableClient.fromConnectionString(scoped,'RelayDevices');await db.listEntities().byPage({maxPageSize:1}).next();
for(const [k,v] of Object.entries({AZURE_OPENAI_ENDPOINT:process.env.AZURE_OPENAI_ENDPOINT,RELAY_AZURE_OPENAI_API_KEY:process.env.RELAY_AZURE_OPENAI_API_KEY,AZURE_TABLE_CONNECTION_STRING:scoped})){
  if(!v)throw Error('Missing '+k);
  const cmd=['--yes','vercel@66.2.0','env','add',k,'--environment','production','--sensitive','--yes','--scope',scope,...(args.includes('--rotate')?['--force']:[])];
  const r=spawnSync('npx',cmd,{input:v,encoding:'utf8',stdio:['pipe','pipe','pipe']});
  if(r.status!==0)throw Error('Vercel did not accept '+k+' (exit '+r.status+'). Review vercel env ls before retrying.');
  console.log('Configured '+k+'.');
}
console.log('Renew the limited table SAS before '+expiresOn.toISOString().slice(0,10)+', then redeploy.');
