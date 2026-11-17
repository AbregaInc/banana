import {exportFeed} from './feed-export.js';
self.onmessage=async({data})=>{
 try{
  const bytes=await exportFeed(data.url,{credentials:data.preview?'same-origin':'omit',images:data.images,onProgress:progress=>self.postMessage({progress})});
  self.postMessage({bytes},[bytes.buffer]);
 }catch(error){self.postMessage({error:error.message});}
};
