import {collectFeed} from './feed-import.js';
import {buildArchive} from './feed-archive.js';
export async function exportFeed(url,{images=true,onProgress=()=>{},...options}={}){
  const collected=await collectFeed(url,{...options,onProgress});
  const {result}=collected,files={};let done=0;
  if(images){
    const assets=result.tables.assets.filter(a=>a.record_type==='food.mealPhoto');
    for(const a of assets){
      const downloaded=await collected.request(a.url,true);
      if(!/^image\/(jpeg|png|webp|heic|heif|gif)$/.test(downloaded.mediaType))throw new Error('A shared photo did not return a supported image. No partial download was saved.');
      const ext=({'image/jpeg':'jpg','image/png':'png','image/webp':'webp','image/heic':'heic','image/heif':'heif','image/gif':'gif'})[downloaded.mediaType];
      const path=`images/photo-${++done}.${ext}`;files[path]=downloaded.bytes;a.file_path=path;a.media_type=downloaded.mediaType;
      onProgress({stage:'images',completed:done,total:assets.length,pages:result.collection.pages,records:result.collection.records});
    }
  }
  await collected.verify();
  result.collection.bytes=collected.bytes;
  result.collection.verifiedAt=new Date().toISOString();
  onProgress({stage:'packaging',records:result.collection.records,calendarIncomplete:Boolean(result.calendarIssues?.length)});
  return buildArchive(result,files);
}
