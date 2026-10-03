const nodemailer = require('nodemailer');
const { authenticated } = require('../lib/email-relay-auth.cjs');
const used = new Map();
module.exports = async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  if (req.method !== 'POST') { res.setHeader('Allow', 'POST'); return res.status(405).json({error:'Method not allowed'}); }
  const envelope = req.body;
  if (!authenticated(envelope?.payload, req.headers['x-augment-signature'])) {
    return res.status(401).json({error:'Unauthorized'});
  }
  const message = JSON.parse(envelope.payload);
  if (typeof message.to !== 'string' || !/^[^\s@<>\r\n]+@[^\s@<>\r\n]+\.[^\s@<>\r\n]+$/.test(message.to) ||
      typeof message.subject !== 'string' || message.subject.length > 200 || /[\r\n]/.test(message.subject) ||
      typeof message.html !== 'string' || message.html.length > 16000 ||
      typeof message.text !== 'string' || message.text.length > 4000) {
    return res.status(400).json({error:'Invalid message'});
  }
  const now=Date.now();
  for (const [nonce,expiry] of used) if (expiry < now) used.delete(nonce);
  if (used.has(message.nonce)) return res.status(409).json({error:'Duplicate request'});
  const user=process.env.GMAIL_USER;
  const password=(process.env.GMAIL_APP_PASSWORD || '').replace(/\s/g,'');
  if (user !== 'evolveapporg@gmail.com' || !password) return res.status(503).json({error:'Email delivery is not configured'});
  used.set(message.nonce, now+120000);
  const transport=nodemailer.createTransport({host:'smtp.gmail.com',port:465,secure:true,
    auth:{user,pass:password},connectionTimeout:10000,greetingTimeout:10000,socketTimeout:20000});
  try {
    await transport.sendMail({from:{name:'Augment',address:user},to:message.to,
      subject:message.subject,html:message.html,text:message.text,
      disableFileAccess:true,disableUrlAccess:true});
    return res.status(200).json({success:true,provider:'gmail'});
  } catch (error) {
    console.error('Verification delivery failed',error.code || 'SMTP_ERROR');
    return res.status(502).json({error:'Verification email delivery failed'});
  } finally { transport.close(); }
};
