const express = require('express');
const multer = require('multer');
const path = require('path');
const axios = require('axios');
const FormData = require('form-data');
const fs = require('fs');
const { pipeline } = require('node:stream/promises');
const crypto = require('crypto');
const QRCode = require('qrcode');
const { createKHQR } = require('@manethpak/khqr-sdk');
require('dotenv').config({ path: path.join(__dirname, '..', '.env') });
const { cert, getApps, initializeApp } = require('firebase-admin/app');
const { getAuth } = require('firebase-admin/auth');
const { activePlan, generationUsage, validRedeemCode } = require('./plan_access');

const app = express();
const PORT = process.env.PORT || 3000;
// Node and Flask run on this same computer. Keep this local so a phone's
// Wi-Fi address can never make Node wait through unreachable Python hosts.
const PYTHON_BACKENDS = (process.env.PYTHON_BACKEND_URL || 'http://127.0.0.1:5000')
  .split(',').map(url => url.trim().replace(/\/$/, '')).filter(Boolean);
const generationJobs = new Map();
const generationQueue = [];
let activeGenerations = 0;
const configuredConcurrency = Number.parseInt(process.env.MAX_ACTIVE_GENERATIONS || '2', 10);
const MAX_ACTIVE_GENERATIONS = Number.isFinite(configuredConcurrency)
  ? Math.max(1, Math.min(2, configuredConcurrency)) : 2;

function drainGenerationQueue() {
  while (activeGenerations < MAX_ACTIVE_GENERATIONS && generationQueue.length) {
    generationQueue.sort((a, b) => b.priority - a.priority || a.queuedAt - b.queuedAt);
    const item = generationQueue.shift();
    activeGenerations += 1;
    try { item.onStart?.(); } catch (_) {}
    Promise.resolve().then(item.work).then(item.resolve, item.reject).finally(() => {
      activeGenerations -= 1;
      drainGenerationQueue();
    });
  }
}

function scheduleGeneration(plan, work, onStart) {
  if (generationQueue.length >= 50) return Promise.reject(new Error('Generation queue is full. Try again later.'));
  return new Promise((resolve, reject) => {
    generationQueue.push({ priority: plan === 'pro' ? 1 : 0,
      queuedAt: Date.now(), work, onStart, resolve, reject });
    drainGenerationQueue();
  });
}
const generatedRoot = path.join(__dirname, '..', 'data', 'generated');
const GENERATED_TTL_MS = 6 * 60 * 60 * 1000;
const usersFile = path.join(__dirname, '..', 'data', 'users.json');
const paymentsFile = path.join(__dirname, '..', 'data', 'payments.json');
const subscriptionsFile = path.join(__dirname, '..', 'data', 'subscriptions.json');
const generationUsageFile = path.join(__dirname, '..', 'data', 'generation-usage.json');
const redemptionsFile = path.join(__dirname, '..', 'data', 'plan-redemptions.json');
const generationReservations = new Map();
const sessions = new Map();
const firebaseServiceAccountFile = path.join(__dirname, '..', 'firebase-service-account.json');
let firebaseAuth = null;
let verificationSigningKey = null;

if (process.env.FIREBASE_SERVICE_ACCOUNT_JSON || fs.existsSync(firebaseServiceAccountFile)) {
  try {
    const serviceAccount = JSON.parse(process.env.FIREBASE_SERVICE_ACCOUNT_JSON ||
      fs.readFileSync(firebaseServiceAccountFile, 'utf8'));
    verificationSigningKey = serviceAccount.private_key;
    if (getApps().length === 0) {
      initializeApp({ credential: cert(serviceAccount) });
    }
    firebaseAuth = getAuth();
    console.log('[Firebase] Admin authentication is configured.');
  } catch (error) {
    console.error('[Firebase] Could not load the service account:', error.message);
  }
}

function readUsers() {
  try {
    return JSON.parse(fs.readFileSync(usersFile, 'utf8'));
  } catch (error) {
    if (error.code === 'ENOENT') return [];
    console.error('[Auth] Could not read user store:', error.message);
    return [];
  }
}

function writeUsers(users) {
  fs.mkdirSync(path.dirname(usersFile), { recursive: true });
  fs.writeFileSync(usersFile, JSON.stringify(users, null, 2));
}

function safeUser(user) {
  return { id: user.id, email: user.email, createdAt: user.createdAt };
}

function hashPassword(password, salt = crypto.randomBytes(16).toString('hex')) {
  return new Promise((resolve, reject) => {
    crypto.scrypt(password, salt, 64, (error, derivedKey) => {
      if (error) return reject(error);
      resolve({ salt, hash: derivedKey.toString('hex') });
    });
  });
}

function createSession(userId) {
  const token = crypto.randomBytes(32).toString('hex');
  sessions.set(token, { userId, createdAt: Date.now() });
  return token;
}

function getBearerToken(request) {
  const header = request.headers.authorization || '';
  return header.startsWith('Bearer ') ? header.slice(7) : null;
}

const PLAN_CATALOG = Object.freeze({
  plus: { amount: 2.99, currency: 'USD', label: 'Plus' },
  pro: { amount: 5.99, currency: 'USD', label: 'Pro' },
});
const paymentAttempts = new Map();
const verificationEmailAttempts = new Map();
const verificationEmailLastSent = new Map();
const passwordResetAttempts = new Map();
const passwordResetLastSent = new Map();
const emailVerificationCodes = new Map();
const passwordVerificationCodes = new Map();
const passwordChangeTokens = new Map();

const OTP_TTL_MS = 10 * 60 * 1000;
const PASSWORD_TOKEN_TTL_MS = 10 * 60 * 1000;
const OTP_MAX_ATTEMPTS = 5;

function codeDigest(purpose, subject, code) {
  const secret = process.env.OTP_SECRET || process.env.RESEND_API_KEY || 'augment-local-only';
  return crypto.createHmac('sha256', secret).update(`${purpose}:${subject}:${code}`).digest('hex');
}

function newVerificationCode(store, purpose, subject) {
  const code = crypto.randomInt(0, 1000000).toString().padStart(6, '0');
  store.set(subject, {
    digest: codeDigest(purpose, subject, code),
    expiresAt: Date.now() + OTP_TTL_MS,
    attempts: 0,
  });
  return code;
}

function consumeVerificationCode(store, purpose, subject, code) {
  const record = store.get(subject);
  if (!record || record.expiresAt < Date.now()) {
    store.delete(subject);
    return { ok: false, reason: 'expired' };
  }
  if (record.attempts >= OTP_MAX_ATTEMPTS) {
    store.delete(subject);
    return { ok: false, reason: 'attempts' };
  }
  record.attempts += 1;
  const supplied = Buffer.from(codeDigest(purpose, subject, code), 'hex');
  const expected = Buffer.from(record.digest, 'hex');
  const ok = supplied.length === expected.length && crypto.timingSafeEqual(supplied, expected);
  if (ok) store.delete(subject);
  return { ok, reason: ok ? null : 'invalid' };
}

function verificationEmailMarkup({ displayName, code, purpose }) {
  const isPassword = purpose === 'password';
  const heading = isPassword ? 'Change your password' : 'Verify your email';
  const instruction = isPassword
    ? 'Enter this code in Augment to continue changing your password.'
    : 'Enter this code in Augment to verify your email address.';
  const safeName = escapeHtml(displayName || 'Musician');
  return {
    subject: isPassword ? `${code} is your Augment password code` : `${code} is your Augment verification code`,
    text: `Hi ${displayName || 'Musician'},\n\n${instruction}\n\n${code}\n\nThis code expires in 10 minutes. Never share it with anyone.`,
    html: `<!doctype html>
<html><body style="margin:0;background:#fff9f5;font-family:Arial,sans-serif;color:#202020">
  <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="padding:32px 16px;background:#fff9f5">
    <tr><td align="center"><table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="max-width:520px;background:#fff;border:1px solid #eadfda;border-radius:18px;overflow:hidden">
      <tr><td style="height:8px;background:#ca000a"></td></tr>
      <tr><td style="padding:38px 34px">
        <div style="font-size:25px;font-weight:800;margin-bottom:24px">augment<span style="color:#ca000a">.</span></div>
        <h1 style="font-size:25px;line-height:1.2;margin:0 0 14px">${heading}</h1>
        <p style="font-size:15px;line-height:1.6;margin:0 0 22px">Hi ${safeName}, ${instruction}</p>
        <div style="font-size:34px;letter-spacing:10px;font-weight:800;color:#ca000a;background:#fff4f1;border-radius:12px;padding:18px 12px;text-align:center">${code}</div>
        <p style="font-size:12px;line-height:1.6;color:#777;margin:24px 0 0">This code expires in 10 minutes. Augment will never ask you to share it.</p>
      </td></tr>
    </table></td></tr>
  </table>
</body></html>`,
  };
}

function readPayments() {
  try {
    const data = JSON.parse(fs.readFileSync(paymentsFile, 'utf8'));
    return Array.isArray(data) ? data : [];
  } catch (error) {
    if (error.code === 'ENOENT') return [];
    console.error('[Payments] Could not read payment store:', error.message);
    return [];
  }
}

function writePayments(payments) {
  fs.mkdirSync(path.dirname(paymentsFile), { recursive: true });
  const temporaryFile = `${paymentsFile}.${crypto.randomUUID()}.tmp`;
  fs.writeFileSync(temporaryFile, JSON.stringify(payments, null, 2), { mode: 0o600 });
  fs.renameSync(temporaryFile, paymentsFile);
}

function readSubscriptions() {
  try {
    const data = JSON.parse(fs.readFileSync(subscriptionsFile, 'utf8'));
    return Array.isArray(data) ? data : [];
  } catch (error) {
    if (error.code === 'ENOENT') return [];
    console.error('[Billing] Could not read subscription store:', error.message);
    return [];
  }
}

function writeSubscriptions(subscriptions) {
  fs.mkdirSync(path.dirname(subscriptionsFile), { recursive: true });
  const temporaryFile = `${subscriptionsFile}.${crypto.randomUUID()}.tmp`;
  fs.writeFileSync(temporaryFile, JSON.stringify(subscriptions, null, 2), { mode: 0o600 });
  fs.renameSync(temporaryFile, subscriptionsFile);
}

function readPrivateList(file) {
  try {
    const value = JSON.parse(fs.readFileSync(file, 'utf8'));
    if (!Array.isArray(value)) throw new Error('Expected an array');
    return value;
  } catch (error) {
    if (error.code === 'ENOENT') return [];
    // Never reset a quota or one-use redemption store when it is corrupt.
    throw new Error(`Could not read plan access store: ${path.basename(file)}`);
  }
}

