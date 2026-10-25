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
$('#makePlugin').onclick=async()=>{
  const r=await bridge.call('plugin.make',{description:$('#maker').value});
  $('#pluginOut').textContent = r.json || r.error || '';
};
$('#uploadPlugin').onclick=async()=>{
  const r=await bridge.call('plugin.upload',{json:$('#pluginOut').textContent});
  $('#pluginOut').textContent = (r.message||'') + '\n' + ($('#pluginOut').textContent||'');
};
$('#refreshStore').onclick=async()=>{
  const r=await bridge.call('plugin.store',{});
  $('#pluginOut').textContent = JSON.stringify(r.plugins||r,null,2);
};
$('#saveSettings').onclick=async()=>{
  const r=await bridge.call('settings.save',{baseURL:$('#baseURL').value, apiKey:$('#apiKey').value});
  $('#apiKey').value=''; $('#setMsg').textContent=r.message||'Saved'; $('#setMsg').className=r.ok?'ok':'bad'; refresh();
};
$('#probe').onclick=async()=>{ const r=await bridge.call('settings.probe',{}); $('#setMsg').textContent=r.message||''; $('#setMsg').className=r.ok?'ok':'bad'; };
refresh(); setInterval(refresh, 15000);
