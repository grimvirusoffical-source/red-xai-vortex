'use strict';

const assert = require('node:assert/strict');
const { chromium } = require('playwright-core');

async function main() {
  const base = process.argv[2];
  const origin = new URL(base);
  assert.equal(origin.protocol, 'http:');
  assert.equal(origin.hostname, '127.0.0.1');
  assert.match(origin.port, /^\d+$/);
  const browser = await chromium.launch({channel: 'msedge', headless: true});
  let page;
  try {
    const context = await browser.newContext({acceptDownloads: false});
    page = await context.newPage();
    const jsErrors = [];
    page.on('pageerror', error => jsErrors.push(error.message.slice(0, 220)));
    await page.goto(base, {waitUntil: 'domcontentloaded', timeout: 20000});
    await page.locator('#gate').waitFor({state: 'visible', timeout: 15000});
    await page.waitForFunction(() =>
      ['gTerms', 'gLogin'].some(id => {
        const element = document.getElementById(id);
        return element && getComputedStyle(element).display !== 'none';
      }), {timeout: 12000});

    if (await page.locator('#gTerms').isVisible()) {
      await page.locator('#gAccept').click();
    }
    await page.locator('#gLogin').waitFor({state: 'visible', timeout: 12000});
    await page.locator('#gBrowserChoice').selectOption('default');

    // The approval tab must be created by the actual button click (user
    // gesture), not after a later asynchronous network request.
    const popupPromise = page.waitForEvent('popup', {timeout: 20000});
    await page.locator('#gQuick').click();
    const popup = await popupPromise;
    assert.ok(popup, 'default browser did not open a new approval tab');
    await page.locator('#gApproval').waitFor({state: 'visible', timeout: 30000});
    const approvalLink = await page.locator('#gApprovalLink').getAttribute('href');
    const parsed = new URL(approvalLink);
    assert.equal(parsed.origin, 'https://red-xai.com');
    assert.equal(parsed.pathname, '/redxai-connectx');
    assert.match(parsed.hash, /^#request=[A-Za-z0-9_-]{43}$/);
    const code = (await page.locator('#gApprovalCode').textContent()).trim();
    assert.match(code, /^[A-Za-z0-9]{8}$/);

    // Browser authentication is user-driven. Never automate submitting
    // actual account credentials or granting permissions on production.
    await page.locator('#gApprovalCancel').click();
    await page.locator('#gApproval').waitFor({state: 'hidden', timeout: 10000});
    assert.equal(await page.locator('#gQuick').isDisabled(), false);
    if (jsErrors.length) {
      console.warn('PAGE_ERRORS', jsErrors.map(x => x.replace(/request=[A-Za-z0-9_-]{43}/g, 'request=[redacted]')).join(' | '));
    }
    await popup.close().catch(() => {});
    console.log('WINDOWS_REAL_EDGE_QUICK_LOGIN_START_CODE_POPUP_CANCEL_PASS');
  } catch (error) {
    const info = page ? await page.locator('#gMsg').textContent().catch(() => '') : '';
    const sanitized = String(info || '').replace(/request=[A-Za-z0-9_-]{43}/g, 'request=[redacted]').slice(0, 280);
    console.error('WINDOWS_BROWSER_E2E_FAILED', error.message);
    if (sanitized) console.error('APP_MESSAGE', sanitized);
    throw error;
  } finally {
    await browser.close();
  }
}
main().catch(() => process.exit(1));
