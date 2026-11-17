#!/usr/bin/env node
import {importFeed} from '../public/app/assets/feed-import.js';
import {exportFeed} from '../public/app/assets/feed-export.js';
import {normalizeAnalysis} from '../public/app/assets/analysis-model.js';
import {analysisSchema} from '../public/app/assets/analysis-schema.js';
export {importFeed,exportFeed,normalizeAnalysis,analysisSchema};
// Import as a library, or execute with credentials in environment variables, never argv/logs.
const isMain=typeof process!=='undefined'&&process.argv?.[1]&&import.meta.url===(await import('node:url')).pathToFileURL(process.argv[1]).href;
if(isMain){
 const {writeFile,rename,rm}=await import('node:fs/promises');
 const {resolve}=await import('node:path');
 let scratch=null;
 try{
  const args=process.argv.slice(2);let output='banana-analysis.zip',images=true,maxBytes=64*1024*1024;
  for(let i=0;i<args.length;i++){
   if(args[i]==='--output'&&args[i+1])output=args[++i];
   else if(args[i]==='--no-images')images=false;
   else if(args[i]==='--max-mib'&&/^\d+$/.test(args[i+1]??'')&&Number(args[i+1])>=1&&Number(args[i+1])<=1024)maxBytes=Number(args[++i])*1024*1024;
   else throw new Error('Usage: BANANA_FEED_URL=<private URL> [BANANA_FEED_TOKEN=<token>] node banana-feed.mjs [--output file.zip] [--no-images] [--max-mib 1..1024]');
  }
  if(!process.env.BANANA_FEED_URL)throw new Error('Set BANANA_FEED_URL to your private feed URL. For bearer authentication, remove signature and set BANANA_FEED_TOKEN.');
  const bytes=await exportFeed(process.env.BANANA_FEED_URL,{token:process.env.BANANA_FEED_TOKEN||null,images,maxBytes,onProgress:p=>process.stderr.write(p.stage==='reading'?`Read ${p.records} records across ${p.pages} pages.\n`:p.stage==='images'?`Downloaded ${p.completed}/${p.total} images.\n`:p.stage==='waiting'?`Rate limited; waiting ${p.retryAfterSeconds}s.\n`:'Preparing archive.\n')});
  const path=resolve(output);scratch=path+'.partial-'+process.pid;
  await writeFile(scratch,bytes,{flag:'wx',mode:0o600});await rename(scratch,path);scratch=null;
  process.stderr.write('Complete archive saved.\n');
 }catch(error){if(scratch)await rm(scratch,{force:true});process.stderr.write(error.message+'\n');process.exitCode=1;}
}
