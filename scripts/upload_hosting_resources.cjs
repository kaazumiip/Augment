// Upload approved deployment resources privately; never print credentials/URLs.
const fs = require('node:fs');
const path = require('node:path');
const dotenv = require('../backend/node_modules/dotenv');
const env = dotenv.parse(fs.readFileSync(path.join(__dirname, '../backend/.env')));
const work = path.join(__dirname, '../.codex-hosting');
const base = env.SUPABASE_URL.replace(/\/$/, '') + '/storage/v1';
const headers = { Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
  apikey: env.SUPABASE_SERVICE_ROLE_KEY };
async function request(route, options = {}) {
  const response = await fetch(base + route, {
    ...options, headers: { ...headers, ...options.headers },
  });
  if (!response.ok) throw new Error(`Private storage operation failed (${response.status})`);
  return response.json();
}
(async () => {
  const bucket = 'augment-runtime-private';
  const buckets = await request('/bucket');
  const existing = buckets.find(item => item.id === bucket);
  if (existing?.public) throw new Error('Deployment bucket must be private');
  if (!existing) await request('/bucket', { method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ id: bucket, name: bucket, public: false,
      file_size_limit: 50 * 1024 * 1024 }) });
  const sha256 = fs.readFileSync(path.join(work, 'bundle-sha256.txt'), 'utf8').trim();
  const parts = [];
  for (const filename of fs.readdirSync(work).filter(name => /^resources-part-\d+\.bin$/.test(name)).sort()) {
    const object = `${sha256}/${filename}`;
    await request(`/object/${bucket}/${object}`, { method: 'POST',
      headers: { 'Content-Type': 'application/octet-stream', 'x-upsert': 'true' },
      body: fs.readFileSync(path.join(work, filename)) });
    const signed = await request(`/object/sign/${bucket}/${object}`, { method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ expiresIn: 604800 }) });
    parts.push(env.SUPABASE_URL.replace(/\/$/, '') + '/storage/v1' + signed.signedURL);
    console.log(`Uploaded private resource part ${parts.length}.`);
  }
  fs.writeFileSync(path.join(work, 'resource-manifest.json'), JSON.stringify({sha256, parts}));
  console.log('Private resource manifest ready; temporary links expire after 7 days.');
})().catch(error => { console.error(error.message); process.exitCode = 1; });
