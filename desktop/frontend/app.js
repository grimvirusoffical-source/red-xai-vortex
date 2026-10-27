const bridge = window.vortex || {
  async call(m, a){ return fetch('/bridge/'+m,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(a||{})}).then(r=>r.json()) }
};
const $ = (s)=>document.querySelector(s);
const $$ = (s)=>[...document.querySelectorAll(s)];
let state = {chats:[], active:null, agents:[], models:['vortex'], tiers:[], comp:null, modelExplicit:false};

$$('.tabs button').forEach(b=>b.onclick=()=>{
  $$('.tabs button').forEach(x=>x.classList.toggle('on',x===b));
  $$('.panel').forEach(p=>p.classList.toggle('on', p.id==='tab-'+b.dataset.tab));
  $('#chatside').style.display = b.dataset.tab==='chat' ? '' : 'none';
  if(b.dataset.tab!=='chat') document.querySelector('main').style.gridTemplateColumns='1fr';
  else document.querySelector('main').style.gridTemplateColumns='260px 1fr';
});

async function refresh(){
  try{
    const s = await bridge.call('status');
    $('#status').textContent = s.ok ? 'ready' : (s.error||'error');
    $('#conn').textContent = s.connected ? 'connected' : 'offline';
    $('#conn').className = 'pill '+(s.connected?'ok':'bad');
    if(s.baseURL) $('#baseURL').value = s.baseURL;
    if('autoUpdate' in s) $('#autoUpdate').checked = s.autoUpdate;
    if('secureChat' in s) $('#secureChat').checked = s.secureChat;
    if('phoneChat' in s) $('#phoneChat').checked = s.phoneChat;
    if(s.link){ const L=s.link; $('#linkInfo').textContent = (L.error? L.error : (L.secure? 'Secure chat active · red-X barcode transport' : 'Secure chat off · direct HTTPS')) + (L.phoneURL? ' · Phone: open '+L.phoneURL+' · PIN '+L.phonePIN : ''); $('#phoneQRBox').style.display = L.phoneQR? 'block':'none'; if(L.phoneQR) $('#phoneQR').src = L.phoneQR; }
    state.agents = s.agents||[];
    state.models = s.models||['vortex'];
    state.chats = s.chats||[];
    renderAgents(); renderModels(); renderChats();
    window.VortexWorkspace?.sync();
    window.VortexWorkspace?.refreshSidebar();
  }catch(e){ $('#status').textContent = 'bridge offline'; }
}
function renderAgents(){
  const sel=$('#agentPick'); const cur=sel.value;
  sel.innerHTML = state.agents.map(a=>`<option value="${esc(a.id)}">${esc(a.name)} · ${esc(a.model)}</option>`).join('') || '<option value="vortex-default">Vortex</option>';
  if(cur) sel.value=cur;
  $('#agentList').innerHTML = state.agents.map(a=>`<div class="row" style="margin:6px 0"><strong>${esc(a.name)}</strong> <span class="pill">${esc(a.provider)}</span> <span class="pill">${esc(a.model)}</span></div>`).join('') || '<em style="color:var(--muted)">No agents yet</em>';
}
function renderModels(){
  const sel=$('#modelPick'); const cur=sel.value;
  sel.innerHTML = state.models.map(m=>`<option>${esc(m)}</option>`).join('');
  if(cur) sel.value=cur; else sel.value='vortex';
}
function esc(t){ return String(t??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])); }
function chatBtn(c,label){ return `<button data-id="${esc(c.id)}" class="${c.id===state.active?'on':''}">${esc(label||c.title||'Chat')}</button>`; }
function renderChats(){
  const query=($('#chatSearch')?.value||'').trim().toLocaleLowerCase();
  const matches=c=>!query||(c.title||'').toLocaleLowerCase().includes(query);
  const plain=state.chats.filter(c=>!c.kind&&matches(c)), party=state.chats.filter(c=>c.kind==='party'&&matches(c));
  $('#chatlist').innerHTML = plain.map(c=>chatBtn(c)).join('') || `<em class="muted">${query?'No matching chats':'No chats yet'}</em>`;
  $('#partyList').innerHTML = party.map(c=>chatBtn(c,'👥 '+c.title)).join('') || `<em class="muted">${query?'No matching party chats':'None yet'}</em>`;
  // every agent appears in the sidebar; clicking opens (or creates) its chat
  $('#agentChats').innerHTML = state.agents.filter(a=>!query||`${a.name} ${a.model}`.toLocaleLowerCase().includes(query)).map(a=>{ const c=state.chats.find(x=>x.kind==='agent'&&x.agentID===a.id);
    return `<button data-agent="${esc(a.id)}" class="${c&&c.id===state.active?'on':''}">🤖 ${esc(a.name)} <span class="muted" style="font-size:11px">${esc(a.model)}</span></button>`; }).join('');
  $$('#chatside [data-id]').forEach(b=>b.onclick=()=>{ state.active=b.dataset.id; loadChat(); renderChats(); });
  $$('#agentChats [data-agent]').forEach(b=>b.onclick=async()=>{ const r=await bridge.call('agent.chat',{agent:b.dataset.agent}); state.active=r.id; await refresh(); loadChat(); });
  window.VortexWorkspace?.refreshSidebar();
}
$('#newparty').onclick=()=>{
  const opts=[...state.agents.map(a=>({id:a.id,label:'🤖 '+a.name+' · '+a.model})), ...state.models.map(m=>({id:'model:'+m,label:'🧠 '+m}))];
  $('#partyOpts').innerHTML=opts.map(o=>`<label style="display:block"><input type="checkbox" value="${esc(o.id)}"/> ${esc(o.label)}</label>`).join('');
  $('#partyMsg').textContent=''; $('#partyPick').style.display='';
};
$('#partyCancel').onclick=()=>$('#partyPick').style.display='none';
$('#partyGo').onclick=async()=>{
  const members=$$('#partyOpts input:checked').map(i=>i.value);
  const r=await bridge.call('party.new',{members,title:$('#partyTitle').value.trim()});
  if(!r.ok){ $('#partyMsg').textContent=r.message||'failed'; return; }
  $('#partyPick').style.display='none'; $('#partyTitle').value=''; state.active=r.id; await refresh(); loadChat();
};
function addMsg(role,content,name){ const d=document.createElement('div'); d.className='msg '+role;
  if(name){ const w=document.createElement('span'); w.className='who'; w.textContent=name; d.appendChild(w); }
  const mm=/^\[\[media:([A-Za-z0-9_-]+)\]\]$/.exec(String(content||'').trim());
  if(mm){ const box=document.createElement('div'); box.textContent='Generating…'; d.appendChild(box); fillMedia(box, mm[1], state.active); }
  else renderMessageContent(d,content);
  $('#chatlog').appendChild(d); $('#chatEmpty').hidden=true; return d; }
