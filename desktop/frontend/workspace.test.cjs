const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const html = fs.readFileSync(path.join(__dirname, 'index.html'), 'utf8');
const app = fs.readFileSync(path.join(__dirname, 'app.js'), 'utf8');
const workspaceSource = fs.readFileSync(path.join(__dirname, 'workspace.js'), 'utf8');

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
});

// This DOM adapter executes the real view module without a browser dependency.
// Browser layout/interaction verification is separate; here we exercise rendering,
// API responses, and escaping of saved/imported content across every workspace view.
function harness(fixture) {
  const nodes = new Map(), listeners = {};
  function node(selector) {
    if (!nodes.has(selector)) {
      const eventListeners = {};
      nodes.set(selector, {
        innerHTML:'', textContent:'', value:'', dataset:{}, style:{}, hidden:false,
        classList:{toggle() {}},
        addEventListener(name, handler) { (eventListeners[name] ||= []).push(handler); },
        click() { this.onclick?.({target:this}); for (const handler of eventListeners.click||[]) handler({target:this}); },
        focus() {}, remove() {}, querySelectorAll() { return []; },
      });
    }
    return nodes.get(selector);
  }
  const nav = ['projects','bases','personalities','memory','worlds','coding'].map(view=>({dataset:{wsView:view},classList:{toggle(){}}}));
  const document = {
    querySelector(selector) { return selector === '#chatlog .msg' || selector === '.ws-modal' ? null : node(selector); },
    querySelectorAll(selector) { return selector === '[data-ws-view]' ? nav : []; },
    addEventListener(name, handler) { (listeners[name] ||= []).push(handler); },
  };
  const calls = [];
  const bridge = {async call(method, args) { calls.push({method,args}); return {ok:true,workspace:fixture,usageBytes:128}; }};
  const context = vm.createContext({
    window:{}, document, bridge,
    state:{active:'chat-1',chats:[{id:'chat-1',title:'Example conversation'}]},
    esc:value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])),
    refresh(){},loadChat(){},renderChats(){},console,setTimeout,clearTimeout,
  });
  vm.runInContext(workspaceSource, context, {filename:'workspace.js'});
  return {api:context.window.VortexWorkspace,nodes,nav,listeners,calls,bridge};
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
    chatSettings:[{chatID:'chat-1',mode:'code',projectID:'project-1',personalityID:'',baseIDs:['base-1'],sharedMemory:false,coding:{repoPath:'/example/repo',branch:'main',task:unsafe,diff:'@@ -1 +1 @@\n-'+unsafe+'\n+'+unsafe,files:[{path:unsafe,language:unsafe,content:unsafe}]}}],
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

test('a failed health response still adopts the offline status and cleared source cache', async () => {
  const data=fixture(), h=harness(data);await h.api.load();await h.api.open('bases','base-remote');
  h.bridge.call=async()=>({ok:false,message:'Host unavailable',workspace:{...data,bases:data.bases.map(b=>b.id==='base-remote'?{...b,status:'offline',sources:[]}:b)},usageBytes:128});
  const button={dataset:{wsBaseAction:'health',id:'base-remote'},disabled:false,hasAttribute:()=>false};
  const click=h.listeners.click[0];
  await click({target:{closest:()=>button},preventDefault(){}});
  assert.match(h.nodes.get('#wsContent').innerHTML,/>offline<\/span>/);
  assert.equal(h.nodes.get('#wsMessage').textContent,'Host unavailable');
});
