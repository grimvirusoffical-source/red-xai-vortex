const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const html = fs.readFileSync(path.join(__dirname, 'index.html'), 'utf8');
const app = fs.readFileSync(path.join(__dirname, 'app.js'), 'utf8');
const workspaceSource = fs.readFileSync(path.join(__dirname, 'workspace.js'), 'utf8');
const toolsSource = fs.readFileSync(path.join(__dirname, 'workspace-tools.js'), 'utf8');

test('existing desktop controls and feature panels remain available exactly once', () => {
  const legacyIDs = `gate gTerms gTermsText gDecline gAccept gLogin gCreds gUser gPass gCode gOtp gCallMe gGo gMsg gWait logo actTabBtn nTabBtn status chatside newchat newparty partyPick partyOpts partyTitle partyGo partyCancel partyMsg chatlist agentChats partyList tab-chat agentPick modelPick conn chatlog prompt send composer cQuick cTier cTierName cTierSpeed cLen cDefault cScope tab-activity rAgent rTask rGo rList actStats aFilter aKind aQ aExpJ aExpC aExpMsg actLog tab-agents agentList aName aProv aModel aBase aKey aSave aTest aMsg tab-integrations intLog tab-media mType mPrompt mGo mStyle mQuality mSize mFormat mDur mSpeed mFrames mMsg mJobs tab-plugins maker makePlugin makeMsg iconBox iconPrev iconUp aiIcon iconSkip iconFile iconMsg pluginOut uploadPlugin upMsg myWho refreshMine myMsg myList refreshStore storeMsg storeList rxModal rxCreds rxUser rxPass rxCode rxOtp rxCancel rxGo rxMsg tab-notifications nCount nRefresh nAll nList tab-settings baseURL apiKey secureChat phoneChat linkInfo phoneQRBox phoneQR autoUpdate saveSettings probe setMsg apBar fTerms fSignOut fUser`.split(' ');
  const ids = [...html.matchAll(/\sid="([^"]+)"/g)].map(m => m[1]);
  assert.equal(ids.length, new Set(ids).size, 'duplicate static IDs');
  for (const id of legacyIDs) assert.equal(ids.filter(x => x === id).length, 1, id);
  for (const tab of ['chat','agents','activity','integrations','media','plugins','notifications','settings','workspace']) {
    assert.ok(html.includes(`data-tab="${tab}"`), `${tab} navigation`);
    assert.ok(ids.includes(`tab-${tab}`), `${tab} panel`);
  }
  new vm.Script(app, {filename:'app.js'});
  new vm.Script(workspaceSource, {filename:'workspace.js'});
  new vm.Script(toolsSource, {filename:'workspace-tools.js'});
});