// Fenced code stays text-only and gets a copy control; arbitrary model HTML is never executed.
function renderMessageContent(parent,content){
  const source=String(content||''),fence=/```([^\n`]*)\n([\s\S]*?)```/g;let start=0,match;
  while((match=fence.exec(source))){
    if(match.index>start)parent.appendChild(document.createTextNode(source.slice(start,match.index)));
    const bar=document.createElement('div');bar.className='code-bar';
    const language=document.createElement('span');language.textContent=match[1].trim()||'code';
    const copy=document.createElement('button');copy.textContent='Copy code';copy.type='button';const codeText=match[2];
    copy.onclick=async()=>{try{await navigator.clipboard.writeText(codeText);copy.textContent='Copied';setTimeout(()=>copy.textContent='Copy code',1800);}catch(e){copy.textContent='Copy unavailable';}};
    bar.append(language,copy);const pre=document.createElement('pre'),code=document.createElement('code');code.textContent=codeText;pre.appendChild(code);parent.append(bar,pre);start=fence.lastIndex;
  }
  if(start<source.length)parent.appendChild(document.createTextNode(source.slice(start)));
}
async function loadChat(){
  loadComposer();
  const c = await bridge.call('chat.get',{id:state.active});
  const log=$('#chatlog'); log.innerHTML='';
  state.kind=c.kind||'';
  $('#agentPick').disabled=$('#modelPick').disabled=!!c.kind;
  (c.messages||[]).forEach(m=>addMsg(m.role,m.content,m.name));
  log.scrollTop=log.scrollHeight;
  $('#chatEmpty').hidden=!!(c.messages||[]).length;
  window.VortexWorkspace?.sync();
}
$('#newchat').onclick=async()=>{ const c=await bridge.call('chat.new',{}); state.active=c.id; await refresh(); loadChat(); };
$('#send').onclick=async()=>{
  const text=$('#prompt').value.trim(); if(!text) return;
  if($('#send').disabled)return;
  $('#send').disabled=true; $('#send').textContent='Sending…';
  try{
  $('#prompt').value='';
  $('#prompt').style.height='auto'; $('#chatEmpty').hidden=true;
  if(!state.active){ const c=await bridge.call('chat.new',{}); state.active=c.id; }
  const ms=parseMediaCmd(text);
  if(ms){ ms.chatID=state.active; const r=await bridge.call('media.submit',ms);
    if(!r.ok){ addMsg('user',text); addMsg('assistant','Media: '+(r.message||'failed')); return; }
    await loadChat(); refresh(); return; }
  const log=$('#chatlog');
  const u=document.createElement('div'); u.className='msg user'; u.textContent=text; log.appendChild(u);
  const a=document.createElement('div'); a.className='msg assistant'; a.textContent=state.kind==='party'?'Agents are replying in turn…':'…'; log.appendChild(a);
  if(!state.comp?.perChat) await saveComposer(false);
  const r=await bridge.call('chat.send',{id:state.active, text, agent:$('#agentPick').value, model:$('#modelPick').value, modelExplicit:state.modelExplicit});
  if(r.replies&&r.replies.length){ a.remove(); r.replies.forEach(x=>addMsg('assistant',x.content,x.name)); }
  else { a.textContent=''; renderMessageContent(a,r.reply || r.error || '(no reply)'); }
  // Forbidden/error responses are not assistant turns. Never capture them as
  // memory, world-state updates or Base training data.
  if(!r.error) await window.VortexWorkspace?.afterTurn(r).catch(e=>{ const el=$('#wsTurnNotice');if(el)el.textContent='Reply received. Workspace status could not be refreshed: '+e.message; });
  log.scrollTop=log.scrollHeight; refresh();
  }catch(e){addMsg('assistant','The message could not be completed: '+e.message);}
  finally{$('#send').disabled=false;$('#send').textContent='Send ↗';window.VortexWorkspace?.sync();}
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
async function defaultIcon(){ return (await fitIcon('redx-256.png')).url; }
function withIcon(js,url){ try{ const d=JSON.parse(js); d.icon=url; return JSON.stringify(d,null,2);}catch(e){ return js; } }
function noIcon(js){ try{ const d=JSON.parse(js); delete d.icon; return JSON.stringify(d,null,2);}catch(e){ return js; } }
function readFile(f){ return new Promise(ok=>{ const r=new FileReader(); r.onload=()=>ok(r.result); r.readAsDataURL(f); }); }
$('#iconUp').onclick=()=>$('#iconFile').click();
$('#iconFile').onchange=async e=>{ const f=e.target.files[0]; if(f) await setIcon(await readFile(f),'Uploaded'); e.target.value=''; };
$('#iconSkip').onclick=async()=>{ iconURL=null; $('#iconPrev').src='redx-256.png'; $('#iconMsg').textContent='Using the default red X icon.'; };
$('#aiIcon').onclick=async()=>{ $('#iconMsg').textContent='Generating icon…';
  const r=await bridge.call('plugin.icon',{prompt:$('#maker').value});
  if(r.ok) await setIcon(r.dataURL,'AI icon'); else $('#iconMsg').textContent=(r.message||'failed')+' — upload one or skip to use the red X.'; };
$('#makePlugin').onclick=async()=>{ $('#makeMsg').textContent='Generating…';
  const r=await bridge.call('plugin.make',{description:$('#maker').value});
  $('#makeMsg').textContent=r.json?'Done. Pick an icon, review the JSON, then upload.':(r.error||'');
  if(r.json) $('#pluginOut').value=r.json; };
// Inline RedX sign-in: resolves true when signed in, false on Cancel.
function rxSignIn(){ return new Promise(done=>{ let flow='',method='totp'; const m=$('#rxModal');
  const reset=()=>{flow='';method='totp';$('#rxCreds').style.display='';$('#rxCode').style.display='none';$('#rxCallMe').style.display='none';$('#rxGo').textContent='Sign in';$('#rxMsg').textContent='';$('#rxPass').value='';$('#rxOtp').value='';};
  reset(); m.style.display='flex';
  $('#rxCancel').onclick=()=>{ m.style.display='none'; reset(); done(false); };
  $('#rxGo').onclick=async()=>{ $('#rxMsg').textContent='';
    const r=flow?await bridge.call('redx.2fa',{flow,method,code:$('#rxOtp').value})
               :await bridge.call('redx.login',{login:$('#rxUser').value,password:$('#rxPass').value});
    if(!r.ok){ $('#rxMsg').textContent=r.error||'Sign-in failed.'; return; }
    if(r.next==='2fa'){ flow=r.flow; method=r.methods?.totp?'totp':'call'; $('#rxCreds').style.display='none'; $('#rxCode').style.display=''; $('#rxCallMe').style.display=r.methods?.call?'':'none'; $('#rxGo').textContent='Verify'; return; }
    if(r.next==='2fa_setup'){ $('#rxMsg').textContent='Finish two-factor setup at red-xai.com, then sign in again.'; return; }
    m.style.display='none'; reset(); done(true); };
  $('#rxCallMe').onclick=async()=>{ const r=await bridge.call('redx.call',{flow}); if(r.ok){method='call';$('#rxMsg').textContent='Calling you now. Enter the code you hear.';} else $('#rxMsg').textContent=r.message||'Call failed.'; };
}); }
async function withSignIn(call,msgEl){ let r=await call(); if(r.needSignIn){ if(!await rxSignIn()){ msgEl.textContent='You must sign in to Red-XAI first to upload.'; msgEl.className='bad'; return null; } r=await call(); } return r; }
$('#uploadPlugin').onclick=async()=>{ const el=$('#upMsg'); el.className='muted';
  if(!$('#pluginOut').value.trim()){ el.textContent='Generate a plugin first.'; return; }
  const js=withIcon($('#pluginOut').value, iconURL||await defaultIcon()); el.textContent='Uploading…';
  const r=await withSignIn(()=>bridge.call('plugin.upload',{json:js}),el); if(!r) return;
  if(r.ok){ el.className='ok'; el.textContent=`Published "${r.plugin.name}" as ${r.plugin.author}.`; loadMine(); loadStore(); }
  else { el.className='bad'; el.textContent=r.message||'Upload failed.'; } };
let STORE='';
function iconSrc(p){ if(p.hasIcon&&p.icon&&STORE) return STORE+'/'+p.icon+'?v='+encodeURIComponent(p.updated||''); return 'redx-256.png'; }
function pCard(p){ const d=document.createElement('div'); d.className='card';
  d.innerHTML='<div style="display:flex;gap:8px;align-items:center"><img width="48" height="48" style="border-radius:10px"/><div><b></b><div class="muted by" style="font-size:12px"></div></div></div><div class="muted ds" style="font-size:12px;margin:6px 0"></div><div class="muted st" style="font-size:12px"></div><div class="row act" style="margin-top:6px"></div>';
  const im=d.querySelector('img'); im.onerror=()=>{im.onerror=null;im.src='redx-256.png';}; im.src=iconSrc(p);
  d.querySelector('b').textContent=p.name||p.id; d.querySelector('.by').textContent='by '+(p.author||p.uploader||'?')+' · v'+(p.version||'1.0.0');
  d.querySelector('.ds').textContent=p.description||''; d.querySelector('.st').textContent=(p.installs||0)+' install'+(p.installs===1?'':'s');
  return d; }
let installed=new Set();
async function loadStore(){ $('#storeMsg').textContent='Loading…';
  const r=await bridge.call('plugin.store',{}); STORE=r.storeBase||STORE; const list=r.plugins||[];
  installed=new Set(((await bridge.call('plugin.installed',{})).ids)||[]);
  $('#storeList').innerHTML=''; list.forEach(p=>{ const d=pCard(p); const b=document.createElement('button');
    b.textContent=installed.has(p.id)?'Reinstall':'Install';
    b.onclick=async()=>{ b.disabled=true; const x=await bridge.call('plugin.install',{id:p.id}); b.disabled=false;
      $('#storeMsg').textContent=x.message||''; if(x.ok) loadStore(); };
    d.querySelector('.act').appendChild(b); $('#storeList').appendChild(d); });
  $('#storeMsg').textContent=r.ok===false?(r.message||'Store unreachable'):(list.length?list.length+' plugins':'No plugins yet.'); }
async function loadMine(){ const el=$('#myMsg'); el.className='muted'; el.textContent='Loading…';
  const r=await withSignIn(()=>bridge.call('plugin.mine',{}),el); if(!r) return;
  if(r.ok===false){ el.textContent=r.message||''; return; } STORE=r.storeBase||STORE;
  $('#myWho').textContent=r.username?('· '+r.username):''; const list=r.plugins||[];
  $('#myList').innerHTML=''; list.forEach(p=>{ const d=pCard(p); const act=d.querySelector('.act');
    const e=document.createElement('button'); e.textContent='Edit'; const x=document.createElement('button'); x.textContent='Unpublish'; act.append(e,x);
    x.onclick=async()=>{ if(!confirm(`Unpublish "${p.name||p.id}" and delete it from the store?`)) return;
      const r=await withSignIn(()=>bridge.call('plugin.delete',{id:p.id}),el); if(r){ el.textContent=r.ok?'Unpublished '+p.id:(r.message||''); loadMine(); loadStore(); } };
    e.onclick=()=>{ act.innerHTML=''; const f=document.createElement('div');
      f.innerHTML='<input class="n" placeholder="Name"/><input class="v" placeholder="Version" style="margin-top:4px"/><textarea class="ds" rows="3" style="margin-top:4px;width:100%"></textarea><label class="muted" style="font-size:12px">New icon <input type="file" class="ic" accept="image/*"/></label><div class="row"><button class="primary s">Save</button><button class="ghost c">Cancel</button></div>';
      f.querySelector('.n').value=p.name||''; f.querySelector('.v').value=p.version||''; f.querySelector('.ds').value=p.description||'';
      f.querySelector('.c').onclick=loadMine;
      f.querySelector('.s').onclick=async()=>{ const patch={name:f.querySelector('.n').value,version:f.querySelector('.v').value,description:f.querySelector('.ds').value};
        const ic=f.querySelector('.ic').files[0]; if(ic) patch.icon=(await fitIcon(await readFile(ic))).url;
        const r=await withSignIn(()=>bridge.call('plugin.update',{id:p.id,patch}),el); if(r){ el.textContent=r.ok?'Saved '+p.id:(r.message||''); if(r.ok){loadMine();loadStore();} } };
      act.appendChild(f); };
    $('#myList').appendChild(d); });
  const tot=list.reduce((a,p)=>a+(p.installs||0),0);
  el.textContent=list.length?`${list.length} published · ${tot} total installs`:'You have not published any plugins yet.'; }
$('#refreshStore').onclick=loadStore; $('#refreshMine').onclick=loadMine;
document.querySelector('[data-tab="plugins"]').addEventListener('click',()=>{ loadStore(); loadMine(); });
$('#saveSettings').onclick=async()=>{
  const r=await bridge.call('settings.save',{baseURL:$('#baseURL').value, apiKey:$('#apiKey').value, autoUpdate:$('#autoUpdate').checked, secureChat:$('#secureChat').checked, phoneChat:$('#phoneChat').checked});
  $('#apiKey').value=''; $('#setMsg').textContent=r.message||'Saved'; $('#setMsg').className=r.ok?'ok':'bad'; refresh();
};
$('#probe').onclick=async()=>{ const r=await bridge.call('settings.probe',{}); $('#setMsg').textContent=r.message||''; $('#setMsg').className=r.ok?'ok':'bad'; };
let updateStatusPolling=0;
$('#checkUpdatesNow').onclick=async()=>{
  const button=$('#checkUpdatesNow'),label=$('#updateStatus');
  if(button.disabled)return;
  button.disabled=true;label.textContent='Checking GitHub releases…';
  try{
    const r=await bridge.call('update.check');
    label.textContent=r.message||r.error||'Update check failed.';
    if(!r.ok||!r.available)return;
    if(!window.confirm('Install Vortex '+r.version+'? The signed package will be verified, then Vortex will restart.'))return;
    const result=await bridge.call('update.install');
    label.textContent=result.message||result.error||'Could not start the update.';
    if(!result.ok)return;
    clearInterval(updateStatusPolling);
    updateStatusPolling=setInterval(async()=>{
      try{
        const s=await bridge.call('update.status');
        if(s.message)label.textContent=s.message;
        if(!s.busy){clearInterval(updateStatusPolling);updateStatusPolling=0;button.disabled=false;}
      }catch(e){label.textContent='Vortex is restarting; reopen the updated app if necessary.';clearInterval(updateStatusPolling);updateStatusPolling=0;}
    },1500);
  }catch(e){label.textContent='GitHub could not be reached; try again.';}
  finally{if(!updateStatusPolling)button.disabled=false;}
};

refresh(); setInterval(refresh, 15000);

// ---- Media: exact-spec generation, in-chat generation, viewer (Download / Regenerate / Redesign)
const mDone={};
function fmtBytes(n){ return n>1048576?(n/1048576).toFixed(1)+' MB':(n/1024).toFixed(0)+' KB'; }
function mInfo(d){ const i=d.info||{}, sp=d.spec||{}, p=[];
  if(i.width) p.push(`${i.width}×${i.height}px`);
  p.push(i.format||(sp.format||'').toUpperCase());
  if(sp.type==='image') p.push(`${sp.quality} quality (${i.steps||'?'} steps${i.jpegQuality?`, JPEG q${i.jpegQuality}`:''})`); else if(sp.quality) p.push(sp.quality+' quality');
  if(i.duration) p.push((+i.duration).toFixed(1)+'s');
  if(i.sampleRate) p.push(`${i.sampleRate} Hz ${i.bitDepth}-bit ${i.channels>1?'stereo':'mono'}`);
  if(i.fps) p.push(`${i.frames} frames @ ${i.fps} fps`);
  if(i.style||sp.style) p.push('style: '+(i.style||sp.style));
  if(i.bytes) p.push(fmtBytes(i.bytes));
  return p.filter(Boolean).join(' · '); }
function mPlayer(d){ const x=d.result; if(!x||!x.b64) return ''; const u=`data:${x.mime};base64,${x.b64}`;
  if(x.mime.startsWith('image')) return `<img src="${u}" style="max-width:100%;max-height:420px;border-radius:8px;display:block">`;
  if(x.mime.startsWith('audio')) return `<audio controls src="${u}" style="width:100%"></audio>`;
  if(x.mime.startsWith('video')) return `<video controls loop autoplay muted playsinline src="${u}" style="max-width:100%;border-radius:8px"></video>`; return ''; }
function mCard(d, chatID){
  const sp=d.spec||{}, id=esc(d.id);
  if(d.status!=='done'){
    const pct=d.progress||0, pos=d.position?` · #${d.position} in queue`:'';
    if(d.status==='failed'||d.status==='error') return `<div class="media-card"><b>${esc(sp.type||d.type||'media')}</b> <span class="bad">failed ${esc(d.error||'')}</span></div>`;
    return `<div class="media-card"><b>${esc(sp.type||d.type||'media')}</b> <span class="muted">${esc(d.status||'queued')}${pos}</span> <span class="muted">${esc(sp.prompt||'')}</span>
      <div style="background:#222;height:6px;border-radius:3px;margin-top:4px"><div style="width:${pct}%;height:6px;background:#e0263a;border-radius:3px"></div></div></div>`; }
  const x=d.result||{}; const href=x.b64?`data:${x.mime};base64,${x.b64}`:'#';
  const isImg=sp.type==='image';
  return `<div class="media-card" data-media="${id}" data-chat="${esc(chatID||'')}">${mPlayer(d)}
    <div class="muted" style="margin-top:6px;font-size:12px"><b>${esc(sp.type)}</b> · ${esc(mInfo(d))}</div>
    <div class="muted" style="font-size:12px">“${esc(sp.prompt||'')}”</div>
    <div class="row" style="margin-top:6px;gap:6px">
      <a class="btn ghost" href="${href}" download="${esc(d.filename||'vortex-media')}"><button class="ghost">Download</button></a>
      <button class="ghost" data-mact="regen">Regenerate</button>
      <button class="ghost" data-mact="redesign">Redesign</button></div>
    <div class="mredesign" style="display:none;margin-top:6px">
      <input data-k="prompt" value="${esc(sp.prompt||'')}" placeholder="Prompt" style="width:100%">
      <div class="row" style="gap:6px;margin-top:4px;flex-wrap:wrap">
        <input data-k="style" value="${esc(sp.style||'')}" placeholder="Style" style="flex:1;min-width:120px">
        <select data-k="quality">${['draft','standard','high'].map(q=>`<option ${q===sp.quality?'selected':''}>${q}</option>`).join('')}</select>
        ${isImg?`<input data-k="size" value="${esc(sp.size||'')}" placeholder="WxH" style="width:100px">
        <select data-k="format">${['png','jpeg'].map(q=>`<option ${q===sp.format?'selected':''}>${q}</option>`).join('')}</select>`:''}
        ${sp.type==='music'||sp.type==='sfx'?`<input data-k="duration" type="number" value="${sp.duration||''}" style="width:70px" title="seconds">`:''}
        ${sp.type==='video'?`<input data-k="frames" type="number" value="${sp.frames||16}" style="width:70px" title="frames">`:''}
        ${sp.type==='speech'?`<input data-k="speed" type="number" step="0.1" value="${sp.speed||1}" style="width:70px" title="speed">`:''}
        <button class="primary" data-mact="redesignGo">Generate redesign</button></div></div>
    <div class="mmsg muted" style="font-size:12px"></div></div>`; }
