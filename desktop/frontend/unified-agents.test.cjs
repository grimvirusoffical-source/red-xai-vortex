'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const root = __dirname;
const html = fs.readFileSync(path.join(root,'index.html'),'utf8');
const app = fs.readFileSync(path.join(root,'app.js'),'utf8');
const agents = fs.readFileSync(path.join(root,'agent-ui.js'),'utf8');

test('one visible agent creator has all permissions and schedule controls', () => {
  for (const id of ['agentEditor','aNew','aName','aInstructions','aGoal','aProv','aMode','aModel',
      'aKey','aPC','aAlways','aEvery','aNonstop','aRunning','aRunOn','aWorkerStatus',
      'aSave','aRunNow','aKill','aResetKill']) {
    assert.equal([...html.matchAll(new RegExp('id="'+id+'"','g'))].length,1,id);
  }
  assert.match(html,/<option value="cloudpc">Cloud PC/);
  assert.match(html,/<option value="mix">Mix/);
  assert.match(html,/<option value="auto">Auto/);
  assert.match(agents,/bridge\.call\('agent\.kill'/);
  assert.match(agents,/bridge\.call\('agent\.worker\.status'/);
  assert.match(agents,/bridge\.call\('agent\.remote\.list'/);
  assert.match(agents,/bridge\.call\('agent\.save'/);
  assert.match(agents,/bridge\.call\('agent\.toggle'/);
});

test('team chat requires a designated leader and can create a separate workspace', () => {
  for (const id of ['partyLeader','partyWorkspaceName','partyInstructions','partyOpts','partyGo']) {
    assert.equal([...html.matchAll(new RegExp('id="'+id+'"','g'))].length,1,id);
  }
  assert.match(app,/bridge\.call\('party\.new'/);
  assert.match(app,/workspaceName:\$\('#partyWorkspaceName'\)/);
  assert.match(app,/leaderID/);
  assert.match(app,/members\.length<2/);
});

test('agent list uses text nodes instead of executing model-provided HTML', () => {
  assert.match(agents,/document\.createElement\('strong'\)/);
  assert.match(agents,/name\.textContent = a\.name/);
  assert.match(agents,/item\.append/);
  assert.doesNotMatch(agents,/innerHTML/);
});

test('the agent editor does not start a remote task on the local desktop', () => {
  assert.match(agents,/a\.runOn === 'server' \|\| a\.runOn === 'cloudpc'/);
  assert.match(agents,/bridge\.call\('run\.start'/);
  assert.match(agents,/if \(a\.running\) return show/);
});
