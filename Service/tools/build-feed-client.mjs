import {build} from 'esbuild';
import {readFile,writeFile} from 'node:fs/promises';
import {analysisSchema} from '../public/app/assets/analysis-schema.js';
const license=await readFile('public/app/assets/vendor/fflate-LICENSE','utf8');
await build({banner:{js:'/* Banana feed client: AGPL-3.0-only. Source and license: https://github.com/AbregaInc/banana\nBundled fflate license follows:\n'+license+'\n*/'},entryPoints:['tools/feed-client-entry.mjs'],outfile:'public/app/assets/banana-feed.mjs',bundle:true,platform:'node',format:'esm',target:'node24',legalComments:'inline'});
await writeFile('public/app/assets/analysis-schema.json',JSON.stringify(analysisSchema,null,2)+'\n');