async function mAgain(card, act){
  const id=card.dataset.media, chatID=card.dataset.chat||'', msg=card.querySelector('.mmsg');
  let r;
  if(act==='regen') r=await bridge.call('media.regenerate',{id,chatID});
  else { const ch={id,chatID}; card.querySelectorAll('.mredesign [data-k]').forEach(e=>{ const k=e.dataset.k; ch[k]=(k==='duration'||k==='speed'||k==='frames')?+e.value:e.value; }); r=await bridge.call('media.redesign',ch); }
  if(!r.ok){ msg.textContent=r.message||'failed'; msg.className='mmsg bad'; return; }
  msg.textContent=`Queued ${r.id}`+(chatID?' — it appears below in this chat.':' — see the list above.');
  if(chatID) loadChat(); else mPoll(); }
document.addEventListener('click',e=>{ const b=e.target.closest('[data-mact]'); if(!b) return; const card=b.closest('.media-card'); const a=b.dataset.mact;
  if(a==='redesign'){ const f=card.querySelector('.mredesign'); f.style.display=f.style.display==='none'?'block':'none'; return; }
  mAgain(card, a==='regen'?'regen':'redesign'); });
// In-chat media placeholders [[media:ID]] poll until finished.
async function fillMedia(el, id, chatID){
  for(let n=0;n<900;n++){ const d=await bridge.call('media.job',{id}); if(!el.isConnected) return;
    el.innerHTML=mCard(d, chatID); if(d.status==='done'||d.status==='failed'||d.status==='error'||d.ok===false) return;
    await new Promise(r=>setTimeout(r,2000)); } }
