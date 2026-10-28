/* Presentation controls use browser capabilities; PC policy is enforced by the bridge. */
(() => {
  'use strict';
  const byID = id => document.getElementById(id);
  const narrow = window.matchMedia('(max-width: 950px)');
  let sidebarOpen = !narrow.matches;
  let policyBusy = false;
  let policy = {alwaysAllow: false, canConfigure: false, revision: -1};
  const mode = byID('royalControlMode');
  const stop = byID('royalControlStop');
  const controlStatus = byID('royalControlStatus');
  const focus = byID('royalFocus');
  const fullscreen = byID('royalFullscreen');

  function showSidebar(open) {
    sidebarOpen = open;
    document.body.classList.toggle('royal-sidebar-collapsed', !open);
    document.body.classList.toggle('royal-sidebar-open', open);
    for (const id of ['royalSidebarToggle', 'royalMinimize']) {
      byID(id).setAttribute('aria-expanded', String(open));
      byID(id).title = open ? 'Hide conversations sidebar' : 'Show conversations sidebar';
    }
    byID('royalSidebarScrim').hidden = !open || !narrow.matches;
  }
  function toggleSidebar() {
    if (!byID('tab-chat').classList.contains('on')) {
      document.querySelector('[data-tab="chat"]').click();
      showSidebar(true);
    } else showSidebar(!sidebarOpen);
  }
  function setFocus(on) {
    document.body.classList.toggle('royal-focus', on);
    focus.setAttribute('aria-pressed', String(on));
    focus.setAttribute('aria-label', on ? 'Leave focus mode' : 'Focus current view');
    focus.title = on ? 'Leave focus mode · Escape restores navigation' : 'Focus current view · Escape restores navigation';
  }
  function updateFullscreen() {
    const active = !!document.fullscreenElement;
    fullscreen.setAttribute('aria-label', active ? 'Leave browser fullscreen' : 'Enter browser fullscreen');
    fullscreen.title = active ? 'Leave browser fullscreen' : 'Enter browser fullscreen';
    fullscreen.setAttribute('aria-pressed', String(active));
  }
  byID('royalSidebarToggle').addEventListener('click', toggleSidebar);
  byID('royalMinimize').addEventListener('click', toggleSidebar);
  byID('royalSidebarScrim').addEventListener('click', () => showSidebar(false));
  focus.addEventListener('click', () => setFocus(!document.body.classList.contains('royal-focus')));
  fullscreen.addEventListener('click', async () => {
    try {
      if (document.fullscreenElement) await document.exitFullscreen();
      else if (document.documentElement.requestFullscreen) await document.documentElement.requestFullscreen();
      else fullscreen.title = 'Browser fullscreen is unavailable here';
    } catch (_) { fullscreen.title = 'This browser did not allow fullscreen'; }
  });
  document.addEventListener('fullscreenchange', updateFullscreen);
  document.addEventListener('keydown', event => {
    if (event.key !== 'Escape' || document.querySelector('.ws-modal')) return;
    if (document.body.classList.contains('royal-focus')) setFocus(false);
    else if (narrow.matches && sidebarOpen) showSidebar(false);
  });
  narrow.addEventListener('change', () => showSidebar(!narrow.matches));
  document.querySelectorAll('.tabs button').forEach(button => button.addEventListener('click', () => {
    if (narrow.matches) showSidebar(false);
  }));
  showSidebar(sidebarOpen);
  updateFullscreen();
  if (!document.documentElement.requestFullscreen) {
    fullscreen.disabled = true;
    fullscreen.title = 'Browser fullscreen is unavailable here';
  }


  const palette = byID('royalPalette');
  let paletteProfile = '';
  const palettes = new Set(['gold', 'purple', 'light', 'red']);
  function setPalette(value, persist = false) {
    const chosen = palettes.has(value) ? value : 'gold';
    document.documentElement.dataset.royalPalette = chosen;
    palette.value = chosen;
    if (persist) {
      try { paletteProfile && window.localStorage?.setItem('vortex.royalPalette.' + paletteProfile, chosen); } catch (_) { /* Theme still applies when storage is unavailable. */ }
    }
  }
  let savedPalette = 'gold';
  // Old machine-wide presentation settings are not adopted by a new account.
  setPalette(savedPalette);
  window.addEventListener('vortex-account-changed', event => {
    paletteProfile = /^[a-f0-9]{64}$/.test(event.detail?.id || '') ? event.detail.id : '';
    let value = 'gold';
    try { if(paletteProfile)value=window.localStorage?.getItem('vortex.royalPalette.'+paletteProfile)||'gold'; } catch(_){}
    policy={alwaysAllow:false,canConfigure:false,revision:-1};
    setPalette(value);
  });
  palette.addEventListener('change', () => setPalette(palette.value, true));

  function renderPolicy(value, message) {
    if (!Number.isSafeInteger(value.revision) || value.revision < policy.revision) return;
    policy = value;
    mode.checked = value.alwaysAllow === true;
    mode.disabled = policyBusy || value.canConfigure !== true;
    controlStatus.dataset.mode = value.alwaysAllow === true ? 'alwaysAllow' : 'ask';
    controlStatus.textContent = message || (value.alwaysAllow === true ? 'Full control on' : 'Ask each time');
    controlStatus.title = value.message || (value.canConfigure === true
      ? 'Local PC control policy. Stop control remains available in every view.'
      : 'Only the local operator can change this permission.');
  }
  function showPolicyError(error) {
    mode.checked = policy.alwaysAllow === true;
    mode.disabled = policyBusy || policy.canConfigure !== true;
    controlStatus.dataset.mode = 'error';
    controlStatus.textContent = 'Control unavailable';
    controlStatus.title = String(error?.message || 'Could not read local PC control status.').slice(0, 250);
  }
  async function callPolicy(method, args) {
    const result = await bridge.call(method, args || {});
    if (!result || result.ok !== true) throw new Error(result?.message || result?.error || 'PC control request failed.');
    return result;
  }
  async function refreshPolicy() {
    if (policyBusy || document.hidden) return;
    try { renderPolicy(await callPolicy('pcControl.status')); }
    catch (error) { showPolicyError(error); }
  }
  async function resyncAfterFailure(error) {
    try { renderPolicy(await callPolicy('pcControl.status')); }
    catch (_) { /* Keep the last confirmed state when the bridge is unavailable. */ }
    showPolicyError(error);
  }
  mode.addEventListener('change', async () => {
    if (policyBusy) return;
    const requested = mode.checked;
    policyBusy = true;
    mode.disabled = true;
    controlStatus.textContent = 'Updating…';
    try { renderPolicy(await callPolicy('pcControl.set', {alwaysAllow: requested, revision: policy.revision})); }
    catch (error) { await resyncAfterFailure(error); }
    finally { policyBusy = false; mode.disabled = policy.canConfigure !== true; }
  });
  stop.addEventListener('click', async () => {
    if (stop.disabled) return;
    stop.disabled = true;
    policyBusy = true;
    mode.disabled = true;
    controlStatus.textContent = 'Stopping…';
    try {
      const result = await callPolicy('pcControl.stop');
      renderPolicy(result, 'Control stopped');
      controlStatus.title = `${Number(result.stopped) || 0} active runs stopped. New actions require approval.`;
    } catch (error) { await resyncAfterFailure(error); }
    finally { policyBusy = false; stop.disabled = false; mode.disabled = policy.canConfigure !== true; }
  });
  document.addEventListener('visibilitychange', refreshPolicy);
  window.setInterval(refreshPolicy, 5000);
  refreshPolicy();
})();
