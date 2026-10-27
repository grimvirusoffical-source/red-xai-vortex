'use strict';
// Real Windows Edge UI with local-only synthetic authentication responses.
// Never send an actual website password or approve a production account grant.
const assert=require('node:assert/strict');
const {chromium}=require('playwright-core');
async function main(){
 const base=process.argv[2],u=new URL(base);
 assert.equal(u.origin,'http://127.0.0.1:'+u.port);
 const browser=await chromium.launch({channel:'msedge',headless:true});
 const answer=(route,value)=>route.fulfill({status:200,contentType:'application/json',body:JSON.stringify(value)});
 try{
  const ctx=await browser.newContext({acceptDownloads:false});
  async function loginPage(){
   const page=await ctx.newPage();
   await page.goto(base,{waitUntil:'domcontentloaded',timeout:20000});
   await page.waitForFunction(()=>['gTerms','gLogin'].some(id=>{
    const e=document.getElementById(id);
    return e&&getComputedStyle(e).display!=='none';
   }),{timeout:17000});
   if(await page.locator('#gTerms').isVisible())await page.locator('#gAccept').click();
   await page.locator('#gLogin').waitFor({state:'visible',timeout:12000});
   for(const id of ['#gChooseQuick','#gChoosePassword','#gQuickSection','#gPasswordSection']){
    assert.equal(await page.locator(id).count(),1,'missing '+id);
   }
   return page;
  }
  // Website grant only: no password or MFA requests.
  const quick=await loginPage();
  assert.equal(await quick.locator('#gQuickSection').isVisible(),true);
  assert.equal(await quick.locator('#gPasswordSection').isVisible(),false);
  let oldAuth=0,quickPolls=0,approved=false;
  await quick.route('**/bridge/redx.login',r=>{oldAuth++;return answer(r,{ok:false})});
  await quick.route('**/bridge/redx.2fa',r=>{oldAuth++;return answer(r,{ok:false})});
  await quick.route('**/bridge/redx.quick.start',r=>answer(r,{
   ok:true,code:'TEST0001',interval:2,url:'https://red-xai.com/redxai-connectx#request='+'a'.repeat(43)
  }));
  await quick.route('**/bridge/redx.quick.poll',r=>{quickPolls++;approved=true;return answer(r,{ok:true,signedIn:true})});
  await quick.route('**/bridge/gate.status',r=>approved?
   answer(r,{ok:true,signedIn:true,username:'quick@test.invalid',termsAccepted:'2026-10-25'}):r.continue());
  const popupPromise=quick.waitForEvent('popup',{timeout:15000});
  await quick.locator('#gQuick').click();
  const popup=await popupPromise;
  await quick.locator('#gate').waitFor({state:'hidden',timeout:16000});
  assert.ok(quickPolls>0);
  assert.equal(oldAuth,0);
  await popup.close().catch(()=>{});
  await quick.close();
  console.log('QUICK_LOGIN_ALONE_OPENED_VORTEX_WITH_ZERO_PASSWORD_OR_MFA_CALLS');

  // Password only: never call Quick Login.
  const pwd=await loginPage();
  await pwd.locator('#gChoosePassword').click();
  assert.equal(await pwd.locator('#gQuickSection').isVisible(),false);
  let quickStarts=0,logins=0,signedIn=false;
  await pwd.route('**/bridge/redx.quick.start',r=>{quickStarts++;return answer(r,{ok:false})});
  await pwd.route('**/bridge/redx.login',r=>{logins++;signedIn=true;return answer(r,{ok:true,signedIn:true})});
  await pwd.route('**/bridge/gate.status',r=>signedIn?
   answer(r,{ok:true,signedIn:true,username:'password@test.invalid',termsAccepted:'2026-10-25'}):r.continue());
  await pwd.locator('#gUser').fill('synthetic.invalid');
  await pwd.locator('#gPass').fill('synthetic-nonsecret');
  await pwd.locator('#gGo').click();
  await pwd.locator('#gate').waitFor({state:'hidden',timeout:8000});
  assert.equal(logins,1);assert.equal(quickStarts,0);
  await pwd.close();
  console.log('PASSWORD_LOGIN_ALONE_OPENED_VORTEX_WITH_ZERO_QUICK_STARTS');

  // Switching methods discards a pending 2FA challenge.
  const sw=await loginPage();
  await sw.locator('#gChoosePassword').click();
  let mfa=0;
  await sw.route('**/bridge/redx.login',r=>answer(r,{
   ok:true,next:'2fa',flow:'synthetic-flow',methods:{totp:true,call:false}
  }));
  await sw.route('**/bridge/redx.2fa',r=>{mfa++;return answer(r,{ok:false})});
  await sw.locator('#gUser').fill('synthetic.invalid');
  await sw.locator('#gPass').fill('synthetic-nonsecret');
  await sw.locator('#gGo').click();
  await sw.locator('#gCode').waitFor({state:'visible',timeout:7000});
  await sw.locator('#gChooseQuick').click();
  assert.equal(await sw.locator('#gQuickSection').isVisible(),true);
  assert.equal(await sw.locator('#gCode').isVisible(),false);
  assert.equal(mfa,0);
  await sw.close();
  console.log('UNFINISHED_PASSWORD_2FA_NEVER_BLOCKS_QUICK_LOGIN');
 }finally{await browser.close()}
}
main().catch(e=>{console.error('ALTERNATIVE_AUTH_WINDOWS_E2E_FAILED',e.message);process.exit(1)});
