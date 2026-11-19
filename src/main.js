import {TranslationCall} from './call.js';
import {openHistory,saveTranslation} from './history.js';
const $=id=>document.getElementById(id);
const target=$('target'), access=$('access'), guide=$('guide'), audio=$('output');
let savedRecord=null,unlocked=false,call=null,wake=null,ticker=0,levelBusy=false,started=0,words='',record=null,afterUnlock=null;
const bars=[];
for(let x=1;x<560;x+=5){
  const p=x/560, h=2+47*(.18+.82*Math.abs(Math.sin(22*p)))*Math.exp(-(((p-.54)/.30)**2))*Math.abs(Math.sin(p*Math.PI))*(.66+.34*Math.abs(Math.sin(51*p)));
  const el=document.createElementNS('http://www.w3.org/2000/svg','line');
  for(const [k,v] of Object.entries({x1:x,x2:x,stroke:'currentColor','stroke-width':2.4,'stroke-linecap':'round'}))el.setAttribute(k,v);
  bars.push({el,h});$('wave').append(el);
}
function draw(gain){for(const {el,h} of bars){el.setAttribute('y1',57-h*gain);el.setAttribute('y2',57+h*gain);}}
draw(1);
try{target.value=localStorage.getItem('relay-target')==='de'?'de':'en';}catch{}
function lang(){ $('target-label').textContent=target.selectedOptions[0].textContent; }
lang();target.onchange=()=>{lang();try{localStorage.setItem('relay-target',target.value);}catch{}};
function notice(msg){$('notice').textContent=msg;$('notice').hidden=!msg;}
function state(next){
  document.body.dataset.state=next;
  $('status').textContent=({idle:'Standby',connecting:'Connecting',live:'Listening'})[next];
  $('action-text').textContent=({idle:'Start listening',connecting:'Cancel',live:'Stop listening'})[next];
  $('action-icon').setAttribute('href','/icons.svg#'+(next==='idle'?'headphones':'stop'));
  target.disabled=next!=='idle';$('mic').disabled=$('refresh-mics').disabled=next!=='idle';
}
function captions(delta){
  const b=$('caption-box'), nearEnd=b.scrollHeight-b.clientHeight-b.scrollTop<28;
  words+=delta;$('words').textContent=words;
  $('placeholder').hidden=!!words;
  if(nearEnd)b.scrollTop=b.scrollHeight;
}
function savingNote(msg){$('save-status').textContent=msg;$('save-status').hidden=!msg;}
function resetCaptions(){savedRecord=null;words='';record=null;$('save').hidden=true;$('save').disabled=false;savingNote('');captions('');}
$('save').onclick=async()=>{
  const item=record;if(!item)return;$('save').disabled=true;savingNote('Saving…');
  try{await saveTranslation(item);if(record===item){savedRecord=item;$('save').hidden=true;savingNote('Saved to History.');}}
  catch(e){if(record===item){$('save').disabled=false;savingNote(e.message+' You can retry while this page is open.');}}
};
$('history-open').onclick=()=>{if(unlocked)openHistory();else{afterUnlock=openHistory;showInvite();}};
function clock(){let seconds=Math.max(0,Math.floor((Date.now()-started)/1000));$('clock').textContent=[Math.floor(seconds/60),seconds%60].map(n=>String(n).padStart(2,'0')).join(':');}
async function acquireWake(c){
  if(!$('stay-awake').checked || !c || c!==call || wake || document.visibilityState!=='visible' || !navigator.wakeLock)return;
  try {const lock=await navigator.wakeLock.request('screen');
    if(c!==call || c.closed || wake || !$('stay-awake').checked){await lock.release();return;}
    wake=lock;lock.addEventListener('release',()=>{if(wake===lock)wake=null;},{once:true});
  }catch{}
}
$('stay-awake').onchange=()=>{if($('stay-awake').checked){if(call?.started)acquireWake(call);}else{const l=wake;wake=null;l?.release().catch(()=>{});}};
function showInvite(){if(!access.open)access.showModal();}
function explain(e){return e.name==='NotAllowedError'?'Microphone access was denied. Allow the microphone in your browser settings, then try again.':e.name==='NotFoundError'?'No microphone was found. Connect a microphone and try again.':e.name==='NotReadableError'?'The microphone is busy. Close the other recording app and try again.':e.message||'Could not start audio.';}
function start(){
  if(call){call.end();return;}
  if(!unlocked){afterUnlock=null;showInvite();return;}
  if(record&&record!==savedRecord&&!window.confirm('Start a new session and discard the unsaved transcript?'))return;
  notice('');started=0;resetCaptions();$('clock').textContent='00:00';state('connecting');draw(.15);
  const c=new TranslationCall({audio,
    onLive(){started=Date.now();state('live');acquireWake(c);ticker=setInterval(async()=>{
      if(c!==call)return;clock();if(levelBusy || document.hidden)return;levelBusy=true;
      try{const level=await c.level();if(c===call)draw(.035+Math.min(1,level*4));}catch{}finally{levelBusy=false;}
    },250);},
    onCaption:captions,onInterrupted(paused){if(c===call&&c.started)$('status').textContent=paused?'Microphone paused':'Listening';},onPlayNeeded:()=>{$('play').hidden=false;notice('Tap below to allow translated audio.');},
    onEnd(reason){if(call!==c)return;
      if(started&&words.trim()){record={id:started+'.'+crypto.randomUUID(),startedAt:started,seconds:Math.min(86400,Math.max(0,Math.round((Date.now()-started)/1000))),target:target.value,text:words};$('save').hidden=false;}
      call=null;clearInterval(ticker);levelBusy=false;
      const lock=wake;wake=null;if(lock)lock.release().catch(()=>{});$('play').hidden=true;state('idle');draw(1);notice(reason);}
  });call=c;
  c.open(target.value,$('mic').value).catch(e=>{if(c.closed)return;c.end(explain(e));if(e.status===401){unlocked=false;showInvite();}});
}
$('main-action').onclick=start;
$('play').onclick=()=>{audio.play().then(()=>{$('play').hidden=true;notice('');}).catch(()=>notice('Check your AirPods or audio output in Control Center, then tap Enable translated audio.'));};
document.addEventListener('visibilitychange',()=>{if(!document.hidden&&call){call.visibleAgain();if(call?.started)acquireWake(call);}});
window.addEventListener('pagehide',()=>call?.end());
window.addEventListener('offline',()=>{if(call)call.end('Internet disconnected. Reconnect and start again.');});
$('guide-open').onclick=()=>guide.showModal();
$('refresh-mics').onclick=async()=>{
  const info=$('mic-info');let stream;
  $('refresh-mics').disabled=true;
  try {
    stream=await navigator.mediaDevices.getUserMedia({audio:true});
    const keep=$('mic').value,inputs=(await navigator.mediaDevices.enumerateDevices()).filter(x=>x.kind==='audioinput'&&x.deviceId&&x.deviceId!=='default');
    $('mic').replaceChildren(new Option('System default',''),...inputs.map((x,i)=>new Option(x.label||'Microphone '+(i+1),x.deviceId)));
    if(inputs.some(x=>x.deviceId===keep))$('mic').value=keep;
    info.textContent=inputs.length?'Choose an input for the next session.':'This browser exposes only the system input.';
  }catch(e){info.textContent=explain(e);}finally{stream?.getTracks().forEach(t=>t.stop());$('refresh-mics').disabled=!!call;}
};
for(const btn of document.querySelectorAll('[data-close]'))btn.onclick=()=>btn.closest('dialog').close();
function extract(input){let v=input.trim();if(v.includes('#')) v=new URLSearchParams(v.slice(v.indexOf('#')+1)).get('invite')||'';return v;}
function readInviteLink(){const fragment=new URLSearchParams(location.hash.slice(1));
  if(!fragment.has('invite'))return;const token=fragment.get('invite');history.replaceState(null,'',location.pathname+location.search);if(!unlocked){$('invite').value=token;showInvite();}
}
readInviteLink();window.addEventListener('hashchange',readInviteLink);
$('unlock-form').onsubmit=async(e)=>{
  e.preventDefault();const err=$('invite-error');err.hidden=true;$('unlock').disabled=true;
  try{const r=await fetch('/api/access',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({invite:extract($('invite').value)})});
    const v=await r.json();if(!r.ok)throw Error(v.error);
    unlocked=true;$('invite').value='';access.close();notice('Device unlocked. Connect your AirPods, then start listening.');const resume=afterUnlock;afterUnlock=null;resume?.();
  }catch(e){err.textContent=e.message || 'Could not unlock the device.';err.hidden=false;}finally{$('unlock').disabled=false;}
};
fetch('/api/access',{cache:'no-store'}).then(r=>r.ok?r.json():null).then(v=>{if(v?.unlocked){unlocked=true;if(access.open){access.close();$('invite').value='';}}}).catch(()=>{});
if('serviceWorker' in navigator && import.meta.env.PROD) navigator.serviceWorker.register('/sw.js').catch(()=>{});