// Parse "/image prompt --size 768x512 --quality high --style \"oil paint\" --format jpeg"
function parseMediaCmd(text){
  let source=String(text||'').trim();
  const natural=/^(?:(?:please|can you|could you|would you)\s+)*(?:generate|create|make|draw|render|paint)\s+(?:me\s+)?(?:(?:a|an|some|short)\s+)*(image|picture|photo|illustration|artwork|video|clip|music|song|sound effect|sound|speech|voiceover)\s+(?!\s*(?:prompt|editor|player|(?:generation\s+)?(?:code|script))\b)(?:(?:of|showing|about|for|that says|saying)\s+)?([\s\S]+)$/i.exec(source);
  if(natural){const kinds={picture:'image',photo:'image',illustration:'image',artwork:'image',clip:'video',song:'music','sound effect':'sfx',sound:'sfx',voiceover:'speech'};source='/'+(kinds[natural[1].toLowerCase()]||natural[1].toLowerCase())+' '+natural[2];}
  const m=source.match(/^\/(image|img|speech|tts|say|music|sfx|sound|video)\b\s*([\s\S]*)$/i); if(!m) return null;
  const type={img:'image',tts:'speech',say:'speech',sound:'sfx'}[m[1].toLowerCase()]||m[1].toLowerCase();
  const spec={type}; let rest=m[2];
  rest=rest.replace(/--(size|quality|style|format|duration|speed|frames)\s+("([^"]*)"|'([^']*)'|(\S+))/gi,(_,k,__,a,b,c)=>{ const v=a??b??c; k=k.toLowerCase();
    spec[k]=(k==='duration'||k==='speed'||k==='frames')?+v:v; return ''; });
  spec.prompt=rest.trim(); return spec; }
