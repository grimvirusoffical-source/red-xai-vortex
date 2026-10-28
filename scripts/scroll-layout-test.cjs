'use strict';
// Isolated headless browser: renders repository HTML/CSS only. No login,
// user browser profile, live account, or application API is accessed.
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),cp=require('node:child_process');
const {pathToFileURL}=require('node:url');
const root=path.resolve(__dirname,'..'),frontend=path.join(root,'desktop/frontend');
const temp=fs.mkdtempSync(path.join(os.tmpdir(),'vortex-scroll-fixture-'));
const browser=process.env.VORTEX_TEST_BROWSER||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const html=fs.readFileSync(path.join(frontend,'index.html'),'utf8').replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi,'').replace('<head>','<head><base href="'+pathToFileURL(frontend+path.sep).href+'">');
fs.writeFileSync(path.join(temp,'fixture.html'),html);
const child=cp.spawn(browser,['--headless=new','--no-first-run','--no-default-browser-check','--disable-background-networking','--remote-debugging-port=0','--user-data-dir='+path.join(temp,'profile'),'about:blank'],{stdio:'ignore'});
const pause=ms=>new Promise(r=>setTimeout(r,ms));let ws;
(async()=>{
 const portFile=path.join(temp,'profile/DevToolsActivePort');for(let i=0;i<100&&!fs.existsSync(portFile);i++)await pause(100);
 if(!fs.existsSync(portFile))throw Error('Isolated browser did not start');
 const port=fs.readFileSync(portFile,'utf8').split('\n')[0];
 const pages=await (await fetch('http://127.0.0.1:'+port+'/json/list')).json();
 ws=new WebSocket(pages.find(p=>p.type==='page').webSocketDebuggerUrl);
 await new Promise((r,j)=>{ws.onopen=r;ws.onerror=j});let id=0;const pending=new Map();
 ws.onmessage=e=>{const m=JSON.parse(e.data);const p=pending.get(m.id);if(p){pending.delete(m.id);clearTimeout(p.timer);m.error?p.reject(Error(m.error.message)):p.resolve(m.result)}};
 const send=(method,params={})=>new Promise((resolve,reject)=>{const n=++id;const timer=setTimeout(()=>{pending.delete(n);reject(Error('Browser command timed out: '+method))},10000);pending.set(n,{resolve,reject,timer});ws.send(JSON.stringify({id:n,method,params}))});
 await send('Page.enable');await send('Page.navigate',{url:pathToFileURL(path.join(temp,'fixture.html')).href});await pause(700);
 const tests=[];
 for(const [width,height]of [[1280,720],[900,540],[640,480]]){
  await send('Emulation.setDeviceMetricsOverride',{width,height,deviceScaleFactor:1,mobile:false});
  for(const [panel,button]of [['agents','aSave'],['mcp','mcp-save']]){
   const r=await send('Runtime.evaluate',{returnByValue:true,expression:`(()=>{document.getElementById('gate').style.display='none';for(const e of document.querySelectorAll('.panel')){e.classList.remove('on');e.style.display='none'}const p=document.getElementById('tab-${panel}');p.classList.add('on');p.style.display='block';for(const d of p.querySelectorAll('details'))d.open=true;const b=document.getElementById('${button}');if(!b)return {error:'Missing save button'};b.scrollIntoView({block:'end'});const r=b.getBoundingClientRect();return {panel:'${panel}',width:innerWidth,height:innerHeight,scrollHeight:p.scrollHeight,clientHeight:p.clientHeight,buttonTop:r.top,buttonBottom:r.bottom,reachable:r.top>=0&&r.bottom<=innerHeight+1}})()`});
   if(r.exceptionDetails)throw Error(r.exceptionDetails.text);const item=r.result.value;tests.push(item);
   if(!item.reachable)throw Error('Save button unreachable: '+JSON.stringify(item));
  }
 }
 fs.mkdirSync(path.join(root,'verification'),{recursive:true});fs.writeFileSync(path.join(root,'verification/scroll-layout.json'),JSON.stringify({passed:true,tests},null,2));console.log(JSON.stringify({passed:true,tests},null,2));
})().catch(e=>{console.error(e.message);process.exitCode=1}).finally(async()=>{ws?.close();child.kill();await pause(300);try{fs.rmSync(temp,{recursive:true,force:true})}catch{}});
