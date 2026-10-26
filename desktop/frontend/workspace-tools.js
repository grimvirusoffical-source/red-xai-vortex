/* Managed hosting, reviewed updates, local ingestion, and approved patch flows. */
(() => {
  'use strict';
  const core=window.VortexWorkspace;
  if(!core)return;
  const q=s=>document.querySelector(s);
  const e=value=>esc(value);
  const hostStates=new Map(), extractionStates=new Map();
  let ingestion=null, patchDraft={chatID:null,patch:'',review:null}, fieldID=0;
  const current=()=>core.get();
  const rpc=(action,args={})=>core.request('workspace.action',{action,...args});
  const date=value=>value?new Date(value).toLocaleString():'Not checked';
  const textField=(label,name,value='',placeholder='',area=false)=>{const id='wst-'+name+'-'+fieldID++;return `<label for="${id}">${e(label)}</label>${area?`<textarea id="${id}" name="${name}" placeholder="${e(placeholder)}">${e(value)}</textarea>`:`<input id="${id}" name="${name}" value="${e(value)}" placeholder="${e(placeholder)}"/>`}`;};
  const check=(name,label,on=false)=>`<label class="ws-checkbox"><input type="checkbox" name="${name}"${on?' checked':''}/> ${e(label)}</label>`;
  const badge=(label,ok)=>`<span class="pill ${ok?'ok':''}">${e(label)} · ${ok?'ready':'unavailable'}</span>`;
  const pending=(workspace,kind)=> (workspace.proposals||[]).filter(p=>!kind||p.kind===kind);
  const summary=result=>result?`${result.status||'unknown'} · ${result.method||'not extracted'} · ${date(result.checkedAt)}`:'Not extracted';
  const settingsSelect=(label,name,value)=>{const id='wst-'+name+'-'+fieldID++;return `<label for="${id}">${e(label)}</label><select id="${id}" name="${name}">${[['off','Off'],['review','Suggest changes for my review'],['save','Save automatically after each turn']].map(([v,label])=>`<option value="${v}"${(value||'off')===v?' selected':''}>${label}</option>`).join('')}</select>`;};
  function proposalsHTML(workspace,kind){
    const proposals=pending(workspace,kind);
    return `<section class="ws-editor wst-section"><div class="ws-section-head"><h3>Suggested updates <span class="ws-count">${proposals.length}</span></h3><button type="button" class="ghost" data-wst-action="reload">Refresh</button></div><p class="ws-note">Review mode keeps extracted memories and story changes here until you accept them. Edit a suggestion before saving it to its displayed scope.</p>${proposals.length?proposals.map(p=>`<form data-wst-form="proposal" data-id="${e(p.id)}" class="wst-proposal"><div class="row"><span class="pill">${p.kind==='worldState'?'World state':'Memory'}</span><span class="pill">${e(p.scope||'global')}${p.scopeID?' · '+e(workspace.worlds.find(w=>w.id===p.scopeID)?.name||workspace.projects.find(w=>w.id===p.scopeID)?.name||p.scopeID):''}</span></div>${textField('Suggested title','title',p.title)}${textField('Suggested update','text',p.text,'',true)}<div class="row actions"><button type="submit" class="primary">${p.kind==='worldState'?'Save world state':'Save memory'}</button><button type="button" class="ghost" data-wst-action="proposal.reject" data-id="${e(p.id)}">Dismiss</button><small class="muted">${e(date(p.createdAt))}</small></div></form>`).join(''):'<div class="workspace-empty">No updates are waiting for review. Turn on suggested memory or world updates in a conversation’s Context &amp; memory settings.</div>'}</section>`;
  }
  function hostingHTML(base){
    const status=hostStates.get(base.id),running=!!status?.running,config=base.hosting||{};
    return `<section class="ws-editor wst-section"><div class="ws-section-head"><h3>Host this XAI Base</h3><span class="pill ${running?'ok':''}">${status?running?'Hosting active':'Stopped':'Status not checked'}</span></div><p class="ws-note">Share this computer’s Base through the bundled Base host. Access requires an expiring invite token; you can revoke each grant here. Hosting runs while Vortex is open and resumes with Vortex until you stop it.</p><div class="row wst-tools"><button class="ghost" data-wst-action="host.status" data-id="${e(base.id)}">Check hosting</button><button class="ghost" data-wst-action="host.sync" data-id="${e(base.id)}">Publish latest sources</button>${running?`<button class="danger" data-wst-action="host.stop" data-id="${e(base.id)}">Stop hosting</button>`:''}</div>${status?.error?`<p class="ws-note bad">${e(status.error)}</p>`:''}${status?.available===false?'<p class="ws-note bad">The Base host helper is not installed beside this Vortex build.</p>':''}<details class="ws-subsection"${!running?' open':''}><summary>Hosting connection settings</summary>${status?`<p class="ws-note">${Number(status.sourceCount)||0} published sources · ${e(status.revision||'No revision')}<br/>Local endpoint: ${e(status.endpoint||'Not running')}${status.publicEndpoint?'<br/>Shared endpoint: '+e(status.publicEndpoint):''}</p>`:''}<form data-wst-form="host-start" data-id="${e(base.id)}">${textField('Listen address','listen',config.listen||'127.0.0.1:0','127.0.0.1:0')}${textField('Public HTTPS endpoint (optional)','publicEndpoint',status?.publicEndpoint||config.publicEndpoint||'','https://knowledge.example.com')}<details><summary>Direct TLS hosting</summary><p class="ws-note">For a private network or a trusted HTTPS reverse proxy, use the appropriate listen address. A direct non-loopback listener requires TLS certificate and key files.</p>${textField('TLS certificate path','tlsCert',config.tlsCert||'','/absolute/path/fullchain.pem')}${textField('TLS private key path','tlsKey',config.tlsKey||'','/absolute/path/private-key.pem')}</details><div class="actions"><button type="submit" class="primary"${running?' disabled':''}>${running?'Hosting active':'Start hosting'}</button>${running?'<p class="ws-note">Stop hosting before changing its connection settings.</p>':''}</div></form></details>${running?`<div class="ws-subsection"><h4>Access grants</h4>${(status.grants||[]).length?(status.grants||[]).map(g=>`<div class="ws-source"><div><b>${e(g.name||g.id)}</b><small>${e((g.scopes||[]).join(', '))} · expires ${e(date(g.expiresAt))}</small></div><button class="danger" data-wst-action="host.revoke" data-id="${e(base.id)}" data-grant-id="${e(g.id)}">Revoke</button></div>`).join(''):'<p class="ws-note">No access grants created yet.</p>'}<form data-wst-form="host-grant" data-id="${e(base.id)}">${textField('Invite label','name','','e.g. My other computer')}<label for="wst-days">Expires in days</label><input id="wst-days" type="number" name="days" min="1" max="365" value="30"/>${check('read','Read source text',true)}${check('search','Search source text',true)}<p class="ws-note">The token appears once in a private dialog after you create it. Share it only with someone you authorize.</p><div class="actions"><button class="primary" type="submit">Create access invite</button></div></form></div>`:''}</section>`;
  }
  function ingestionHTML(workspace,base){
    const tools=ingestion?.tools||{},documents=(ingestion?.documents||[]).filter(d=>!base||d.baseID===base.id);
    const attachments=base?workspace.attachments.filter(a=>(base.sources||[]).some(s=>s.attachmentID===a.id)):workspace.attachments;
    return `<section class="ws-editor wst-section"><div class="ws-section-head"><h3>Document &amp; media imports</h3><button class="ghost" data-wst-action="ingestion.status">Check local tools</button></div><p class="ws-note">Import document text over an authorized connection. PDFs, images, audio, and video can be processed with locally installed tools; extraction stays on this computer.</p><div class="row wst-tools">${badge('PDF text',!!tools.pdf)}${badge('Image OCR',!!tools.ocr)}${badge('Audio/video',!!tools.ffmpeg)}${badge('Transcription',!!tools.whisper&&!!tools.whisperModel)}</div>${!ingestion?'<p class="ws-note">Check tools to show availability. Missing capabilities preserve the original upload and display an extraction error instead of inventing content.</p>':''}<details class="ws-subsection"><summary>Transcription setup</summary><form data-wst-form="ingestion-configure">${textField('Local Whisper model path','whisperModel',tools.whisperModel,'/absolute/path/model.bin')}<p class="ws-note">Vortex detects pdftotext, tesseract, ffmpeg, and whisper-cli on the local PATH. Select a model you already have; this form does not install executables or download models.</p><div class="actions"><button type="submit" class="ghost">Save transcription settings</button></div></form></details>${base&&!base.endpoint?`<form data-wst-form="source-fetch" data-base-id="${e(base.id)}" class="ws-subsection"><h4>Import a connected document</h4>${textField('Document title','name','','e.g. Research notes')}${textField('Document URL','url','','https://docs.google.com/document/d/…')}<label for="wst-document-token">Access token for a private document (optional)</label><input id="wst-document-token" type="password" name="accessToken" autocomplete="off" placeholder="Authorized access token; never added to model context"/>${check('refreshOnUse','Refresh this document when this Base is used')}<p class="ws-note">Public Google Docs can use their text export. Private documents need your authorized access token. Automatic refresh is opt-in, only while this Base is selected, and at most once every five minutes.</p><div class="actions"><button type="submit" class="primary">Import document</button></div></form>`:''}${documents.length?`<div class="ws-subsection"><h4>Connected document status</h4>${documents.map(d=>{const b=workspace.bases.find(b=>b.id===d.baseID),source=b?.sources.find(s=>s.id===d.sourceID);return `<div class="wst-import-result"><div class="ws-source"><div><b>${e(source?.name||'Connected document')}</b><small>${e(summary(d.result))} · ${d.refreshOnUse?'Refresh on use':'Manual refresh'}</small>${d.lastError?`<p class="ws-note bad">${e(d.lastError)}</p>`:''}</div><button class="ghost" data-wst-action="source.refresh" data-base-id="${e(d.baseID)}" data-source-id="${e(d.sourceID)}">Refresh</button><button class="ghost" data-wst-action="source.disconnect" data-base-id="${e(d.baseID)}" data-source-id="${e(d.sourceID)}">Stop sync / forget access</button></div>${d.result?.text?`<details><summary>Imported text excerpt</summary><pre class="ws-preview">${e(d.result.text.slice(0,4000))}</pre></details>`:''}</div>`;}).join('')}</div>`:''}${attachments.length?`<div class="ws-subsection"><h4>Attachment extraction</h4>${attachments.map(a=>{const result=ingestion?.extractions?.[a.id],local=extractionStates.get(a.id);return `<div class="wst-import-result"><div class="ws-source"><div><b>${e(a.name)}</b><small>${e(a.mimeType)} · ${e(local?.error?'unavailable · '+local.error:summary(result))}</small></div><button class="ghost" data-wst-action="attachment.extract" data-id="${e(a.id)}">${result?'Extract again':'Extract text'}</button></div>${a.text?`<details><summary>Extracted text excerpt</summary><pre class="ws-preview">${e(a.text.slice(0,4000))}</pre></details>`:''}</div>`;}).join('')}</div>`:''}</section>`;
  }
  function patchHTML(chatID){
    const draft=patchDraft.chatID===chatID?patchDraft:{patch:'',review:null},review=draft.review;
    return `<section class="ws-editor wst-section"><h3>Review &amp; apply a code patch</h3><p class="ws-note">Save an absolute repository path in Coding context above, then paste a unified text patch. Review performs a read-only applicability check. Applying creates a pending action in Activity for your Allow/Deny decision.</p><form data-wst-form="patch-review">${textField('Proposed patch','patch',draft.patch,'--- a/file.txt\n+++ b/file.txt\n@@ -1 +1 @@\n-old\n+new',true)}<div class="row actions"><button class="primary" type="submit">Review patch</button><button class="ghost" type="button" data-wst-action="patch.apply"${review?.checkPassed?'':' disabled'}>Request approval to apply</button></div></form>${review?`<div class="wst-patch-review"><div class="row"><span class="pill ${review.checkPassed?'ok':'bad'}">${review.checkPassed?'Applies cleanly':'Needs attention'}</span><span class="pill">${(review.files||[]).length} files</span><span class="ok">+${Number(review.additions)||0}</span><span class="bad">−${Number(review.deletions)||0}</span></div>${review.checkError?`<p class="ws-note bad">${e(review.checkError)}</p>`:''}<ul>${(review.files||[]).map(file=>`<li>${e(file)}</li>`).join('')}</ul><div class="ws-diff" aria-label="Proposed patch preview">${String(draft.patch).split('\n').map(line=>`<div class="${line.startsWith('@@')?'hunk':line.startsWith('+')&&!line.startsWith('+++')?'added':line.startsWith('-')&&!line.startsWith('---')?'removed':''}">${e(line)||' '}</div>`).join('')}</div></div>`:''}<div id="wstPatchStatus" role="status"></div></section>`;
  }
  function decorate(){
    const {workspace,view,selected,chatID}=current();let html='';
    if(view==='bases'){
      const base=workspace.bases.find(b=>b.id===selected.base);
      if(base){if(!base.endpoint)html+=hostingHTML(base);html+=ingestionHTML(workspace,base);}
    }
    if(view==='memory')html+=proposalsHTML(workspace,'memory')+ingestionHTML(workspace);
    if(view==='worlds')html+=proposalsHTML(workspace,'worldState');
    if(view==='coding')html+=patchHTML(chatID);
    if(html)q('#wsContent').insertAdjacentHTML('beforeend',`<div class="wst-extensions">${html}</div>`);
    decorateChat();
  }
  function decorateContext(form,settings){
    const html=`<div class="ws-subsection"><h4>Remember and evolve</h4>${settingsSelect('Capture useful memories from this chat','memoryCapture',settings.memoryCapture)}${settingsSelect('Update the selected world’s story state','stateEvolution',settings.stateEvolution)}<p class="ws-note">Both start off. Review mode creates editable suggestions. Automatic mode saves after each completed turn within your quota. Memories use this chat’s world or project scope; global capture requires shared memory on. World state updates require a selected world.</p></div>`;
    form.querySelector('.actions').insertAdjacentHTML('beforebegin',html);
  }
  function decorateChat(){
    const {workspace,chatSettings}=current(),strip=q('#wsChatContext');if(!strip)return;
    const proposals=pending(workspace).filter(p=>p.chatID===current().chatID);
    if(proposals.length&&!strip.querySelector?.('[data-wst-action="proposals"]'))strip.insertAdjacentHTML('beforeend',`<button data-wst-action="proposals">Review ${proposals.length} suggestion${proposals.length===1?'':'s'}</button>`);
    if(chatSettings.memoryCapture&&chatSettings.memoryCapture!=='off'&&!strip.querySelector?.('.wst-capture'))strip.insertAdjacentHTML('beforeend',`<span class="pill wst-capture">Memory: ${e(chatSettings.memoryCapture)}</span>`);
  }
  function afterTurn(response){
    const el=q('#wsTurnNotice');if(!el)return;
    el.textContent=response?.warning||'';el.className=response?.warning?'bad':'';decorateChat();
    const count=pending(current().workspace).filter(p=>p.chatID===current().chatID).length;
    if(count&&!response?.warning)el.textContent=`${count} suggested memory or story update${count===1?' is':'s are'} ready for your review.`;
  }
  function showInvite(invite){
    q('.ws-modal')?.remove();const wrapper=document.createElement('div');wrapper.className='ws-modal wst-invite';
    wrapper.innerHTML='<div class="ws-editor" role="dialog" aria-modal="true" aria-labelledby="wst-invite-title"><div class="modal-heading"><h3 id="wst-invite-title">Your Base access invite</h3><button type="button" data-ws-close aria-label="Close">×</button></div><p class="ws-note">The token is shown only in this dialog and is not retained in the workspace. Copy it for the authorized receiving computer, then close this dialog. You can revoke the grant in Hosting.</p><label>Endpoint</label><div class="ws-preview wst-invite-endpoint"></div><label>Remote Base ID</label><div class="ws-preview wst-invite-id"></div><label for="wst-invite-token">Access token</label><input id="wst-invite-token" type="password" readonly autocomplete="off"/><div class="row actions"><button type="button" class="ghost wst-reveal">Reveal token</button><button type="button" class="primary wst-copy">Copy connection details</button><button type="button" class="ghost" data-ws-close>Close</button></div><p class="ws-note wst-invite-expiry"></p><p class="ws-note wst-invite-status" role="status"></p></div>';
    wrapper.querySelector('.wst-invite-endpoint').textContent=invite.endpoint||'';wrapper.querySelector('.wst-invite-id').textContent=invite.remoteID||'';const token=wrapper.querySelector('#wst-invite-token');token.value=invite.token||'';wrapper.querySelector('.wst-invite-expiry').textContent='Expires '+date(invite.expiresAt);
    wrapper.querySelector('.wst-reveal').onclick=event=>{const reveal=token.type==='password';token.type=reveal?'text':'password';event.target.textContent=reveal?'Hide token':'Reveal token';};
    wrapper.querySelector('.wst-copy').onclick=async()=>{try{await navigator.clipboard.writeText(JSON.stringify({endpoint:invite.endpoint,remoteID:invite.remoteID,token:invite.token},null,2));wrapper.querySelector('.wst-invite-status').textContent='Connection details copied. Share them only with the authorized recipient.';}catch{wrapper.querySelector('.wst-invite-status').textContent='Clipboard unavailable. Reveal the token and copy the fields manually.';}};
    document.body.appendChild(wrapper);wrapper.querySelector('.wst-reveal').focus();
  }
  async function refreshIngestion(){ingestion=await rpc('ingestion.status');return ingestion;}
  async function refreshWorkspace(){await core.load();core.render();}
  async function extractUploaded(attachment){
    try{
      if(!ingestion)await refreshIngestion();const tools=ingestion.tools||{},type=attachment.mimeType||'',name=attachment.name||'';
      const textLike=type.startsWith('text/')||/\.(docx|json|csv|html?|md|txt)$/i.test(name);
      const supported=textLike||(type==='application/pdf'&&tools.pdf)||(type.startsWith('image/')&&tools.ocr)||(type.startsWith('audio/')&&tools.ffmpeg&&tools.whisper&&tools.whisperModel)||(type.startsWith('video/')&&tools.ffmpeg&&(tools.ocr||(tools.whisper&&tools.whisperModel)));
      if(!supported){extractionStates.set(attachment.id,{error:'Required local extraction tools are unavailable; original file preserved.'});return;}
      core.notice('Extracting '+attachment.name+' with local tools…');const response=await rpc('attachment.extract',{id:attachment.id});
      ingestion.extractions={...ingestion.extractions,[attachment.id]:response.ingestion};extractionStates.delete(attachment.id);
    }catch(error){extractionStates.set(attachment.id,{error:error.message});core.notice('Uploaded '+attachment.name+'. Extraction unavailable: '+error.message,true);}
  }
  async function submit(form){
    const type=form.dataset.wstForm,f=Object.fromEntries(new FormData(form).entries());
    if(type==='proposal'){await rpc('proposal.accept',{id:form.dataset.id,title:f.title,text:f.text});core.notice('Reviewed update saved to its selected scope.');await refreshWorkspace();return;}
    if(type==='host-start'){const response=await rpc('host.start',{id:form.dataset.id,listen:f.listen||'127.0.0.1:0',publicEndpoint:f.publicEndpoint,tlsCert:f.tlsCert,tlsKey:f.tlsKey});hostStates.set(form.dataset.id,response.hosting);core.notice('Base hosting settings applied.');core.render();return;}
    if(type==='host-grant'){
      const scopes=['read','search'].filter(scope=>form.elements[scope].checked);if(!scopes.length)throw new Error('Select at least one permission.');
      const response=await rpc('host.grant',{id:form.dataset.id,name:f.name,days:Number(f.days),scopes});hostStates.set(form.dataset.id,response.hosting);core.notice('Access invite created. Its token is available only in the private dialog.');core.render();showInvite(response.invite);return;
    }
    if(type==='source-fetch'){await rpc('source.fetch',{baseID:form.dataset.baseId,url:f.url,name:f.name,accessToken:f.accessToken,refreshOnUse:!!form.elements.refreshOnUse.checked});form.elements.accessToken.value='';await refreshIngestion();await refreshWorkspace();core.notice('Document text imported. Private access credentials, when supplied, stay separate from the workspace.');return;}
    if(type==='ingestion-configure'){ingestion=await rpc('ingestion.configure',{whisperModel:f.whisperModel});core.notice('Local transcription settings saved.');core.render();return;}
    if(type==='patch-review'){
      const {chatID}=current();if(!chatID)throw new Error('Save Coding context for a chat before reviewing a patch.');
      const response=await rpc('coding.patch.review',{chatID,patch:f.patch});patchDraft={chatID,patch:f.patch,review:response.review};core.notice(response.review.checkPassed?'Patch reviewed. Request approval when ready.':'Patch review found an applicability problem.',!response.review.checkPassed);core.render();return;
    }
  }
  async function action(button){
    const type=button.dataset.wstAction,id=button.dataset.id;
    if(type==='reload'){await refreshWorkspace();return;}
    if(type==='proposals'){const proposals=pending(current().workspace).filter(p=>p.chatID===current().chatID);await core.open(proposals.some(p=>p.kind==='memory')?'memory':'worlds');return;}
    if(type.startsWith('host.')){
      if(type==='host.revoke'&&!confirm('Revoke this access grant on the host? Existing clients using its token will lose access.'))return;
      const response=await rpc(type,{id,grantID:button.dataset.grantId});hostStates.set(id,response.hosting);core.notice(type==='host.revoke'?'Access grant revoked on the host.':type==='host.stop'?'Hosting stopped.':type==='host.sync'?'Latest local sources published.':'Hosting status refreshed.');core.render();return;
    }
    if(type==='proposal.reject'){await rpc(type,{id});core.notice('Suggestion dismissed.');await refreshWorkspace();return;}
    if(type==='ingestion.status'){await refreshIngestion();core.notice('Local extraction tools checked.');core.render();return;}
    if(type==='source.refresh'||type==='source.disconnect'){
      await rpc(type,{baseID:button.dataset.baseId,sourceID:button.dataset.sourceId});await refreshIngestion();await refreshWorkspace();core.notice(type==='source.refresh'?'Connected document refreshed.':'Document sync stopped and its local access credential forgotten. The last imported snapshot remains available.');return;
    }
    if(type==='attachment.extract'){
      try{const response=await rpc(type,{id});if(!ingestion)await refreshIngestion();ingestion.extractions={...ingestion.extractions,[id]:response.ingestion};extractionStates.delete(id);await refreshWorkspace();core.notice('Local text extraction complete.');}
      catch(error){extractionStates.set(id,{error:error.message});core.render();throw error;}return;
    }
    if(type==='patch.apply'){
      const {chatID}=current(),form=q('[data-wst-form="patch-review"]'),patch=form.elements.patch.value;
      if(patchDraft.chatID!==chatID||patchDraft.patch!==patch||!patchDraft.review?.checkPassed)throw new Error('Review the current patch successfully before requesting approval.');
      const response=await rpc('coding.patch.apply',{chatID,patch});q('#wstPatchStatus').innerHTML=`<p class="ws-note">${e(response.message||'Patch is waiting for your approval.')} Run ${e(response.runID)}.</p><button type="button" class="primary" data-wst-action="open-activity">Open Activity to Allow / Deny</button>`;core.notice('Patch queued for your approval in Activity. Repository changes require Allow.');return;
    }
    if(type==='open-activity'){q('[data-tab="activity"]').click();return;}
  }
  function report(error,container){
    core.notice(error.message,true);if(container){let el=container.querySelector('.wst-error');if(!el){el=document.createElement('p');el.className='ws-note bad wst-error';el.setAttribute('role','alert');container.appendChild(el);}el.textContent=error.message;}
  }
  document.addEventListener('submit',async event=>{
    const form=event.target.closest('[data-wst-form]');if(!form)return;event.preventDefault();const buttons=[...form.querySelectorAll('button')].map(button=>[button,button.disabled]);buttons.forEach(([button])=>button.disabled=true);
    try{core.notice(form.dataset.wstForm==='patch-review'?'Reviewing patch…':'Working…');await submit(form);}catch(error){report(error,form);}finally{buttons.forEach(([button,disabled])=>button.disabled=disabled);}
  });
  document.addEventListener('click',async event=>{
    const button=event.target.closest('[data-wst-action]');if(!button)return;event.preventDefault();button.disabled=true;
    try{await action(button);}catch(error){report(error,button.closest('.ws-editor'));}finally{button.disabled=false;}
  });
  document.addEventListener('input',event=>{if(event.target.name!=='patch')return;const form=event.target.closest('[data-wst-form="patch-review"]');if(!form)return;const button=form.querySelector('[data-wst-action="patch.apply"]');if(button)button.disabled=patchDraft.patch!==event.target.value||!patchDraft.review?.checkPassed;});
  window.VortexWorkspaceTools={decorate,decorateContext,decorateChat,afterTurn,extractUploaded,refreshIngestion};
})();