// This DOM adapter executes the real view module without a browser dependency.
// Browser layout/interaction verification is separate; here we exercise rendering,
// API responses, and escaping of saved/imported content across every workspace view.
function harness(fixture) {
  const nodes = new Map(), listeners = {}, created=[];
  function node(selector) {
    if (!nodes.has(selector)) {
      const eventListeners = {};
      nodes.set(selector, {
        innerHTML:'', textContent:'', value:'', dataset:{}, style:{}, hidden:false,disabled:false,
        classList:{toggle() {}},
        addEventListener(name, handler) { (eventListeners[name] ||= []).push(handler); },
        click() { this.onclick?.({target:this}); for (const handler of eventListeners.click||[]) handler({target:this}); },
        focus() {}, remove() {}, querySelectorAll() { return []; },querySelector(){return null;},
        insertAdjacentHTML(position,value){this.innerHTML=position==='afterbegin'?value+this.innerHTML:this.innerHTML+value;},
        setAttribute(name,value){this[name]=value;},appendChild(){},
      });
    }
    return nodes.get(selector);
  }
  const nav = ['projects','bases','personalities','memory','worlds','coding'].map(view=>({dataset:{wsView:view},classList:{toggle(){}}}));
  const document = {
    querySelector(selector) { return selector === '#chatlog .msg' || selector === '.ws-modal' ? null : node(selector); },
    querySelectorAll(selector) { return selector === '[data-ws-view]' ? nav : []; },
    addEventListener(name, handler) { (listeners[name] ||= []).push(handler); },
    createElement(tag){const prefix='created-'+created.length,element=node(prefix);element.tag=tag;element.querySelector=selector=>node(prefix+' '+selector);created.push(element);return element;},
    body:{appendChild(){}},
  };
  const calls = [];
  const bridge = {async call(method, args) { calls.push({method,args}); return {ok:true,workspace:fixture,usageBytes:128}; }};
  const context = vm.createContext({
    window:{}, document, bridge,
    state:{active:'chat-1',chats:[{id:'chat-1',title:'Example conversation'}]},
    esc:value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])),
    refresh(){},loadChat(){},renderChats(){},console,setTimeout,clearTimeout,
    FormData:class {constructor(form){this.values=form.values||{};}entries(){return Object.entries(this.values);}},
    confirm:()=>true,
  });
  vm.runInContext(workspaceSource, context, {filename:'workspace.js'});
  vm.runInContext(toolsSource, context, {filename:'workspace-tools.js'});
  return {api:context.window.VortexWorkspace,tools:context.window.VortexWorkspaceTools,nodes,nav,listeners,calls,bridge,created};
}

function fixture() {
  const unsafe = '<img src=x onerror="globalThis.compromised=true"> & "quoted"';
  return {
    version:1,
    projects:[{id:'project-1',name:unsafe,description:unsafe,instructions:unsafe,chatIDs:['chat-1'],attachmentIDs:['attachment-1'],baseIDs:['base-1'],personalityID:'personality-1',memoryEnabled:true}],
    personalities:[{id:'personality-1',name:unsafe,description:unsafe,instructions:unsafe}],
    bases:[{id:'base-1',name:unsafe,description:unsafe,status:'local',permissions:{read:true,search:true},sources:[{id:'source-1',name:unsafe,kind:'text',text:unsafe,tags:[unsafe],bytes:20}]},{id:'base-remote',name:'Remote',endpoint:'https://private-host.example',remoteID:'remote-1',status:'online',permissions:{read:true,search:true},sources:[]}],
    memory:{quotaBytes:67108864,entries:[{id:'memory-1',title:unsafe,text:unsafe,scope:'global',attachmentIDs:['attachment-1'],tags:[unsafe]}]},
    worlds:[{id:'world-1',name:unsafe,description:unsafe,instructions:unsafe,lore:unsafe,characters:unsafe,worldState:unsafe,memoryEnabled:true}],
    attachments:[{id:'attachment-1',name:unsafe,mimeType:'text/plain',bytes:128}],
    chatSettings:[{chatID:'chat-1',mode:'code',projectID:'project-1',personalityID:'',baseIDs:['base-1'],sharedMemory:false,memoryCapture:'review',stateEvolution:'off',coding:{repoPath:'/example/repo',branch:'main',task:unsafe,diff:'@@ -1 +1 @@\n-'+unsafe+'\n+'+unsafe,files:[{path:unsafe,language:unsafe,content:unsafe}]}}],
    proposals:[{id:'proposal-1',chatID:'chat-1',kind:'memory',scope:'project',scopeID:'project-1',title:unsafe,text:unsafe,createdAt:'2026-10-26T12:00:00Z'},{id:'proposal-2',chatID:'chat-1',kind:'worldState',scope:'world',scopeID:'world-1',title:unsafe,text:unsafe,createdAt:'2026-10-26T12:00:00Z'}],
  };
}

