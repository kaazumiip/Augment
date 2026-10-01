const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const { Readable } = require('node:stream');
const { pipeline } = require('node:stream/promises');
const source = fs.readFileSync(path.join(__dirname, '../backend/src/index.js'), 'utf8');
const functions = source.slice(source.indexOf('function safePathPart('), source.indexOf('function cleanExpiredGeneratedFiles('));
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'augment-artifact-test-'));
const generatedRoot = path.join(directory, 'data/generated');
let failure = null;
const calls = [];
const context = vm.createContext({ fs, path, pipeline, generatedRoot, __dirname: path.join(directory, 'src'), console,
  pythonRequest: async (_, url) => {
    calls.push(url);
    if (failure || url.endsWith('missing.pdf')) throw { response: { status: 404 } };
    return { data: Readable.from([Buffer.from('artifact:' + url)]) };
  },
});
vm.runInContext(functions, context);
(async () => {
  const input = { output_file: 'score.musicxml', audio_file: 'play.wav', pdf_file: 'missing.pdf',
    parts: [{ output_file: 'part.musicxml' }], system_images: ['system.png'] };
  const result = await context.storeArtifactsForUser(input, 'user', 'job');
  assert.equal(result.output_file, 'job--score.musicxml');
  assert.equal(result.parts[0].output_file, 'job--part.musicxml');
  for (const name of ['score.musicxml', 'play.wav', 'part.musicxml', 'system.png']) {
    assert.ok(fs.readFileSync(path.join(generatedRoot, 'user/job', name), 'utf8').startsWith('artifact:'));
  }
  assert.equal(calls.length, 5);
  failure = true;
  await assert.rejects(context.storeArtifactsForUser({ output_file: 'lost.musicxml' }, 'user', 'failed'));
  failure = false;
  const localDirectory = path.join(directory, 'python/output');
  fs.mkdirSync(localDirectory, { recursive: true });
  fs.writeFileSync(path.join(localDirectory, 'local.musicxml'), 'local score');
  const count = calls.length;
  await context.storeArtifactsForUser({ output_file: 'local.musicxml' }, 'user', 'local');
  assert.equal(calls.length, count);
  assert.equal(fs.readFileSync(path.join(generatedRoot, 'user/local/local.musicxml'), 'utf8'), 'local score');
  console.log('PASS: remote artifact streaming, nested parts, optional missing PDF, required score failure, local compatibility.');
  console.log('Test files:', directory);
})().catch(error => { console.error(error); process.exitCode = 1; });
