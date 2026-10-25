const bridge = window.vortex || {
  async call(m, a){ return fetch('/bridge/'+m,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(a||{})}).then(r=>r.json()) }
};
const $ = (s)=>document.querySelector(s);
const $$ = (s)=>[...document.querySelectorAll(s)];
let state = {chats:[], active:null, agents:[], models:['vortex']};

$$('.tabs button').forEach(b=>b.onclick=()=>{
  $$('.tabs button').forEach(x=>x.classList.toggle('on',x===b));
  $$('.panel').forEach(p=>p.classList.toggle('on', p.id==='tab-'+b.dataset.tab));
  $('#chatside').style.display = b.dataset.tab==='chat' ? '' : 'none';
  if(b.dataset.tab!=='chat') document.querySelector('main').style.gridTemplateColumns='1fr';
  else document.querySelector('main').style.gridTemplateColumns='240px 1fr';
});

async function refresh(){
  try{
    const s = await bridge.call('status');
    $('#status').textContent = s.ok ? 'ready' : (s.error||'error');
    $('#conn').textContent = s.connected ? 'connected' : 'offline';
    $('#conn').className = 'pill '+(s.connected?'ok':'bad');
    if(s.baseURL) $('#baseURL').value = s.baseURL;
    state.agents = s.agents||[];
    state.models = s.models||['vortex'];
    state.chats = s.chats||[];
    renderAgents(); renderModels(); renderChats();
  }catch(e){ $('#status').textContent = 'bridge offline'; }
}
function renderAgents(){
  const sel=$('#agentPick'); const cur=sel.value;
  sel.innerHTML = state.agents.map(a=>`<option value="${a.id}">${a.name} · ${a.model}</option>`).join('') || '<option value="vortex-default">Vortex</option>';
  if(cur) sel.value=cur;
  $('#agentList').innerHTML = state.agents.map(a=>`<div class="row" style="margin:6px 0"><strong>${a.name}</strong> <span class="pill">${a.provider}</span> <span class="pill">${a.model}</span></div>`).join('') || '<em style="color:var(--muted)">No agents yet</em>';
}
function renderModels(){
  const sel=$('#modelPick'); const cur=sel.value;
  sel.innerHTML = state.models.map(m=>`<option>${m}</option>`).join('');
  if(cur) sel.value=cur; else sel.value='vortex';
}
function renderChats(){
  $('#chatlist').innerHTML = state.chats.map(c=>`<button data-id="${c.id}" class="${c.id===state.active?'on':''}">${c.title||'Chat'}</button>`).join('');
  $$('#chatlist button').forEach(b=>b.onclick=()=>{ state.active=b.dataset.id; loadChat(); });
}
async function loadChat(){
  const c = await bridge.call('chat.get',{id:state.active});
  const log=$('#chatlog'); log.innerHTML='';
  (c.messages||[]).forEach(m=>{
    const d=document.createElement('div'); d.className='msg '+m.role; d.textContent=m.content; log.appendChild(d);
  });
  log.scrollTop=log.scrollHeight;
}
$('#newchat').onclick=async()=>{ const c=await bridge.call('chat.new',{}); state.active=c.id; await refresh(); loadChat(); };
$('#send').onclick=async()=>{
  const text=$('#prompt').value.trim(); if(!text) return;
  $('#prompt').value='';
  if(!state.active){ const c=await bridge.call('chat.new',{}); state.active=c.id; }
  const log=$('#chatlog');
  const u=document.createElement('div'); u.className='msg user'; u.textContent=text; log.appendChild(u);
  const a=document.createElement('div'); a.className='msg assistant'; a.textContent='…'; log.appendChild(a);
  const r=await bridge.call('chat.send',{id:state.active, text, agent:$('#agentPick').value, model:$('#modelPick').value});
  a.textContent = r.reply || r.error || '(no reply)';
  log.scrollTop=log.scrollHeight; refresh();
};
$('#aSave').onclick=async()=>{
  const r=await bridge.call('agent.save',{name:$('#aName').value, provider:$('#aProv').value, model:$('#aModel').value, baseURL:$('#aBase').value, apiKey:$('#aKey').value});
  $('#aKey').value=''; $('#aMsg').textContent=r.message||'Saved'; $('#aMsg').className=r.ok?'ok':'bad'; refresh();
};
$('#aTest').onclick=async()=>{
  const r=await bridge.call('agent.testVortex',{});
  $('#aMsg').textContent=r.message||''; $('#aMsg').className=r.ok?'ok':'bad';
};
$$('[data-int]').forEach(b=>b.onclick=async()=>{
  const r=await bridge.call('integration',{id:b.dataset.int});
  $('#intLog').textContent = (r.message||JSON.stringify(r)) + '\n' + ($('#intLog').textContent||'');
});
const ICON=256; let iconURL=null;
function fitIcon(src){ return new Promise((ok,bad)=>{ const im=new Image(); im.crossOrigin='anonymous';
  im.onload=()=>{ const c=document.createElement('canvas'); c.width=c.height=ICON; const s=Math.min(im.width,im.height);
    c.getContext('2d').drawImage(im,(im.width-s)/2,(im.height-s)/2,s,s,0,0,ICON,ICON);
    ok({url:c.toDataURL('image/png'),w:im.width,h:im.height}); }; im.onerror=bad; im.src=src; }); }
