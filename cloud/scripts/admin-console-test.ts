/** Real owner gates and route handlers, with synthetic credentials/disposable storage. */
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { NextRequest } from 'next/server';
import { SignJWT } from 'jose';
import { middleware, config } from '../src/middleware';
import { adminPasswordFromEnv } from '../src/lib/admin';
import { adminEmailFromEnv, isConsoleOwner } from '../src/lib/console-owner';
import { getConsoleOwnerFromRequest, getConsoleOwnerFromToken } from '../src/lib/console-auth';
import { createSessionToken, hashPassword } from '../src/lib/auth';
import { getStorage, resetStorageAdapterForTests, type UserRecord } from '../src/lib/storage';
import * as login from '../src/app/api/auth/owner-login/route';
import * as appLogin from '../src/app/api/auth/login/route';
import * as register from '../src/app/api/auth/register/route';
import * as me from '../src/app/api/auth/me/route';
import * as licenses from '../src/app/api/admin/licenses/route';
import * as manage from '../src/app/api/admin/licenses/[id]/route';
import * as revoke from '../src/app/api/admin/licenses/[id]/revoke/route';
import * as users from '../src/app/api/admin/users/route';
import * as releases from '../src/app/api/admin/releases/route';
const secret='synthetic-owner-console-secret-only',origin='https://console.invalid';
let checks=0;
async function check(name:string,fn:()=>void|Promise<void>){await fn();checks++;console.log(`PASS ${name}`);}
async function main(){
 const previous=process.cwd(),scratch=await fs.mkdtemp(path.join(os.tmpdir(),'socialbox-owner-test-')),savedEnv={...process.env};
 process.chdir(scratch);delete process.env.BLOB_READ_WRITE_TOKEN;delete process.env.ADMIN_PASSWORD;
 process.env.JWT_SECRET=secret;process.env.ADMIN_EMAIL='owner@fixture.invalid';process.env.ADMIN_USERNAME='owner';resetStorageAdapterForTests();
 const request=(pathname:string,token?:string,body?:unknown,method=body===undefined?'GET':'POST',from=origin)=>new Request(origin+pathname,{
  method,headers:{origin:from,'content-type':'application/json',...(token?{cookie:`socialbox_session=${token}`}:{})},...(body===undefined?{}:{body:JSON.stringify(body)})});
 const run=(pathname:string,token?:string)=>middleware(new NextRequest(request(pathname,token)));
 try{
  const storage=getStorage(),passwordHash=await hashPassword('synthetic-password-only'),at=new Date().toISOString();
  const records:UserRecord[]=[
   {id:'owner',email:'owner@fixture.invalid',username:'owner',role:'admin',passwordHash,createdAt:at,licensedAt:at},
   {id:'other-admin',email:'someone@fixture.invalid',username:'someone',role:'admin',passwordHash,createdAt:at,licensedAt:at},
   {id:'customer',email:'customer@fixture.invalid',username:'customer',role:'user',passwordHash,createdAt:at,licensedAt:at}];
  await storage.writeCollection('users',records);
  const tokens=Object.fromEntries(await Promise.all(records.map(async user=>[user.id,await createSessionToken({...user,username:user.username!,licensed:true})]))),owner=tokens.owner;
  await check('owner policy binds canonical identity, not all administrators',()=>{
   assert(isConsoleOwner(records[0]));assert(!isConsoleOwner(records[1]));assert(!isConsoleOwner(records[2]));
   assert(!isConsoleOwner({email:records[0].email,role:'user'}));assert(!isConsoleOwner({email:'owner@another.invalid',role:'admin'}));
   process.env.ADMIN_EMAIL=' OWNER@FIXTURE.INVALID ';assert.equal(adminEmailFromEnv(),records[0].email);
   delete process.env.ADMIN_EMAIL;assert.equal(adminEmailFromEnv(),'owner@redditbox.local');process.env.ADMIN_EMAIL=records[0].email;assert.equal(adminPasswordFromEnv(),'');
  });
  await check('owner-only browser console; unrelated pages redirect to licenses',async()=>{
   for(const pathname of ['/','/admin','/admin/releases','/admin/unknown','/updates','/apps/reddit'])
    for(const token of [undefined,'invalid',tokens['other-admin'],tokens.customer])assert.equal((await run(pathname,token)).headers.get('location'),origin+'/login');
   const response=await run('/admin',owner);assert.equal(response.headers.get('location'),null);assert.equal(response.headers.get('cache-control'),'private, no-store');
   for(const pathname of ['/','/admin/releases','/admin/unknown','/updates','/apps/reddit'])assert.equal((await run(pathname,owner)).headers.get('location'),origin+'/admin');
   for(const token of [undefined,'invalid',owner,tokens.customer]) {
    const install=await run('/install',token);assert.equal(install.headers.get('location'),null);assert.equal(install.headers.get('cache-control'),'no-store');
   }
   assert(!config.matcher.some(pattern=>pattern.startsWith('/api')||pattern.startsWith('/apt')));
  });
  await check('login avoids stale-session loops; invalid signer denies; cached identity never authorizes',async()=>{
   for(const token of [owner,tokens.customer,'invalid'])assert.equal((await run('/login',token)).headers.get('location'),null);
   process.env.JWT_SECRET='short';assert.equal((await run('/admin',owner)).headers.get('location'),origin+'/login');process.env.JWT_SECRET=secret;
   const stale=await new SignJWT({sub:'other-admin',email:records[0].email,role:'admin'}).setProtectedHeader({alg:'HS256'}).setExpirationTime('5m').sign(new TextEncoder().encode(secret));
   assert.equal(await getConsoleOwnerFromToken(stale),null);
  });
  await check('all admin read/write handlers reject other admin before mutation',async()=>{
   const before=JSON.stringify(await storage.readAuthState());
   for(const token of [undefined,tokens['other-admin'],tokens.customer]){
    assert.equal(await getConsoleOwnerFromRequest(request('/api/admin/licenses',token)),null);
    for(const handler of [licenses.GET,users.GET,releases.GET])assert.equal((await handler(request('/api/admin/licenses',token))).status,403);
    for(const handler of [licenses.POST,releases.POST])assert.equal((await handler(request('/api/admin/licenses',token,{}))).status,403);
    const context={params:{id:'no-such-key'}};
    assert.equal((await manage.PATCH(request('/api/admin/licenses/no-such-key',token,{},'PATCH'),context)).status,403);
    assert.equal((await manage.DELETE(request('/api/admin/licenses/no-such-key',token,undefined,'DELETE'),context)).status,403);
    assert.equal((await revoke.POST(request('/api/admin/licenses/no-such-key/revoke',token,{}),context)).status,403);
   }
   assert.equal(JSON.stringify(await storage.readAuthState()),before);
  });
  await check('owner creates and lists licenses without exposing plaintext on list',async()=>{
   const created=await licenses.POST(request('/api/admin/licenses',owner,{label:'Synthetic phone'}));assert.equal(created.status,200);const body=await created.json();assert.equal(body.licenses.length,1);
   const listed=await licenses.GET(request('/api/admin/licenses',owner));assert.equal(listed.status,200);assert(!(await listed.text()).includes(body.licenses[0].key));
  });
  await check('fresh role demotion denies owner JWT for server pages and APIs',async()=>{
   await storage.mutateCollection<UserRecord>('users',rows=>rows.map(row=>row.id==='owner'?{...row,role:'user'}:row));
   assert.equal(await getConsoleOwnerFromToken(owner),null);assert.equal((await licenses.GET(request('/api/admin/licenses',owner))).status,403);
   await storage.mutateCollection<UserRecord>('users',rows=>rows.map(row=>row.id==='owner'?{...row,role:'admin'}:row));assert.equal((await getConsoleOwnerFromToken(owner))?.id,'owner');
  });
  await check('fresh identity change denies cached owner claims',async()=>{
   await storage.mutateCollection<UserRecord>('users',rows=>rows.map(row=>row.id==='owner'?{...row,email:'changed@fixture.invalid'}:row));assert.equal(await getConsoleOwnerFromToken(owner),null);
   await storage.mutateCollection<UserRecord>('users',rows=>rows.map(row=>row.id==='owner'?{...row,email:records[0].email}:row));
  });
  await check('browser sign-in rejects non-owner, malformed and cross-origin requests',async()=>{
   for(const username of ['someone','customer','unknown']){
    const response=await login.POST(request('/api/auth/owner-login',undefined,{username,password:'synthetic-password-only'}));assert.equal(response.status,401);assert.equal(response.headers.get('set-cookie'),null);
   }
   assert.equal((await login.POST(request('/api/auth/owner-login',undefined,{username:'owner',password:'wrong'}))).status,401);
   for(const body of [null,[],{username:1,password:'x'},{username:'owner',password:'x'.repeat(5000)}])assert.equal((await login.POST(request('/api/auth/owner-login',undefined,body))).status,400);
   assert.equal((await login.POST(request('/api/auth/owner-login',undefined,{username:'owner',password:'synthetic-password-only'},'POST','https://other.invalid'))).status,403);
  });
  await check('owner login keeps credentials, returns httpOnly cookie and no bearer token',async()=>{
   const before=JSON.stringify(await storage.readAuthState());
   const response=await login.POST(request('/api/auth/owner-login',undefined,{username:'OWNER',password:'synthetic-password-only'}));assert.equal(response.status,200);
   const body=await response.json();assert.equal(body.user.consoleOwner,true);assert.equal(body.token,undefined);assert(response.headers.get('set-cookie')?.includes('HttpOnly'));
   assert.equal(response.headers.get('cache-control'),'private, no-store');assert.equal(JSON.stringify(await storage.readAuthState()),before);
   assert.equal((await(await me.GET(request('/api/auth/me',owner))).json()).user.consoleOwner,true);
   assert.equal((await(await me.GET(request('/api/auth/me',tokens['other-admin']))).json()).user.consoleOwner,false);
  });
  await check('customer login/registration still work for app but cannot grant console',async()=>{
   const response=await appLogin.POST(request('/api/auth/login',undefined,{username:'customer',password:'synthetic-password-only'}));assert.equal(response.status,200);assert((await response.json()).token);
   const registered=await register.POST(request('/api/auth/register',undefined,{email:'new@fixture.invalid',password:'synthetic-password-only'}));assert.equal(registered.status,200);const body=await registered.json();assert.equal(body.user.role,'user');
   assert.equal(await getConsoleOwnerFromToken(body.token),null);assert.equal((await licenses.GET(request('/api/admin/licenses',body.token))).status,403);
  });
 }finally{resetStorageAdapterForTests();process.chdir(previous);await fs.rm(scratch,{recursive:true,force:true});for(const key of Object.keys(process.env))if(!(key in savedEnv))delete process.env[key];Object.assign(process.env,savedEnv);}
 console.log(`PASS ${checks} owner-only console groups; synthetic credentials and disposable storage only.`);
}
main().catch(error=>{console.error(error);process.exitCode=1;});
