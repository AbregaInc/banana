import { build } from 'esbuild';
import { existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const directory = dirname(fileURLToPath(import.meta.url));
const upstream = resolve(process.argv[2]);
const output = resolve(process.argv[3]);
mkdirSync(output, { recursive: true });
const packages = { 'pi-ai': 'ai', 'pi-telemetry': 'telemetry', 'pi-durable': 'durable', chord: 'chord' };
const plugin = { name: 'reviewed-upstream-source', setup(builder) {
  builder.onResolve({ filter: /^@earendil-works\/(pi-ai|pi-telemetry|pi-durable|chord)(\/.*)?$/ }, ({ path }) => {
    const [, name, suffix] = path.match(/^@earendil-works\/(pi-ai|pi-telemetry|pi-durable|chord)(\/.*)?$/);
    const base = resolve(upstream, 'packages', packages[name], 'src', suffix ? suffix.slice(1) : 'index');
    return { path: existsSync(base + '.ts') ? base + '.ts' : resolve(base, 'index.ts') };
  });
  builder.onResolve({ filter: /^typebox$/ }, () => ({ path: resolve(upstream, 'node_modules/typebox/build/index.mjs') }));
} };
for (const [entry, filename] of [['bootstrap.js', 'bootstrap.js'], ['entry.js', 'pi.js'], ['app.js', 'app.js']]) {
  const result = await build({ entryPoints: [resolve(directory, entry)], outfile: resolve(output, filename), bundle: true, metafile: true,
    platform: 'browser', format: 'iife', conditions: ['source'], plugins: [plugin],
    nodePaths: [resolve(upstream, 'node_modules')],
  });
  if (entry !== 'entry.js') writeFileSync(resolve(output, entry.replace('.js', '') + '-metafile.json'), JSON.stringify(result.metafile));
}