async function setIcon(src,why){ const f=await fitIcon(src); iconURL=f.url; $('#iconPrev').src=f.url;
  $('#iconMsg').textContent=(f.w===ICON&&f.h===ICON)?why+': 256×256 ✓':why+`: ${f.w}×${f.h} → auto-fitted to 256×256`; }
async function defaultIcon(){ return (await fitIcon('logo.png')).url; }
function withIcon(js,url){ try{ const d=JSON.parse(js); d.icon=url; return JSON.stringify(d,null,2);}catch(e){ return js; } }
$('#iconFile').onchange=e=>{ const f=e.target.files[0]; if(!f) return; const r=new FileReader(); r.onload=()=>setIcon(r.result,'Uploaded'); r.readAsDataURL(f); };
$('#aiIcon').onclick=async()=>{ $('#iconMsg').textContent='Generating icon…';
  const r=await bridge.call('plugin.icon',{prompt:$('#maker').value});
  if(r.ok) await setIcon(r.dataURL,'AI icon'); else $('#iconMsg').textContent=r.message||'failed'; };
$('#makePlugin').onclick=async()=>{
  const r=await bridge.call('plugin.make',{description:$('#maker').value});
  $('#pluginOut').textContent = r.json ? withIcon(r.json, iconURL||await defaultIcon()) : (r.error||'');
};
$('#uploadPlugin').onclick=async()=>{
  const js=withIcon($('#pluginOut').textContent, iconURL||await defaultIcon());
  const r=await bridge.call('plugin.upload',{json:js});
  $('#pluginOut').textContent = (r.message||'') + '\n' + js;
};
function iconSrc(i){ return (typeof i==='string' && /^(data:image|https:)/.test(i)) ? i : 'logo.png'; }
$('#refreshStore').onclick=async()=>{
  const r=await bridge.call('plugin.store',{}); const list=r.plugins||[];
  $('#storeList').innerHTML=''; list.forEach(p=>{ const d=document.createElement('div'); d.className='card';
    d.innerHTML='<img width="48" height="48" style="border-radius:10px;float:left;margin-right:8px"/><b></b><div style="color:var(--muted);font-size:12px"></div>';
    d.querySelector('img').src=iconSrc(p.icon); d.querySelector('b').textContent=p.name||p.id||'Plugin';
    d.querySelector('div').textContent=p.description||''; $('#storeList').appendChild(d); });
  if(!list.length) $('#pluginOut').textContent = JSON.stringify(r,null,2);
};
$('#saveSettings').onclick=async()=>{
  const r=await bridge.call('settings.save',{baseURL:$('#baseURL').value, apiKey:$('#apiKey').value});
  $('#apiKey').value=''; $('#setMsg').textContent=r.message||'Saved'; $('#setMsg').className=r.ok?'ok':'bad'; refresh();
};
$('#probe').onclick=async()=>{ const r=await bridge.call('settings.probe',{}); $('#setMsg').textContent=r.message||''; $('#setMsg').className=r.ok?'ok':'bad'; };
refresh(); setInterval(refresh, 15000);

