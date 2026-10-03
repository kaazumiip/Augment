const assert=require('node:assert/strict');
const crypto=require('node:crypto');
const Module=require('node:module');
const {authenticated}=require('../landing/lib/email-relay-auth.cjs');
const keys=crypto.generateKeyPairSync('rsa',{modulusLength:2048});
const now=Date.now();
const message={audience:'augment-verification-email',timestamp:now,nonce:'a'.repeat(32)};
const payload=JSON.stringify(message);
const signature=crypto.sign('RSA-SHA256',Buffer.from(payload),keys.privateKey).toString('base64');
assert(authenticated(payload,signature,now,keys.publicKey));
assert(!authenticated(payload+' ',signature,now,keys.publicKey));
assert(!authenticated(payload,signature,now+61000,keys.publicKey));
assert(!authenticated('{}',signature,now,keys.publicKey));
assert(!authenticated(payload,'invalid',now,keys.publicKey));
let sent=0;
const load=Module._load;
Module._load=function(name,...args){
 if(name==='nodemailer')return {createTransport:()=>({sendMail:async()=>sent++,close:()=>{}})};
 return load.call(this,name,...args);
};
const handler=require('../landing/api/send-verification');
Module._load=load;
const response=()=>({setHeader(){},status(code){this.code=code;return this;},json(body){this.body=body;return this;}});
(async()=>{
 let res=response();await handler({method:'GET',headers:{}},res);assert.equal(res.code,405);
 res=response();await handler({method:'POST',headers:{},body:{payload}},res);assert.equal(res.code,401);
 assert.equal(sent,0);
 console.log('Signature, tampering, expiry, method and unauthorized-send checks passed.');
})().catch(error=>{console.error(error);process.exitCode=1});
