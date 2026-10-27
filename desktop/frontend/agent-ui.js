'use strict';
/* One agent editor for manual tasks, periodic jobs and continuous local agents.
   This UI NEVER executes instructions on its own; the bridge enforces grants. */
(() => {
  let editing = '';
  let agents = [];
  const el = id => document.getElementById(id);
  const checked = () => [...document.querySelectorAll('#agentPermissions input:checked')].map(e => e.value);
  const show = (message, ok) => {
    el('aMsg').textContent = message || '';
    el('aMsg').className = ok ? 'ok' : 'bad';
  };
  const choosePermissions = allowed => {
    document.querySelectorAll('#agentPermissions input').forEach(e => { e.checked = allowed.includes(e.value); });
  };
  function fresh() {
    editing = '';
    el('aEditorTitle').textContent = 'Create an agent';
    for (const id of ['aName','aInstructions','aGoal','aBase','aKey']) el(id).value = '';
    el('aProv').value = 'vortex'; el('aModel').value = 'vortex'; el('aMode').value = 'auto';
    el('aEvery').value = '0';
    for (const id of ['aPC','aAlways','aNonstop','aRunning']) el(id).checked = false;
    choosePermissions(['web','files-read']);
  }
  function edit(a) {
    if (!a) return;
    editing = a.id;
    el('aEditorTitle').textContent = 'Edit ' + a.name;
    el('aName').value = a.name || ''; el('aInstructions').value = a.systemPrompt || '';
    el('aGoal').value = a.goal || ''; el('aProv').value = a.provider || 'vortex';
    el('aModel').value = a.model || 'vortex'; el('aMode').value = a.modelMode || 'single';
    el('aBase').value = a.baseURL || ''; el('aKey').value = '';
    el('aEvery').value = String(a.nonstop ? 0 : (a.scheduleSeconds || 0));
    el('aPC').checked = a.pcControlOn === true; el('aAlways').checked = a.alwaysAllow === true;
    el('aNonstop').checked = a.nonstop === true; el('aRunning').checked = a.running === true;
    const previous = ['web','files-read','files-write',...(a.pcControlOn ? ['shell'] : [])];
    choosePermissions(Array.isArray(a.permissions) ? a.permissions : previous);
    el('agentEditor').scrollIntoView({block:'nearest'});
  }
  async function save() {
    const request = {
      id: editing, name: el('aName').value, instructions: el('aInstructions').value,
      goal: el('aGoal').value, provider: el('aProv').value, model: el('aModel').value,
      modelMode: el('aMode').value, baseURL: el('aBase').value, apiKey: el('aKey').value,
      toolsOn: true, permissions: checked(), pcControlOn: el('aPC').checked,
      alwaysAllow: el('aAlways').checked, nonstop: el('aNonstop').checked,
      scheduleSeconds: Number(el('aEvery').value), running: el('aRunning').checked
    };
    const response = await bridge.call('agent.save', request);
    el('aKey').value = '';
    show(response.message || response.error || 'Could not save agent.', response.ok);
    if (response.ok) { editing = response.id; el('aEditorTitle').textContent = 'Edit ' + request.name; await refresh(); }
    return response;
  }
  async function run(a) {
    if (!a) return show('Save the agent before running it.', false);
    const response = await bridge.call('run.start', {agentID: a.id, task: a.goal || a.systemPrompt});
    show(response.message || response.error || (response.ok ? 'Task started. Track real tool results in Activity.' : 'Unable to start task.'), response.ok);
    if (response.ok) actPoll();
  }
  async function dispatch(a, action) {
    let response;
    if (action === 'edit') return edit(a);
    if (action === 'run') return run(a);
    if (action === 'toggle') response = await bridge.call('agent.toggle', {id:a.id, running:!a.running});
    if (action === 'delete') response = await bridge.call('agent.delete', {id:a.id});
    if (!response) return;
    show(response.message || response.error || (response.ok ? 'Agent updated.' : 'Unable to update agent.'), response.ok);
    if (action === 'delete' && editing === a.id && response.ok) fresh();
    await refresh();
  }
  function render(values) {
    agents = values || [];
    const list = el('agentList');
    list.replaceChildren();
    for (const a of agents) {
      const item = document.createElement('div');
      item.className = 'row';
      item.style.cssText = 'margin:8px 0;padding:8px;border:1px solid var(--line);border-radius:8px';
      const name = document.createElement('strong'); name.textContent = a.name;
      const detail = document.createElement('small');
      detail.className = 'muted';
      detail.textContent = (a.modelMode === 'mix' ? 'Multi-model' : a.modelMode === 'auto' ? 'Smart routing' : a.model) +
        (a.running ? ' · Scheduled' : ' · Manual');
      item.append(name,detail);
      for (const [action,label] of [['edit','Edit'],['toggle',a.running?'Pause':'Start'],['run','Run'],['delete','Delete']]) {
        if (action === 'delete' && a.id === 'vortex-default') continue;
        const button = document.createElement('button');
        button.type = 'button'; button.className = action === 'delete' ? 'danger' : 'ghost';
        button.textContent = label; button.addEventListener('click', () => dispatch(a,action));
        item.append(button);
      }
      list.append(item);
    }
    if (!agents.length) list.textContent = 'No agents yet.';
  }
  el('aNew').addEventListener('click', fresh);
  el('aSave').addEventListener('click', save);
  el('aRunNow').addEventListener('click', async () => {
    if (!editing) { const r = await save(); if (!r.ok) return; }
    await run(agents.find(a => a.id === editing));
  });
  el('aProv').addEventListener('change', () => { if (el('aProv').value !== 'vortex') el('aMode').value = 'single'; });
  el('aNonstop').addEventListener('change', () => { if (el('aNonstop').checked) el('aEvery').value = '0'; });
  el('aKill').addEventListener('click', async () => {
    const r = await bridge.call('agent.kill',{});
    show(r.message || r.error || (r.ok ? 'Emergency stop activated. All scheduled agents paused.' : 'Stop failed.'),r.ok);
    await refresh();
  });
  el('aResetKill').addEventListener('click', async () => {
    const r = await bridge.call('agent.resume',{});
    show(r.message || r.error || 'Reset failed.',r.ok);
  });
  window.AgentUI = {render,edit,fresh,save};
})();