function mRender(list){
  $('#mJobs').innerHTML=(list||[]).map(j=>`<div class="card" data-job="${esc(j.id)}">${mDone[j.id]||mCard(j)}</div>`).join('')||'<span class="muted">No media yet.</span>'; }
async function mPoll(){
  const r=await bridge.call('media.jobs',{}); if(!r.ok){return;}
  const list=r.jobs||r.data||[];
  for(const j of list){ if(j.status==='done'&&!mDone[j.id]){ const d=await bridge.call('media.job',{id:j.id}); if(d.status==='done') mDone[j.id]=mCard(d); } }
  if(document.activeElement && document.activeElement.closest && document.activeElement.closest('#mJobs')) return; // don't clobber an open Redesign form
  mRender(list); }
function mSpecFromForm(){ const t=$('#mType').value, sp={type:t,prompt:$('#mPrompt').value,style:$('#mStyle').value,quality:$('#mQuality').value};
  if(t==='image'){ sp.size=$('#mSize').value; sp.format=$('#mFormat').value; }
  if(t==='music'||t==='sfx') sp.duration=+$('#mDur').value; if(t==='speech') sp.speed=+$('#mSpeed').value; if(t==='video') sp.frames=+$('#mFrames').value; return sp; }
function mShowFields(){ const t=$('#mType').value; $$('.mspec [data-for]').forEach(e=>e.style.display=e.dataset.for.split(' ').includes(t)?'':'none'); }
$('#mType').onchange=mShowFields; mShowFields();
$('#mGo').onclick=async()=>{
  const r=await bridge.call('media.submit',mSpecFromForm());
  $('#mMsg').textContent=r.ok?`Queued ${r.id} (position ${r.position})`:(r.message||'failed'); $('#mMsg').className=r.ok?'ok':'bad'; mPoll();
};
setInterval(()=>{ if($('#tab-media').classList.contains('on')) mPoll(); }, 2000);

