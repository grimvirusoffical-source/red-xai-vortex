const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, 'royal-shell.js'), 'utf8');
const settle = () => new Promise(resolve => setImmediate(resolve));

function harness({phone = false, fullscreen = true, local = true, savedPalette = 'gold', storageBlocked = false} = {}) {
  function classList(initial = []) {
    const values = new Set(initial);
    return {contains: key => values.has(key), toggle(key, on) { if (on ?? !values.has(key)) values.add(key); else values.delete(key); }};
  }
  const nodes = new Map(), events = {}, calls = [], timers = [];
  function node(id) {
    if (!nodes.has(id)) nodes.set(id, {
      checked: false, disabled: id === 'royalControlMode', hidden: false, value: '', textContent: '', title: '', dataset: {},
      classList: classList(id === 'tab-chat' ? ['on'] : []), attributes: {}, listeners: {},
      setAttribute(key, value) { this.attributes[key] = value; },
      addEventListener(key, callback) { this.listeners[key] = callback; },
      async emit(key, event = {}) { await this.listeners[key]?.(event); },
      click() { node('tab-chat').classList.toggle('on', true); },
    });
    return nodes.get(id);
  }
  const matcher = {matches: phone, addEventListener(key, callback) { this.listener = callback; }};
  const document = {
    hidden: false, body: {classList: classList()}, fullscreenElement: null,
    documentElement: {dataset: {}}, getElementById: node,
    querySelector(selector) { return selector === '.ws-modal' ? null : node('chat-navigation'); },
    querySelectorAll() { return [node('chat-navigation')]; },
    addEventListener(name, callback) { events[name] = callback; },
    async exitFullscreen() { document.fullscreenElement = null; events.fullscreenchange?.(); },
  };
  if (fullscreen) document.documentElement.requestFullscreen = async () => { document.fullscreenElement = document.documentElement; events.fullscreenchange?.(); };
  let status = {ok: true, alwaysAllow: false, canConfigure: local, activeRuns: 0, mode: 'ask', revision: 0};
  const bridge = {async call(method, args) {
    calls.push({method, args});
    if (method === 'pcControl.set') status = {...status, alwaysAllow: args.alwaysAllow, revision: status.revision + 1};
    if (method === 'pcControl.stop') status = {...status, alwaysAllow: false, revision: status.revision + 1, stopped: 2};
    return {...status};
  }};
  const storage = new Map([['vortex.royalPalette', savedPalette]]);
  const window = {addEventListener(name,callback){events[name]=callback;},matchMedia: () => matcher, setInterval(callback) { timers.push(callback); },
    vortexAccountStorage: {
      getItem(key) { if (storageBlocked) throw new Error('Storage unavailable'); return storage.get(key); },
      setItem(key, value) { if (storageBlocked) throw new Error('Storage unavailable'); storage.set(key, value); },
    },
  };
  vm.runInNewContext(source, {window, document, bridge, console}, {filename: 'royal-shell.js'});
  return {node, document, events, calls, bridge, matcher, timers, storage};
}

test('local control follows confirmed server policy and sends its current revision', async () => {
  const h = harness();
  assert.equal(h.node('royalControlMode').disabled, true);
  assert.equal(h.node('royalControlMode').checked, false);
  await settle();
  assert.equal(h.node('royalControlStatus').textContent, 'Ask each time');
  h.node('royalControlMode').checked = true;
  await h.node('royalControlMode').emit('change');
  const change = h.calls.find(c => c.method === 'pcControl.set');
  assert.equal(change.args.alwaysAllow, true);
  assert.equal(change.args.revision, 0);
  assert.equal(h.node('royalControlStatus').textContent, 'Full control on');
  await h.node('royalControlStop').emit('click');
  assert.equal(h.node('royalControlMode').checked, false);
  assert.equal(h.node('royalControlStatus').textContent, 'Control stopped');
  assert.ok(h.node('royalControlStatus').title.includes('2 active runs stopped'));
  assert.equal(h.node('royalControlStop').disabled, false);
});

test('remote/phone clients cannot configure control but retain the Stop action', async () => {
  const h = harness({phone: true, local: false});
  await settle();
  assert.equal(h.node('royalControlMode').disabled, true);
  assert.equal(h.node('royalControlStop').disabled, false);
  await h.node('royalControlStop').emit('click');
  assert.equal(h.calls.at(-1).method, 'pcControl.stop');
  assert.equal(h.node('royalControlMode').disabled, true);
});