function writePrivateList(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temporary = `${file}.${crypto.randomUUID()}.tmp`;
  fs.writeFileSync(temporary, JSON.stringify(value, null, 2), { mode: 0o600 });
  fs.renameSync(temporary, file);
}

function userGenerationUsage(userId) {
  const subscription = readSubscriptions().find((item) => item.userId === userId);
  return generationUsage({ userId, subscription, usage: readPrivateList(generationUsageFile),
    reservations: generationReservations.get(userId) || 0 });
}

function reserveGeneration(userId) {
  const usage = userGenerationUsage(userId);
  if (usage.inProgress >= 1) return { error: 'A sheet generation is already running for this account.', status: 429, usage };
  if (usage.remaining !== null && usage.remaining <= 0) {
    return { error: `${usage.plan === 'free' ? 'Free' : 'Plus'} monthly sheet limit reached. Your allowance resets next month.`, status: 403, usage };
  }
  generationReservations.set(userId, usage.inProgress + 1);
  return { usage };
}

function finishGeneration(userId, month, succeeded) {
  const reserved = generationReservations.get(userId) || 0;
  if (reserved <= 1) generationReservations.delete(userId);
  else generationReservations.set(userId, reserved - 1);
  if (!succeeded) return;
  const rows = readPrivateList(generationUsageFile);
  const record = rows.find((row) => row.userId === userId && row.month === month);
  if (record) record.count = Math.max(0, Number(record.count) || 0) + 1;
  else rows.push({ userId, month, count: 1 });
  writePrivateList(generationUsageFile, rows);
}

function subscriptionStatus(subscription) {
  if (!subscription) return { plan: 'free', status: 'free', autoRenew: false, currentPeriodEnd: null, gracePeriodEnd: null };
  if (subscription.source === 'redeem' && subscription.permanent === true && subscription.plan === 'pro') {
    return { plan: 'pro', status: 'active', source: 'redeem', permanent: true,
      autoRenew: false, currentPeriodEnd: null, gracePeriodEnd: null };
  }
  const now = Date.now();
  const periodEnd = Date.parse(subscription.currentPeriodEnd);
  const gracePeriodEnd = Date.parse(subscription.gracePeriodEnd);
  return {
    plan: activePlan(subscription, now),
    status: now <= periodEnd ? 'active' : now <= gracePeriodEnd ? 'grace' : 'expired',
    autoRenew: subscription.autoRenew === true,
    currentPeriodEnd: subscription.currentPeriodEnd,
    gracePeriodEnd: subscription.gracePeriodEnd,
    source: subscription.source || 'payment', permanent: false,
  };
}

function limited(key, limit, windowMs) {
  const now = Date.now();
  const attempts = (paymentAttempts.get(key) || []).filter((time) => now - time < windowMs);
  if (attempts.length >= limit) return true;
  attempts.push(now);
  paymentAttempts.set(key, attempts);
  return false;
}

async function requirePaymentUser(req, res, next) {
  const token = getBearerToken(req);
  if (!token || !firebaseAuth) {
    return res.status(401).json({ error: 'Sign in with Firebase to use payments.' });
  }
  try {
    // Firebase ID tokens are short-lived and cryptographically verified here.
    // Revocation checks require an additional Google network request and made
    // checkout creation time out on mobile connections.
    const decoded = await firebaseAuth.verifyIdToken(token);
    req.paymentUserId = decoded.uid;
    next();
  } catch (_) {
    return res.status(401).json({ error: 'Your sign-in session is invalid or expired.' });
  }
}

async function requireFirebaseUser(req, res, next) {
  const token = getBearerToken(req);
  if (!token || !firebaseAuth) {
    return res.status(401).json({ error: 'Sign in to generate music sheets.' });
  }
  try {
    const decoded = await firebaseAuth.verifyIdToken(token);
    req.userId = decoded.uid;
    next();
  } catch (_) {
    return res.status(401).json({ error: 'Your sign-in session is invalid or expired.' });
  }
}

function safePathPart(value) {
  return String(value || '').replace(/[^A-Za-z0-9_-]/g, '_');
}

function collectArtifactNames(value, names = new Set()) {
  if (!value || typeof value !== 'object') return names;
  const artifactKeys = new Set([
    'output_file', 'pdf_file', 'audio_file', 'sheet_image', 'combined_musicxml',
  ]);
  for (const [key, child] of Object.entries(value)) {
    if (artifactKeys.has(key) && typeof child === 'string' && child) {
      names.add(path.basename(child));
    } else if (key === 'system_images' && Array.isArray(child)) {
      child.filter((item) => typeof item === 'string')
        .forEach((item) => names.add(path.basename(item)));
    } else if (child && typeof child === 'object') {
      collectArtifactNames(child, names);
    }
  }
  return names;
}

function rewriteArtifactNames(value, jobId) {
  if (!value || typeof value !== 'object') return value;
  const artifactKeys = new Set([
    'output_file', 'pdf_file', 'audio_file', 'sheet_image', 'combined_musicxml',
  ]);
  if (Array.isArray(value)) {
    return value.map((item) => rewriteArtifactNames(item, jobId));
  }
  const rewritten = {};
  for (const [key, child] of Object.entries(value)) {
    if (artifactKeys.has(key) && typeof child === 'string' && child) {
      rewritten[key] = `${jobId}--${path.basename(child)}`;
    } else if (key === 'system_images' && Array.isArray(child)) {
      rewritten[key] = child.map((item) =>
        typeof item === 'string' ? `${jobId}--${path.basename(item)}` : item);
    } else {
      rewritten[key] = child && typeof child === 'object'
        ? rewriteArtifactNames(child, jobId) : child;
    }
  }
  return rewritten;
}

async function storeArtifactsForUser(result, userId, jobId) {
  const pythonOutput = path.join(__dirname, '..', 'python', 'output');
  const destination = path.join(generatedRoot, safePathPart(userId), jobId);
  fs.mkdirSync(destination, { recursive: true });
  const artifactNames = [...collectArtifactNames(result)];
  for (const filename of artifactNames) {
    const source = path.join(pythonOutput, filename);
    const target = path.join(destination, filename);
    if (fs.existsSync(source) && fs.statSync(source).isFile()) {
      fs.copyFileSync(source, target);
      continue;
    }
    // Railway runs Python in a separate container. Its output directory is
    // not Node's filesystem: transfer the actual bytes before declaring a
    // generation complete or rewriting the filenames to user-owned paths.
    try {
      const response = await pythonRequest('get', `/api/sheet/download/${encodeURIComponent(filename)}`, {
        responseType: 'stream', timeout: 180000,
      });
      await pipeline(response.data, fs.createWriteStream(target));
    } catch (error) {
      // Unavailable optional PNG/PDF artifacts are sometimes listed even
      // when the renderer reports them unavailable. MusicXML is essential.
      if (error.response?.status === 404 && !/\.(musicxml|xml)$/i.test(filename)) {
        console.warn(`[Node] Optional generated artifact unavailable: ${filename}`);
        continue;
      }
      throw error;
    }
  }
  return rewriteArtifactNames(result, jobId);
}

function cleanExpiredGeneratedFiles() {
  if (!fs.existsSync(generatedRoot)) return;
  const cutoff = Date.now() - GENERATED_TTL_MS;
  for (const userEntry of fs.readdirSync(generatedRoot, { withFileTypes: true })) {
    if (!userEntry.isDirectory()) continue;
    const userDirectory = path.join(generatedRoot, userEntry.name);
    for (const jobEntry of fs.readdirSync(userDirectory, { withFileTypes: true })) {
      if (!jobEntry.isDirectory()) continue;
      const jobDirectory = path.join(userDirectory, jobEntry.name);
      if (fs.statSync(jobDirectory).mtimeMs < cutoff) {
        fs.rmSync(jobDirectory, { recursive: true, force: true });
      }
    }
    if (fs.readdirSync(userDirectory).length === 0) fs.rmdirSync(userDirectory);
  }
  for (const [jobId, job] of generationJobs) {
    if (job.createdAt < cutoff) generationJobs.delete(jobId);
  }
  for (const temporaryRoot of [
    path.join(__dirname, '..', 'python', 'output'),
    path.join(__dirname, '..', 'python', 'uploads'),
    path.join(__dirname, '..', 'uploads'),
  ]) {
    if (!fs.existsSync(temporaryRoot)) continue;
    for (const entry of fs.readdirSync(temporaryRoot, { withFileTypes: true })) {
      const entryPath = path.join(temporaryRoot, entry.name);
      if (fs.statSync(entryPath).mtimeMs < cutoff) {
        fs.rmSync(entryPath, { recursive: true, force: true });
      }
    }
  }
}

fs.mkdirSync(generatedRoot, { recursive: true });
cleanExpiredGeneratedFiles();
setInterval(cleanExpiredGeneratedFiles, 15 * 60 * 1000).unref();

function publicPayment(payment) {
  return {
    id: payment.id,
    kind: payment.kind || 'plan',
    plan: payment.plan || null,
    items: payment.kind === 'marketplace' ? payment.items || [] : undefined,
    amount: payment.amount,
    currency: payment.currency,
    status: payment.status,
    expiresAt: payment.expiresAt,
    paidAt: payment.paidAt || null,
    recipientName: process.env.BAKONG_MERCHANT_NAME || 'CHANMONYROTH HOUT',
    // This is deliberately exposed as state only. The app never receives the
    // transaction hash or the Bakong credential used to verify it.
    verificationUsed: payment.status === 'paid' || payment.status === 'expired',
    qrImage: payment.qrImage,
    paymentLink: payment.paymentLink || null,
  };
}

async function loadMarketplaceCart({ listingIds, buyerId }) {
  const url = (process.env.SUPABASE_URL || '').replace(/\/$/, '');
  const serviceKey = (process.env.SUPABASE_SERVICE_ROLE_KEY || '').trim();
  if (!url || !serviceKey) {
    throw new Error('Marketplace checkout is not configured. Set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY on the server.');
  }
  const uniqueIds = [...new Set(listingIds)];
  if (!uniqueIds.length || uniqueIds.length > 20 || uniqueIds.some((id) => !/^[0-9a-f-]{36}$/i.test(id))) {
    throw new Error('Your cart contains an invalid marketplace listing.');
  }
  const response = await axios.get(`${url}/rest/v1/market_listings`, {
    params: { select: 'id,owner_id,title,price,asset_url', id: `in.(${uniqueIds.join(',')})` },
    headers: { apikey: serviceKey, Authorization: `Bearer ${serviceKey}` },
    timeout: 10000,
  });
  const listings = Array.isArray(response.data) ? response.data : [];
  if (listings.length !== uniqueIds.length) throw new Error('One or more cart products are no longer available.');
  if (listings.some((listing) => listing.owner_id === buyerId)) {
    throw new Error('You cannot purchase your own marketplace listing.');
  }
  return listings;
}

