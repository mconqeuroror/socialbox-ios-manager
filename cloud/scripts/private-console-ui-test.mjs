// Starts the real production build with disposable users/keys. No production requests.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createRequire} from 'node:module';
import {spawn} from 'node:child_process';
const require=createRequire(import.meta.url),{chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright'),bcrypt=require('bcryptjs');
const cloud=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const scratch=await fs.mkdtemp(path.join(os.tmpdir(),'socialbox-private-console-ui-'));
const output=process.env.CLOUD_UI_OUTPUT;assert(output,'CLOUD_UI_OUTPUT required');await fs.mkdir(output,{recursive:true});
const origin='http://localhost:32139',password='synthetic-browser-password-only',at='2026-09-28T12:00:00.000Z';
const passwordHash=await bcrypt.hash(password,10);
const state={id:'auth-state',formatVersion:1,users:[{id:'owner',email:'owner@fixture.invalid',username:'owner',passwordHash,role:'admin',licensedAt:at,createdAt:at},
 {id:'other',email:'other@fixture.invalid',username:'other',passwordHash,role:'admin',licensedAt:at,createdAt:at}],
 licenses:Array.from({length:40},(_,i)=>({id:`key${i+1}`,keyHash:passwordHash,createdAt:at,activatedBy:null,activatedAt:null,revokedAt:null,expiresAt:null,
  kind:'device',ownerUserId:'owner',maxActivations:1,label:`Test phone ${String(i+1).padStart(2,'0')}`,note:'Synthetic test only',activations:[]})),devices:[],'pairing-codes':[]};
await fs.mkdir(path.join(scratch,'.data'));const statePath=path.join(scratch,'.data/auth-state.json');
await fs.writeFile(statePath,JSON.stringify({version:1,items:[state]}));
const env={...process.env,NODE_ENV:'production',JWT_SECRET:'synthetic-private-console-browser-secret',ADMIN_EMAIL:'owner@fixture.invalid',ADMIN_USERNAME:'owner',ADMIN_PASSWORD:password};
delete env.BLOB_READ_WRITE_TOKEN;delete env.BLOB_ACCESS;delete env.APT_BLOB_READ_WRITE_TOKEN;
const serverCode=`const {createRequire}=require('node:module');const req=createRequire(${JSON.stringify(path.join(cloud,'package.json'))});const next=req('next');const http=require('node:http');const app=next({dev:false,dir:${JSON.stringify(cloud)},hostname:'127.0.0.1',port:32139});app.prepare().then(()=>{http.createServer(app.getRequestHandler()).listen(32139,'127.0.0.1',()=>console.log('FIXTURE_READY'));}).catch(e=>{console.error(e);process.exit(1);});`;
const server=spawn(process.execPath,['-e',serverCode],{cwd:scratch,env,stdio:['ignore','pipe','pipe']});let serverLog='';
const ready=new Promise((resolve,reject)=>{const timeout=setTimeout(()=>reject(new Error('Fixture server startup timed out')),30000);server.stdout.on('data',chunk=>{serverLog+=chunk;if(serverLog.includes('FIXTURE_READY')){clearTimeout(timeout);resolve();}});server.stderr.on('data',chunk=>{serverLog+=chunk;});server.once('exit',code=>{clearTimeout(timeout);reject(new Error(`Fixture server exit ${code}: ${serverLog}`));});});
let browser,checks=0;const errors=[];
try{
 await ready;browser=await chromium.launch({headless:true,executablePath:process.env.CHROME_EXECUTABLE});
 const context=await browser.newContext({viewport:{width:1280,height:900},colorScheme:'dark',permissions:['clipboard-read','clipboard-write']});
 const page=await context.newPage();page.on('pageerror',error=>errors.push(error.message));
 const check=async(name,fn)=>{await fn();checks++;console.log(`PASS ${name}`);};
 await check('anonymous admin routes remain protected',async()=>{for(const url of ['/','/updates','/admin/releases']){await page.goto(origin+url);await page.getByRole('button',{name:'Sign in',exact:true}).waitFor();assert.equal(new URL(page.url()).pathname,'/login');}assert.equal(await page.getByText('Create account',{exact:true}).count(),0);});
 await check('client installation page is public and has no unapproved download',async()=>{await page.goto(origin+'/install');await page.getByRole('heading',{name:'Get SocialBox',exact:true}).waitFor();await page.getByRole('heading',{name:'Client build is being tested',exact:true}).waitFor();assert.equal(await page.locator('a[href^="sileo:"]').count(),0);assert.equal(await page.getByRole('link',{name:'Contact @sctweaks ↗',exact:true}).getAttribute('href'),'https://t.me/sctweaks');await page.screenshot({path:path.join(output,'client-install-pending.png')});await page.goto(origin+'/login');});
 await check('another administrator cannot use the owner browser sign-in',async()=>{await page.getByLabel('Username',{exact:true}).fill('other');await page.getByLabel('Password',{exact:true}).fill(password);await page.getByRole('button',{name:'Sign in',exact:true}).click();await page.getByRole('alert').getByText('Invalid username or password').waitFor();assert.equal(new URL(page.url()).pathname,'/login');});
 await check('owner existing credentials open 40 license records',async()=>{await page.getByLabel('Username',{exact:true}).fill('owner');await page.getByRole('button',{name:'Sign in',exact:true}).click();await page.getByRole('heading',{name:'License keys',exact:true}).waitFor();assert.equal(await page.locator('article').count(),40);assert.equal(await page.getByRole('link',{name:'App releases',exact:true}).count(),0);});
 await check('all secondary browser pages return to license-only console',async()=>{for(const url of ['/updates','/admin/releases','/apps/reddit']){await page.goto(origin+url);await page.getByRole('heading',{name:'License keys',exact:true}).waitFor();assert.equal(new URL(page.url()).pathname,'/admin');}});
 await check('license search binds right item among 40 records',async()=>{await page.getByRole('textbox',{name:'Search keys'}).fill('phone 40');assert.equal(await page.locator('article').count(),1);await page.getByRole('textbox',{name:'Search keys'}).fill('');});
 await check('owner creates one permanent single-device key',async()=>{
  await page.getByRole('button',{name:'+ Create key',exact:true}).click();await page.getByLabel('Name',{exact:true}).fill('Synthetic new phone');
  assert.equal(await page.getByLabel('Device limit',{exact:true}).count(),0);assert.equal(await page.getByLabel('Expires after (days)',{exact:true}).count(),0);
  await page.getByText('No expiry. One device. Enter the key once in the app; license checks continue.',{exact:true}).waitFor();
  await page.screenshot({path:path.join(output,'permanent-one-device-form.png')});
  await page.getByRole('button',{name:'Generate key',exact:true}).click();await page.getByRole('heading',{name:'Save your key',exact:true}).waitFor();
  await page.getByRole('heading',{name:'Synthetic new phone',exact:true}).waitFor();
  assert.equal(await page.locator('article').count(),41);assert(await page.getByRole('button',{name:'+ Create key',exact:true}).isDisabled());
  const saved=JSON.parse(await fs.readFile(statePath,'utf8')).items[0].licenses,created=saved.filter(row=>row.label==='Synthetic new phone');
  assert.equal(saved.length,41);assert.equal(created.length,1);assert.equal(created[0].kind,'device');assert.equal(created[0].expiresAt,null);assert.equal(created[0].maxActivations,1);assert.deepEqual(created[0].activations,[]);
  const key=(await page.getByRole('region',{name:'New keys',exact:true}).locator('code').textContent())?.trim();assert(key);assert(await bcrypt.compare(key,created[0].keyHash));
 });
 await check('generated key can be copied then cleared; no duplication',async()=>{await page.getByRole('button',{name:'Copy keys',exact:true}).click();await page.getByRole('button',{name:'Copied',exact:true}).waitFor();await page.getByRole('button',{name:'I saved my keys',exact:true}).click();assert.equal(await page.getByRole('region',{name:'New keys'}).count(),0);});
 await page.screenshot({path:path.join(output,'private-licenses-desktop.png')});
 await check('mobile 375px has no horizontal overflow',async()=>{await page.setViewportSize({width:375,height:812});assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);});
 await page.screenshot({path:path.join(output,'private-licenses-mobile.png')});
 await check('fresh role revocation rejects server-rendered page despite cached JWT',async()=>{const data=JSON.parse(await fs.readFile(statePath,'utf8'));data.items[0].users.find(user=>user.id==='owner').role='user';await fs.writeFile(statePath,JSON.stringify(data));await page.goto(origin+'/admin');await page.getByRole('button',{name:'Sign in',exact:true}).waitFor();assert.equal(new URL(page.url()).pathname,'/login');const denied=await context.request.get(origin+'/api/admin/licenses');assert.equal(denied.status(),403);});
 await check('machine update API remains public with no stable release',async()=>{const result=await context.request.get(origin+'/api/releases/socialbox/latest');assert.equal(result.status(),200);assert.equal((await result.json()).available,false);});
 assert.deepEqual(errors,[]);
 await fs.writeFile(path.join(output,'result.json'),JSON.stringify({ok:true,checks,scope:'Actual production build and API handlers, disposable synthetic owner and 40 keys; no production requests or mutations.'},null,2));
 console.log(`PASS ${checks} private-console production browser checks`);
}finally{await browser?.close();server.kill('SIGTERM');await fs.writeFile(path.join(output,'fixture-server.log'),serverLog);await fs.rm(scratch,{recursive:true,force:true});}