test('failed policy changes resync and display the rejection without claiming success', async () => {
  const h = harness();
  await settle();
  const original = h.bridge.call;
  h.bridge.call = async (method, args) => method === 'pcControl.set' ? {ok: false, message: 'Permission changed; retry locally.'} : original(method, args);
  h.node('royalControlMode').checked = true;
  await h.node('royalControlMode').emit('change');
  assert.equal(h.node('royalControlMode').checked, false);
  assert.equal(h.node('royalControlStatus').textContent, 'Control unavailable');
  assert.ok(h.node('royalControlStatus').title.includes('Permission changed'));
  assert.equal(h.calls.at(-1).method, 'pcControl.status');
});

test('stale status responses cannot undo the visible result of Stop', async () => {
  const h = harness();
  await settle();
  let complete;
  h.bridge.call = async method => method === 'pcControl.status' ? new Promise(resolve => { complete = resolve; }) : {ok: true, canConfigure: true, alwaysAllow: false, revision: 4, stopped: 1};
  const refresh = h.timers[0]();
  await h.node('royalControlStop').emit('click');
  complete({ok: true, canConfigure: true, alwaysAllow: true, revision: 3});
  await refresh;
  assert.equal(h.node('royalControlMode').checked, false);
  assert.equal(h.node('royalControlStatus').textContent, 'Control stopped');
});

test('browser gems perform honest view actions, preserve drafts and restore navigation', async () => {
  const h = harness({phone: true});
  await settle();
  h.node('prompt').value = 'My unfinished message';
  assert.equal(h.document.body.classList.contains('royal-sidebar-collapsed'), true);
  await h.node('royalMinimize').emit('click');
  assert.equal(h.node('royalSidebarScrim').hidden, false);
  h.events.keydown({key: 'Escape'});
  assert.equal(h.node('royalSidebarScrim').hidden, true);
  await h.node('royalFocus').emit('click');
  assert.equal(h.document.body.classList.contains('royal-focus'), true);
  assert.equal(h.node('royalFocus').attributes['aria-label'], 'Leave focus mode');
  h.events.keydown({key: 'Escape'});
  assert.equal(h.document.body.classList.contains('royal-focus'), false);
  assert.equal(h.node('prompt').value, 'My unfinished message');
  await h.node('royalFullscreen').emit('click');
  assert.equal(h.node('royalFullscreen').attributes['aria-label'], 'Leave browser fullscreen');
  await h.node('royalFullscreen').emit('click');
  assert.equal(h.node('royalFullscreen').attributes['aria-label'], 'Enter browser fullscreen');
});

test('unsupported browser fullscreen is disabled and described accurately', () => {
  const h = harness({fullscreen: false});
  assert.equal(h.node('royalFullscreen').disabled, true);
  assert.ok(h.node('royalFullscreen').title.includes('unavailable'));
});


test('palette choice restores locally and persists across new sessions', async () => {
  const h = harness({savedPalette: 'purple'});
  await settle();
  assert.equal(h.document.documentElement.dataset.royalPalette, 'purple');
  assert.equal(h.node('royalPalette').value, 'purple');
  h.node('royalPalette').value = 'light';
  await h.node('royalPalette').emit('change');
  assert.equal(h.storage.get('vortex.royalPalette'), 'light');
  const next = harness({savedPalette: h.storage.get('vortex.royalPalette')});
  assert.equal(next.document.documentElement.dataset.royalPalette, 'light');
  assert.equal(h.node('royalControlStop').disabled, false);
});

test('invalid or unavailable palette storage falls back safely without blocking controls', async () => {
  const invalid = harness({savedPalette: '<script>invalid</script>'});
  assert.equal(invalid.document.documentElement.dataset.royalPalette, 'gold');
  const unavailable = harness({savedPalette: 'purple', storageBlocked: true});
  assert.equal(unavailable.document.documentElement.dataset.royalPalette, 'gold');
  unavailable.node('royalPalette').value = 'red';
  await unavailable.node('royalPalette').emit('change');
  await settle();
  assert.equal(unavailable.document.documentElement.dataset.royalPalette, 'red');
  assert.equal(unavailable.node('royalControlStop').disabled, false);
});

test('verified account change restores only that account’s palette',async()=>{
 const h=harness({savedPalette:'purple'});await settle();
 assert.equal(h.document.documentElement.dataset.royalPalette,'purple');
 h.storage.set('vortex.royalPalette','red');h.events['vortex-account-ready']();
 assert.equal(h.document.documentElement.dataset.royalPalette,'red');
});