test('all workspace views escape imported text and retain unique form IDs', async () => {
  const h = harness(fixture());
  await h.api.load();
  for (const [view, id] of [['projects','project-1'],['bases','base-1'],['bases','base-remote'],['personalities','personality-1'],['memory','memory-1'],['worlds','world-1'],['coding',undefined]]) {
    await h.api.open(view,id);
    const result = h.nodes.get('#wsContent').innerHTML;
    assert.ok(result.includes('ws-editor'), view);
    assert.ok(!result.includes('<img src=x'), `${view} raw source HTML`);
    assert.ok(!result.includes('value="<'), `${view} attribute escaping`);
    const ids = [...result.matchAll(/\sid="([^"]+)"/g)].map(m=>m[1]);
    assert.equal(ids.length,new Set(ids).size,`${view} duplicate form IDs`);
  }
  const strip=h.nodes.get('#wsChatContext').innerHTML;
  assert.ok(strip.includes('&lt;img'), 'project personality names are escaped in context strip');
  assert.ok(!strip.includes('private-host.example'), 'host address is excluded from context strip');
});

test('managed hosting and ingestion render returned metadata safely', async()=>{
  const data=fixture(),h=harness(data);await h.api.load();await h.api.open('bases','base-1');
  const unsafe='<img src=x onerror="unsafe()">';
  h.bridge.call=async(method,args)=>args.action==='host.status'?{ok:true,hosting:{running:true,available:true,endpoint:'http://127.0.0.1:17000',sourceCount:1,grants:[{id:'grant-1',name:unsafe,scopes:['read','search'],expiresAt:'2026-10-27T12:00:00Z'}]}}:{ok:true,tools:{pdf:'/tools/pdf',ocr:'',ffmpeg:'',whisper:'',whisperModel:unsafe},documents:[{baseID:'base-1',sourceID:'source-1',refreshOnUse:true,result:{status:'ready',method:'document-text',text:unsafe,checkedAt:'2026-10-26T12:00:00Z'}}],extractions:{}};
  for(const action of ['host.status','ingestion.status'])await h.listeners.click[1]({target:{closest:()=>({dataset:{wstAction:action,id:'base-1'},closest:()=>null})},preventDefault(){}});
  const result=h.nodes.get('#wsContent').innerHTML;
  assert.ok(result.includes('Hosting active'));
  assert.ok(result.includes('Create access invite'));
  assert.ok(result.includes('Imported text excerpt'));
  assert.ok(!result.includes(unsafe),'host grant names and extracted text must be escaped');
  assert.ok(result.includes('&lt;img'),'unsafe metadata is shown as text');
});

test('one-time host invite token stays out of workspace state and ordinary rendered cards',async()=>{
  const data=fixture(),h=harness(data);await h.api.load();await h.api.open('bases','base-1');
  const secret='one-time-secret-for-test';
  h.bridge.call=async()=>({ok:true,workspace:data,hosting:{running:true,available:true,sourceCount:1,grants:[]},invite:{endpoint:'https://base.example',remoteID:'base-1',token:secret,grantID:'grant-1',expiresAt:'2026-10-27T12:00:00Z'}});
  const form={dataset:{wstForm:'host-grant',id:'base-1'},values:{name:'Test computer',days:'30'},elements:{read:{checked:true},search:{checked:true}},querySelectorAll:()=>[]};
  await h.listeners.submit[1]({target:{closest:()=>form},preventDefault(){}});
  assert.ok(!JSON.stringify(h.api.get().workspace).includes(secret),'token must not be persisted in workspace');
  assert.ok(!h.nodes.get('#wsContent').innerHTML.includes(secret),'token must not appear in ordinary cards');
  const modal=h.created.find(el=>el.className==='ws-modal wst-invite');
  assert.ok(modal,'invite is shown in a one-time dialog');
  assert.match(modal.innerHTML,/type="password" readonly/);
  assert.equal(modal.querySelector('#wst-invite-token').value,secret);
});

