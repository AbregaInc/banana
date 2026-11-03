// Small, bounded language rules for explicit UI commands and literal data.
// Ambiguous requests still go through the model; this is not an intent/query catalog.
const quoted = /"(?:\\.|[^"\\])*"|“[^”]*”/g;
export function hideQuotedData(value) {
  return value.replace(quoted, '[quoted text]');
}
const pageNames={plan:'plan',calendar:'plan',agenda:'plan',workouts:'workouts',nutrition:'nutrition',notes:'notes',routines:'routines',library:'library',review:'review',sleep:'review',trends:'review',assistant:'assistant',settings:'settings'};
const prefix=new Set(['hi','hello','hey','please','help','with','this','quick','question','could','would','can','you']);
const suffix=new Set(['page','screen','thanks','thank','you','please']);
export function directPageCommand(value) {
  // Quoted commands, negation, and compound requests never use this shortcut.
  if(value.match(quoted))return null;
  const words=value.toLowerCase().match(/[a-z]+(?:['’][a-z]+)?|\d+/g)??[];
  const at=words.findIndex(w=>['open','go','take','show'].includes(w));
  if(at<0 || !words.slice(0,at).every(w=>prefix.has(w)))return null;
  let tail=words.slice(at+1);
  if(words[at]==='go'){if(tail.shift()!=='to')return null;}
  if(words[at]==='take'){if(tail.shift()!=='me'||tail.shift()!=='to')return null;}
  if(['the','my'].includes(tail[0]))tail.shift();
  const section=pageNames[tail.shift()];
  if(!section || !tail.every(w=>suffix.has(w)))return null;
  if(words[at]==='show' && !tail.some(w=>w==='page'||w==='screen'))return null;
  return section;
}
export function searchWithoutCourtesy(query, source) {
  if(typeof query!=='string')return query;
  // Quotes request literal search text, even when the title is "Giving Thanks".
  if(source.match(quoted)?.some(q=>q.slice(1,-1).toLowerCase()===query.toLowerCase()))return query;
  const courtesy=source.match(/\b(thanks|thank you|please)[.!?\s]*$/i)?.[1];
  if(!courtesy)return query;
  const clean=query.replace(new RegExp('\\s+'+courtesy+'[.!?\\s]*$','i'),'').trim();
  return clean || query;
}
export function directConversationCommand(value) {
  if(value.match(quoted))return null;
  const words=value.toLowerCase().match(/[a-z]+(?:['’][a-z]+)?|\d+/g)??[];
  const at=words.findIndex(w=>['start','begin','create','open'].includes(w));
  if(at<0 || !words.slice(0,at).every(w=>prefix.has(w)))return null;
  const tail=words.slice(at+1);
  if(['a','the'].includes(tail[0]))tail.shift();
  if(!['new','fresh'].includes(tail.shift()) || !['chat','conversation','thread'].includes(tail.shift()))return null;
  return tail.every(w=>suffix.has(w))?'new':null;
}