async function createMarketplaceKhqr({ amount, id }) {
  const accountId = (process.env.BAKONG_ACCOUNT_ID || '').trim();
  if (!accountId) throw new Error('Bakong checkout is not configured. Set BAKONG_ACCOUNT_ID on the server.');
  const merchantId = (process.env.BAKONG_MERCHANT_ID || '').trim();
  const acquiringBank = (process.env.BAKONG_ACQUIRING_BANK || '').trim();
  const khqr = createKHQR({ baseURL: 'https://api-bakong.nbc.gov.kh' });
  const result = khqr.qr.generateKHQR({
    bakongAccountID: accountId,
    merchantName: process.env.BAKONG_MERCHANT_NAME || 'CHANMONYROTH HOUT',
    merchantCity: process.env.BAKONG_MERCHANT_CITY || 'Phnom Penh',
    currency: 'USD', amount,
    // Keep the cart and seller details in the server-side order. The KHQR
    // uses the same short payment fields as the working plan checkout.
    billNumber: `AUG-${id.replace(/-/g, '').slice(0, 18)}`,
    storeLabel: 'Augment', terminalLabel: 'Mobile',
    purposeOfTransaction: 'Marketplace',
    expirationTimestamp: Date.now() + 90 * 1000,
    ...(merchantId && acquiringBank ? { merchantID: merchantId, acquiringBank } : {}),
  });
  if (result.error || !result.result?.qr || !result.result?.md5) {
    throw new Error('KHQR generation failed. Check the merchant configuration.');
  }
  const qrImage = await QRCode.toDataURL(result.result.qr, { errorCorrectionLevel: 'M', margin: 2, width: 640 });
  let paymentLink = null;
  if (process.env.BAKONG_DEEPLINK_ENABLED === 'true' && (process.env.BAKONG_TOKEN || '').trim()) {
    try {
      const icon = String(process.env.BAKONG_DEEPLINK_APP_ICON_URL || 'https://evolve123.online/favicon.ico');
      const response = await axios.post('https://api-bakong.nbc.gov.kh/v1/generate_deeplink_by_qr', {
        qr: result.result.qr,
        sourceInfo: {
          appIconUrl: icon.startsWith('https://') ? icon : 'https://evolve123.online/favicon.ico',
          appName: process.env.BAKONG_DEEPLINK_APP_NAME || 'Augment',
          appDeepLinkCallback: 'augment://payment/callback',
        },
      }, { headers: { Authorization: `Bearer ${process.env.BAKONG_TOKEN}`, 'Content-Type': 'application/json' }, timeout: 10000, validateStatus: () => true });
      const candidate = response.data?.responseCode === 0 ? response.data?.data?.shortLink : null;
      if (typeof candidate === 'string') {
        const parsed = new URL(candidate);
        const host = parsed.hostname.toLowerCase();
        if (parsed.protocol === 'https:' && (host.endsWith('.nbc.gov.kh') || host === 'api-bakong.nbc.gov.kh')) paymentLink = candidate;
      }
    } catch (error) {
      console.warn('[Marketplace] Bakong deeplink unavailable:', error.message);
    }
  }
  return { md5: result.result.md5, qrImage, paymentLink };
}

function processingEstimate(job) {
  if (job.status !== 'processing') return job;
  const elapsedSeconds = (Date.now() - job.createdAt) / 1000;
  const phases = job.isVideo
    ? [
        [10, 'Extracting audio from video'], [35, 'Separating vocals and instruments'],
        [150, 'Transcribing notes to MIDI'], [300, 'Cleaning rhythm and engraving score'],
        [480, 'Rendering instrument playback'],
      ]
    : job.isSoloMelody
    ? [
        [8, 'Analyzing the song'], [22, 'Finding the main melody'],
        [95, 'Cleaning rhythm and engraving score'], [150, 'Rendering instrument playback'],
      ]
    : [
        [0, 'Separating vocals and instruments'],
        [120, 'Transcribing the main melody'],
        [260, 'Cleaning rhythm and engraving score'],
        [420, 'Rendering instrument playback'],
      ];
  let phaseIndex = phases.findIndex((phase, index) => {
    const next = phases[index + 1];
    return elapsedSeconds >= phase[0] && (!next || elapsedSeconds < next[0]);
  });
  if (phaseIndex < 0) phaseIndex = 0;
  const [start, stage] = phases[phaseIndex];
  const nextStart = phases[phaseIndex + 1]?.[0] || start + 300;
  const phaseProgress = Math.min(1, Math.max(0, (elapsedSeconds - start) / (nextStart - start)));
  const progress = Math.max(job.progress || 0,
    Math.min(95, Math.round(8 + phaseIndex * 20 + phaseProgress * 20)));
  // Keep the per-job high-water mark across status polls. This is still an
  // elapsed-time estimate, not measured model completion.
  job.progress = progress;
  return { ...job, stage, progress, progress_is_estimate: true };
}

app.disable('x-powered-by');
app.use(['/api/sheet/render-edited', '/api/sheet/preview-bar'], express.json({ limit: '3mb' }));
app.use(express.json({ limit: '32kb' }));

