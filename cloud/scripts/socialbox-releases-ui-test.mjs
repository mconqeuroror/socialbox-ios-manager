// Built Next.js views with synthetic intercepted release APIs. Never production state.
import {createRequire} from 'node:module';
import {mkdir,writeFile} from 'node:fs/promises';
import assert from 'node:assert/strict';
import {SignJWT} from 'jose';

const require=createRequire(import.meta.url),{chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const origin=process.env.CLOUD_UI_ORIGIN||'http://127.0.0.1:32131';
assert.equal(new URL(origin).hostname,'127.0.0.1','UI tests must target the local synthetic server');
const output=process.env.CLOUD_UI_OUTPUT;assert(output,'CLOUD_UI_OUTPUT is required');await mkdir(output,{recursive:true});
const browser=await chromium.launch({headless:true,executablePath:process.env.CHROME_EXECUTABLE});
const completed=[],errors=[],unexpected=[];let posts=0,attests=0,releases=0,getRequests=0;
const check=async(name,run)=>{await run();completed.push(name);};
const at='2026-09-28T12:00:00.000Z';
const labels={backup_restore:'Backup and restore',upgrade_data:'Upgrade preserves data',launch_switch:'Launch and switch A → B → A',
  proxy_failure:'Proxy failure blocks direct fallback',license_activation:'Customer license activation'};
const observations=Object.fromEntries(Object.keys(labels).map(key=>[key,`PASS synthetic ${key}; predecessor .16; backup fixture-001; no actual device claim.`]));
const candidate=(sequence,blockers)=>({id:`socialbox-${sequence}`,sequence,packageVersion:`3.1.0-1+socialbox.${sequence}`,
  sha256:(sequence===16?'a':'b').repeat(64),size:48*1048576,architecture:'iphoneos-arm64',minimumIOS:'16.0',
  supportedFrom:[`3.1.0-1+socialbox.${sequence-1}`],notes:'Synthetic fixture: clearer navigation and update notices. No real package is published.',
  commit:'1'.repeat(40),artifactURL:null,blockers});
const blocked=candidate(16,['Storage transition and network isolation acceptance remain incomplete.']);
const ready=candidate(17,['Complete every device acceptance check for this exact package.']);
let state={id:'stable',revision:0,current:null,receipts:[],history:[]},failRelease=false,failRead=false;
try {
  const context=await browser.newContext({viewport:{width:1280,height:1100},colorScheme:'dark'});
  const token=await new SignJWT({sub:'fixture',role:'admin'}).setProtectedHeader({alg:'HS256'}).setExpirationTime('10m')
    .sign(new TextEncoder().encode(process.env.CLOUD_UI_JWT_SECRET||'synthetic-socialbox-admin-ui-2026'));
  await context.addCookies([{name:'socialbox_session',value:token,url:origin}]);
  // No remote request is allowed; all mutation routes below are intercepted.
  await context.route('**/*',route=>new URL(route.request().url()).origin===origin?route.continue():route.abort());
  await context.route('**/api/**',async route=>{
    const request=route.request(),pathname=new URL(request.url()).pathname;let body,status=200;
    if(pathname==='/api/auth/me')body={user:{id:'fixture',email:'fixture@invalid.test',role:'admin'}};
    else if(pathname==='/api/admin/releases'&&request.method()==='GET') {
      getRequests++;
      if(failRead){status=503;body={error:'Synthetic release service unavailable'};}
      else body={state,candidates:[blocked,ready]};
    } else if(pathname==='/api/admin/releases'&&request.method()==='POST') {
      posts++;const input=request.postDataJSON();
      assert.equal(input.candidateID,ready.id);assert.equal(input.sha256,ready.sha256);assert.equal(input.revision,state.revision);
      if(input.action==='attest') {
        attests++;assert.deepEqual(input.checks,observations);assert.deepEqual(Object.keys(input).sort(),['action','candidateID','checks','revision','sha256']);
        state={...state,revision:state.revision+1,receipts:[{candidateID:ready.id,sha256:ready.sha256,checks:input.checks,actor:'fixture',at}]};
        ready.blockers=[];body={state};
      } else if(input.action==='release') {
        releases++;assert.deepEqual(Object.keys(input).sort(),['action','candidateID','revision','sha256']);
        if(failRelease){status=409;body={error:'Release state changed. Refresh and review it again.'};}
        else {state={...state,revision:state.revision+1,current:ready.id,history:[{candidateID:ready.id,sha256:ready.sha256,actor:'fixture',at}]};body={state};}
      } else {unexpected.push(`POST ${input.action}`);status=400;body={error:'Unexpected synthetic action'};}
    } else {unexpected.push(`${request.method()} ${pathname}`);status=400;body={error:'Unexpected synthetic request'};}
    await route.fulfill({status,contentType:'application/json',body:JSON.stringify(body)});
  });
  const page=await context.newPage();page.on('pageerror',error=>errors.push(error.message));
  await page.goto(origin+'/admin/releases');await page.getByRole('heading',{name:'Test first. Release once.',exact:true}).waitFor();
  const blockedCard=page.locator('article').filter({has:page.getByRole('heading',{name:blocked.packageVersion,exact:true})});
  const readyCard=page.locator('article').filter({has:page.getByRole('heading',{name:ready.packageVersion,exact:true})});
  await readyCard.waitFor();
  await check('initial rendering performs reads but zero mutations',async()=>{assert.equal(posts,0);assert(getRequests>0);assert.equal(await page.locator('article').count(),2);});
  await check('engineering and missing-acceptance blockers disable Release',async()=>{assert(await blockedCard.getByRole('button',{name:'Release update',exact:true}).isDisabled());assert(await readyCard.getByRole('button',{name:'Release update',exact:true}).isDisabled());});
  await page.screenshot({path:output+'/releases-blocked-desktop.png',fullPage:true});
  await readyCard.getByRole('button',{name:'Record iPhone test',exact:true}).click();
  await check('opening acceptance form performs no mutation',async()=>{assert.equal(posts,0);assert.equal(await readyCard.getByRole('textbox').count(),5);});
  await readyCard.getByLabel(labels.backup_restore,{exact:true}).fill(observations.backup_restore);
  await readyCard.getByRole('button',{name:'Save passed test results',exact:true}).click();
  await check('incomplete acceptance form cannot submit',async()=>{assert.equal(posts,0);assert.equal(await readyCard.locator('form').evaluate(form=>form.checkValidity()),false);assert(await readyCard.getByRole('button',{name:'Release update',exact:true}).isDisabled());});
  for(const [key,label] of Object.entries(labels))if(key!=='backup_restore')await readyCard.getByLabel(label,{exact:true}).fill(observations[key]);
  await readyCard.getByRole('button',{name:'Save passed test results',exact:true}).click();
  await readyCard.getByText(/Device results recorded/).waitFor();
  await check('saving observed checks binds exact package hash and fields',async()=>{assert.equal(attests,1);assert.equal(posts,1);assert.deepEqual(state.receipts[0].checks,observations);assert.equal(await readyCard.locator('form').count(),0);assert(await readyCard.getByRole('button',{name:'Release update',exact:true}).isEnabled());});
  await check('passing another candidate does not clear engineering blocker',async()=>assert(await blockedCard.getByRole('button',{name:'Release update',exact:true}).isDisabled()));
  await readyCard.getByText('Exact package',{exact:true}).click();
  await check('review exposes immutable package hash before release',async()=>assert(await readyCard.getByText(`SHA-256 ${ready.sha256}`,{exact:true}).isVisible()));
  await page.screenshot({path:output+'/releases-ready-desktop.png',fullPage:true});
  await page.setViewportSize({width:375,height:812});
  await check('375px review layout has no horizontal overflow',async()=>assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false));
  await page.screenshot({path:output+'/releases-ready-mobile.png',fullPage:true});
  page.once('dialog',dialog=>dialog.dismiss());await readyCard.getByRole('button',{name:'Release update',exact:true}).click();
  await check('cancelled release confirmation performs no POST',async()=>{assert.equal(posts,1);assert.equal(releases,0);assert.equal(state.current,null);});
  failRelease=true;page.once('dialog',dialog=>dialog.accept());await readyCard.getByRole('button',{name:'Release update',exact:true}).click();
  await page.locator('main').getByRole('alert').getByText('Release state changed. Refresh and review it again.',{exact:true}).waitFor();
  await check('stale revision stays an error and does not appear published',async()=>{assert.equal(releases,1);assert.equal(state.current,null);assert.equal(state.history.length,0);assert.equal(await readyCard.getByText('Public',{exact:true}).count(),0);assert(await readyCard.getByRole('button',{name:'Release update',exact:true}).isEnabled());});
  await page.locator('main').getByRole('alert').getByRole('button',{name:'Refresh',exact:true}).click();await page.locator('main').getByRole('alert').waitFor({state:'detached'});
  failRelease=false;page.once('dialog',dialog=>{assert(dialog.message().includes(ready.packageVersion));dialog.accept();});
  await readyCard.getByRole('button',{name:'Release update',exact:true}).click();await readyCard.getByText('Public',{exact:true}).waitFor();
  await check('confirmed release publishes the exact reviewed artifact once',async()=>{assert.equal(releases,2);assert.equal(posts,3);assert.equal(state.current,ready.id);assert.equal(state.history.length,1);assert.equal(state.history[0].sha256,ready.sha256);assert.equal(await readyCard.getByRole('button',{name:'Release update',exact:true}).count(),0);});
  failRead=true;await page.reload();await page.locator('main').getByRole('alert').getByText('Synthetic release service unavailable',{exact:true}).waitFor();
  await check('read failure retains an explicit error instead of false success',async()=>{assert.equal(posts,3);assert.equal(await page.locator('article').count(),0);});
  failRead=false;await page.locator('main').getByRole('alert').getByRole('button',{name:'Refresh',exact:true}).click();await readyCard.getByText('Public',{exact:true}).waitFor();
  await check('refresh recovers the last confirmed release without a mutation',async()=>{assert.equal(posts,3);assert.equal(state.history.length,1);});
  await context.clearCookies();await page.goto(origin+'/admin/releases');await page.getByRole('button',{name:'Sign in',exact:true}).waitFor();
  await check('anonymous admin release navigation requires login',async()=>assert.equal(new URL(page.url()).pathname,'/login'));
  // This is the real built server-rendered empty /updates page, not a mocked page.
  await page.goto(origin+'/updates');await page.getByRole('heading',{name:'No public update yet',exact:true}).waitFor();
  await check('public empty release has no misleading installation controls',async()=>{assert.equal(new URL(page.url()).pathname,'/updates');assert.equal(await page.getByLabel('Sileo source',{exact:true}).count(),0);assert.equal(await page.getByRole('link',{name:'Repository signing key',exact:true}).count(),0);assert.equal(posts,3);});
  await check('375px public unavailable page has no horizontal overflow',async()=>assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false));
  await check('public support links to the configured owner',async()=>assert.equal(await page.getByRole('link',{name:'Contact @sctweaks ↗',exact:true}).getAttribute('href'),'https://t.me/sctweaks'));
  await page.screenshot({path:output+'/updates-unavailable-mobile.png',fullPage:true});
  await check('no runtime errors or unexpected API requests',async()=>{assert.deepEqual(errors,[]);assert.deepEqual(unexpected,[]);});
  const result={ok:true,checks:completed.length,completed,mockPOSTs:posts,mockAttests:attests,mockReleaseAttempts:releases,
    scope:'Real built Next.js UI. Admin release APIs intercepted with synthetic candidates. Public /updates is the real unavailable server page. No production mutations or device acceptance.'};
  await writeFile(output+'/result.json',JSON.stringify(result,null,2)+'\n');console.log(JSON.stringify(result,null,2));
} finally {await browser.close();}
