const test=require('node:test'),assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path');
const html=fs.readFileSync(path.join(__dirname,'index.html'),'utf8');
const source=fs.readFileSync(path.join(__dirname,'app.js'),'utf8');
test('Manual update button is available independent of auto-update toggle',()=>{
  assert.match(html,/id="checkUpdatesNow"/);
  assert.match(html,/id="updateStatus"[^>]*role="status"/);
  assert.match(source,/bridge.call\('update.check'\)/);
  assert.match(source,/bridge.call\('update.install'\)/);
  assert.match(source,/bridge.call\('update.status'\)/);
  assert.match(source,/window.confirm\(/);
  assert.ok(!source.includes("$('#checkUpdatesNow').disabled=$('#autoUpdate').checked"));
});
