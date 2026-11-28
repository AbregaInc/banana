// Small, bounded language rules for explicit UI commands and literal data.
// Ambiguous requests still go through the model; this is not an intent/query catalog.
const quoted = /"(?:\\.|[^"\\])*"|“[^”]*”/g;
export function hideQuotedData(value) {
  return value.replace(quoted, '[quoted text]');
}
const pageNames={plan:'plan',calendar:'plan',agenda:'plan',mail:'mail',email:'mail',inbox:'mail',workouts:'workouts',nutrition:'nutrition',notes:'notes',routines:'routines',library:'library',review:'review',sleep:'review',trends:'review',assistant:'assistant',settings:'settings'};
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
export function namedCalendarLookup(value) {
  const title = value.trim().match(/^(?:find|search|look up|locate|when is|where is|which calendar is)\b[^"“\n]*\b(?:calendar|event|appointment)\b[^"“\n]*["“]([^"”\n]{1,120})["”](?:[ .?!,]*|[ ,]+(?:on(?: my calendar)?|please)[.?!]*)$/iu);
  if (title && !/\b(?:and|then|instead)\b/i.test(hideQuotedData(value))) return title[1];
  const match = value.trim().match(/^(?:when is|what(?:['’]?s| is)) +(?:(?:my|our) +)?([\p{L}][\p{L}\p{M}-]*(?: +[\p{L}][\p{L}\p{M}-]*){0,3})['’]?s +(birthday|anniversary)[?.!]?$/iu);
  if (!match || /\b(?:and|or|not)\b/i.test(match[1])) return null;
  const query = `${match[1]} ${match[2]}`;
  return query.length <= 120 ? query : null;
}

export function referencesMailbox(value) {
  return /\b(?:inbox|outbox|spam folder|email thread|unread messages|my (?:gmail|mail|emails|messages)|(?:in|from|to|read|open|find|forward|archive|delete|search) (?:the |an? |my |this |your |each |most recent )?(?:email|mailbox|mail thread)\b)/i.test(hideQuotedData(value));
}

export function asksToFindMail(value) {
  const words = hideQuotedData(value).trim();
  // Finding a thread is distinct from reading it to answer a question or carrying out an action.
  return /^(?:(?:please|can you|could you)\s+)?(?:find|search|pull up|locate|look (?:for|up)|show|list|do i have)\b/i.test(words)
    && !/\b(?:exact phrase|attachments?|summari[sz]e|extract|forward|send|reply|delete|delete duplicates|spam|scheduled|drafts?)\b|[<>$]/i.test(words);
}

export function explicitOneOffCalendarDraft(value) {
  if (!value.match(quoted)) return false;
  const words = hideQuotedData(value);
  return /^(?:draft|prepare|create|put|add|make|schedule|block|i(?:['’]d| would) like)\b/i.test(words.trim())
    && /\ball[- ]day\b|\b(?:[01]\d|2[0-3]):[0-5]\d\b/i.test(words)
    && !/\b(?:recurr\w*|repeat\w*|every|each|series|daily|(?:bi)?weekly|monthly|yearly|annually|fortnightly|alternat\w*|week(?:days|ends|nights)|(?:mon|tues|wednes|thurs|fri|satur|sun)days|invite|attendees?|flight|time\s?zone|existing|replace|move|change|email|message|log|record|calories)\b/i.test(words);
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
