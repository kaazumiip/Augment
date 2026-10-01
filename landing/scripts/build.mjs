import { cp, mkdir, rm } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const landingDirectory = path.resolve(scriptDirectory, '..');
const publicDirectory = path.join(landingDirectory, 'public');
const outputDirectory = path.join(landingDirectory, 'dist');

await rm(outputDirectory, { recursive: true, force: true });
await mkdir(outputDirectory, { recursive: true });
await cp(publicDirectory, outputDirectory, { recursive: true });
console.log(`Augment landing site ready: ${outputDirectory}`);
