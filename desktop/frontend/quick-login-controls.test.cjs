'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const html=fs.readFileSync(path.join(__dirname,'index.html'),'utf8');
const js=fs.readFileSync(path.join(__dirname,'app.js'),'utf8');
test('Windows Quick Login has all browser choice and approval controls required by app.js',()=>{
 const required=['gQuick','gBrowserChoice','gApproval','gApprovalCode','gApprovalLink','gApprovalCancel'];
 for(const id of required)assert.equal([...html.matchAll(new RegExp('id="'+id+'"','g'))].length,1,id);
 for(const browser of ['default','edge','chrome','firefox','brave','safari'])assert.match(html,new RegExp('value="'+browser+'"'));
 assert.match(js,/bridge.call\('redx.quick.start'\)/);
 assert.match(js,/bridge.call\('redx.quick.open'/);
 assert.match(js,/bridge.call\('redx.quick.poll'\)/);
 assert.match(js,/bridge.call\('redx.quick.cancel'\)/);
 assert.match(js,/\^#request=\[A-Za-z0-9_-\]\{43\}\$/);
});
test('Quick Login still preserves the original password and MFA fallback',()=>{
 for(const id of ['gUser','gPass','gGo','gOtp','gCode','gCallMe']){
  assert.match(html,new RegExp('id="'+id+'"'));
 }
 assert.match(js,/bridge.call\('redx.login'/);
 assert.match(js,/bridge.call\('redx.2fa'/);
});

test('Default browser uses script-opened approval tab for safe close-and-return after login',()=>{
 assert.match(js,/window\.open\('about:blank','_blank'\)/);
 assert.match(js,/approvalTab\.location\.replace\(url\.href\)/);
 assert.match(js,/approvalTab\?\.close\(\)/);
 assert.match(js,/selectedBrowser==='default'/);
 assert.match(js,/opt\.value==='safari'&&!quickIsMac/);
 assert.match(html,/same identity across Red-XAI apps/);
});

test('Quick Login and password are two independent user-selectable methods',()=>{
 for(const id of ['gChooseQuick','gChoosePassword','gQuickSection','gPasswordSection']){
  assert.equal([...html.matchAll(new RegExp('id="'+id+'"','g'))].length,1,id);
 }
 assert.match(html,/<section id="gPasswordSection"[^>]*hidden>/);
 assert.match(html,/Quick Login is not required/);
 assert.match(js,/let gFlow=.*authMethod='quick'/);
 assert.match(js,/function chooseSignInMethod\(method\)/);
 assert.match(js,/if\(authMethod!=='quick'\)return/);
 assert.match(js,/if\(authMethod!=='password'\)return/);
 assert.match(js,/gFlow='';gMethod='totp'/);
 assert.match(js,/gFlow='';quickStopUI\(\)/);
 assert.match(js,/if\(v\.signedIn\)[\s\S]{0,600}await gate\(\)/);
 assert.match(js,/attempt!==quickAttempt/);
});

test('Windows and Linux expose persistent account switching without hiding the original footer logout',()=>{
 for(const id of ['accountLogOut','fSignOut']){
  assert.equal([...html.matchAll(new RegExp('id="'+id+'"','g'))].length,1,id);
 }
 assert.match(html,/<button id="accountLogOut"[^>]+type="button"/);
 assert.match(js,/\$\('#accountLogOut'\)\.onclick=signOutVortex/);
 assert.match(js,/\$\('#fSignOut'\)\.onclick=signOutVortex/);
 assert.match(js,/bridge\.call\('redx\.logout'/);
 assert.doesNotMatch(js,/bridge\.call\('redx\.owner\.continue'/);
 assert.doesNotMatch(html,/id="gOwnerContinue"/);
 assert.match(js,/g\.signedIn!==true/);
 assert.match(js,/location\.reload\(\)/);
});
