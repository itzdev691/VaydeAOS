import { build } from 'esbuild';
import { readdir, readFile, mkdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

await mkdir('dist', { recursive: true });
// Compile the vendored modules separately for their regression suite.
await build({ entryPoints: (await readdir('vendor/siwc-local/src')).filter(f => f.endsWith('.ts')).map(f => `vendor/siwc-local/src/${f}`),
  outdir: 'vendor/siwc-local/dist', platform: 'node', format: 'esm', target: 'node22' });

await build({ entryPoints: ['main.mjs'], bundle: true, platform: 'node', format: 'esm',
  target: 'node22', outfile: 'dist/helper.mjs', banner: { js: 'import { createRequire as __createRequire } from "node:module"; const require = __createRequire(import.meta.url);' } });

const notices = [await readFile('vendor/siwc-local/LICENSE', 'utf8')];
async function collect(directory) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    if (entry.name.startsWith('.')) continue;
    const path = join(directory, entry.name);
    if (entry.name.startsWith('@')) { await collect(path); continue; }
    if (!entry.isDirectory()) continue;
    const pkg = JSON.parse(await readFile(join(path, 'package.json'), 'utf8'));
    if (pkg.name === 'esbuild' || pkg.name.startsWith('@esbuild/')) continue;
    const licenseFiles = (await readdir(path)).filter(f => /^(licen[sc]e|notice)(\.|$)/i.test(f));
    for (const license of licenseFiles) notices.push(`\n## ${pkg.name}@${pkg.version}\n\n${await readFile(join(path, license), 'utf8')}`);
  }
}
await collect('node_modules');
await writeFile('dist/THIRD_PARTY_NOTICES.txt', notices.join('\n'));