const allowedOrigins = new Set(
  (process.env.CORS_ORIGINS || 'http://localhost:3000,http://127.0.0.1:3000')
    .split(',').map((origin) => origin.trim()).filter(Boolean),
);
app.use((req, res, next) => {
  const origin = req.headers.origin;
  if (origin && allowedOrigins.has(origin)) res.header('Access-Control-Allow-Origin', origin);
  res.header('Vary', 'Origin');
  res.header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.header('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  if (req.method === 'OPTIONS') return res.sendStatus(200);
  next();
});

app.post('/api/auth/register', async (req, res) => {
  const email = String(req.body?.email || '').trim().toLowerCase();
  const password = String(req.body?.password || '');
  if (!/^\S+@\S+\.\S+$/.test(email)) {
    return res.status(400).json({ error: 'Enter a valid email address.' });
  }
  if (password.length < 8) {
    return res.status(400).json({ error: 'Password must be at least 8 characters.' });
  }

  try {
    const users = readUsers();
    if (users.some((user) => user.email === email)) {
      return res.status(409).json({ error: 'An account with this email already exists.' });
    }
    const { salt, hash } = await hashPassword(password);
    const user = {
      id: crypto.randomUUID(),
      email,
      passwordHash: hash,
      salt,
      createdAt: new Date().toISOString(),
    };
    users.push(user);
    writeUsers(users);
    return res.status(201).json({ token: createSession(user.id), user: safeUser(user) });
  } catch (error) {
    console.error('[Auth] Registration failed:', error.message);
    return res.status(500).json({ error: 'Unable to create your account right now.' });
  }
});

app.post('/api/auth/login', async (req, res) => {
  const email = String(req.body?.email || '').trim().toLowerCase();
  const password = String(req.body?.password || '');
  const user = readUsers().find((item) => item.email === email);
  if (!user) return res.status(401).json({ error: 'Email or password is incorrect.' });

  try {
    const { hash } = await hashPassword(password, user.salt);
    const expected = Buffer.from(user.passwordHash, 'hex');
    const supplied = Buffer.from(hash, 'hex');
    if (expected.length !== supplied.length || !crypto.timingSafeEqual(expected, supplied)) {
      return res.status(401).json({ error: 'Email or password is incorrect.' });
    }
    return res.json({ token: createSession(user.id), user: safeUser(user) });
  } catch (error) {
    console.error('[Auth] Login failed:', error.message);
    return res.status(500).json({ error: 'Unable to sign you in right now.' });
  }
});

app.get('/api/auth/me', (req, res) => {
  const session = sessions.get(getBearerToken(req));
  if (!session) return res.status(401).json({ error: 'Session expired. Please sign in again.' });
  const user = readUsers().find((item) => item.id === session.userId);
  if (!user) return res.status(401).json({ error: 'Session expired. Please sign in again.' });
  return res.json({ user: safeUser(user) });
});

app.post('/api/auth/logout', (req, res) => {
  const token = getBearerToken(req);
  if (token) sessions.delete(token);
  return res.status(204).send();
});

// Bakong's token is used only here on the server to verify the transaction.
// Amounts and plan names come from PLAN_CATALOG, never from the mobile client.
app.post('/api/payments/bakong/checkout', requirePaymentUser, async (req, res) => {
  const plan = String(req.body?.plan || '').toLowerCase();
  const product = PLAN_CATALOG[plan];
  if (!product) return res.status(400).json({ error: 'Choose a supported paid plan.' });
  const current = readSubscriptions().find((item) => item.userId === req.paymentUserId);
  if (current?.source === 'redeem' && current.permanent === true) {
    return res.status(409).json({ error: 'This account already has permanent Pro access.' });
  }
  if (limited(`checkout:${req.paymentUserId}`, 6, 60 * 60 * 1000)) {
    return res.status(429).json({ error: 'Too many checkout attempts. Please try again later.' });
  }

  const accountId = (process.env.BAKONG_ACCOUNT_ID || '').trim();
  if (!accountId) {
    return res.status(503).json({ error: 'Bakong checkout is not configured. Set BAKONG_ACCOUNT_ID on the server.' });
  }

  try {
    const id = crypto.randomUUID();
    const qrLifetimeMs = 90 * 1000;
    const expiresAt = new Date(Date.now() + qrLifetimeMs).toISOString();
    const optional = {
      currency: product.currency,
      amount: product.amount,
      billNumber: `AUG-${id.replace(/-/g, '').slice(0, 18)}`,
      storeLabel: 'Augment',
      terminalLabel: 'Mobile',
      purposeOfTransaction: `${product.label} plan`,
      expirationTimestamp: Date.now() + qrLifetimeMs,
    };
    const merchantId = (process.env.BAKONG_MERCHANT_ID || '').trim();
    const acquiringBank = (process.env.BAKONG_ACQUIRING_BANK || '').trim();
    const khqr = createKHQR({ baseURL: 'https://api-bakong.nbc.gov.kh' });
    const result = khqr.qr.generateKHQR({
      bakongAccountID: accountId,
      merchantName: process.env.BAKONG_MERCHANT_NAME || 'CHANMONYROTH HOUT',
      merchantCity: process.env.BAKONG_MERCHANT_CITY || 'Phnom Penh',
      ...optional,
      ...(merchantId && acquiringBank ? { merchantID: merchantId, acquiringBank } : {}),
    });
    if (result.error || !result.result?.qr || !result.result?.md5) {
      throw new Error('KHQR generation failed. Check the merchant configuration.');
    }
    const qrImage = await QRCode.toDataURL(result.result.qr, { errorCorrectionLevel: 'M', margin: 2, width: 640 });
    let paymentLink = null;
    const rawIcon = (process.env.BAKONG_DEEPLINK_APP_ICON_URL || '').trim();
    const deepLinkIconUrl = rawIcon.startsWith('https://') ? rawIcon : 'https://evolve123.online/favicon.ico';
    if (process.env.BAKONG_DEEPLINK_ENABLED === 'true') {
      try {
        const deepLinkResponse = await axios.post(
          'https://api-bakong.nbc.gov.kh/v1/generate_deeplink_by_qr',
          {
            qr: result.result.qr,
            sourceInfo: {
              appIconUrl: deepLinkIconUrl,
              appName: process.env.BAKONG_DEEPLINK_APP_NAME || 'Augment',
              // This is handled by the mobile app's registered URI scheme.
              // It only returns the customer to the open checkout; the server
              // still verifies the MD5 before it activates a plan.
              appDeepLinkCallback: 'augment://payment/callback',
            },
          },
          { headers: { Authorization: `Bearer ${process.env.BAKONG_TOKEN}`, 'Content-Type': 'application/json' }, timeout: 10000, validateStatus: () => true },
        );
        if (deepLinkResponse.status >= 200 && deepLinkResponse.status < 300 && deepLinkResponse.data?.responseCode === 0) {
          const candidate = deepLinkResponse.data?.data?.shortLink;
          // Validate all deep links before returning them to Flutter; accept HTTPS links from Bakong only.
          if (typeof candidate === 'string') {
            try {
              const parsed = new URL(candidate);
              const isHttps = parsed.protocol === 'https:';
              const hostname = parsed.hostname.toLowerCase();
              const isBakongDomain =
                hostname === 'bakong-deeplink.nbc.gov.kh' ||
                hostname === 'api-bakong.nbc.gov.kh' ||
                hostname.endsWith('.bakong.nbc.gov.kh') ||
                hostname.endsWith('.nbc.gov.kh');
              paymentLink = (isHttps && isBakongDomain) ? candidate : null;
            } catch (_) {
              paymentLink = null;
            }
          }
        }
      } catch (error) {
        console.warn('[Payments] Bakong deeplink unavailable:', error.message);
      }
    }
    const payments = readPayments();
    const payment = {
      id, userId: req.paymentUserId, plan, amount: product.amount, currency: product.currency,
      md5: result.result.md5, status: 'pending', createdAt: new Date().toISOString(), expiresAt, qrImage, paymentLink,
    };
    payments.push(payment);
    writePayments(payments);
    return res.status(201).json(publicPayment(payment));
  } catch (error) {
    console.error('[Payments] Unable to create Bakong checkout:', error.message);
    return res.status(502).json({ error: 'Unable to create the Bakong payment QR. Please try again.' });
  }
});

// The mobile client only submits listing IDs and quantities. Prices, titles,
// and seller IDs always come from Supabase on the server, so a modified app
// cannot lower the cart total before creating a KHQR payment.
app.post('/api/marketplace/checkout', requirePaymentUser, async (req, res) => {
  const requestedItems = Array.isArray(req.body?.items) ? req.body.items : [];
  if (!requestedItems.length || requestedItems.length > 20) {
    return res.status(400).json({ error: 'Choose one to twenty marketplace products.' });
  }
  if (limited(`marketplace-checkout:${req.paymentUserId}`, 6, 60 * 60 * 1000)) {
    return res.status(429).json({ error: 'Too many checkout attempts. Please try again later.' });
  }
  try {
    const quantities = new Map();
    for (const item of requestedItems) {
      const listingId = String(item?.listingId || '');
      const quantity = Number(item?.quantity || 0);
      if (!/^[0-9a-f-]{36}$/i.test(listingId) || !Number.isInteger(quantity) || quantity < 1 || quantity > 10) {
        return res.status(400).json({ error: 'Your cart has an invalid product or quantity.' });
      }
      quantities.set(listingId, (quantities.get(listingId) || 0) + quantity);
    }
    if ([...quantities.values()].some((quantity) => quantity > 10)) {
      return res.status(400).json({ error: 'A maximum of 10 copies per product is allowed.' });
    }
    const listings = await loadMarketplaceCart({ listingIds: [...quantities.keys()], buyerId: req.paymentUserId });
    const items = listings.map((listing) => {
      const unitPrice = Math.round(Number(listing.price) * 100) / 100;
      if (!Number.isFinite(unitPrice) || unitPrice < 0) throw new Error('A listing has an invalid price.');
      return {
        listingId: listing.id, sellerId: listing.owner_id, title: String(listing.title || 'Marketplace item').slice(0, 120),
        unitPrice, quantity: quantities.get(listing.id), assetUrl: listing.asset_url || null,
      };
    });
    const amount = Math.round(items.reduce((total, item) => total + item.unitPrice * item.quantity, 0) * 100) / 100;
    if (amount <= 0) return res.status(400).json({ error: 'Free products do not need checkout.' });
    const id = crypto.randomUUID();
    const khqr = await createMarketplaceKhqr({ amount, id });
    const payments = readPayments();
    const expiresAt = new Date(Date.now() + 90 * 1000).toISOString();
    const payment = {
      id, kind: 'marketplace', userId: req.paymentUserId, items,
      amount, currency: 'USD', md5: khqr.md5, status: 'pending',
      createdAt: new Date().toISOString(), expiresAt, qrImage: khqr.qrImage, paymentLink: khqr.paymentLink,
      sellerPayoutStatus: 'pending',
    };
    payments.push(payment);
    writePayments(payments);
    return res.status(201).json(publicPayment(payment));
  } catch (error) {
    console.error('[Marketplace] Unable to create checkout:', error.message);
    return res.status(502).json({ error: error.message || 'Unable to create the marketplace QR. Please try again.' });
  }
});

// Digital marketplace delivery is granted only after the Bakong verifier has
// changed the order to paid.  The response contains the immutable item
// snapshot stored with the order, so a buyer can still retrieve a purchase if
// a seller later edits or unlists the storefront card.
app.get('/api/marketplace/purchases', requirePaymentUser, (req, res) => {
  const purchases = readPayments()
    .filter((payment) =>
      payment.kind === 'marketplace' &&
      payment.userId === req.paymentUserId &&
      payment.status === 'paid' &&
      Array.isArray(payment.items))
    .flatMap((payment) => payment.items.map((item) => ({
      orderId: payment.id,
      paidAt: payment.paidAt || payment.createdAt,
      currency: payment.currency || 'USD',
      title: String(item.title || 'Marketplace item').slice(0, 120),
      listingId: item.listingId || null,
      quantity: Math.max(1, Number(item.quantity) || 1),
      assetUrl: typeof item.assetUrl === 'string' && item.assetUrl.startsWith('https://')
        ? item.assetUrl : null,
    })))
    .sort((a, b) => String(b.paidAt).localeCompare(String(a.paidAt)));
  return res.json({ purchases });
});

// Seller funds are deliberately kept as a request ledger.  A buyer pays
// Augment first, and an operator pays the seller to the payout destination
// they configured in the app.  This endpoint never exposes buyer details or
// pretends that a bank transfer happened automatically.
function marketplaceSellerSummary(sellerId) {
  const summary = {
    currency: 'USD',
    availableBalance: 0,
    payoutRequestedBalance: 0,
    paidOutBalance: 0,
    awaitingBuyerPaymentBalance: 0,
    sales: [],
  };
  for (const payment of readPayments()) {
    if (payment.kind !== 'marketplace' || !Array.isArray(payment.items)) continue;
    for (const item of payment.items) {
      if (String(item.sellerId || '') !== sellerId) continue;
      const amount = Math.round(Number(item.unitPrice || 0) * Number(item.quantity || 0) * 100) / 100;
      if (!Number.isFinite(amount) || amount <= 0) continue;
      let payoutStatus = 'awaiting_payment';
      if (payment.status === 'paid') {
        // Older local payment records predate per-seller payout states.  A
        // confirmed sale from one of those records is available to request.
        payoutStatus = payment.sellerPayouts?.[sellerId] ||
            (payment.sellerPayoutStatus === 'paid' ? 'paid' : 'available');
        if (payoutStatus === 'requested') summary.payoutRequestedBalance += amount;
        else if (payoutStatus === 'paid') summary.paidOutBalance += amount;
        else summary.availableBalance += amount;
      } else if (payment.status === 'pending') {
        summary.awaitingBuyerPaymentBalance += amount;
      }
      summary.sales.push({
        orderId: payment.id,
        listingId: item.listingId,
        title: String(item.title || 'Marketplace item').slice(0, 120),
        quantity: Number(item.quantity || 0),
        amount,
        orderStatus: payment.status || 'pending',
        payoutStatus,
        paidAt: payment.paidAt || null,
      });
    }
  }
  for (const key of ['availableBalance', 'payoutRequestedBalance', 'paidOutBalance', 'awaitingBuyerPaymentBalance']) {
    summary[key] = Math.round(summary[key] * 100) / 100;
  }
  summary.sales.sort((a, b) => String(b.paidAt || '').localeCompare(String(a.paidAt || '')));
  return summary;
}

app.get('/api/marketplace/seller/summary', requirePaymentUser, (req, res) => {
  return res.json(marketplaceSellerSummary(req.paymentUserId));
});

app.post('/api/marketplace/seller/request-payout', requirePaymentUser, (req, res) => {
  const payments = readPayments();
  let requested = 0;
  for (const payment of payments) {
    if (payment.kind !== 'marketplace' || payment.status !== 'paid' || !Array.isArray(payment.items)) continue;
    const sellerItems = payment.items.filter((item) => String(item.sellerId || '') === req.paymentUserId);
    if (!sellerItems.length) continue;
    payment.sellerPayouts = payment.sellerPayouts || {};
    const current = payment.sellerPayouts[req.paymentUserId] ||
        (payment.sellerPayoutStatus === 'paid' ? 'paid' : 'available');
    if (current !== 'available') continue;
    payment.sellerPayouts[req.paymentUserId] = 'requested';
    requested += sellerItems.reduce((total, item) => total + Number(item.unitPrice || 0) * Number(item.quantity || 0), 0);
  }
  if (requested <= 0) {
    return res.status(400).json({ error: 'There is no available seller balance to request.' });
  }
  writePayments(payments);
  return res.json({
    requestedAmount: Math.round(requested * 100) / 100,
    ...marketplaceSellerSummary(req.paymentUserId),
  });
});

app.post('/api/payments/bakong/:paymentId/verify', requirePaymentUser, async (req, res) => {
  const paymentId = String(req.params.paymentId || '');
  if (!/^[0-9a-f-]{36}$/i.test(paymentId)) return res.status(400).json({ error: 'Invalid payment reference.' });
  const payments = readPayments();
  const payment = payments.find((item) => item.id === paymentId && item.userId === req.paymentUserId);
  if (!payment) return res.status(404).json({ error: 'Payment not found.' });
  if (payment.status === 'paid') return res.json(publicPayment(payment));
  if (Date.parse(payment.expiresAt) <= Date.now()) {
    payment.status = 'expired';
    writePayments(payments);
    return res.json(publicPayment(payment));
  }
  if (!(process.env.BAKONG_TOKEN || '').trim()) {
    return res.status(503).json({ error: 'Bakong payment verification is not configured.' });
  }
  const checks = Number(payment.verificationChecks || 0);
  if (checks >= 12) {
    return res.status(429).json({
      ...publicPayment(payment),
      error: 'The automatic payment check limit was reached for this QR.',
    });
  }
  const lastCheck = Date.parse(payment.verificationAttemptedAt || '');
  if (Number.isFinite(lastCheck) && Date.now() - lastCheck < 15000) {
    return res.status(429).json({
      ...publicPayment(payment),
      error: 'Please wait before checking this payment again.',
    });
  }
  const dailyCutoff = Date.now() - 24 * 60 * 60 * 1000;
  const dailyChecks = payments.reduce((total, item) => total +
    (Array.isArray(item.verificationHistory)
      ? item.verificationHistory.filter((value) => Date.parse(value) >= dailyCutoff).length
      : (Date.parse(item.verificationAttemptedAt || '') >= dailyCutoff ? 1 : 0)), 0);
  if (dailyChecks >= 90) {
    return res.status(429).json({
      ...publicPayment(payment),
      error: 'The daily Bakong verification limit has been reached. Please try again later.',
    });
  }
  try {
    payment.verificationAttemptedAt = new Date().toISOString();
    payment.verificationChecks = checks + 1;
    payment.verificationHistory = [
      ...(Array.isArray(payment.verificationHistory) ? payment.verificationHistory : []),
      payment.verificationAttemptedAt,
    ];
    const response = await axios.post('https://api-bakong.nbc.gov.kh/v1/check_transaction_by_md5', { md5: payment.md5 }, {
      headers: { Authorization: `Bearer ${process.env.BAKONG_TOKEN}`, 'Content-Type': 'application/json' },
      timeout: 10000,
      validateStatus: () => true,
    });
    // A non-zero Bakong response is unpaid/unknown; it must never grant access.
    if (response.status >= 200 && response.status < 300 && response.data?.responseCode === 0) {
      payment.status = 'paid';
      payment.paidAt = new Date().toISOString();
      payment.providerReference = response.data?.data?.hash || null;
      if (payment.kind === 'marketplace') {
        // The buyer payment is confirmed, but sellers are paid later by the
        // Augment operator after the marketplace refund/dispute window.
        payment.orderStatus = 'paid';
        payment.sellerPayoutStatus = 'pending';
        payment.sellerPayouts = Object.fromEntries(
          [...new Set((payment.items || []).map((item) => String(item.sellerId || '')).filter(Boolean))]
            .map((sellerId) => [sellerId, 'available']),
        );
      } else {
        const subscriptions = readSubscriptions();
        const existingIndex = subscriptions.findIndex((item) => item.userId === req.paymentUserId);
        const existing = existingIndex >= 0 ? subscriptions[existingIndex] : null;
        // A QR created before code redemption can still settle later. Record
        // the payment, but never replace permanent Pro with that older plan.
        if (!(existing?.source === 'redeem' && existing.permanent === true)) {
          const now = Date.now();
          // Early renewal of the same plan extends remaining time.
          const startAt = existing?.plan === payment.plan && Date.parse(existing.currentPeriodEnd) > now
            ? Date.parse(existing.currentPeriodEnd) : now;
          const currentPeriodEnd = new Date(startAt + 30 * 24 * 60 * 60 * 1000).toISOString();
          const subscription = {
            userId: req.paymentUserId,
            plan: payment.plan,
            autoRenew: existing?.autoRenew !== false,
            currentPeriodEnd,
            gracePeriodEnd: new Date(Date.parse(currentPeriodEnd) + 3 * 24 * 60 * 60 * 1000).toISOString(),
            updatedAt: new Date().toISOString(),
          };
          if (existingIndex >= 0) subscriptions[existingIndex] = subscription;
          else subscriptions.push(subscription);
          payment.currentPeriodEnd = currentPeriodEnd;
          writeSubscriptions(subscriptions);
        }
      }
    }
    writePayments(payments);
    return res.json(publicPayment(payment));
  } catch (error) {
    console.error('[Payments] Bakong verification failed:', error.message);
    return res.status(502).json({ error: 'Unable to verify the payment right now. Please try again.' });
  }
});

app.get('/api/payments', requirePaymentUser, (req, res) => {
  let payments = readPayments().filter((payment) => payment.userId === req.paymentUserId);
  // A payment history is a receipt list. Pending/expired QR attempts are
  // still retained internally for verification, but are not transactions.
  if (req.query.status === 'paid') {
    payments = payments.filter((payment) => payment.status === 'paid');
  }
  return res.json({ payments: payments.map(publicPayment).reverse() });
});

app.get('/api/billing/subscription', requirePaymentUser, (req, res) => {
  const subscription = readSubscriptions().find((item) => item.userId === req.paymentUserId);
  return res.json(subscriptionStatus(subscription));
});

app.get('/api/billing/usage', requirePaymentUser, (req, res) => {
  try {
    return res.json(userGenerationUsage(req.paymentUserId));
  } catch (error) {
    console.error('[Billing] Usage unavailable:', error.message);
    return res.status(503).json({ error: 'Plan usage is temporarily unavailable.' });
  }
});

app.post('/api/billing/redeem', requirePaymentUser, (req, res) => {
  if (limited(`redeem:${req.paymentUserId}`, 5, 60 * 60 * 1000)) {
    return res.status(429).json({ error: 'Too many code attempts. Try again in an hour.' });
  }
  if (!validRedeemCode(req.body?.code, process.env.AUGMENT_VIP_REDEEM_CODE || 'AugmentVip')) {
    return res.status(400).json({ error: 'That redeem code is not valid.' });
  }
  try {
    const redemptions = readPrivateList(redemptionsFile);
    if (redemptions.some((item) => item.userId === req.paymentUserId)) {
      return res.status(409).json({ error: 'This account has already redeemed AugmentVip.' });
    }
    const subscriptions = readPrivateList(subscriptionsFile);
    const index = subscriptions.findIndex((item) => item.userId === req.paymentUserId);
    if (index >= 0 && subscriptions[index].source === 'redeem' && subscriptions[index].permanent === true) {
      return res.json(subscriptionStatus(subscriptions[index]));
    }
    const now = new Date().toISOString();
    const subscription = { userId: req.paymentUserId, plan: 'pro', source: 'redeem',
      permanent: true, autoRenew: false, currentPeriodEnd: null,
      gracePeriodEnd: null, updatedAt: now };
    if (index >= 0) subscriptions[index] = subscription;
    else subscriptions.push(subscription);
    writeSubscriptions(subscriptions);
    redemptions.push({ userId: req.paymentUserId, redeemedAt: now, codeId: 'augment-vip' });
    writePrivateList(redemptionsFile, redemptions);
    return res.json(subscriptionStatus(subscription));
  } catch (error) {
    console.error('[Billing] Redeem failed:', error.message);
    return res.status(503).json({ error: 'Redeeming is temporarily unavailable. Please try again.' });
  }
});

// Bakong QR requires customer confirmation each cycle. This preference controls
// renewal reminders and whether the account should prompt for a fresh QR.
app.post('/api/billing/subscription/auto-renew', requirePaymentUser, (req, res) => {
  if (typeof req.body?.autoRenew !== 'boolean') {
    return res.status(400).json({ error: 'autoRenew must be true or false.' });
  }
  const subscriptions = readSubscriptions();
  const index = subscriptions.findIndex((item) => item.userId === req.paymentUserId);
  if (index < 0 || subscriptionStatus(subscriptions[index]).plan === 'free') {
    return res.status(404).json({ error: 'There is no active subscription to update.' });
  }
  if (subscriptions[index].source === 'redeem' && subscriptions[index].permanent === true) {
    return res.status(409).json({ error: 'Redeemed Pro has no renewal to change.' });
  }
  subscriptions[index].autoRenew = req.body.autoRenew;
  subscriptions[index].updatedAt = new Date().toISOString();
  writeSubscriptions(subscriptions);
  return res.json(subscriptionStatus(subscriptions[index]));
});

// Firebase users need this claim for Supabase Third-Party Auth to map them to
// Postgres' authenticated role. The client refreshes its Firebase token after
// this endpoint reports an update.
app.post('/api/auth/supabase-role', async (req, res) => {
  if (!firebaseAuth) {
    return res.status(503).json({ error: 'Firebase Admin is not configured on the server.' });
  }
  const token = getBearerToken(req);
  if (!token) return res.status(401).json({ error: 'A Firebase ID token is required.' });

  try {
    const decoded = await firebaseAuth.verifyIdToken(token);
    const user = await firebaseAuth.getUser(decoded.uid);
    const claims = user.customClaims || {};
    if (claims.role === 'authenticated') {
      return res.json({ roleUpdated: false });
    }
    await firebaseAuth.setCustomUserClaims(decoded.uid, { ...claims, role: 'authenticated' });
    return res.json({ roleUpdated: true });
  } catch (error) {
    console.error('[Firebase] Failed to sync Supabase role:', error.message);
    return res.status(401).json({ error: 'Unable to verify your Firebase session.' });
  }
});

function escapeHtml(value) {
  return String(value || '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#039;');
}

async function sendResendEmail({ to, subject, html, text }) {
  const resendKey = process.env.RESEND_API_KEY;
  const from = process.env.RESEND_FROM_EMAIL;
  if (!resendKey || !from) {
    const error = new Error('Branded email is not configured.');
    error.code = 'EMAIL_NOT_CONFIGURED';
    throw error;
  }
  await axios.post(
    'https://api.resend.com/emails',
    { from, to: [to], subject, html, text },
    {
      headers: { Authorization: `Bearer ${resendKey}`, 'Content-Type': 'application/json' },
      timeout: 10000,
    },
  );
}

async function sendVerificationEmail({ to, subject, html, text }) {
  if (!verificationSigningKey) throw new Error('Verification email signing is not configured.');
  const payload = JSON.stringify({ audience: 'augment-verification-email',
    timestamp: Date.now(), nonce: crypto.randomBytes(16).toString('hex'),
    to, subject, html, text });
  const signature = crypto.sign('RSA-SHA256', Buffer.from(payload), verificationSigningKey).toString('base64');
  await axios.post('https://augment-landing.vercel.app/api/send-verification', { payload }, {
    headers: { 'x-augment-signature': signature }, timeout: 30000,
  });
}

app.post('/api/auth/send-verification-code', async (req, res) => {
  if (!firebaseAuth) return res.status(503).json({ error: 'Firebase Admin is not configured.' });
  const token = getBearerToken(req);
  if (!token) return res.status(401).json({ error: 'A Firebase ID token is required.' });

  try {
    const decoded = await firebaseAuth.verifyIdToken(token);
    const user = await firebaseAuth.getUser(decoded.uid);
    if (!user.email) return res.status(400).json({ error: 'This account has no email address.' });
    if (user.emailVerified) return res.json({ sent: false, alreadyVerified: true });

    const now = Date.now();
    const lastSent = verificationEmailLastSent.get(user.uid) || 0;
    const cooldownMs = 60 * 1000;
    if (now - lastSent < cooldownMs) {
      return res.status(429).json({
        error: 'Please wait before requesting another code.',
        retryAfter: Math.ceil((cooldownMs - (now - lastSent)) / 1000),
      });
    }
    if (limited(`verify:${user.uid}`, 3, 60 * 60 * 1000)) {
      return res.status(429).json({ error: 'Too many codes requested. Try again in an hour.' });
    }

    const code = newVerificationCode(emailVerificationCodes, 'email', user.uid);
    const message = verificationEmailMarkup({
      displayName: user.displayName || user.email.split('@')[0],
      code,
      purpose: 'email',
    });
    try {
      await sendVerificationEmail({ to: user.email, ...message });
    } catch (error) {
      emailVerificationCodes.delete(user.uid);
      throw error;
    }
    verificationEmailLastSent.set(user.uid, now);
    return res.json({ sent: true, expiresIn: OTP_TTL_MS / 1000 });
  } catch (error) {
    console.error('[Email] Verification code failed:', error.response?.data?.message || error.message);
    return res.status(502).json({ error: 'Unable to send the verification code right now.' });
  }
});

app.post('/api/auth/verify-email-code', async (req, res) => {
  if (!firebaseAuth) return res.status(503).json({ error: 'Firebase Admin is not configured.' });
  const token = getBearerToken(req);
  const code = String(req.body?.code || '').trim();
  if (!token) return res.status(401).json({ error: 'A Firebase ID token is required.' });
  if (!/^\d{6}$/.test(code)) return res.status(400).json({ error: 'Enter the six-digit code.' });

  try {
    const decoded = await firebaseAuth.verifyIdToken(token);
    const result = consumeVerificationCode(emailVerificationCodes, 'email', decoded.uid, code);
    if (!result.ok) {
      return res.status(400).json({
        error: result.reason === 'expired'
          ? 'This code has expired. Request a new one.'
          : result.reason === 'attempts'
            ? 'Too many incorrect attempts. Request a new code.'
            : 'That code is incorrect. Please try again.',
      });
    }
    await firebaseAuth.updateUser(decoded.uid, { emailVerified: true });
    return res.json({ verified: true });
  } catch (error) {
    console.error('[Email] Code verification failed:', error.message);
    return res.status(502).json({ error: 'Unable to verify the code right now.' });
  }
});

app.post('/api/auth/send-password-code', async (req, res) => {
  if (!firebaseAuth) return res.status(503).json({ error: 'Firebase Admin is not configured.' });
  const email = String(req.body?.email || '').trim().toLowerCase();
  if (!/^\S+@\S+\.\S+$/.test(email)) return res.status(400).json({ error: 'Enter a valid email address.' });

  const now = Date.now();
  const key = crypto.createHash('sha256').update(email).digest('hex');
  const lastSent = passwordResetLastSent.get(key) || 0;
  if (now - lastSent < 60 * 1000) {
    return res.status(429).json({
      error: 'Please wait before requesting another code.',
      retryAfter: Math.ceil((60 * 1000 - (now - lastSent)) / 1000),
    });
  }
  if (limited(`password:${key}`, 3, 60 * 60 * 1000)) {
    return res.status(429).json({ error: 'Too many codes requested. Try again in an hour.' });
  }

  // Always return the same result so this endpoint cannot reveal registered emails.
  try {
    const user = await firebaseAuth.getUserByEmail(email);
    const code = newVerificationCode(passwordVerificationCodes, 'password', key);
    const message = verificationEmailMarkup({
      displayName: user.displayName || email.split('@')[0],
      code,
      purpose: 'password',
    });
    await sendVerificationEmail({ to: email, ...message });
    passwordResetLastSent.set(key, now);
  } catch (error) {
    if (error.code !== 'auth/user-not-found') {
      console.error('[Email] Password code failed:', error.response?.data?.message || error.message);
    }
  }
  return res.json({ sent: true, expiresIn: OTP_TTL_MS / 1000 });
});

app.post('/api/auth/verify-password-code', async (req, res) => {
  const email = String(req.body?.email || '').trim().toLowerCase();
  const code = String(req.body?.code || '').trim();
  if (!/^\S+@\S+\.\S+$/.test(email) || !/^\d{6}$/.test(code)) {
    return res.status(400).json({ error: 'Enter the six-digit code.' });
  }
  const key = crypto.createHash('sha256').update(email).digest('hex');
  const result = consumeVerificationCode(passwordVerificationCodes, 'password', key, code);
  if (!result.ok) {
    return res.status(400).json({
      error: result.reason === 'expired'
        ? 'This code has expired. Request a new one.'
        : result.reason === 'attempts'
          ? 'Too many incorrect attempts. Request a new code.'
          : 'That code is incorrect. Please try again.',
    });
  }
  try {
    const user = await firebaseAuth.getUserByEmail(email);
    const resetToken = crypto.randomBytes(32).toString('base64url');
    const tokenDigest = crypto.createHash('sha256').update(resetToken).digest('hex');
    passwordChangeTokens.set(tokenDigest, {
      uid: user.uid,
      expiresAt: Date.now() + PASSWORD_TOKEN_TTL_MS,
    });
    return res.json({ verified: true, resetToken });
  } catch (_) {
    return res.status(400).json({ error: 'That code is no longer valid.' });
  }
});

app.post('/api/auth/change-password-with-code', async (req, res) => {
  if (!firebaseAuth) return res.status(503).json({ error: 'Firebase Admin is not configured.' });
  const resetToken = String(req.body?.resetToken || '');
  const newPassword = String(req.body?.newPassword || '');
  if (newPassword.length < 8 || newPassword.length > 128) {
    return res.status(400).json({ error: 'Use a password between 8 and 128 characters.' });
  }
  const tokenDigest = crypto.createHash('sha256').update(resetToken).digest('hex');
  const record = passwordChangeTokens.get(tokenDigest);
  if (!record || record.expiresAt < Date.now()) {
    passwordChangeTokens.delete(tokenDigest);
    return res.status(400).json({ error: 'This password session expired. Request a new code.' });
  }
  passwordChangeTokens.delete(tokenDigest);
  try {
    await firebaseAuth.updateUser(record.uid, { password: newPassword });
    await firebaseAuth.revokeRefreshTokens(record.uid);
    return res.json({ changed: true });
  } catch (error) {
    console.error('[Email] Password change failed:', error.message);
    return res.status(502).json({ error: 'Unable to change the password right now.' });
  }
});

app.post('/api/auth/send-verification-email', async (req, res) => {
  if (!firebaseAuth) {
    return res.status(503).json({ error: 'Firebase Admin is not configured on the server.' });
  }

  const token = getBearerToken(req);
  if (!token) return res.status(401).json({ error: 'A Firebase ID token is required.' });

  try {
    const decoded = await firebaseAuth.verifyIdToken(token);
    const user = await firebaseAuth.getUser(decoded.uid);
    if (!user.email) return res.status(400).json({ error: 'This account has no email address.' });
    if (user.emailVerified) return res.json({ sent: false, alreadyVerified: true });

    const now = Date.now();
    const lastSent = verificationEmailLastSent.get(user.uid) || 0;
    const cooldownMs = 60 * 1000;
    if (now - lastSent < cooldownMs) {
      return res.status(429).json({
        error: 'Please wait before requesting another verification email.',
        retryAfter: Math.ceil((cooldownMs - (now - lastSent)) / 1000),
      });
    }
    if (limited(`verify:${user.uid}`, 3, 60 * 60 * 1000)) {
      return res.status(429).json({
        error: 'Too many verification emails requested. Try again in an hour.',
        retryAfter: 3600,
      });
    }

    if (!process.env.RESEND_API_KEY || !process.env.RESEND_FROM_EMAIL) {
      return res.status(503).json({ error: 'Branded verification email is not configured.' });
    }

    const actionSettings = process.env.EMAIL_VERIFICATION_CONTINUE_URL
      ? { url: process.env.EMAIL_VERIFICATION_CONTINUE_URL, handleCodeInApp: false }
      : undefined;
    const verificationLink = await firebaseAuth.generateEmailVerificationLink(
      user.email,
      actionSettings,
    );
    const displayName = escapeHtml(user.displayName || user.email.split('@')[0] || 'Musician');
    const safeLink = escapeHtml(verificationLink);
    const subject = 'Verify your Augment email';
    const text = [
      `Hi ${user.displayName || 'Musician'},`,
      '',
      'Verify your email address to finish securing your Augment account:',
      verificationLink,
      '',
      'If you did not create this account, you can ignore this email.',
    ].join('\n');
    const html = `<!doctype html>
<html><body style="margin:0;background:#fff9f5;font-family:Arial,sans-serif;color:#202020">
  <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="padding:32px 16px;background:#fff9f5">
    <tr><td align="center">
      <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="max-width:520px;background:#ffffff;border:1px solid #eadfda;border-radius:18px;overflow:hidden">
        <tr><td style="height:8px;background:#ca000a"></td></tr>
        <tr><td style="padding:38px 34px">
          <div style="font-size:25px;font-weight:800;margin-bottom:24px">augment<span style="color:#ca000a">.</span></div>
          <h1 style="font-size:25px;line-height:1.2;margin:0 0 14px">Verify your email</h1>
          <p style="font-size:15px;line-height:1.6;margin:0 0 22px">Hi ${displayName}, verify your email address to finish securing your Augment account.</p>
          <a href="${safeLink}" style="display:inline-block;background:#ca000a;color:#ffffff;text-decoration:none;font-size:14px;font-weight:700;padding:14px 22px;border-radius:10px">Verify email address</a>
          <p style="font-size:12px;line-height:1.6;color:#777;margin:26px 0 0">If you did not create this account, you can safely ignore this email.</p>
        </td></tr>
      </table>
    </td></tr>
  </table>
</body></html>`;

    await sendResendEmail({ to: user.email, subject, html, text });
    verificationEmailLastSent.set(user.uid, now);
    return res.json({ sent: true });
  } catch (error) {
    const detail = error.response?.data?.message || error.message;
    console.error('[Email] Verification email failed:', detail);
    if (error.code === 'auth/invalid-continue-uri' || error.code === 'auth/unauthorized-continue-uri') {
      return res.status(500).json({ error: 'The verification return URL is not authorized in Firebase.' });
    }
    return res.status(502).json({ error: 'Unable to send the verification email right now.' });
  }
});

app.post('/api/auth/send-password-reset', async (req, res) => {
  if (!firebaseAuth) {
    return res.status(503).json({ error: 'Firebase Admin is not configured on the server.' });
  }
  const token = getBearerToken(req);
  if (!token) return res.status(401).json({ error: 'A Firebase ID token is required.' });

  try {
    const decoded = await firebaseAuth.verifyIdToken(token);
    const user = await firebaseAuth.getUser(decoded.uid);
    if (!user.email) return res.status(400).json({ error: 'This account has no email address.' });

    const now = Date.now();
    const lastSent = passwordResetLastSent.get(user.uid) || 0;
    const cooldownMs = 60 * 1000;
    if (now - lastSent < cooldownMs) {
      return res.status(429).json({
        error: 'Please wait before requesting another password email.',
        retryAfter: Math.ceil((cooldownMs - (now - lastSent)) / 1000),
      });
    }
    if (limited(`password:${user.uid}`, 3, 60 * 60 * 1000)) {
      return res.status(429).json({
        error: 'Too many password emails requested. Try again in an hour.',
        retryAfter: 3600,
      });
    }
    if (!process.env.RESEND_API_KEY || !process.env.RESEND_FROM_EMAIL) {
      return res.status(503).json({ error: 'Branded password email is not configured.' });
    }

    const actionSettings = process.env.PASSWORD_RESET_CONTINUE_URL
      ? { url: process.env.PASSWORD_RESET_CONTINUE_URL, handleCodeInApp: false }
      : undefined;
    const resetLink = await firebaseAuth.generatePasswordResetLink(user.email, actionSettings);
    const displayName = escapeHtml(user.displayName || user.email.split('@')[0] || 'Musician');
    const safeLink = escapeHtml(resetLink);
    const subject = 'Reset your Augment password';
    const text = [
      `Hi ${user.displayName || 'Musician'},`,
      '',
      'Use this secure link to reset your Augment password:',
      resetLink,
      '',
      'If you did not request this change, you can ignore this email.',
    ].join('\n');
    const html = `<!doctype html>
<html><body style="margin:0;background:#fff9f5;font-family:Arial,sans-serif;color:#202020">
  <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="padding:32px 16px;background:#fff9f5">
    <tr><td align="center">
      <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="max-width:520px;background:#ffffff;border:1px solid #eadfda;border-radius:18px;overflow:hidden">
        <tr><td style="height:8px;background:#ca000a"></td></tr>
        <tr><td style="padding:38px 34px">
          <div style="font-size:25px;font-weight:800;margin-bottom:24px">augment<span style="color:#ca000a">.</span></div>
          <h1 style="font-size:25px;line-height:1.2;margin:0 0 14px">Reset your password</h1>
          <p style="font-size:15px;line-height:1.6;margin:0 0 22px">Hi ${displayName}, use this secure link to choose a new Augment password.</p>
          <a href="${safeLink}" style="display:inline-block;background:#ca000a;color:#ffffff;text-decoration:none;font-size:14px;font-weight:700;padding:14px 22px;border-radius:10px">Reset password</a>
          <p style="font-size:12px;line-height:1.6;color:#777;margin:26px 0 0">If you did not request this change, you can safely ignore this email.</p>
        </td></tr>
      </table>
    </td></tr>
  </table>
</body></html>`;

    await sendResendEmail({ to: user.email, subject, html, text });
    passwordResetLastSent.set(user.uid, now);
    return res.json({ sent: true });
  } catch (error) {
    const detail = error.response?.data?.message || error.message;
    console.error('[Email] Password reset email failed:', detail);
    if (error.code === 'auth/invalid-continue-uri' || error.code === 'auth/unauthorized-continue-uri') {
      return res.status(500).json({ error: 'The password return URL is not authorized in Firebase.' });
    }
    return res.status(502).json({ error: 'Unable to send the password email right now.' });
  }
});

async function pythonRequest(method, path, config = {}) {
  let lastError;

  for (const baseUrl of PYTHON_BACKENDS) {
    try {
      return await axios({
        method,
        url: `${baseUrl}${path}`,
        ...config,
      });
    } catch (error) {
      lastError = error;
      if (error.response) {
        const detail = error.response.data?.error || error.message;
        console.error(
          `[Node] Python generation error at ${baseUrl} ` +
              `(${error.response.status}): ${detail}`,
        );
        throw error;
      }
      console.warn(`[Node] Python backend unavailable at ${baseUrl}: ${error.message}`);
    }
  }

  throw lastError || new Error('Unable to connect to Python backend');
}

// Keep transient uploads outside src so nodemon does not restart Node while a
// long generation is running and discard its in-memory job status.
const uploadsDir = path.join(__dirname, '..', 'uploads');
if (!fs.existsSync(uploadsDir)) {
  fs.mkdirSync(uploadsDir, { recursive: true });
}

const storage = multer.diskStorage({
  destination: (req, file, cb) => {
    cb(null, uploadsDir);
  },
  filename: (req, file, cb) => {
    const uniqueSuffix = Date.now() + '-' + Math.round(Math.random() * 1E9);
    cb(null, uniqueSuffix + path.extname(file.originalname));
  }
});

const upload = multer({
  storage: storage,
  limits: { fileSize: 50 * 1024 * 1024 },
  fileFilter: (req, file, cb) => {
    const allowedTypes = [
      '.mp3', '.wav', '.m4a', '.aac', '.flac', '.ogg', '.opus', '.wma', '.aif', '.aiff', '.caf',
      '.mp4', '.mov', '.mkv', '.webm', '.avi', '.3gp',
      '.mid', '.midi', '.musicxml', '.xml', '.mxl', '.krn', '.abc',
    ];
    const ext = path.extname(file.originalname).toLowerCase();
    if (allowedTypes.includes(ext)) {
      cb(null, true);
    } else {
      cb(new Error('Invalid file type. Upload audio, video, MIDI, or MusicXML.'));
    }
  }
});

app.use('/download', express.static(path.join(__dirname, 'public', 'download-site'), {
  setHeaders(res) { res.setHeader('Cache-Control', 'no-cache'); },
}));

app.get('/', (req, res) => {
  res.json({ message: 'API is running' });
});

app.get('/api/health', async (req, res) => {
  try {
    const response = await pythonRequest('get', '/api/health');
    res.json({ node: 'ok', python: response.data,
      verification_email: { provider: 'vercel-gmail', configured: Boolean(verificationSigningKey),
        signer_fingerprint: verificationSigningKey ? crypto.createHash('sha256').update(
          crypto.createPublicKey(verificationSigningKey).export({type:'spki',format:'der'})
        ).digest('hex') : null } });
  } catch (error) {
    res.json({ node: 'ok', python: 'unavailable', message: 'Start Python backend on port 5000' });
  }
});

app.post('/api/sheet/generate', requireFirebaseUser, upload.single('file'), (req, res) => {
  if (!req.file) {
    return res.status(400).json({ error: 'No file uploaded' });
  }

  let access;
  try {
    access = reserveGeneration(req.userId);
  } catch (error) {
    fs.unlink(req.file.path, () => {});
    return res.status(503).json({ error: 'Plan usage is temporarily unavailable.' });
  }
  if (access.error) {
    fs.unlink(req.file.path, () => {});
    return res.status(access.status).json({ error: access.error, usage: access.usage });
  }

  const jobId = crypto.randomUUID();
  const instrument = req.body.instrument || 'Piano';
  const mode = req.body.mode || 'solo';
  const instruments = req.body.instruments;
  const timeSignature = req.body.time_signature;
  const isVideo = ['.mp4', '.mov', '.mkv', '.webm', '.avi', '.3gp']
    .includes(path.extname(req.file.originalname).toLowerCase());
  generationJobs.set(jobId, {
    userId: req.userId,
    status: 'queued', createdAt: Date.now(), isVideo,
    isSoloMelody: false,
    stage: 'Waiting for generation slot', progress: 3,
  });

  // Return immediately to the phone. Demucs and Basic Pitch can work for many
  // minutes, while the app polls this job instead of keeping one USB request open.
  res.status(202).json({ job_id: jobId, status: 'processing' });

  (async () => {
    let succeeded = false;
    try {
      const form = new FormData();
      form.append('file', fs.createReadStream(req.file.path), req.file.originalname);
      form.append('instrument', instrument);
      form.append('mode', mode);
      if (instruments) form.append('instruments', instruments);
      if (timeSignature) form.append('time_signature', timeSignature);
      const response = await scheduleGeneration(access.usage.plan,
        () => pythonRequest('post', '/api/sheet/generate', {
          data: form, headers: form.getHeaders(), timeout: 1800000,
        }),
        () => generationJobs.set(jobId, {
          userId: req.userId, status: 'processing', createdAt: Date.now(), isVideo,
          isSoloMelody: false, stage: isVideo ? 'Extracting audio from video' :
            'Separating vocals and instruments', progress: 5,
        }));
      const storedResult = await storeArtifactsForUser(response.data, req.userId, jobId);
      finishGeneration(req.userId, access.usage.month, true);
      succeeded = true;
      generationJobs.set(jobId, {
        status: 'complete', result: storedResult, userId: req.userId, createdAt: Date.now(),
      });
    } catch (error) {
      const detail = error.response?.data?.error || error.message || 'Generation failed';
      generationJobs.set(jobId, {
        status: 'failed', error: detail, userId: req.userId, createdAt: Date.now(),
      });
    } finally {
      if (!succeeded) finishGeneration(req.userId, access.usage.month, false);
      if (fs.existsSync(req.file.path)) fs.unlink(req.file.path, () => {});
    }
  })();
});

app.post('/api/voice/analyze', upload.single('file'), async (req, res) => {
  if (!req.file) return res.status(400).json({ error: 'No voice recording was received.' });
  try {
    const form = new FormData();
    form.append('file', fs.createReadStream(req.file.path), req.file.originalname || 'voice.wav');
    const response = await pythonRequest('post', '/api/voice/analyze', {
      data: form,
      headers: form.getHeaders(),
      timeout: 60000,
      validateStatus: () => true,
    });
    res.status(response.status).json(response.data);
  } catch (error) {
    res.status(502).json({ error: `Voice analysis is unavailable: ${error.message}` });
  } finally {
    fs.unlink(req.file.path, () => {});
  }
});

app.get('/api/sheet/jobs/:jobId', requireFirebaseUser, (req, res) => {
  const job = generationJobs.get(req.params.jobId);
  if (!job) return res.status(404).json({ error: 'Generation job not found' });
  if (job.userId !== req.userId) return res.status(404).json({ error: 'Generation job not found' });
  res.json(processingEstimate(job));
});

app.post('/api/sheet/generate-url', requireFirebaseUser, async (req, res) => {
  let access;
  let succeeded = false;
  try {
    const { url, instrument, mode = 'solo', instruments,
      time_signature: timeSignature } = req.body;
    if (!url) {
      return res.status(400).json({ error: 'No URL provided' });
    }
    access = reserveGeneration(req.userId);
    if (access.error) return res.status(access.status).json({ error: access.error, usage: access.usage });

    const isYouTube = /(?:youtube\.com|youtu\.be)/.test(url);

    if (isYouTube) {
      const response = await scheduleGeneration(access.usage.plan, () =>
        pythonRequest('post', '/api/sheet/generate-youtube', {
          data: {
          url,
          instrument: instrument || 'Piano',
          mode,
          ...(instruments ? { instruments } : {}),
          ...(timeSignature ? { time_signature: timeSignature } : {}),
        },
        // Full YouTube tracks are downloaded, separated, then transcribed.
          timeout: 1800000,
        }));
      const jobId = crypto.randomUUID();
      const stored = await storeArtifactsForUser(response.data, req.userId, jobId);
      finishGeneration(req.userId, access.usage.month, true);
      succeeded = true;
      return res.json(stored);
    }

    const response = await axios.get(url, { responseType: 'arraybuffer', timeout: 30000 });
    const ext = path.extname(new URL(url).pathname) || '.mid';
    const filename = `url-${Date.now()}${ext}`;
    const filepath = path.join(uploadsDir, filename);
    fs.writeFileSync(filepath, response.data);

    const form = new FormData();
    form.append('file', fs.createReadStream(filepath), filename);
    form.append('instrument', instrument || 'Piano');
    form.append('mode', mode);
    if (instruments) {
      form.append('instruments',
        typeof instruments === 'string' ? instruments : JSON.stringify(instruments));
    }
    if (timeSignature) form.append('time_signature', timeSignature);

    const result = await scheduleGeneration(access.usage.plan, () =>
      pythonRequest('post', '/api/sheet/generate', {
        data: form, headers: form.getHeaders(), timeout: 1800000,
      }));

    fs.unlink(filepath, () => {});
    const jobId = crypto.randomUUID();
    const stored = await storeArtifactsForUser(result.data, req.userId, jobId);
    finishGeneration(req.userId, access.usage.month, true);
    succeeded = true;
    res.json(stored);
  } catch (error) {
    if (error.response) {
      const data = typeof error.response.data === 'string'
        ? { error: error.response.data }
        : error.response.data;
      res.status(error.response.status).json(data);
    } else {
      res.status(500).json({ error: error.message });
    }
  } finally {
    if (access && !access.error && !succeeded) finishGeneration(req.userId, access.usage.month, false);
  }
});

app.get('/api/sheet/download/:filename', requireFirebaseUser, async (req, res) => {
  try {
    const separator = req.params.filename.indexOf('--');
    if (separator > 0) {
      const jobId = safePathPart(req.params.filename.slice(0, separator));
      const filename = path.basename(req.params.filename.slice(separator + 2));
      const currentPath = path.join(generatedRoot, safePathPart(req.userId), jobId, filename);
      const legacyPath = path.join(__dirname, '..', 'generated', safePathPart(req.userId), jobId, filename);
      let filePath = fs.existsSync(currentPath) ? currentPath : legacyPath;
      // Optional PDF export may fail while the mandatory MusicXML succeeds.
      // Retry Python's lazy PDF exporter only after verifying ownership of
      // the corresponding XML in this user's generated job directory.
      if (!fs.existsSync(filePath) && path.extname(filename).toLowerCase() === '.pdf') {
        const stem = filename.slice(0, -4);
        const ownedXml = [currentPath, legacyPath].some((candidate) =>
          ['.musicxml', '.xml'].some((extension) => {
            const xmlPath = path.join(path.dirname(candidate), stem + extension);
            return fs.existsSync(xmlPath) && fs.statSync(xmlPath).isFile();
          }));
        if (ownedXml) {
          const response = await pythonRequest('get', `/api/sheet/download/${encodeURIComponent(filename)}`, {
            responseType: 'arraybuffer', timeout: 180000,
          });
          const bytes = Buffer.from(response.data);
          if (bytes.subarray(0, 5).toString() !== '%PDF-') {
            return res.status(502).json({ error: 'PDF export did not return a valid PDF. MusicXML is still available.' });
          }
          filePath = currentPath;
          fs.mkdirSync(path.dirname(filePath), { recursive: true });
          fs.writeFileSync(filePath, bytes);
        }
      }
      if (!fs.existsSync(filePath) || !fs.statSync(filePath).isFile()) {
        return res.status(404).json({ error: 'Generated file expired or was not found.' });
      }
      return res.download(filePath, filename);
    }
    console.log(`[Node] Download request: ${req.params.filename}`);
    const response = await pythonRequest('get', `/api/sheet/download/${req.params.filename}`, {
      responseType: 'stream'
    });

    const ext = path.extname(req.params.filename).toLowerCase();
    const mimeMap = {
      '.wav': 'audio/wav',
      '.mp3': 'audio/mpeg',
      '.png': 'image/png',
      '.pdf': 'application/pdf',
      '.musicxml': 'application/xml',
      '.xml': 'application/xml',
    };
    const contentType = mimeMap[ext] || 'application/octet-stream';

    res.setHeader('Content-Type', contentType);
    res.setHeader('Content-Disposition', `attachment; filename="${req.params.filename}"`);
    response.data.pipe(res);
  } catch (error) {
    const status = error.response ? error.response.status : 500;
    const detail = error.response
      ? (error.response.statusText || `Python backend returned ${status}`)
      : (error.message || 'Download request failed');
    console.error(`[Node] Download error for ${req.params.filename}: status=${status}, detail=${detail}`);
    res.status(status).json({ error: 'Could not create the requested file', detail });
  }
});

app.post('/api/sheet/preview-bar', requireFirebaseUser, async (req, res) => {
  try {
    const response = await pythonRequest('post', '/api/sheet/preview-bar', {
      data: { musicxml_content: req.body.musicxml_content },
      responseType: 'arraybuffer', timeout: 45000,
    });
    res.type('audio/wav').set('Cache-Control', 'no-store').send(Buffer.from(response.data));
  } catch (error) {
    res.status(error.response?.status || 502).json({ error: 'Could not preview this bar. Please try again.' });
  }
});

app.post('/api/sheet/render-edited', requireFirebaseUser, async (req, res) => {
  try {
    // Fresh filenames prevent an edit from overwriting another user's output.
    const jobId = crypto.randomUUID();
    const response = await pythonRequest('post', '/api/sheet/render-edited', {
      data: { musicxml_content: req.body.musicxml_content, instrument: req.body.instrument,
        output_file: `edited_${jobId}.musicxml` }, timeout: 180000,
    });
    if (!response.data.audio_available) return res.status(502).json({ error: 'Edited playback could not be prepared.' });
    res.json(await storeArtifactsForUser(response.data, req.userId, jobId));
  } catch (error) {
    res.status(error.response?.status || 502).json({ error: 'Could not save edited playback. Please try again.' });
  }
});

app.get('/api/sheet/preview/:filename', async (req, res) => {
  try {
    const response = await pythonRequest('get', `/api/sheet/preview/${req.params.filename}`, {
      responseType: 'stream'
    });

    res.setHeader('Content-Type', 'application/xml');
    response.data.pipe(res);
  } catch (error) {
    res.status(404).json({ error: 'File not found' });
  }
});

// Multer validates uploads before the route handler. Return JSON here so the
// Flutter app can show the real reason instead of trying to decode HTML.
app.use((error, req, res, next) => {
  if (error) {
    const status = error.code === 'LIMIT_FILE_SIZE' ? 413 : 400;
    return res.status(status).json({ error: error.message || 'Upload failed' });
  }
  next();
});

app.get('/assets/web/js/opensheetmusicdisplay.min.js', (req, res) => {
  const bundledJsPath = path.join(__dirname, 'public', 'opensheetmusicdisplay.min.js');
  const jsPath = fs.existsSync(bundledJsPath) ? bundledJsPath :
    path.join(__dirname, '..', '..', 'frontend', 'assets', 'web', 'js', 'opensheetmusicdisplay.min.js');
  if (fs.existsSync(jsPath)) {
    res.setHeader('Content-Type', 'application/javascript');
    res.setHeader('Cache-Control', 'public, max-age=3600');
    fs.createReadStream(jsPath).pipe(res);
  } else {
    res.status(404).send('OSMD not found');
  }
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(`Node server running at http://172.23.212.8:${PORT}`);
  console.log(`Python backend priority: ${PYTHON_BACKENDS.join(' -> ')}`);
});
