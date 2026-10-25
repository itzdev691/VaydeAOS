import { spawn } from 'node:child_process';
import { access, constants } from 'node:fs/promises';
import { ChatGPTError } from './vendor/siwc-local/dist/index.js';

export function createEncryption(executable) {
  async function transform(mode, data) {
    return new Promise((resolve, reject) => {
      const child = spawn(executable, [mode], { stdio: ['pipe', 'pipe', 'ignore'],
        env: { PATH: '/usr/bin:/bin', HOME: process.env.HOME, TMPDIR: process.env.TMPDIR } });
      const chunks = [];
      let length = 0;
      const timer = setTimeout(() => child.kill('SIGKILL'), 60_000);
      const fail = () => reject(new ChatGPTError('credential_storage_unavailable', ''));
      child.on('error', fail);
      child.stdin.on('error', fail);
      child.stdout.on('data', chunk => {
        length += chunk.length;
        if (length > 8 * 1024 * 1024) child.kill('SIGKILL'); else chunks.push(chunk);
      });
      child.on('close', code => { clearTimeout(timer); code === 0 ? resolve(Buffer.concat(chunks)) : fail(); });
      child.stdin.end(data);
    });
  }
  return { id: 'vaydeaos-keychain-aes256gcm-v1',
    async isAvailable() { try { await access(executable, constants.X_OK); return true; } catch { return false; } },
    encrypt: plaintext => transform('encrypt', Buffer.from(plaintext, 'utf8')),
    decrypt: async ciphertext => (await transform('decrypt', ciphertext)).toString('utf8') };
}
