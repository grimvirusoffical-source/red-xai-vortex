/* Local workspace controls. The bridge validates storage, quotas, remote access, and context. */
(() => {
  'use strict';
  let workspace = {projects:[],personalities:[],bases:[],memory:{quotaBytes:67108864,entries:[]},worlds:[],chatSettings:[],attachments:[]};
  let usageBytes = 0, view = 'projects', selected = {}, loaded = false, loading = null, codingDraft = null, fieldCounter = 0;
  const names = {project:'projects',personality:'personalities',base:'bases',memory:'memory',world:'worlds'};
  const labels = {projects:'Projects',bases:'XAI Bases',personalities:'Personalities',memory:'Memory',worlds:'Worlds',coding:'Coding context'};
  const q = s => document.querySelector(s);
  const qa = s => [...document.querySelectorAll(s)];
  const text = value => esc(value);
  const fmt = n => n >= 1048576 ? (n/1048576).toFixed(1)+' MB' : n >= 1024 ? (n/1024).toFixed(1)+' KB' : (n||0)+' B';
  const collection = kind => kind === 'memory' ? (workspace.memory?.entries||[]) : (workspace[names[kind]]||[]);
  const entity = kind => collection(kind).find(x=>x.id===selected[kind]) || {};
  const empty = (title,description) => `<div class="workspace-empty"><b>${text(title)}</b>${text(description)}</div>`;
  const field = (label,name,value='',placeholder='',type='input') => {const id='ws-'+name+'-'+fieldCounter++;return `<label for="${id}">${text(label)}</label>${type==='textarea'?`<textarea id="${id}" name="${name}" placeholder="${text(placeholder)}">${text(value)}</textarea>`:`<input id="${id}" name="${name}" value="${text(value)}" placeholder="${text(placeholder)}"/>`}`;};
  const option = (value,label,current) => `<option value="${text(value)}"${String(value)===String(current)?' selected':''}>${text(label)}</option>`;
  const select = (label,name,items,current='',none='None') => {const id='ws-'+name+'-'+fieldCounter++;return `<label for="${id}">${text(label)}</label><select id="${id}" name="${name}">${option('',none,current)}${items.map(i=>option(i.id,i.name||i.title||'Untitled',current)).join('')}</select>`;};
  const check = (name,label,checked=false) => `<label class="ws-checkbox"><input name="${name}" type="checkbox"${checked?' checked':''}/> ${text(label)}</label>`;
  const checks = (label,name,items,chosen=[],none='Nothing available yet.') => `<label>${text(label)}</label><div class="check-list">${items.length?items.map(i=>`<label><input type="checkbox" name="${name}" value="${text(i.id)}"${chosen.includes(i.id)?' checked':''}/> ${text(i.name||i.title||'Untitled')}</label>`).join(''):`<p class="ws-note">${text(none)}</p>`}</div>`;
  const actions = (kind,id,label='Save') => `<div class="row actions"><button class="primary" type="submit">${text(label)}</button><button type="button" class="ghost" data-ws-new="${kind}">New</button>${id?`<button type="button" class="danger" data-ws-delete="${kind}" data-id="${text(id)}">Delete</button>`:''}</div>`;
  const attachmentNames = ids => (ids||[]).map(id=>workspace.attachments.find(a=>a.id===id)).filter(Boolean);
  const attachmentList = ids => `<div class="ws-attachment-list">${attachmentNames(ids).map(a=>`<div><span>${text(a.name)} <small>· ${text(a.mimeType)} · ${fmt(a.bytes)}</small></span><button type="button" data-remove-attachment="${text(a.id)}">Detach</button></div>`).join('')}</div>`;
  const fileField = (label='Add files') => `<label>${text(label)}</label><input name="files" type="file" multiple accept="image/*,audio/*,video/*,.txt,.md,.json,.csv,.pdf,.doc,.docx,.html,.xml,.js,.ts,.py,.go,.cs,.cpp,.c,.h,.yaml,.yml"/><p class="ws-note">Files stay in local storage. Text files can supply text context; other media supply metadata until an extraction tool is connected.</p>`;
  const baseStatus = b => `<span class="pill ${b.status==='online'||b.status==='local'?'ok':b.status==='offline'||b.status==='revoked'?'bad':''}">${text(b.status||'local')}</span>`;
  function notice(message,error=false){ const el=q('#wsMessage'); el.textContent=message||''; el.className=error?'bad':''; }
  function accept(r){
    if(r?.workspace) workspace={...workspace,...r.workspace,memory:{...workspace.memory,...r.workspace.memory}};
    if(Number.isFinite(r?.usageBytes)) usageBytes=r.usageBytes;
    if(!r || r.ok===false){const error=new Error(r?.message||r?.error||'The workspace request failed.');error.workspaceUpdated=!!r?.workspace;throw error;}
    if(r.readOnly&&r.warning)notice('Workspace is read-only: '+r.warning,true);
    loaded=true; return r;
  }
  async function request(method,args={}){ return accept(await bridge.call(method,args)); }
  async function load(){
    if(loading) return loading;
    loading=request('workspace.get').then(()=>{renderSidebar();renderContext();return workspace;}).catch(e=>{notice(e.message,true);throw e;}).finally(()=>{loading=null;});
    return loading;
  }
  async function open(next='projects',id){
    view=next;
    if(id!==undefined){const kind=Object.keys(names).find(k=>names[k]===next);if(kind)selected[kind]=id;}
    q('[data-tab="workspace"]').click();
    try{if(!loaded) await load();render();}catch(e){q('#wsContent').innerHTML=empty('Workspace unavailable',e.message);}
  }
  function renderSidebar(){
    const el=q('#wsSidebarProjects');
    if(!el)return;
    const query=(q('#chatSearch')?.value||'').trim().toLocaleLowerCase();
    el.innerHTML=workspace.projects.map(p=>`<div class="sidebar-project-group"><button class="sidebar-project" data-open-project="${text(p.id)}"><span class="project-dot"></span><span>${text(p.name)}</span><small>${(p.chatIDs||[]).length}</small></button>${state.chats.filter(c=>(p.chatIDs||[]).includes(c.id)&&(!query||(c.title||'').toLocaleLowerCase().includes(query))).map(c=>`<button class="project-chat ${c.id===state.active?'on':''}" data-project-chat="${text(c.id)}">${text(c.title||'Chat')}</button>`).join('')}</div>`).join('')||'<em>No projects yet</em>';
  }
  function list(kind,description){
    const items=collection(kind);
    return `<div><div class="ws-section-head"><h3>${text(labels[names[kind]])}<span class="ws-count">${items.length}</span></h3><button class="ghost" data-ws-new="${kind}">+ New</button></div><div class="ws-list">${items.length?items.map(i=>`<article class="ws-item ${selected[kind]===i.id?'selected':''}" tabindex="0" role="button" data-ws-select="${kind}" data-id="${text(i.id)}"><div class="ws-item-head"><h3>${text(i.name||i.title||'Untitled')}</h3>${kind==='base'?baseStatus(i):''}</div><p>${text((i.description||i.text||description).slice(0,150))}${(i.description||i.text||'').length>150?'…':''}</p><div class="row">${kind==='project'?`${(i.chatIDs||[]).length} chats <span>·</span> ${(i.attachmentIDs||[]).length} files <span>·</span> ${(i.baseIDs||[]).length} bases`:kind==='base'?`${(i.sources||[]).length} sources <span>·</span> ${i.remoteID?'Remote connection':'Local knowledge'}`:kind==='memory'?`${text(i.scope||'global')} <span>·</span> ${(i.attachmentIDs||[]).length} attachments`:kind==='world'?`${i.memoryEnabled?'World memory on':'World memory off'}`:'Reusable conversation style'}</div></article>`).join(''):empty('Make room for an idea',description)}</div></div>`;
  }
  function projects(){
    const p=entity('project');
    return `<div class="ws-split">${list('project','Group conversations, files, and instructions around a shared goal.')}<form class="ws-editor" data-ws-form="project"><h3>${p.id?'Project settings':'Create a project'}</h3><p>A home for work that deserves a little continuity.</p>${field('Project name','name',p.name,'e.g. My next big idea')}${field('Description','description',p.description,'What are you working toward?','textarea')}${field('Project instructions','instructions',p.instructions,'Context the assistant should use in this project.','textarea')}${select('Default personality','personalityID',workspace.personalities,p.personalityID)}${checks('Conversations','chatIDs',state.chats,p.chatIDs||[],'Create a chat first, then add it here.')}${checks('Connected knowledge bases','baseIDs',workspace.bases.filter(b=>b.status!=='revoked'),p.baseIDs||[])}${check('memoryEnabled','Use this project’s own memory',p.memoryEnabled)}${attachmentList(p.attachmentIDs)}${fileField('Project files')}<p class="ws-note">Project context follows chats assigned here. Shared global memory remains a separate choice in each chat.</p>${actions('project',p.id,p.id?'Save project':'Create project')}</form></div>`;
  }
  function bases(){
    const b=entity('base');
    return `<div class="ws-split">${list('base','Build a collection of useful source material, or securely connect one hosted elsewhere.')}<div><form class="ws-editor" data-ws-form="base"><div class="ws-item-head"><h3>${b.id?'Base details':'Create an XAI Base'}</h3>${b.id?baseStatus(b):''}</div><p>Reusable knowledge, with clear sources and access controls.</p>${field('Base name','name',b.name,'e.g. Product handbook')}${field('Description','description',b.description,'What does this collection cover?','textarea')}${check('read','Allow source text in context',b.permissions?.read!==false)}${check('search','Allow local keyword retrieval',b.permissions?.search!==false)}<p class="ws-note">Bases provide selected knowledge context. Adding sources does not train or change the underlying model.</p>${actions('base',b.id,b.id?'Save details':'Create base')}</form>${b.id?`<div class="ws-editor ws-subsection"><h4>Sources <span class="ws-count">${(b.sources||[]).length}</span></h4>${(b.sources||[]).length?b.sources.map(s=>`<div class="ws-source"><span class="ws-source-icon">${s.kind==='image'?'▧':s.kind==='audio'?'♫':s.kind==='video'?'▷':'▤'}</span><div><b>${text(s.name||s.kind)}</b><small>${text(s.kind||'document')} · ${fmt(s.bytes||0)}${s.text?' · text searchable':' · metadata saved'}${s.tags?.length?' · '+text(s.tags.join(', ')):''}</small></div>${b.endpoint?'':`<button type="button" data-ws-source-delete="${text(s.id)}" data-base="${text(b.id)}" title="Remove source">Remove</button>`}</div>`).join(''):empty('No sources yet','Add text, documents, or mixed media below.')}${b.endpoint?'<p class="ws-note">Sources in this remote Base are managed on its host.</p>':`<form data-ws-form="source" class="ws-subsection"><h4>Add a source</h4>${field('Source title','name','','e.g. API notes or character reference')}${field('Source text / extracted document text','text','','Paste notes, .txt content, or text copied from a document.','textarea')}${field('Document link (optional)','url','','https://docs.google.com/document/d/…')}${field('Tags (comma separated)','tags','','reference, product, research')}${fileField('Text, images, audio, video, or documents')}<p class="ws-note">Google Docs and other private documents require authorized access. A saved link is a reference; paste or upload exported text to make its contents available now.</p><div class="actions"><button class="primary" type="submit">Add source</button></div></form>`}<form data-ws-form="base-search" class="ws-subsection"><h4>Find source material</h4><label for="ws-query">Keywords</label><div class="row"><input id="ws-query" name="query" placeholder="Search this Base…" style="flex:1"/><button type="submit" class="ghost">Search</button></div><div id="wsSearchResults"></div></form><div class="ws-subsection"><details><summary>Remote hosting &amp; access</summary><p class="ws-note">Connect a compatible authenticated Base server on another PC or VPS. Use a private network or HTTPS hostname. The host’s address is shown only in these connection settings.</p><form data-ws-form="remote">${field('Endpoint','endpoint',b.endpoint,'https://knowledge.example.com')}${field('Remote Base ID','remoteID',b.remoteID,'ID from the host')}<label for="ws-token">Access token</label><input id="ws-token" name="token" type="password" autocomplete="off" placeholder="Stored separately in private local credential storage; leave blank to reuse"/><div class="row actions"><button class="primary" type="submit">Connect</button><button type="button" class="ghost" data-ws-base-action="health" data-id="${text(b.id)}">Check health</button><button type="button" class="ghost" data-ws-base-action="disconnect" data-id="${text(b.id)}">Disconnect</button><button type="button" class="danger" data-ws-base-action="revoke" data-id="${text(b.id)}">Forget access token</button></div></form>${b.lastChecked?`<p class="ws-note">Last checked: ${text(new Date(b.lastChecked).toLocaleString())}</p>`:''}${b.lastError?`<p class="ws-note bad">${text(b.lastError)}</p>`:''}</details></div></div>`:''}</div></div>`;
  }
  function personalities(){
    const p=entity('personality');
    return `<div class="ws-split">${list('personality','Save a voice and working style, then bring it into any conversation.')}<div><form class="ws-editor" data-ws-form="personality"><h3>${p.id?'Edit personality':'Create a personality'}</h3><p>Give your assistant a familiar way of working with you.</p>${field('Name','name',p.name,'e.g. Thoughtful coding partner')}${field('Description','description',p.description,'A short description')}${field('Personality instructions','instructions',p.instructions,'Describe tone, expertise, preferences, and behavior.','textarea')}<p class="ws-note">Personality instructions guide responses. They do not grant tool permissions or change safety settings.</p>${actions('personality',p.id,p.id?'Save personality':'Create personality')}${p.id?`<div class="ws-subsection"><button class="ghost" type="button" data-ws-export="${text(p.id)}">Export personality JSON</button></div>`:''}</form><form class="ws-editor ws-subsection" data-ws-form="personality-import"><h4>Import a personality</h4><p class="ws-note">Upload an exported personality JSON file or paste its contents.</p><label for="ws-personality-file">JSON file</label><input id="ws-personality-file" name="personalityFile" type="file" accept="application/json,.json"/>${field('Personality JSON','json','','{"name":"…","instructions":"…"}','textarea')}<div class="actions"><button type="submit" class="ghost">Import personality</button></div></form></div></div>`;
  }
  function scopeSelect(e){
    return `<div class="ws-inline-fields"><div><label for="ws-scope">Memory scope</label><select id="ws-scope" name="scope">${['global','project','world'].map(v=>option(v,v==='global'?'Shared across opted-in chats':v==='project'?'Only one project':'Only one world',e.scope||'global')).join('')}</select></div><div>${select('Project or world','scopeID',[...workspace.projects.map(p=>({...p,name:'Project · '+p.name})),...workspace.worlds.map(w=>({...w,name:'World · '+w.name}))],e.scopeID,'Global memory')}</div></div>`;
  }
  function memory(){
    const e=entity('memory'),quota=workspace.memory.quotaBytes||0,pct=quota?Math.min(100,usageBytes/quota*100):0;
    return `<div class="ws-split"><div><form class="ws-editor" data-ws-form="quota"><h3>Your local memory</h3><p>You decide what is remembered and how much room it gets.</p><div class="ws-stat"><span>${fmt(usageBytes)} used</span><span>${fmt(quota)} quota</span></div><div class="ws-meter"><span style="width:${pct.toFixed(2)}%"></span></div><label for="ws-quota">Storage quota (MB)</label><div class="row"><input id="ws-quota" name="quotaMB" type="number" min="1" max="102400" step="1" value="${Math.max(1,Math.round(quota/1048576))}" style="flex:1"/><button type="submit" class="ghost">Set quota</button></div><p class="ws-note">The quota covers memory entries and the files attached to those entries. Project files, Base sources, and existing chat history use separate local storage.</p><p class="ws-note">Global memory is added only to chats where shared memory is on. World and project memory stay within their chosen scope.</p></form><div style="margin-top:22px">${list('memory','Add a fact, a preference, a reference, or a moment worth keeping.')}</div><div class="ws-editor ws-subsection"><h4>Local attachments</h4><p class="ws-note">Delete unused files to free space. Referenced files must be detached from their project or memory first.</p>${workspace.attachments.length?workspace.attachments.map(a=>`<div class="ws-source"><div><b>${text(a.name)}</b><small>${text(a.mimeType)} · ${fmt(a.bytes)}</small></div><button data-ws-attachment-download="${text(a.id)}">Download</button><button data-ws-attachment-delete="${text(a.id)}">Delete file</button></div>`).join(''):'<p class="ws-note">No files stored yet.</p>'}</div></div><form class="ws-editor" data-ws-form="memory"><h3>${e.id?'Edit a memory':'Add something to remember'}</h3><p>Write it directly, attach a reference, and choose where it belongs.</p>${field('Title','title',e.title,'e.g. My writing preferences')}${field('Memory','text',e.text,'What should the assistant remember?','textarea')}${scopeSelect(e)}${field('Tags (comma separated)','tags',(e.tags||[]).join(', '),'preference, reference')}${attachmentList(e.attachmentIDs)}${fileField('Memory attachments')}${actions('memory',e.id,e.id?'Save memory':'Remember this')}</form></div>`;
  }
  function worlds(){
    const w=entity('world');
    return `<div class="ws-split">${list('world','Create a world with its own characters, lore, and evolving story.')}<form class="ws-editor" data-ws-form="world"><h3>${w.id?'World settings':'Create a world'}</h3><p>A consistent setting for stories that can go deeper.</p>${field('World name','name',w.name,'e.g. The last city of Aster')}${field('Premise','description',w.description,'Set the scene.','textarea')}${field('Narrator instructions','instructions',w.instructions,'Perspective, pacing, tone, interaction rules…','textarea')}${field('World lore','lore',w.lore,'Locations, history, cultures, rules, and secrets.','textarea')}${field('Characters','characters',w.characters,'Names, roles, motivations, relationships, and character voice.','textarea')}${field('Current world state','worldState',w.worldState,'Where are we? What has changed? What is unresolved?','textarea')}${check('memoryEnabled','Use personal memory saved specifically for this world',w.memoryEnabled)}<p class="ws-note">World memory is separate from global memory. Shared memory starts off for roleplay chats; you can explicitly enable it in that chat’s context settings.</p>${actions('world',w.id,w.id?'Save world':'Create world')}${w.id?`<div class="ws-subsection ws-tools"><button type="button" class="ghost" data-ws-world-chat="${text(w.id)}">Start a roleplay chat</button><button type="button" class="ghost" data-ws-world-memory="${text(w.id)}">Add world memory</button></div>`:''}</form></div>`;
  }
  function coding(){
    const c=workspace.chatSettings.find(c=>c.chatID===state.active)||{},code=codingDraft?.chatID===state.active?codingDraft.coding:c.coding||{};
    return `<div class="ws-split"><div><div class="ws-editor"><h3>Work through the code</h3><p>A focused workspace for selected source files, diffs, and debugging context.</p><p class="ws-note"><strong>Current chat:</strong> ${text(state.chats.find(c=>c.id===state.active)?.title||'A new coding chat will be created when you save.')}</p><div class="ws-tools" style="margin-top:17px"><button data-ws-code-task="review">Review a diff</button><button data-ws-code-task="debug">Debug an issue</button><button data-ws-code-task="plan">Plan a change</button></div><p class="ws-note">These workflows prepare an explicit request with the context you select. Execution still uses the existing agent and approval controls in Activity.</p><div class="ws-subsection"><h4>Selected source files</h4><div class="ws-code-files">${(code.files||[]).length?code.files.map(f=>`<details><summary>${text(f.path)} · ${text(f.language||'text')}</summary><pre>${text(f.content)}</pre></details>`).join(''):empty('No source files selected','Provide paths in the context editor or upload text source files.')}</div></div></div></div><form class="ws-editor" data-ws-form="coding"><h3>Code-aware context</h3><p>Supply only the repository files and details relevant to this conversation.</p>${field('Local repository path','repoPath',code.repoPath,'/path/to/your/project')}${field('Branch or revision','branch',code.branch,'main')}${field('Task / expected behavior','task',code.task,'Describe the change, error, or question.','textarea')}${field('Selected file paths (one per line)','paths',(code.files||[]).map(f=>f.path).join('\n'),'src/main.go\nREADME.md','textarea')}<div class="ws-tools"><button type="button" class="ghost" data-ws-inspect>Read selected files &amp; Git diff</button></div><p class="ws-note">Reads only explicit file paths from this computer. Inspecting a repository does not edit files, execute project code, or apply patches.</p><label>Upload source files</label><input name="codeFiles" type="file" multiple accept=".txt,.md,.js,.ts,.tsx,.jsx,.py,.go,.cs,.c,.cpp,.h,.hpp,.rs,.java,.kt,.swift,.json,.yaml,.yml,.html,.css,.sh,.sql,.diff,.patch"/>${field('Patch / unified diff','diff',code.diff,'Paste a diff for review.','textarea')}${code.diff?`<div class="ws-diff" aria-label="Diff preview">${diffHTML(code.diff)}</div>`:''}<div class="row actions"><button type="submit" class="primary">Save coding context</button><button type="button" class="ghost" data-ws-preview>Save &amp; preview context</button><button type="button" class="ghost" data-ws-return-chat>Return to chat</button></div><div id="wsContextPreview"></div></form></div>`;
  }
  function diffHTML(diff){return String(diff).split('\n').map(line=>`<div class="${line.startsWith('@@')?'hunk':line.startsWith('+')&&!line.startsWith('+++')?'added':line.startsWith('-')&&!line.startsWith('---')?'removed':''}">${text(line)||' '}</div>`).join('');}
  function render(){
    qa('[data-ws-view]').forEach(b=>b.classList.toggle('on',b.dataset.wsView===view));
    q('#wsContent').innerHTML=({projects,bases,personalities,memory,worlds,coding}[view]||projects)();
    renderSidebar();renderContext();
  }
  function chatSettings(id=state.active){return workspace.chatSettings.find(c=>c.chatID===id)||{chatID:id,baseIDs:[],sharedMemory:false,mode:'chat',coding:{}};}
  function renderContext(){
    const el=q('#wsChatContext');if(!el)return;
    const c=chatSettings(),p=workspace.projects.find(p=>p.id===c.projectID||(p.chatIDs||[]).includes(state.active)),person=workspace.personalities.find(person=>person.id===(c.personalityID||p?.personalityID)),world=workspace.worlds.find(w=>w.id===c.worldID);
    const bases=[...new Set([...(p?.baseIDs||[]),...(c.baseIDs||[])])].filter(id=>workspace.bases.some(b=>b.id===id&&b.status!=='revoked'));
    el.innerHTML=`${p?`<button data-open-project="${text(p.id)}">▱ ${text(p.name)}</button>`:''}${person?`<span class="pill">${text(person.name)}</span>`:''}${world?`<span class="pill">✧ ${text(world.name)}</span>`:''}${bases.length?`<button data-context-bases>${bases.length} base${bases.length===1?'':'s'}</button>`:''}${c.mode==='code'?'<button data-open-coding>⌘ Coding context</button>':''}<label title="When enabled, this chat can use global memory entries saved on this computer."><input id="wsSharedMemory" type="checkbox"${c.sharedMemory?' checked':''}/> Shared memory ${c.sharedMemory?'on':'off'}</label>`;
    q('#chatTitle').textContent=state.chats.find(c=>c.id===state.active)?.title||'A little curiosity goes a long way.';
    const hasMessages=!!q('#chatlog .msg');q('#chatEmpty').hidden=hasMessages;
  }
  async function ensureChat(){
    if(!state.active){const c=await bridge.call('chat.new',{});if(!c.id)throw new Error(c.message||'Could not create a conversation.');state.active=c.id;await refresh();await loadChat();}
    return state.active;
  }
  async function save(kind,value){
    const r=await request('workspace.save',{kind,value});
    const saved=r.value||r.entity;
    if(r.id)selected[kind]=r.id;
    else if(saved?.id)selected[kind]=saved.id;
    else if(!value.id&&names[kind]){const items=collection(kind);selected[kind]=items.find(x=>(x.name||x.title)===(value.name||value.title))?.id;}
    return r;
  }
  function formObject(form){return Object.fromEntries(new FormData(form).entries());}
  function checked(form,name){return [...form.querySelectorAll(`input[name="${name}"]:checked`)].map(x=>x.value);}
  function readBase64(file){return new Promise((resolve,reject)=>{const r=new FileReader();r.onload=()=>resolve(String(r.result).split(',')[1]||'');r.onerror=()=>reject(new Error('Could not read '+file.name));r.readAsDataURL(file);});}
  async function uploadFiles(form){
    const files=[...(form.elements.files?.files||[])],result=[];
    for(const file of files){
      if(file.size>16*1048576)throw new Error(file.name+' is larger than the 16 MB upload limit.');
      const mimeType=file.type||(/\.(txt|md|csv|json|xml|html?|js|jsx|ts|tsx|py|go|cs|cpp|c|h|hpp|rs|java|kt|swift|yaml|yml|css|sh|sql|diff|patch)$/i.test(file.name)?'text/plain':'application/octet-stream');
      const r=await request('workspace.action',{action:'attachment.add',name:file.name,mimeType,dataBase64:await readBase64(file)});
      if(r.attachment)result.push(r.attachment);
    }
    return result;
  }
  function keptAttachments(form,old=[]){const removed=(form.dataset.removedAttachments||'').split(',');return old.filter(id=>!removed.includes(id));}
  async function saveCoding(form){
    const f=formObject(form),source=codingDraft?.chatID===state.active?codingDraft.coding:chatSettings().coding||{},chatID=await ensureChat(),old=chatSettings(chatID),paths=f.paths.split('\n').map(p=>p.trim()).filter(Boolean),files=[...(source.files||[])].filter(file=>paths.includes(file.path));
    for(const file of [...(form.elements.codeFiles?.files||[])]){
      if(file.size>524288)throw new Error('Select a source file smaller than 512 KB: '+file.name);
      const item={path:file.name,language:file.name.split('.').pop(),content:await file.text()};const i=files.findIndex(x=>x.path===item.path);if(i<0)files.push(item);else files[i]=item;
    }
    await save('chatSettings',{...old,chatID,mode:'code',coding:{...source,repoPath:f.repoPath,branch:f.branch,task:f.task,diff:f.diff,files}});
    codingDraft=null;return chatID;
  }
  async function submit(form){
    const kind=form.dataset.wsForm,f=formObject(form);
    if(['project','personality','base','world'].includes(kind)&&!String(f.name||'').trim())throw new Error('Give this '+kind+' a name first.');
    if(kind==='project'){
      const old=entity('project'),atts=await uploadFiles(form);
      await save('project',{...old,name:f.name,description:f.description,instructions:f.instructions,personalityID:f.personalityID,chatIDs:checked(form,'chatIDs'),baseIDs:checked(form,'baseIDs'),memoryEnabled:!!form.elements.memoryEnabled.checked,attachmentIDs:[...keptAttachments(form,old.attachmentIDs),...atts.map(a=>a.id)]});
    }else if(kind==='personality'){await save(kind,{...entity(kind),name:f.name,description:f.description,instructions:f.instructions});
    }else if(kind==='base'){await save(kind,{...entity(kind),name:f.name,description:f.description,permissions:{read:!!form.elements.read.checked,search:!!form.elements.search.checked}});
    }else if(kind==='world'){await save(kind,{...entity(kind),name:f.name,description:f.description,instructions:f.instructions,lore:f.lore,characters:f.characters,worldState:f.worldState,memoryEnabled:!!form.elements.memoryEnabled.checked});
    }else if(kind==='memory'){
      const old=entity(kind),atts=await uploadFiles(form);
      await save(kind,{...old,title:f.title,text:f.text,scope:f.scope,scopeID:f.scope==='global'?'':f.scopeID,tags:f.tags.split(',').map(x=>x.trim()).filter(Boolean),attachmentIDs:[...keptAttachments(form,old.attachmentIDs),...atts.map(a=>a.id)]});
    }else if(kind==='quota'){await save('memorySettings',{quotaBytes:Math.round(Number(f.quotaMB)*1048576)});
    }else if(kind==='source'){
      const b=entity('base'),atts=await uploadFiles(form),tags=f.tags.split(',').map(t=>t.trim()).filter(Boolean);
      if(f.text.trim()||f.url.trim())await request('workspace.action',{action:'source.import',baseID:b.id,source:{name:f.name||'Document reference',kind:f.url.includes('docs.google.com')?'google-doc':f.url?'document':'text',text:f.text,url:f.url,tags}});
      for(const a of atts)await request('workspace.action',{action:'source.import',baseID:b.id,source:{name:a.name,kind:a.mimeType.startsWith('image/')?'image':a.mimeType.startsWith('audio/')?'audio':a.mimeType.startsWith('video/')?'video':a.text?'text':'document',mimeType:a.mimeType,attachmentID:a.id,text:a.text||'',bytes:a.bytes,tags}});
      if(!f.text.trim()&&!f.url.trim()&&!atts.length)throw new Error('Add source text, a document link, or a file first.');
    }else if(kind==='base-search'){
      const r=await request('workspace.action',{action:'base.search',id:entity('base').id,query:f.query});
      q('#wsSearchResults').innerHTML=(r.sources||[]).length?(r.sources||[]).map(source=>`<div class="ws-source"><div><b>${text(source.name||source.kind)}</b><p class="ws-note">${text((source.text||'Metadata only').slice(0,800))}</p></div></div>`).join(''):empty('No matching source material','Try a different keyword, or check this Base’s search permission and connection.');
      notice('Search complete.');return;
    }else if(kind==='remote'){await request('workspace.action',{action:'base.connect',id:entity('base').id,endpoint:f.endpoint,remoteID:f.remoteID,token:f.token});
    }else if(kind==='personality-import'){
      const file=form.elements.personalityFile.files[0];if(file&&file.size>131072)throw new Error('Personality JSON must be smaller than 128 KB.');
      await request('workspace.action',{action:'personality.import',json:file?await file.text():f.json});
    }else if(kind==='coding'){await saveCoding(form);
    }else if(kind==='chat-context'){
      const chatID=await ensureChat(),old=chatSettings(chatID);
      await save('chatSettings',{...old,chatID,projectID:f.projectID,personalityID:f.personalityID,worldID:f.worldID,mode:f.mode,sharedMemory:!!form.elements.sharedMemory.checked,baseIDs:checked(form,'baseIDs')});
      q('.ws-modal')?.remove();
    }
    notice(kind==='remote'?'Base connection updated.':kind==='source'?'Source material added.':kind==='personality-import'?'Personality imported.':'Saved on this computer.');render();
  }
  function contextDialog(){
    const c=chatSettings();q('.ws-modal')?.remove();
    const wrapper=document.createElement('div');wrapper.className='ws-modal';wrapper.innerHTML=`<form class="ws-editor" data-ws-form="chat-context" role="dialog" aria-modal="true" aria-labelledby="ws-context-title"><div class="modal-heading"><h3 id="ws-context-title">Conversation context</h3><button type="button" data-ws-close aria-label="Close">×</button></div><p class="ws-note">Choose what this conversation can draw on. Your existing agent, model, and tool permissions still apply.</p><label for="ws-mode">Conversation mode</label><select id="ws-mode" name="mode">${[['chat','Everyday conversation'],['code','Coding assistant'],['roleplay','Roleplay / story']].map(i=>option(i[0],i[1],c.mode||'chat')).join('')}</select>${select('Project','projectID',workspace.projects,c.projectID)}${select('Personality','personalityID',workspace.personalities,c.personalityID,'Use project default')}${select('Roleplay world','worldID',workspace.worlds,c.worldID)}${checks('Additional XAI Bases','baseIDs',workspace.bases.filter(b=>b.status!=='revoked'),c.baseIDs||[])}${check('sharedMemory','Use shared global memory in this chat',c.sharedMemory)}<p class="ws-note">Project and world memory are scoped to their own settings. Shared memory makes your global entries available to this conversation.</p><div class="row actions"><button type="submit" class="primary">Save context</button><button type="button" class="ghost" data-ws-close>Cancel</button><button type="button" class="ghost" data-open-coding>Code context</button></div></form>`;
    document.body.appendChild(wrapper);wrapper.querySelector('select').focus();
  }
  async function dispatch(button){
    if(button.dataset.wsNew){selected[button.dataset.wsNew]='';notice('');render();return;}
    if(button.dataset.wsSelect){selected[button.dataset.wsSelect]=button.dataset.id;notice('');render();return;}
    if(button.dataset.openProject){await open('projects',button.dataset.openProject);return;}
    if(button.dataset.projectChat){state.active=button.dataset.projectChat;await loadChat();renderChats();q('[data-tab="chat"]').click();return;}
    if(button.hasAttribute('data-ws-return-chat')){q('[data-tab="chat"]').click();return;}
    if(button.hasAttribute('data-ws-close')){q('.ws-modal')?.remove();q('#wsChatSetup').focus();return;}
    if(button.hasAttribute('data-open-coding')){q('.ws-modal')?.remove();await open('coding');return;}
    if(button.hasAttribute('data-context-bases')){await open('bases');return;}
    if(button.dataset.removeAttachment){const form=button.closest('form');form.dataset.removedAttachments=[form.dataset.removedAttachments,button.dataset.removeAttachment].filter(Boolean).join(',');button.closest('.ws-attachment-list>div').remove();return;}
    if(button.dataset.wsDelete){
      const kind=button.dataset.wsDelete;if(!confirm(`Delete this ${kind==='base'?'Base and its local sources':kind}? Existing conversations will be preserved.`))return;
      await request('workspace.delete',{kind,id:button.dataset.id});selected[kind]='';notice('Deleted. Existing conversations are still available.');render();return;
    }
    if(button.dataset.wsSourceDelete){const b=workspace.bases.find(b=>b.id===button.dataset.base);await save('base',{...b,sources:b.sources.filter(s=>s.id!==button.dataset.wsSourceDelete)});notice('Source removed from this Base.');render();return;}
    if(button.dataset.wsBaseAction){
      const action=button.dataset.wsBaseAction;if(action==='revoke'&&!confirm('Forget this connection’s local access token and cached remote sources? To invalidate the token for other clients, revoke it on the host.'))return;
      await request('workspace.action',{action:'base.'+action,id:button.dataset.id});notice(action==='health'?'Health check complete.':action==='revoke'?'Local access token and cached remote sources forgotten. Revoke the token on the host to invalidate other clients.':'Connection disconnected.');render();return;
    }
    if(button.dataset.wsAttachmentDelete){if(!confirm('Permanently delete this local attachment?'))return;await request('workspace.action',{action:'attachment.delete',id:button.dataset.wsAttachmentDelete});notice('Unused attachment deleted.');render();return;}
    if(button.dataset.wsAttachmentDownload){
      const r=await request('workspace.action',{action:'attachment.get',id:button.dataset.wsAttachmentDownload}),binary=atob(r.dataBase64||''),bytes=new Uint8Array(binary.length);for(let i=0;i<binary.length;i++)bytes[i]=binary.charCodeAt(i);
      const url=URL.createObjectURL(new Blob([bytes],{type:r.attachment?.mimeType||'application/octet-stream'})),a=document.createElement('a');a.href=url;a.download=r.attachment?.name||'attachment';a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);return;
    }
    if(button.dataset.wsExport){
      const r=await request('workspace.action',{action:'personality.export',id:button.dataset.wsExport});const url=URL.createObjectURL(new Blob([typeof r.json==='string'?r.json:JSON.stringify(r.json,null,2)],{type:'application/json'}));const a=document.createElement('a');a.href=url;a.download=(entity('personality').name||'vortex-personality').replace(/[^a-zA-Z0-9_-]/g,'-')+'.json';a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);notice('Personality exported.');return;
    }
    if(button.dataset.wsWorldChat){
      const c=await bridge.call('chat.new',{});if(!c.id)throw new Error('Could not create a roleplay chat.');state.active=c.id;await save('chatSettings',{...chatSettings(c.id),chatID:c.id,mode:'roleplay',worldID:button.dataset.wsWorldChat,sharedMemory:false});await refresh();await loadChat();q('[data-tab="chat"]').click();return;
    }
    if(button.dataset.wsWorldMemory){selected.memory='';await open('memory');const f=q('[data-ws-form="memory"]');f.elements.scope.value='world';f.elements.scopeID.value=button.dataset.wsWorldMemory;f.elements.title.focus();return;}
    if(button.hasAttribute('data-ws-inspect')){
      const form=button.closest('form'),f=formObject(form);
      const r=await request('workspace.action',{action:'coding.inspect',repoPath:f.repoPath,task:f.task,paths:f.paths.split('\n').map(p=>p.trim()).filter(Boolean)});
      codingDraft={chatID:state.active,coding:r.coding};notice('Selected source files and Git diff read. Review the context and save it to this chat when ready.');render();return;
    }
    if(button.hasAttribute('data-ws-preview')){
      const form=button.closest('form'),chatID=await saveCoding(form),r=await request('workspace.action',{action:'coding.context',chatID});q('#wsContextPreview').innerHTML=`<div class="ws-subsection"><h4>Context preview</h4><p class="ws-note">${Number(r.characters)||String(r.context||'').length} characters. Text and media metadata are included within context limits.</p><pre class="ws-preview">${text(r.context||'No additional context selected.')}</pre></div>`;return;
    }
    if(button.dataset.wsCodeTask){
      await ensureChat();const old=chatSettings();await save('chatSettings',{...old,chatID:state.active,mode:'code'});
      const prompts={review:'Review the selected files and diff for correctness, security, and regressions. Explain each actionable issue with the relevant file and line. If you find no issues, say so and note any testing gaps.',debug:'Help debug this issue using the selected source files and task details. Identify the likely cause, explain the evidence, and propose a focused fix and a way to verify it. Ask for missing error output if needed.',plan:'Plan the implementation using the selected repository context. Identify the files to change, preserve existing behavior, and explain how to verify the result.'};q('#prompt').value=prompts[button.dataset.wsCodeTask];q('[data-tab="chat"]').click();q('#prompt').focus();renderContext();return;
    }
  }
  document.addEventListener('submit',async e=>{
    const form=e.target.closest('[data-ws-form]');if(!form)return;e.preventDefault();const buttons=[...form.querySelectorAll('button')];buttons.forEach(b=>b.disabled=true);
    try{notice('Saving…');await submit(form);}catch(err){if(err.workspaceUpdated)render();notice(err.message,true);let local=form.querySelector('.ws-form-message');if(!local){local=document.createElement('p');local.className='ws-form-message bad ws-note';local.setAttribute('role','alert');form.appendChild(local);}local.textContent=err.message;}finally{buttons.forEach(b=>b.disabled=false);}
  });
  document.addEventListener('click',async e=>{
    const button=e.target.closest('[data-ws-new],[data-ws-select],[data-open-project],[data-project-chat],[data-ws-return-chat],[data-ws-close],[data-open-coding],[data-context-bases],[data-remove-attachment],[data-ws-delete],[data-ws-source-delete],[data-ws-base-action],[data-ws-attachment-delete],[data-ws-attachment-download],[data-ws-export],[data-ws-world-chat],[data-ws-world-memory],[data-ws-inspect],[data-ws-preview],[data-ws-code-task]');
    if(!button)return;e.preventDefault();button.disabled=true;try{await dispatch(button);}catch(err){if(err.workspaceUpdated)render();notice(err.message,true);}finally{button.disabled=false;}
  });
  document.addEventListener('keydown',e=>{
    if(e.key==='Escape'){q('.ws-modal')?.remove();q('#wsChatSetup').focus();}
    const modal=q('.ws-modal');if(e.key==='Tab'&&modal){const items=[...modal.querySelectorAll('button,input,select,textarea')].filter(el=>!el.disabled),first=items[0],last=items[items.length-1];if(e.shiftKey&&document.activeElement===first){e.preventDefault();last.focus();}else if(!e.shiftKey&&document.activeElement===last){e.preventDefault();first.focus();}}
    if((e.key==='Enter'||e.key===' ')&&e.target.matches('[data-ws-select]')){e.preventDefault();e.target.click();}
  });
  document.addEventListener('change',async e=>{
    if(e.target.name==='mode'&&e.target.value==='roleplay'){const form=e.target.closest('form');if(form?.elements.sharedMemory)form.elements.sharedMemory.checked=false;}
    if(e.target.id!=='wsSharedMemory')return;const control=e.target;control.disabled=true;try{await ensureChat();await save('chatSettings',{...chatSettings(),chatID:state.active,sharedMemory:control.checked});renderContext();}catch(err){control.checked=!control.checked;notice(err.message,true);}finally{control.disabled=false;}});
  qa('[data-ws-view]').forEach(b=>b.onclick=()=>{view=b.dataset.wsView;notice('');render();});
  q('[data-tab="workspace"]').addEventListener('click',async()=>{try{if(!loaded)await load();render();}catch(e){q('#wsContent').innerHTML=empty('Workspace unavailable',e.message);}});
  q('#wsNewProject').onclick=()=>{selected.project='';open('projects');};
  q('#wsChatSetup').onclick=async()=>{try{if(!loaded)await load();contextDialog();}catch(err){notice(err.message,true);await open();}};
  q('#chatSearch').oninput=()=>renderChats();
  qa('[data-starter]').forEach(b=>b.onclick=()=>{q('#prompt').value=b.dataset.starter;q('#prompt').focus();});
  q('#prompt').addEventListener('keydown',e=>{if(e.key==='Enter'&&!e.shiftKey&&!e.isComposing){e.preventDefault();if(!q('#send').disabled)q('#send').click();}});
  q('#prompt').addEventListener('input',()=>{const el=q('#prompt');el.style.height='auto';el.style.height=Math.min(el.scrollHeight,220)+'px';});
  window.VortexWorkspace={sync:renderContext,refreshSidebar:renderSidebar,open,load};
  load().then(render).catch(()=>{});
})();