// ---- ToS + RedX sign-in gate (required on every launch; re-prompts when terms change)
const TERMS_VERSION='2026-10-25';
let gFlow='',gMethod='totp',quickTimer=0,quickChecking=false,authMethod='quick',quickAttempt=0;
function chooseSignInMethod(method){
  if(method!=='quick'&&method!=='password')return;
  if(method==='password'){
    // Cancel a pending browser grant; password login never depends on Quick Login.
    quickAttempt++;
    quickStopUI();
    void bridge.call('redx.quick.cancel').catch(()=>{});
  }
  if(method==='quick'){
    // No password or MFA challenge is required for a Vortex-scoped browser grant.
    gFlow='';gMethod='totp';
    $('#gPass').value='';$('#gOtp').value='';
    $('#gCreds').style.display='';$('#gCode').style.display='none';$('#gGo').textContent='Sign in';
  }
  authMethod=method;
  $('#gQuickSection').hidden=method!=='quick';
  $('#gPasswordSection').hidden=method!=='password';
  for(const [button,selected] of [['#gChooseQuick',method==='quick'],['#gChoosePassword',method==='password']]){
    $(button).classList.toggle('active',selected);
    $(button).setAttribute('aria-pressed',String(selected));
  }
  $('#gMsg').textContent='';
}
$('#gChooseQuick').onclick=()=>chooseSignInMethod('quick');
$('#gChoosePassword').onclick=()=>chooseSignInMethod('password');
chooseSignInMethod('quick');
function quickStopUI(){
  if(quickTimer) clearInterval(quickTimer);
  quickTimer=0;quickChecking=false;
  $('#gQuick').disabled=false;
  $('#gApproval').style.display='none';
}
// The first-party website approval tab is script-opened from this user click
// when using the default browser; it can therefore close itself and focus the
// Vortex tab after consent. Explicit other browsers must use the OS launcher.
const quickBrowserPicker=$('#gBrowserChoice');
const quickIsMac=/Macintosh|MacIntel|MacPPC|Mac68K/i.test(navigator.userAgent||'');
for(const opt of quickBrowserPicker.options){
  if(opt.value==='safari'&&!quickIsMac){opt.disabled=true;opt.hidden=true;}
}
try{
  const stored=localStorage.getItem('rxql.browserPreference')||'default';
  quickBrowserPicker.value=[...quickBrowserPicker.options].some(x=>x.value===stored&&!x.disabled)?stored:'default';
}catch{quickBrowserPicker.value='default';}
$('#gBrowserChoice').addEventListener('change',()=>{try{localStorage.setItem('rxql.browserPreference',$('#gBrowserChoice').value);}catch{}});
$('#gQuick').onclick=async()=>{
  if(authMethod!=='quick')return;
  const attempt=++quickAttempt;
  const selectedBrowser=quickBrowserPicker.value;
  // Open synchronously from the click before awaiting network I/O, so browser
  // popup blockers treat it as user initiated. A script-opened tab can call
  // window.close() after approval and return focus to its Vortex opener.
  const approvalTab=selectedBrowser==='default'?window.open('about:blank','_blank'):null;
  if(approvalTab){
    try{
      approvalTab.document.title='Connecting to Red-XAI';
      approvalTab.document.body.textContent='Opening secure Red-XAI authorization…';
    }catch{}
  }
  $('#gQuick').disabled=true;$('#gMsg').textContent='Starting secure Red-XAI approval…';
  const r=await bridge.call('redx.quick.start').catch(()=>({ok:false,error:'Could not reach Red-XAI quick login.'}));
  if(attempt!==quickAttempt||authMethod!=='quick'){
    approvalTab?.close();
    await bridge.call('redx.quick.cancel').catch(()=>{});
    return;
  }
  if(!r.ok){approvalTab?.close();quickStopUI();$('#gMsg').textContent=r.error||'Quick login unavailable.';return;}
  let url;
  try {
    url=new URL(r.url);
    if(url.origin!=='https://red-xai.com'||!['/redxai-connect','/redxai-connect/','/redxai-connectx'].includes(url.pathname)
      || !(!url.hash||/^#request=[A-Za-z0-9_-]{43}$/.test(url.hash))) throw Error('Unsafe approval URL');
  } catch(e) {approvalTab?.close();quickStopUI();await bridge.call('redx.quick.cancel');$('#gMsg').textContent='Red-XAI returned an invalid approval link.';return;}
  $('#gApprovalCode').textContent=r.code;
  $('#gApprovalLink').href=url.href;
  $('#gApproval').style.display='';
  $('#gMsg').textContent='Checking your existing Red-XAI website login in the selected browser…';
  let opened={ok:false,error:'Browser did not accept the new tab'};
  if(approvalTab&&!approvalTab.closed){
    try{approvalTab.location.replace(url.href);opened={ok:true};}catch{}
  }
  if(!opened.ok) opened=await bridge.call('redx.quick.open',{browser:selectedBrowser}).catch(()=>({ok:false,error:'Browser not available'}));
  if(attempt!==quickAttempt||authMethod!=='quick'){
    approvalTab?.close();
    await bridge.call('redx.quick.cancel').catch(()=>{});
    return;
  }
  if(!opened.ok) $('#gMsg').textContent=(opened.error||'Could not open browser')+' — select the approval link instead.';
  quickTimer=setInterval(async()=>{
    if(quickChecking||attempt!==quickAttempt||authMethod!=='quick')return;
    quickChecking=true;
    try {
      const v=await bridge.call('redx.quick.poll');
      if(attempt!==quickAttempt||authMethod!=='quick')return;
      if(v.signedIn){
        // A completed Vortex-scoped browser grant alone opens the workspace;
        // never request the desktop password or MFA as a second step.
        gFlow='';quickStopUI();$('#gMsg').textContent='';
        window.focus();
        await gate();
      }
      else if(!v.ok){quickStopUI();$('#gMsg').textContent=v.error||'Approval ended. Try again.';}
    } catch(e){quickStopUI();$('#gMsg').textContent='Could not check approval. Try again.';}
    finally{quickChecking=false;}
  },Math.max(2000,Math.min(10000,(Number(r.interval)||3)*1000)));
};
$('#gApprovalCancel').onclick=async()=>{
  quickAttempt++;
  quickStopUI();await bridge.call('redx.quick.cancel').catch(()=>{});
  $('#gMsg').textContent='Approval cancelled.';
};
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
  if(authMethod!=='password')return;
  $('#gMsg').textContent='';
  let r;
  if(!gFlow) r=await bridge.call('redx.login',{login:$('#gUser').value,password:$('#gPass').value});
  else r=await bridge.call('redx.2fa',{flow:gFlow,method:gMethod,code:$('#gOtp').value});
  if(authMethod!=='password')return;
  if(!r.ok){$('#gMsg').textContent=r.error||'Sign-in failed.';return;}
  if(r.next==='2fa'){gFlow=r.flow;gMethod=r.methods?.totp?'totp':'call';$('#gCreds').style.display='none';$('#gCode').style.display='';$('#gCallMe').style.display=r.methods?.call?'':'none';$('#gGo').textContent='Verify';return;}
  if(r.next==='2fa_setup'){$('#gMsg').textContent='Finish two-factor setup at red-xai.com, then sign in again.';return;}
  gFlow=''; gate();
};
$('#gCallMe').onclick=async()=>{const r=await bridge.call('redx.call',{flow:gFlow});if(r.ok)gMethod='call';$('#gMsg').textContent=r.ok?'Calling you now — enter the code you hear.':(r.message||'Call failed.');};
$('#fSignOut').onclick=async e=>{e.preventDefault();await bridge.call('redx.logout');location.reload();};
$('#fTerms').onclick=async e=>{e.preventDefault();const t=await fetch('terms.md').then(r=>r.text());const w=window.open('','_blank');if(w){w.document.body.innerHTML='<pre style="white-space:pre-wrap"></pre>';w.document.querySelector('pre').textContent=t;}else alert(t);};
gate();

// ---- Notifications (gateway feed) ----
const N={seen:new Set(),primed:false};
async function nRefresh(){
  let r; try{ r=await bridge.call('notif.list'); }catch(e){ return; }
  if(!r||!Array.isArray(r.data)) return;
  const u=r.unread||0;
  $('#nTabBtn').textContent='🔔 Notifications'+(u?` (${u})`:'');
  $('#nCount').textContent=u?`${u} unread`:'';
  document.title=(u?`(${u}) `:'')+'Red-XAI Vortex';
  const box=$('#nList'); if(r.data.length) box.innerHTML='';
  for(const n of r.data){
    const d=document.createElement('div'); d.className='card'; d.style.opacity=n.read?.7:1;
    const t=document.createElement('b'); t.textContent=n.title; if(n.read) t.style.fontWeight='normal';
    const b=document.createElement('div'); b.className='muted'; b.textContent=n.body||'';
    const w=document.createElement('small'); w.textContent=new Date(n.ts*1000).toLocaleString();
    d.append(t,b,w);
    { const k=document.createElement('button'); k.textContent='Dismiss'; k.onclick=async()=>{await bridge.call('notif.read',{ids:[n.id]});nRefresh();}; d.append(' ',k); }
    box.append(d);
    if(!n.read && !N.seen.has(n.id)){ N.seen.add(n.id);
      if(N.primed && 'Notification' in window && Notification.permission==='granted') new Notification(n.title,{body:n.body||''}); }
  }
  N.primed=true;
}
$('#nRefresh').onclick=nRefresh;
$('#nAll').onclick=async()=>{await bridge.call('notif.read',{all:true});nRefresh();};
if('Notification' in window && Notification.permission==='default') Notification.requestPermission();
nRefresh(); setInterval(nRefresh,45000);

// ---- Composer controls: Quick replies, strength slider, reply length (per chat, with a global default) ----
async function loadComposer(){
  const r=await bridge.call('composer.get',{id:state.active||''});
  if(!r.ok) return;
  state.tiers=r.tiers; state.comp=r;
  const c=r.composer;
  $('#cQuick').checked=!!c.quick; $('#cLen').value=c.length;
  $('#cTier').value=Math.max(0,r.tiers.findIndex(t=>t.ID===c.tier));
  showTier();
  $('#cScope').textContent=r.perChat?'Saved for this chat':'Using your default';
}
function showTier(){
  const t=state.tiers[+$('#cTier').value]; if(!t) return;
  $('#cTierName').textContent=t.Name; $('#cTierName').title=t.Model;
  $('#cTierSpeed').textContent=$('#cQuick').checked?'Quick: Vortex Mini · ≈14 tok/s':t.Speed;
}
function compVals(){ const t=state.tiers[+$('#cTier').value]; return {tier:t?t.ID:'vortex', length:$('#cLen').value, quick:$('#cQuick').checked}; }
async function saveComposer(global){
  if(!state.active && !global){ return; }
  const r=await bridge.call('composer.set',Object.assign({id:state.active||'', global}, compVals()));
  if(r.ok && state.comp){ state.comp.perChat=!!state.active; $('#cScope').textContent=global?'Saved as default':'Saved for this chat'; }
}
$('#cTier').oninput=showTier;
['cTier','cLen','cQuick'].forEach(id=>$('#'+id).onchange=()=>{ showTier(); saveComposer(false); });
$('#cDefault').onclick=()=>saveComposer(true);
$('#modelPick').onchange=()=>{ state.modelExplicit=!$('#modelPick').value.startsWith('vortex'); };
loadComposer();

// ---- Agent runs + activity (v2.5) ----
function tfmt(t){ const d=new Date(t); return d.toLocaleString([], {month:'short',day:'numeric',hour:'numeric',minute:'2-digit',second:'2-digit'}); }
function fillAgentSelects(){
  const opts=state.agents.map(a=>`<option value="${esc(a.id)}">${esc(a.name)}</option>`).join('');
  const r=$('#rAgent'), f=$('#aFilter');
  if(r && r.dataset.n!==String(state.agents.length)){ r.innerHTML=opts; r.dataset.n=state.agents.length; }
  if(f && f.dataset.n!==String(state.agents.length)){ const v=f.value; f.innerHTML='<option value="">All agents</option>'+opts; f.value=v; f.dataset.n=state.agents.length; }
}
function runRow(r){
  const ap=r.pending?`<div class="row" style="margin-top:4px"><span>Wants to <b>${esc(r.pending.tool)}</b>: <code>${esc(r.pending.what)}</code></span>
    <button class="primary" data-allow="${esc(r.id)}">Allow once</button><button data-deny="${esc(r.id)}">Deny</button></div>`:'';
  const stop=(r.status==='running'||r.status==='waiting')?` <button data-stop="${esc(r.id)}">Stop</button>`:'';
  return `<div class="run"><b>${esc(r.agent)}</b> · <span class="st-${esc(r.status)}">${esc(r.status)}</span> · step ${r.steps} · ${tfmt(r.started)}${stop}
    <div>${esc(r.task)}</div>${r.result?`<div class="muted">${esc(r.result).slice(0,600)}</div>`:''}${ap}</div>`;
}
function bindRunButtons(root){
  root.querySelectorAll('[data-allow]').forEach(b=>b.onclick=async()=>{ await bridge.call('run.approve',{runID:b.dataset.allow,allow:true}); actPoll(); });
  root.querySelectorAll('[data-deny]').forEach(b=>b.onclick=async()=>{ await bridge.call('run.approve',{runID:b.dataset.deny,allow:false}); actPoll(); });
  root.querySelectorAll('[data-stop]').forEach(b=>b.onclick=async()=>{ await bridge.call('run.stop',{runID:b.dataset.stop}); actPoll(); });
}
async function actLog(){
  const r=await bridge.call('activity.search',{agentID:$('#aFilter').value,kind:$('#aKind').value,q:$('#aQ').value,limit:300});
  $('#actLog').innerHTML=(r.events||[]).map(e=>`<div class="ev"><span class="k">${tfmt(e.ts)}</span> <b>${esc(e.agent)}</b> <span class="pill">${esc(e.kind)}</span> ${esc(e.summary)}
    ${e.detail&&e.detail!==e.summary?`<details><summary>details</summary>${esc(e.detail)}</details>`:''}</div>`).join('')||'<p class="muted">No activity yet.</p>';
}
let actSig='';
async function actPoll(){
  fillAgentSelects();
  const st=await bridge.call('activity.stats',{});
  const runs=st.runs||[];
  const waiting=runs.filter(r=>r.pending);
  const bar=$('#apBar');
  if(waiting.length){ bar.style.display=''; bar.innerHTML='<b>An agent is waiting for you</b>'+waiting.map(runRow).join(''); bindRunButtons(bar); }
  else bar.style.display='none';
  $('#actTabBtn').textContent=waiting.length?`Activity (${waiting.length})`:'Activity';
  if(!$('#tab-activity').classList.contains('on')) return;
  $('#rList').innerHTML=runs.slice(0,10).map(runRow).join(''); bindRunButtons($('#rList'));
  $('#actStats').innerHTML=(st.agents||[]).length?`<table style="width:100%;font-size:13px"><tr><th align=left>Agent</th><th>Runs</th><th>Actions</th><th>Denied</th><th>Errors</th><th align=left>Last activity</th></tr>`+
    st.agents.map(a=>`<tr><td><a href="#" data-ag="${esc(a.agentID)}">${esc(a.agent)}</a></td><td align=center>${a.runs}</td><td align=center>${a.actions}</td><td align=center>${a.denied}</td><td align=center>${a.errors}</td><td>${tfmt(a.last)} · ${esc(a.lastWhat).slice(0,80)}</td></tr>`).join('')+'</table>':'<p class="muted">No activity yet.</p>';
  $('#actStats').querySelectorAll('[data-ag]').forEach(a=>a.onclick=(ev)=>{ ev.preventDefault(); $('#aFilter').value=a.dataset.ag; actLog(); });
  const sig=JSON.stringify(runs.map(r=>[r.id,r.status,r.steps]));
  if(sig!==actSig){ actSig=sig; actLog(); }
}
$('#rGo').onclick=async()=>{ const r=await bridge.call('run.start',{agentID:$('#rAgent').value,task:$('#rTask').value}); if(r.ok){ $('#rTask').value=''; } else alert(r.message); actPoll(); };
$('#aFilter').onchange=actLog; $('#aKind').onchange=actLog;
let aqT; $('#aQ').oninput=()=>{ clearTimeout(aqT); aqT=setTimeout(actLog,250); };
async function actExport(format){ const r=await bridge.call('activity.export',{format,agentID:$('#aFilter').value,kind:$('#aKind').value,q:$('#aQ').value});
  $('#aExpMsg').textContent=r.ok?`Saved ${r.count} entries to ${r.path}`:r.message; }
$('#aExpJ').onclick=()=>actExport('json'); $('#aExpC').onclick=()=>actExport('csv');
$('#actTabBtn').addEventListener('click',()=>{ actSig=''; actPoll(); });
setInterval(actPoll, 2000);
