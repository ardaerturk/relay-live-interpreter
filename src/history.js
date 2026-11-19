// All text is set as textContent; nothing from a transcript becomes markup.
const $=id=>document.getElementById(id);
const format=new Intl.DateTimeFormat(undefined,{dateStyle:'medium',timeStyle:'short'});
const language=t=>t==='de'?'German':'English';
function element(tag,text,cls){const el=document.createElement(tag);el.textContent=text;if(cls)el.className=cls;return el;}
async function request(path,options={}){
  const r=await fetch('/api/history'+path,{cache:'no-store',...options});const value=await r.json();
  if(!r.ok)throw Error(value.error||'History is unavailable.');return value;
}
export function saveTranslation(record){return request('',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(record)});}
let next=null,selection=null,version=0;
function message(text){$('history-message').textContent=text;}
async function browse(append=false){
  const gen=++version;selection=null;$('history-detail').hidden=true;$('history-list').hidden=false;
  if(!append)$('saved-items').replaceChildren();$('more-history').hidden=true;message('Loading…');
  try{const data=await request(append?'?after='+encodeURIComponent(next):'');if(gen!==version)return;next=data.next;
    for(const item of data.items){const btn=element('button','','history-row');btn.append(element('strong',language(item.target)+' translation'),element('span',format.format(item.startedAt)+' · '+Math.max(1,Math.ceil(item.seconds/60))+' min'));btn.onclick=()=>detail(item.id);$('saved-items').append(btn);}
    $('more-history').hidden=!next;message($('saved-items').children.length?'':'No saved transcripts yet. After listening, tap Save.');
  }catch(e){if(gen===version)message(e.message);}
}
async function detail(id){
  const gen=++version;message('Loading…');$('history-list').hidden=true;$('history-detail').hidden=false;$('saved-text').textContent='';$('saved-title').textContent='';$('delete-transcript').hidden=true;$('delete-choice').hidden=true;
  try{const item=await request('?id='+encodeURIComponent(id));if(gen!==version)return;selection=item.id;$('saved-title').textContent=language(item.target)+' · '+format.format(item.startedAt);$('saved-text').textContent=item.text;$('delete-transcript').hidden=false;message('');}
  catch(e){if(gen===version)message(e.message);}
}
export function openHistory(){if(!$('history').open)$('history').showModal();browse();}
$('more-history').onclick=()=>browse(true);$('back-history').onclick=()=>browse();
$('history').addEventListener('close',()=>{version++;selection=null;next=null;$('saved-items').replaceChildren();$('saved-text').textContent='';$('saved-title').textContent='';message('');});
$('delete-transcript').onclick=()=>{$('delete-choice').hidden=false;$('delete-transcript').hidden=true;};
$('keep-transcript').onclick=()=>{$('delete-choice').hidden=true;$('delete-transcript').hidden=false;};
$('confirm-delete').onclick=async()=>{const id=selection;if(!id)return;$('confirm-delete').disabled=true;
 try{await request('?id='+encodeURIComponent(id),{method:'DELETE'});if(selection===id)await browse();}
 catch(e){message(e.message);}finally{$('confirm-delete').disabled=false;}};
