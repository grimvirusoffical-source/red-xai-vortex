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
