// Publish only the explicitly public APK release. Server secrets stay local.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const dotenv = require('../backend/node_modules/dotenv');
const root = path.resolve(__dirname, '..');
const env = dotenv.parse(fs.readFileSync(path.join(root, 'backend/.env')));
const origin = env.SUPABASE_URL.replace(/\/$/, '');
const bucket = 'augment-app-downloads';
const headers = { Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`, apikey: env.SUPABASE_SERVICE_ROLE_KEY };
async function request(route, options = {}) {
  const response = await fetch(origin + '/storage/v1' + route, {
    ...options, headers: { ...headers, ...options.headers },
  });
  if (!response.ok) throw new Error(`APK publication failed (${response.status})`);
  return response.json();
}
(async () => {
  const source = path.join(root, 'landing/public');
  const manifestPath = path.join(source, 'downloads/release.json');
  const release = JSON.parse(fs.readFileSync(manifestPath, 'utf8').replace(/^\uFEFF/, ''));
  const entries = Object.entries(release.apks);
  if (entries.length !== 3) throw new Error('Build all three release APKs first.');
  const buckets = await request('/bucket');
  const existing = buckets.find(item => item.id === bucket);
  if (existing && !existing.public) throw new Error('Refusing to change an existing private bucket.');
  if (!existing) await request('/bucket', { method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ id: bucket, name: bucket, public: true, file_size_limit: 50 * 1024 * 1024 }) });
  for (const [abi, apk] of entries) {
    const data = fs.readFileSync(path.join(source, 'downloads', apk.file));
    const hash = crypto.createHash('sha256').update(data).digest('hex');
    if (hash !== apk.sha256) throw new Error(`APK checksum mismatch: ${abi}`);
    const object = `${hash}/${apk.file}`;
    await request(`/object/${bucket}/${object}`, { method: 'POST', headers: {
      'Content-Type': 'application/vnd.android.package-archive', 'x-upsert': 'true',
    }, body: data });
    apk.url = `${origin}/storage/v1/object/public/${bucket}/${object}`;
    console.log(`Published ${abi} APK (${data.length} bytes).`);
  }
  fs.writeFileSync(manifestPath, JSON.stringify(release, null, 2));
  const target = path.join(root, 'backend/src/public/download-site');
  fs.cpSync(source, target, { recursive: true, filter: file => !file.endsWith('.apk') });
  console.log('Download page prepared for Railway at /download/. Push the changed source to deploy.');
})().catch(error => { console.error(error.message); process.exitCode = 1; });
