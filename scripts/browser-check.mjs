// Uses prerecorded fixtures only. Never opens the computer's live microphone.
// With no fixture directory, checks public UI only. See docs/research.md for the live procedure.
import {chromium} from 'playwright-core';
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import assert from 'node:assert/strict';
const base=process.env.TEST_ORIGIN||'http://localhost:4173', dir=process.env.FIXTURES;
const qa=process.env.QA_DIR; if(qa)await mkdir(qa,{recursive:true});
const browser=await chromium.launch({channel:'chrome',headless:true,args:['--autoplay-policy=no-user-gesture-required','--mute-audio']});
const context=await browser.newContext({viewport:{width:1280,height:900}});
const page=await context.newPage(); const errors=[];
page.on('pageerror',e=>errors.push(e.message));
page.on('console',m=>{if(m.type()==='error')errors.push(m.text());});
try{
 await page.goto(base);await page.waitForSelector('#wave line',{state:'attached'}); assert.equal(await page.title(),'Relay · Live interpreter');
 if(qa)await page.screenshot({path:qa+'/desktop.png'});
 await page.getByRole('button',{name:'Guide'}).click();assert(await page.getByText('Listening with the screen off').isVisible());
 await page.getByRole('button',{name:'Close guide'}).click();
 await page.getByRole('button',{name:'Start listening'}).click();assert(await page.getByRole('heading',{name:'Device invite'}).isVisible());
 await page.getByRole('button',{name:'Close invite'}).click();await page.setViewportSize({width:390,height:844});
 await page.locator('#target').selectOption('de');assert.equal(await page.locator('#target-label').textContent(),'German');
 assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));
 if(qa)await page.screenshot({path:qa+'/mobile.png'});
 if(dir){
  const href=(await readFile(process.env.TEST_INVITE_FILE,'utf8')).trim();
  await page.goto(base+'/#'+new URL(href).hash.slice(1));
  await page.getByRole('button',{name:'Unlock this device'}).click();
  await page.waitForFunction(()=>!document.querySelector('#access').open && document.querySelector('#notice').textContent.startsWith('Device unlocked'));
  const out=[];
  await page.evaluate(()=>{
    window.lab={};
    Object.defineProperty(navigator.mediaDevices,'getUserMedia',{value:async()=>{
      const lab=window.lab,ctx=lab.ctx=new AudioContext(),dst=lab.dst=ctx.createMediaStreamDestination();
      await ctx.resume();const quiet=ctx.createOscillator(),g=ctx.createGain();g.gain.value=0;quiet.connect(g).connect(dst);quiet.start();
      return dst.stream;
    }});
  });
  const trials=process.env.BENCH_SCENARIO==='overlap'?[['en',['staggered','overlap']]]:[['en',['anna','eddy']],['de',['samantha','reed']]];
  for(const [target,names] of trials){
    await page.locator('#target').selectOption(target);
    await page.getByRole('button',{name:'Start listening'}).click();
    try{await page.waitForFunction(()=>document.body.dataset.state==='live',null,{timeout:36000});}
    catch(e){throw Error('Call did not connect: '+await page.locator('#notice').innerText(),{cause:e});}
    await page.waitForFunction(()=>document.querySelector('audio').srcObject?.getAudioTracks().length);
    await page.evaluate(()=>{
      const {ctx}=lab;lab.output=ctx.createAnalyser();lab.output.fftSize=1024;
      lab.source=ctx.createMediaStreamSource(document.querySelector('audio').srcObject);
      lab.source.connect(lab.output);
    });
    for(const name of names){
      const b64=(await readFile(dir+'/'+name+'.wav')).toString('base64');
      const result=await page.evaluate(async({b64,record})=>{
        const {ctx,output,dst}=lab, bytes=Uint8Array.from(atob(b64),c=>c.charCodeAt(0));
        const buffer=await ctx.decodeAudioData(bytes.buffer), src=ctx.createBufferSource();
        src.buffer=buffer;src.connect(dst);const before=document.querySelector('#words').textContent;
        let recording, parts=[];
        if(record){recording=new MediaRecorder(document.querySelector('audio').srcObject,{mimeType:'audio/webm;codecs=opus'}); recording.ondataavailable=e=>parts.push(e.data);recording.start();}
        const origin=performance.now();src.start();
        const samples=new Float32Array(output.fftSize); let firstAudio=null,firstCaption=null,lastSound=0,peak=0;
        for(;;){
          await new Promise(r=>setTimeout(r,20));
          const t=performance.now()-origin;output.getFloatTimeDomainData(samples);
          const rms=Math.sqrt(samples.reduce((s,v)=>s+v*v,0)/samples.length);peak=Math.max(peak,rms);
          if(rms>.012){firstAudio??=Math.round(t);lastSound=t;}
          const text=document.querySelector('#words').textContent.slice(before.length).trim();
          if(text)firstCaption??=Math.round(t);
          if((text && firstAudio && t>buffer.duration*1000+1600 && t-lastSound>2000) || t>18000){
            let sample64;
            if(recording){await new Promise(r=>{recording.onstop=r;recording.stop();});const bytes=new Uint8Array(await new Blob(parts).arrayBuffer());sample64=btoa(Array.from(bytes,c=>String.fromCharCode(c)).join(''));}
            src.disconnect();return {sample64,inputSeconds:+buffer.duration.toFixed(2),audioMs:firstAudio,captionMs:firstCaption,text,peak:+peak.toFixed(3)};
          }
        }
      },{b64,record:!!qa});
      if(result.sample64){await writeFile(qa+'/'+name+'-translation.webm',Buffer.from(result.sample64,'base64'));delete result.sample64;}
      out.push({target,voice:name,...result});console.log(JSON.stringify(out.at(-1)));
      if(qa)await writeFile(qa+'/measures.json',JSON.stringify(out,null,2));
    }
    if(qa)await page.screenshot({path:qa+'/live-'+target+'.png'});
    await page.getByRole('button',{name:'Stop listening'}).click();
    assert.equal(await page.locator('#status').textContent(),'Standby');
    assert(await page.evaluate(()=>!document.querySelector('audio').srcObject && lab.dst.stream.getAudioTracks().every(t=>t.readyState==='ended')));
    await page.evaluate(()=>lab.ctx.close());
    const caption=await page.locator('#words').textContent();
    await page.getByRole('button',{name:'Save',exact:true}).click();
    await page.getByText('Saved to History.').waitFor();
    // A second page shares only the device cookie; it cannot read the live DOM or in-memory record.
    const hist=await context.newPage();await Promise.all([hist.waitForResponse(r=>r.url().endsWith('/api/access')&&r.ok()),hist.goto(base)]);
    await hist.locator('#history-open').click();
    await hist.locator('#saved-items button').first().click();await hist.locator('#delete-transcript').waitFor();
    assert.equal(await hist.locator('#saved-text').textContent(),caption);
    await hist.locator('#delete-transcript').click();await hist.locator('#confirm-delete').click();
    await hist.getByText('No saved transcripts yet.',{exact:false}).waitFor();await hist.close();
  }
  assert(out.every(x=>x.audioMs && x.text),'Every test voice should yield both audible speech and translated captions.');
 }
 assert.deepEqual(errors,[]); console.log('Browser checks passed.');
}finally{await browser.close();}
