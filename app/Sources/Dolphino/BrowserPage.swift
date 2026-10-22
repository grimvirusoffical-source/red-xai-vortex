enum BrowserPage {
    static let html = #"""
<!doctype html><html><head><meta charset="utf-8"><title>Dolphino · Models</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
:root{--bg:#0f1115;--card:#171a21;--line:#262a33;--fg:#e8eaf0;--mut:#8b92a3;--acc:#e0242f;--ok:#2fbf71}
@media (prefers-color-scheme:light){:root{--bg:#f6f7f9;--card:#fff;--line:#e3e5ea;--fg:#14161a;--mut:#667085}}
*{box-sizing:border-box}body{margin:0;font:14px/1.45 -apple-system,BlinkMacSystemFont,sans-serif;background:var(--bg);color:var(--fg)}
header{position:sticky;top:0;background:var(--bg);border-bottom:1px solid var(--line);padding:14px 24px;display:flex;gap:12px;align-items:center;z-index:2;flex-wrap:wrap}
h1{font-size:20px;margin:0 12px 0 0}input,select,button{font:inherit;color:inherit}
input[type=search]{flex:1;min-width:220px;padding:8px 12px;border-radius:10px;border:1px solid var(--line);background:var(--card)}
select{padding:7px 10px;border-radius:10px;border:1px solid var(--line);background:var(--card)}
.tabs button,.chips button{border:1px solid var(--line);background:var(--card);padding:6px 12px;border-radius:999px;cursor:pointer}
.tabs button.on,.chips button.on{background:var(--acc);border-color:var(--acc);color:#fff}
.chips{display:flex;gap:6px;flex-wrap:wrap;padding:12px 24px 0}
main{padding:16px 24px;display:grid;grid-template-columns:repeat(auto-fill,minmax(320px,1fr));gap:14px}
.card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:14px 16px;display:flex;flex-direction:column;gap:8px}
.card h3{margin:0;font-size:16px;display:flex;gap:8px;align-items:center}.mut{color:var(--mut);font-size:12.5px}
.pill{font-size:11px;padding:2px 8px;border-radius:999px;background:rgba(127,127,127,.15)}.pill.ok{background:rgba(47,191,113,.2);color:var(--ok)}
.row{display:flex;gap:8px;align-items:center;flex-wrap:wrap}
.btn{border:0;border-radius:9px;padding:7px 12px;cursor:pointer;background:var(--acc);color:#fff}.btn.sec{background:rgba(127,127,127,.18);color:var(--fg)}.btn:disabled{opacity:.45;cursor:default}
progress{width:100%;height:8px;accent-color:var(--acc)}
#installed{padding:0 24px 24px}#installed table{width:100%;border-collapse:collapse;background:var(--card);border-radius:12px;overflow:hidden}
#installed td,#installed th{padding:8px 12px;border-bottom:1px solid var(--line);text-align:left}
#toast{position:fixed;bottom:18px;left:50%;transform:translateX(-50%);background:#222;color:#fff;padding:9px 16px;border-radius:10px;display:none}
</style></head><body>
<header><h1>🐬 Models</h1>
<div class="tabs"><button id="t-cur" class="on">Curated</button> <button id="t-ol">Ollama library</button> <button id="t-inst">Installed</button></div>
<input type="search" id="q" placeholder="Search models…">
<label class="mut">Install on</label><select id="target"></select></header>
<div class="chips" id="chips"></div>
<main id="grid"></main><div id="installed"></div><div id="toast"></div>
<script>
const T=new URLSearchParams(location.search).get('t');
const api=(p,o={})=>fetch(p+(p.includes('?')?'&':'?')+'t='+T,{...o,headers:{'X-Token':T,'Content-Type':'application/json'}}).then(async r=>{const j=await r.json().catch(()=>({}));if(!r.ok||j.error)throw new Error(j.error?.message||j.error||r.status);return j});
const gb=b=>(b/1e9).toFixed(1)+' GB', $=id=>document.getElementById(id), esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
let tab='cur',cat='all',catalog=[],library=[],jobs={},installed=[],merges=[];
const CATS=[['all','All'],['general','General'],['coding','Coding'],['reasoning','Reasoning'],['fast','Fast & small'],['vision','Vision'],['writing','Writing'],['multilingual','Multilingual'],['embeddings','Embeddings']];
const OLCAT={coding:/code|coder|starcoder|devstral|codestral/i,reasoning:/r1|qwq|reason|think|phi4-reasoning|magistral/i,vision:/vision|vl|llava|moondream|minicpm-v|gemma3/i,embeddings:/embed|bge|minilm|snowflake|nomic/i,fast:/tiny|small|mini|smol|270m|1b|0\.5b/i,multilingual:/qwen|aya|mistral|glm/i};
function toast(m){const t=$('toast');t.textContent=m;t.style.display='block';clearTimeout(t._h);t._h=setTimeout(()=>t.style.display='none',3500)}
function chips(){$('chips').innerHTML=tab=='inst'?'':CATS.map(([k,v])=>`<button class="${k==cat?'on':''}" data-c="${k}">${v}</button>`).join('');$('chips').querySelectorAll('button').forEach(b=>b.onclick=()=>{cat=b.dataset.c;chips();render()})}
function estParams(s){const m=/([\d.]+)\s*([bm])/i.exec(s);if(!m)return null;return parseFloat(m[1])*(m[2].toLowerCase()=='m'?1e6:1e9)}
function jobBar(id){const j=jobs[id];if(!j)return'';if(j.state=='downloading')return `<progress value="${j.done}" max="${j.total||1}"></progress><span class="mut">${Math.round(100*j.done/(j.total||1))}% · ${gb(j.done)} of ${gb(j.total)}</span>`;if(String(j.state).startsWith('error'))return `<span class="mut" style="color:#e55">${esc(j.state)}</span>`;return ''}
function mergeSel(id){return merges.length?`<select data-merge="${esc(id)}"><option value="">Add to merge…</option>${merges.map(m=>`<option value="${esc(m.name)}">${esc(m.name)} (${esc(m.mode)})</option><option value="${esc(m.name)}|judge">${esc(m.name)} as judge</option>`).join('')}</select>`:''}
function render(){
 const q=$('q').value.toLowerCase(),g=$('grid');$('installed').innerHTML='';
 if(tab=='cur'){
  const L=catalog.filter(m=>(cat=='all'||m.category==cat)&&(!q||(m.name+m.id+m.about).toLowerCase().includes(q)));
  g.innerHTML=L.map(m=>`<div class="card"><h3>${esc(m.name)} ${m.installed?'<span class="pill ok">installed</span>':''}</h3>
  <div class="mut">${esc(m.about)}</div><div class="row"><span class="pill">${esc(m.category)}</span><span class="pill">${gb(m.bytes)}</span><span class="pill">RAM ${gb(m.ram_bytes)}</span><span class="pill">${esc(m.speed)}</span><span class="pill">${esc(m.license)}</span></div>
  <div class="mut">${esc(m.id)}</div>${jobBar(m.id)}
  <div class="row">${m.installed?`<button class="btn sec" data-rm="${esc(m.id)}">Remove</button>${mergeSel(m.id)}`:`<button class="btn" data-pull="${esc(m.id)}" ${(!m.fits||!m.pullable)?'disabled':''}>Download</button>`}${!m.fits?'<span class="mut">too big for target RAM</span>':''}</div></div>`).join('')||'<p class="mut">No models.</p>';
 }else if(tab=='ol'){
  const L=library.filter(m=>(cat=='all'||(OLCAT[cat]&&OLCAT[cat].test(m.name+' '+m.about+' '+m.capabilities.join(' '))))&&(!q||(m.name+m.about).toLowerCase().includes(q))).slice(0,300);
  g.innerHTML=L.map(m=>`<div class="card"><h3>${esc(m.name)}</h3><div class="mut">${esc(m.about)}</div>
  <div class="row">${m.capabilities.map(c=>`<span class="pill">${esc(c)}</span>`).join('')}${m.pulls?`<span class="pill">${esc(m.pulls)} pulls</span>`:''}</div>
  <div class="row">${m.sizes.map(s=>{const p=estParams(s);const b=p?p*0.6:0;return `<button class="btn sec" data-ol="${esc(m.name)}:${esc(s)}" title="~${b?gb(b):'?'} Q4 · RAM ~${b?gb(b*1.1+1.5e9):'?'} · ~${b?Math.max(1,Math.round(190e9/b)):'?'} tok/s on a 16-core server">${esc(s)}${b?' · '+gb(b):''}</button>`}).join('')||`<button class="btn sec" data-ol="${esc(m.name)}">latest</button>`}
  <button class="btn sec" data-tags="${esc(m.name)}">All tags…</button></div><div class="tagbox"></div>${jobBar('ol-'+m.name.replace('/','-')+'-latest')}</div>`).join('')||'<p class="mut">Loading Ollama library…</p>';
 }else{
  g.innerHTML='';$('installed').innerHTML=`<table><tr><th>Model</th><th>Size</th><th></th></tr>${installed.filter(m=>!q||m.id.includes(q)).map(m=>`<tr><td>${esc(m.id)}${m.default?' <span class="pill ok">default</span>':''}${jobBar(m.id)}</td><td>${gb(m.bytes)}</td><td class="row"><button class="btn sec" data-rm="${esc(m.id)}">Remove</button>${mergeSel(m.id)}</td></tr>`).join('')}</table>
  ${Object.entries(jobs).filter(([,j])=>j.state=='downloading').map(([id])=>`<p>${esc(id)} ${jobBar(id)}</p>`).join('')}`;
 }
 bind();
}
function bind(){
 document.querySelectorAll('[data-pull]').forEach(b=>b.onclick=async()=>{const m=catalog.find(x=>x.id==b.dataset.pull);try{await api('/x/pull',{method:'POST',body:JSON.stringify({target:$('target').value,kind:'catalog',id:m.id,model:m})});toast('Downloading '+m.name);jobs[m.id]={state:'downloading',done:0,total:m.bytes};render()}catch(e){toast(e.message)}});
 document.querySelectorAll('[data-ol]').forEach(b=>b.onclick=async()=>{const ref=b.dataset.ol;try{await api('/x/pull',{method:'POST',body:JSON.stringify({target:$('target').value,kind:'ollama',ref})});toast('Downloading '+ref)}catch(e){toast(e.message)}});
 document.querySelectorAll('[data-tags]').forEach(b=>b.onclick=async()=>{const box=b.closest('.card').querySelector('.tagbox');box.innerHTML='<span class="mut">Loading tags…</span>';try{const r=await api('/x/tags?name='+encodeURIComponent(b.dataset.tags));box.innerHTML=`<select>${r.tags.map(t=>`<option>${esc(t)}</option>`).join('')}</select> <button class="btn">Download tag</button>`;box.querySelector('button').onclick=async()=>{const ref=b.dataset.tags+':'+box.querySelector('select').value;try{await api('/x/pull',{method:'POST',body:JSON.stringify({target:$('target').value,kind:'ollama',ref})});toast('Downloading '+ref)}catch(e){toast(e.message)}}}catch(e){box.textContent=e.message}});
 document.querySelectorAll('[data-rm]').forEach(b=>b.onclick=async()=>{if(!confirm('Remove '+b.dataset.rm+' and free its disk space?'))return;try{const r=await api('/x/remove',{method:'POST',body:JSON.stringify({target:$('target').value,id:b.dataset.rm})});toast('Removed, freed '+gb(r.freed_bytes||0));load()}catch(e){toast(e.message)}});
 document.querySelectorAll('[data-merge]').forEach(s=>s.onchange=async()=>{if(!s.value)return;const [merge,as]=s.value.split('|');try{await api('/x/merge-add',{method:'POST',body:JSON.stringify({merge,model:s.dataset.merge,as})});toast('Added to '+merge)}catch(e){toast(e.message)}s.value=''});
}
async function load(){
 const t=$('target').value;
 try{catalog=(await api('/x/catalog?target='+t)).catalog||[]}catch(e){toast(e.message)}
 try{const r=await api('/x/installed?target='+t);installed=r.installed||[]}catch(e){}
 try{merges=(await api('/x/merges')).merges||[]}catch(e){}
 render();
}
async function poll(){try{const r=await api('/x/jobs?target='+$('target').value);const was=Object.values(jobs).some(j=>j.state=='downloading');jobs={};(r.jobs||[]).forEach(j=>jobs[j.id]=j);const now=Object.values(jobs).some(j=>j.state=='downloading');if(was&&!now)load();else if(now)render()}catch(e){}setTimeout(poll,1500)}
async function init(){
 const ts=(await api('/x/targets')).targets;$('target').innerHTML=ts.map(t=>`<option value="${esc(t.id)}" ${t.active?'selected':''}>${esc(t.name)}</option>`).join('');
 $('target').onchange=load;$('q').oninput=render;
 const tabs={cur:'t-cur',ol:'t-ol',inst:'t-inst'};Object.entries(tabs).forEach(([k,id])=>$(id).onclick=async()=>{tab=k;Object.values(tabs).forEach(x=>$(x).classList.toggle('on',x==id));chips();render();if(k=='ol'&&!library.length){try{library=(await api('/x/ollama')).library||[];render()}catch(e){toast(e.message)}}});
 chips();await load();poll();
}
init().catch(e=>document.body.innerHTML='<p style="padding:24px">'+esc(e.message)+'</p>');
</script></body></html>
"""#
}