test('upload extraction probes local capabilities and leaves unsupported media intact',async()=>{
  const h=harness(fixture());await h.api.load();const actions=[];
  h.bridge.call=async(method,args)=>{actions.push(args.action);return {ok:true,tools:{pdf:'',ocr:'',ffmpeg:'',whisper:''},documents:[],extractions:{}};};
  await h.tools.extractUploaded({id:'image-1',name:'photo.png',mimeType:'image/png'});
  assert.deepEqual(actions,['ingestion.status']);
  await h.api.open('memory','memory-1');
  assert.ok(h.api.get().workspace.attachments.length===1,'unrelated stored file is preserved');
});

test('reviewed patch approval rejects edits made after the applicability check',async()=>{
  const h=harness(fixture());await h.api.load();await h.api.open('coding');const actions=[];
  const patch='--- a/readme.txt\n+++ b/readme.txt\n@@ -1 +1 @@\n-old\n+new\n';
  h.bridge.call=async(method,args)=>{actions.push(args.action);return args.action==='coding.patch.review'?{ok:true,review:{checkPassed:true,files:['readme.txt'],additions:1,deletions:1}}:{ok:true,runID:'patch-1',message:'Waiting for approval'};};
  const form={dataset:{wstForm:'patch-review'},values:{patch},querySelectorAll:()=>[]};
  await h.listeners.submit[1]({target:{closest:()=>form},preventDefault(){}});
  const renderedForm=h.nodes.get('[data-wst-form="patch-review"]')||{elements:{}};
  renderedForm.elements={patch:{value:patch+'modified'}};
  h.nodes.set('[data-wst-form="patch-review"]',renderedForm);
  const button={dataset:{wstAction:'patch.apply'},closest:()=>null};
  await h.listeners.click[1]({target:{closest:()=>button},preventDefault(){}});
  assert.deepEqual(actions,['coding.patch.review'],'a changed patch cannot be queued for approval');
  assert.match(h.nodes.get('#wsMessage').textContent,/Review the current patch/);
  renderedForm.elements.patch.value=patch;
  await h.listeners.click[1]({target:{closest:()=>button},preventDefault(){}});
  assert.deepEqual(actions,['coding.patch.review','coding.patch.apply']);
  assert.match(h.nodes.get('#wstPatchStatus').innerHTML,/Open Activity to Allow \/ Deny/);
});

test('reviewed memory proposals submit user edits and refresh the remaining queue',async()=>{
  const data=fixture(),h=harness(data);await h.api.load();await h.api.open('memory');let accepted;
  const next={...data,proposals:data.proposals.filter(p=>p.id!=='proposal-1')};
  h.bridge.call=async(method,args)=>{if(args?.action==='proposal.accept')accepted=args;return {ok:true,workspace:next,usageBytes:128};};
  const form={dataset:{wstForm:'proposal',id:'proposal-1'},values:{title:'Edited title',text:'Reviewed memory text'},querySelectorAll:()=>[]};
  await h.listeners.submit[1]({target:{closest:()=>form},preventDefault(){}});
  assert.equal(accepted.id,'proposal-1');
  assert.equal(accepted.title,'Edited title');
  assert.equal(accepted.text,'Reviewed memory text');
  assert.ok(!h.api.get().workspace.proposals.some(p=>p.id==='proposal-1'));
});

test('a failed health response still adopts the offline status and cleared source cache', async () => {
  const data=fixture(), h=harness(data);await h.api.load();await h.api.open('bases','base-remote');
  h.bridge.call=async()=>({ok:false,message:'Host unavailable',workspace:{...data,bases:data.bases.map(b=>b.id==='base-remote'?{...b,status:'offline',sources:[]}:b)},usageBytes:128});
  const button={dataset:{wsBaseAction:'health',id:'base-remote'},disabled:false,hasAttribute:()=>false};
  const click=h.listeners.click[0];
  await click({target:{closest:()=>button},preventDefault(){}});
  assert.match(h.nodes.get('#wsContent').innerHTML,/>offline<\/span>/);
  assert.equal(h.nodes.get('#wsMessage').textContent,'Host unavailable');
});
