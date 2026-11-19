// Signaling is authenticated by Relay; after negotiation the media path is browser ↔ Azure.
export class TranslationCall {
  constructor({onLive,onCaption,onEnd,onInterrupted,onPlayNeeded,audio}) {
    Object.assign(this,{onLive,onCaption,onEnd,onInterrupted,onPlayNeeded,audio});
    this.closed=false; this.controller=new AbortController();
  }
  async open(target,deviceId) {
    if(!navigator.mediaDevices?.getUserMedia || !window.RTCPeerConnection) throw Error('Use Safari or another browser with microphone access over HTTPS.');
    this.setupTimer=setTimeout(()=>this.end('The connection timed out. Check the microphone permission and try again.'),35000);
    if(navigator.audioSession){try{this.priorAudioType=navigator.audioSession.type;navigator.audioSession.type='play-and-record';}catch{}}
    const s=await navigator.mediaDevices.getUserMedia({audio:{...(deviceId?{deviceId:{exact:deviceId}}:{}),channelCount:1,echoCancellation:true,noiseSuppression:true},video:false});
    if(this.closed) {s.getTracks().forEach(t=>t.stop());return;}
    this.stream=s; const pc=this.pc=new RTCPeerConnection();
    const mic=s.getAudioTracks()[0];
    mic.onended=()=>this.end('The microphone disconnected. Check the audio route and start again.');
    mic.onmute=()=>this.muted(mic);
    mic.onunmute=()=>{clearTimeout(this.muteTimer);this.onInterrupted(false);};
    pc.addTrack(mic,s);
    pc.ontrack=({track,streams})=>{
      if(this.closed)return;
      this.audio.srcObject=streams[0]??new MediaStream([track]);
      this.audio.play().catch(()=>{if(!this.closed)this.onPlayNeeded();});
    };
    pc.onconnectionstatechange=()=>{
      if(this.closed)return;
      if(pc.connectionState==='connected'){
        clearTimeout(this.dropTimer);clearTimeout(this.setupTimer);
        if(!this.started){this.started=Date.now();this.lifeTimer=setTimeout(()=>this.end('Session ended after 20 minutes. Start again to continue.'),1200000);this.onLive();}
      } else if(pc.connectionState==='failed') this.end('The audio connection failed. Check your network and start again.');
      else if(pc.connectionState==='disconnected'){clearTimeout(this.dropTimer);this.dropTimer=setTimeout(()=>this.end('The audio connection was lost. Start again to reconnect.'),7000);}
    };
    const channel=this.channel=pc.createDataChannel('oai-events');
    channel.onmessage=({data})=>{
      if(this.closed)return;
      let e;try{e=JSON.parse(data)}catch{return;}
      if(e.type==='session.output_transcript.delta' && typeof e.delta==='string')this.onCaption(e.delta);
      else if(e.type==='error')this.end('Azure interrupted the translation. Start again to reconnect.');
      else if(e.type==='session.closed')this.end('The interpreter ended this session.');
    };
    channel.onclose=()=>{if(!this.closed)this.end('The interpreter disconnected. Start again to reconnect.');};
    const offer=await pc.createOffer(); if(this.closed)return;
    await pc.setLocalDescription(offer);if(this.closed)return;
    const res=await fetch('/api/connect',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({sdp:offer.sdp,target}),signal:this.controller.signal});
    const result=await res.json();
    if(!res.ok){const err=Error(result.error||'Could not open the interpreter.');err.status=res.status;throw err;}
    if(!this.closed) await pc.setRemoteDescription({type:'answer',sdp:result.sdp});
  }
  async level(){
    if(!this.pc || this.pc.connectionState!=='connected')return 0;
    const stats=await this.pc.getStats();
    for(const r of stats.values()) if(r.type==='media-source' && r.kind==='audio' && r.audioLevel!==undefined)return r.audioLevel;
    return 0;
  }
  muted(track){
    if(this.closed)return;
    this.onInterrupted(true);clearTimeout(this.muteTimer);
    // Safari may briefly mute the input when moving between apps. Give it time to recover.
    // A sustained mute ends the paid session, even if the display is still locked.
    this.muteTimer=setTimeout(()=>{if(!this.closed&&track.muted)this.end('Microphone paused by the browser. Tap Start to reconnect, or use Relay for iPhone with the screen locked.');},12000);
  }
  visibleAgain(){
    if(this.closed)return;
    if(this.started && Date.now()-this.started>=1200000)this.end('Session ended after 20 minutes. Start again to continue.');
    else {
      const mic=this.stream?.getAudioTracks()[0];
      if(mic?.readyState==='ended'){this.end('Microphone access ended. Start again to continue.');return;}
      if(mic?.muted)this.muted(mic);
      if(this.audio.srcObject&&this.audio.paused)this.audio.play().catch(()=>{if(!this.closed)this.onPlayNeeded();});
    }
  }
  end(reason=''){
    if(this.closed)return;this.closed=true;
    for(const id of [this.setupTimer,this.dropTimer,this.muteTimer,this.lifeTimer])clearTimeout(id);
    this.controller.abort();
    this.stream?.getTracks().forEach(t=>{t.onended=t.onmute=t.onunmute=null;t.stop();});
    if(this.channel){this.channel.onclose=this.channel.onmessage=null;this.channel.close();}
    if(this.pc){this.pc.ontrack=this.pc.onconnectionstatechange=null;this.pc.close();}
    this.audio.pause();this.audio.srcObject=null;
    if(this.priorAudioType!==undefined)try{navigator.audioSession.type=this.priorAudioType;}catch{}
    this.onEnd(reason);
  }
}