// Media job queue with live progress
const mOut={};
function mRender(list){
  $('#mJobs').innerHTML=(list||[]).map(j=>{
    const pct=j.progress||0, st=j.status, pos=j.position?` · #${j.position} in queue`:'';
    const secs=j.seconds?` · ${(+j.seconds).toFixed(1)}s`:'';
    const res=mOut[j.id]?`<div style="margin-top:6px">${mOut[j.id]}</div>`:'';
    return `<div class="card" data-job="${j.id}"><b>${j.type}</b> <span class="muted">${st}${pos}${secs}</span>
      <div style="background:#222;height:6px;border-radius:3px;margin-top:4px"><div style="width:${pct}%;height:6px;background:#e0263a;border-radius:3px"></div></div>${res}</div>`}).join('')||'<span class="muted">No jobs yet.</span>';
}
function mMedia(r){const x=r.result;if(!x||!x.b64)return '';const u=`data:${x.mime};base64,${x.b64}`;
  if(x.mime.startsWith('image'))return `<img src="${u}" style="max-width:256px">`;
  if(x.mime.startsWith('audio'))return `<audio controls src="${u}"></audio>`;
  if(x.mime.startsWith('video'))return `<video controls loop src="${u}" style="max-width:256px"></video>`;return '';}
async function mPoll(){
  const r=await bridge.call('media.jobs',{}); if(!r.ok){return;}
  const list=r.jobs||r.data||[];
  for(const j of list){ if(j.status==='done'&&!mOut[j.id]){ const d=await bridge.call('media.job',{id:j.id}); mOut[j.id]=mMedia(d)||'(done)'; } }
  mRender(list);
}
$('#mGo').onclick=async()=>{
  const r=await bridge.call('media.submit',{type:$('#mType').value,prompt:$('#mPrompt').value});
  $('#mMsg').textContent=r.ok?`Queued ${r.id} (position ${r.position})`:(r.message||'failed'); $('#mMsg').className=r.ok?'ok':'bad'; mPoll();
};
setInterval(()=>{ if($('#tab-media').classList.contains('on')) mPoll(); }, 1500);

// ---- ToS + RedX sign-in gate (required on every launch; re-prompts when terms change)
const TERMS_VERSION='2026-10-25';
let gFlow='';
async function gate(){
  const show=id=>['gTerms','gLogin','gWait'].forEach(x=>$('#'+x).style.display=x===id?'':'none');
  show('gWait');
  const g=await bridge.call('gate.status').catch(()=>({}));
  if(g.termsAccepted!==TERMS_VERSION){
    $('#gTermsText').textContent=await fetch('terms.md').then(r=>r.text()).catch(()=>'Terms unavailable.');
    show('gTerms'); return;
  }
  if(!(g.signedIn||g.owner)){ show('gLogin'); return; }
  $('#fUser').textContent=g.username?('· '+g.username):(g.owner?'· owner mode':'');
  $('#gate').style.display='none';
}
$('#gAccept').onclick=async()=>{await bridge.call('gate.accept',{version:TERMS_VERSION}); gate();};
$('#gDecline').onclick=()=>{document.body.innerHTML='<p style="padding:40px">You must accept the Terms of Service to use Red-XAI Vortex. Close this window to quit.</p>';};
$('#gGo').onclick=async()=>{
  $('#gMsg').textContent='';
  let r;
  if(!gFlow) r=await bridge.call('redx.login',{login:$('#gUser').value,password:$('#gPass').value});
  else r=await bridge.call('redx.2fa',{flow:gFlow,method:'totp',code:$('#gOtp').value});
  if(!r.ok){$('#gMsg').textContent=r.error||'Sign-in failed.';return;}
  if(r.next==='2fa'){gFlow=r.flow;$('#gCreds').style.display='none';$('#gCode').style.display='';$('#gGo').textContent='Verify';return;}
  if(r.next==='2fa_setup'){$('#gMsg').textContent='Finish two-factor setup at red-xai.com, then sign in again.';return;}
  gFlow=''; gate();
};
$('#gCallMe').onclick=async()=>{const r=await bridge.call('redx.call',{flow:gFlow});$('#gMsg').textContent=r.ok?'Calling you now — enter the code you hear.':(r.message||'Call failed.');};
$('#fSignOut').onclick=async e=>{e.preventDefault();await bridge.call('redx.logout');location.reload();};
$('#fTerms').onclick=async e=>{e.preventDefault();const t=await fetch('terms.md').then(r=>r.text());const w=window.open('','_blank');if(w){w.document.body.innerHTML='<pre style="white-space:pre-wrap"></pre>';w.document.querySelector('pre').textContent=t;}else alert(t);};
gate();
