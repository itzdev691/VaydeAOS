import { createChatGPT } from './vendor/siwc-local/dist/index.js';
import { createInterface } from 'node:readline';
import { spawn } from 'node:child_process';
import { dirname, isAbsolute, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createEncryption } from './encryption.mjs';
import { createBridge } from './bridge.mjs';

const directory = dirname(fileURLToPath(import.meta.url));
const storageDir = process.argv[2];
if (!storageDir || !isAbsolute(storageDir)) process.exit(64);
// stdout is exclusively the protocol. SDK logging must never disclose request content.
console.log = console.warn = console.error = console.debug = console.info = () => {};
const chatgpt = createChatGPT({ appName: 'VaydeAOS', appId: 'dev.vaydeaos.app', redirectPort: 0,
  sendHostId: true, storageDir, credentialEncryption: createEncryption(join(directory, 'credential-vault')),
  openBrowser: async url => {
    if (new URL(url).origin !== 'https://auth.openai.com') throw new Error('Invalid authorization origin');
    await new Promise((resolve, reject) => {
      const child = spawn('/usr/bin/open', [url], { stdio: 'ignore' });
      child.on('error', reject); child.on('close', code => code === 0 ? resolve() : reject(new Error('Browser unavailable')));
    });
  } });
const send = value => process.stdout.write(JSON.stringify(value) + '\n');
const bridge = createBridge(chatgpt, send);
chatgpt.subscribe(session => send({ kind: 'session', session: {
  status: session.status, sharing: session.sharing, profileId: session.profileId,
  profileLabel: session.profileLabel, identity: session.identity ? { name: session.identity.name, email: session.identity.email } : undefined,
} }));
// A bound prevents malformed parent input from retaining unlimited data before a newline.
let outstandingBytes = 0;
process.stdin.on('data', chunk => {
  outstandingBytes += chunk.length;
  if (outstandingBytes > 24 * 1024 * 1024) process.exit(65);
  if (chunk.includes(10)) outstandingBytes = chunk.length - chunk.lastIndexOf(10) - 1;
});
const input = createInterface({ input: process.stdin, crlfDelay: Infinity });
input.on('line', line => {
  try { const request = JSON.parse(line); if (request && typeof request === 'object') void bridge.dispatch(request); }
  catch { process.exitCode = 65; input.close(); }
});
function close() { bridge.close(); setTimeout(() => process.exit(0), 1500).unref(); }
input.on('close', close);
process.on('SIGTERM', close);
process.stdout.on('error', close);
process.on('uncaughtException', () => { bridge.close(); process.exit(70); });
process.on('unhandledRejection', () => { bridge.close(); process.exit(70); });
