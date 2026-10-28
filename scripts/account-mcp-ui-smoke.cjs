'use strict';
// Real Chromium layout/interaction checks with explicit fixture accounts.
// No real account, API key, provider, or computer-control tool is used.
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const {chromium} = require(path.join(root, 'verification/browser/node_modules/playwright-core'));
const frontend = path.join(root, 'desktop/frontend');
const appSource = fs.readFileSync(path.join(frontend, 'app.js'), 'utf8');
const terms = /(?:const|let) TERMS_VERSION\s*=\s*['"]([^'"]+)/.exec(appSource)?.[1];
assert.ok(terms, 'Terms version must be read from actual app source');
const server = http.createServer((req, res) => {
  let requested;
  try { requested = decodeURIComponent(new URL(req.url, 'http://localhost').pathname); } catch { res.writeHead(400).end(); return; }
  const file = path.resolve(frontend, '.' + (requested === '/' ? '/index.html' : requested));
  if (!file.startsWith(frontend + path.sep)) { res.writeHead(403).end(); return; }
  if (!fs.existsSync(file) || !fs.statSync(file).isFile()) { res.writeHead(404).end(); return; }
  const mime = {'.js':'text/javascript','.html':'text/html','.css':'text/css','.png':'image/png','.svg':'image/svg+xml'};
  res.writeHead(200, {'Content-Type': mime[path.extname(file)] || 'text/plain'}); fs.createReadStream(file).pipe(res);
});
(async () => {
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const browser = await chromium.launch({executablePath: process.env.CHROME_PATH || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true});
  const results = [];
  try {
    for (const viewport of [{width:1280,height:720},{width:800,height:600}]) {
      const context = await browser.newContext({viewport});
      const page = await context.newPage();
      const pageErrors = []; page.on('pageerror', error => pageErrors.push(error.message));
      await page.route('**/*', route => new URL(route.request().url()).hostname === '127.0.0.1' ? route.continue() : route.abort());
      await page.addInitScript(({terms}) => {
        const agents = [], connections = []; const calls = [];
        window.__fixture = {agents, connections, calls};
        window.vortex = {async call(method, input = {}) {
          calls.push({method,input});
          if (method === 'gate.status') return {ok:true,signedIn:true,termsAccepted:terms,profileID:'a'.repeat(64),profileLease:'fixture-lease',username:'Fixture account A',owner:false,ownerAvailable:false};
          if (method === 'composer.get') return {ok:true,composer:{quick:false,length:'normal',tier:'vortex-pro'},tiers:[{ID:'vortex-pro',Name:'Pro',Model:'vortex-pro',Speed:'fixture'}],perChat:false};
          if (method === 'status') return {ok:true,connected:true,models:['vortex-pro'],chats:[],agents,baseURL:'https://fixture.invalid/v1',link:{}};
          if (method === 'agent.save') {agents.push({...input,id:'fixture-agent'});return {ok:true,id:'fixture-agent',message:'Saved fixture agent'};}
          if (method === 'pcControl.status') return {ok:true,alwaysAllow:false,canConfigure:true,revision:1};
          if (method === 'mcp.list') return {ok:true,servers:connections};
          if (method === 'mcp.save') {connections.push({...input.server,hasKey:!!input.apiKey});return {ok:true};}
          if (method === 'mcp.test') return {ok:true,tools:[{name:'fixture-tool'}],message:'Fixture tool discovery succeeded'};
          if (method === 'workspace.get') return {ok:true,projects:[],personalities:[],memories:[],bases:[],sessions:[],patches:[],worlds:[],worldProposals:[],memoryProposals:[],settings:{},active:{}};
          return {ok:true,data:[],items:[],runs:[],events:[],agents:[],projects:[],models:[],installed:[],published:[],bases:[],settings:{}};
        }};
      }, {terms});
      await page.goto('http://127.0.0.1:' + server.address().port, {waitUntil:'networkidle'});
      await page.waitForSelector('#gate', {state:'hidden'});
      assert.equal(await page.locator('#gOwnerContinue').isVisible(), false);
      const agentTab=page.locator('[data-tab="agents"]');
      if (!(await agentTab.isVisible())) await page.locator('#royalMinimize').click();
      await agentTab.click();
      await page.locator('#aName').fill('Scrollable fixture agent');
      await page.locator('#aInstructions').fill('Test form only. Do not execute any actions.');
      await page.locator('#aGoal').fill('Confirm Save remains reachable.');
      await page.locator('#aSave').scrollIntoViewIfNeeded();
      const bounds=await page.locator('#aSave').boundingBox();
      assert.ok(bounds && bounds.y>=0 && bounds.y+bounds.height<=viewport.height, 'Save agent must be reachable within the viewport');
      await page.locator('#aSave').click();
      await page.waitForFunction(() => window.__fixture.agents.length===1);
      const scroll=await page.locator('#tab-agents').evaluate(el=>({scrollHeight:el.scrollHeight,clientHeight:el.clientHeight,overflow:getComputedStyle(el).overflowY,scrollTop:el.scrollTop}));
      assert.match(scroll.overflow,/auto|scroll/);
      assert.ok(scroll.scrollHeight>scroll.clientHeight && scroll.scrollTop>0, 'Actual agent panel must scroll');
      const mcpTab=page.locator('[data-tab="mcp"]');
      if (!(await mcpTab.isVisible())) await page.locator('#royalMinimize').click();
      await mcpTab.click(); await page.locator('#mcp-firecrawl').click();
      assert.equal(await page.locator('#mcp-url').inputValue(),'https://mcp.firecrawl.dev/v2/mcp');
      assert.equal(await page.locator('#mcp-auth').inputValue(),'bearer');
      await page.locator('#mcp-key').fill('fixture-not-a-real-key');
      await page.locator('#mcp-save').scrollIntoViewIfNeeded();await page.locator('#mcp-save').click();
      await page.waitForFunction(()=>window.__fixture.connections.length===1);
      const connection=await page.evaluate(()=>window.__fixture.connections[0]);
      assert.equal(connection.authMode,'bearer');assert.equal(connection.hasKey,true);assert.equal(connection.apiKey,undefined);
      assert.equal(await page.locator('#mcp-key').inputValue(),'');
      assert.equal(await page.getByText('fixture-not-a-real-key',{exact:true}).count(),0);
      assert.deepEqual(pageErrors,[], 'The complete browser fixture must load without uncaught errors');
      results.push({viewport,agentSaved:true,scroll,firecrawlPreset:true,secretNotInSavedDefinition:true,pageErrors});
      await context.close();
    }
    fs.mkdirSync(path.join(root,'verification'),{recursive:true});
    fs.writeFileSync(path.join(root,'verification/account-mcp-ui.json'),JSON.stringify({fixtureOnly:true,results},null,2));
    console.log(JSON.stringify({fixtureOnly:true,results},null,2));
  } finally {await browser.close();await new Promise(resolve=>server.close(resolve));}
})().catch(error=>{console.error(error.stack);server.close();process.exitCode=1;});
