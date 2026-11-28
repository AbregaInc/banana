import { defineDoc, defineExtension, defineTool, section, hook, GenerationTask } from '@earendil-works/pi-durable';
import { getCurrentSystemMessage } from '@earendil-works/pi-ai/utils/transcript';
import { Type } from 'typebox';

export const WorkspaceDoc = defineDoc({ kind: 'banana.workspace', version: 1, scope: 'conversation', history: 'latest', fork: 'current',
  initial: () => ({ revision: 0, action: null, operation: null }), checkpointWhen: () => true });

export async function updateWorkspace(owner, conversationId, fields, operation, nativeTool, ctx) {
  const before = await owner.snapshot(WorkspaceDoc, conversationId, ctx);
  if (before?.operation === operation) return before.action;
  const revision = before?.revision ?? 0;
  if (fields.revision !== revision) throw new Error('The workspace changed. Try again.');
  const action = fields.kind === 'dismiss' ? null : await nativeTool({ name: 'app_workspace', arguments: fields, operationId: operation }, ctx.abortSignal);
  await owner.commit(async tx => {
    const doc = await tx.doc(WorkspaceDoc, conversationId);
    if (doc.operation === operation) return;
    if (doc.revision !== revision) throw new Error('The workspace changed while preparing this action. Try again.');
    doc.revision = revision + 1; doc.action = action; doc.operation = operation;
  }, ctx);
  return action;
}

export async function workspaceRequestText(harness, api, ctx) {
  const remembered = await api.memo('workspace-request-text', ctx);
  if (remembered !== undefined) return remembered;
  const conversation = await harness.conversation(api.conversationId, ctx);
  const view = await conversation.context(ctx);
  const user = [...view.messages].reverse().find(message => message.role === 'user');
  const text = typeof user?.content === 'string' ? user.content : (user?.content ?? []).filter(part => part.type === 'text').map(part => part.text).join('\n');
  return api.memo('workspace-request-text', text, ctx);
}

export function workspaceExtension(nativeTool, uuid, requestText = async () => undefined, mailAvailable = false) {
  const names = new Set(['prepare_meal', 'prepare_event', 'prepare_event_from_email', 'search_app', 'search_mail', 'open_page']);
  const day = { day: Type.Optional(Type.String({description:'The day word as the person said it: today, tomorrow, yesterday, a weekday, or YYYY-MM-DD. Default today.'})) };
  const tool = (name, description, fields, kind, section) => defineTool({name,description,
    parameters:Type.Object({...fields,revision:Type.Optional(Type.Integer({description:'Host metadata; omit.'}))},{additionalProperties:false}),replay:'safe',
    execute:async(args,api,ctx)=>{
      const operation=await api.memo('workspace-operation',uuid(),ctx);
      const sourceRequest=await requestText(api,ctx);
      const action=await updateWorkspace(api,api.conversationId,{...args,kind,...(section ? {section} : {}),...(sourceRequest ? {sourceRequest} : {})},operation,nativeTool,ctx);
      return {output:[{type:'text',text:JSON.stringify({action:brief(action), saved:false, instruction:'The native workspace is the answer. Review and save there.'})}],control:{terminate:true}};
    }});
  return defineExtension({name:'banana-workspace',hooks:[hook(GenerationTask,{
    beforeRequest:async({messages},api,ctx)=>{
      const text=getCurrentSystemMessage(messages)?.sections?.['app-workspace']??'';
      const match=text.match(/^(?:<app-workspace>\n)?Revision (\d+)\n/);
      if(match)await api.memo('workspace-basis',Number(match[1]),ctx);
    },
    afterResponse:async(message,api,ctx)=>{
      const revision=await api.memo('workspace-basis',ctx);
      for(const part of message.content)if(part.type==='toolCall'&&names.has(part.name)){
        if(!Number.isSafeInteger(revision))throw new Error('Missing workspace revision.');
        part.arguments={...part.arguments,revision};
      }
    }
  })],sections:[section('app-workspace',async({read,conversationId},ctx)=>{
    const doc=await read.snapshot(WorkspaceDoc,conversationId,ctx);
    return `Revision ${doc?.revision??0}\n`+'Draft tools open native review and never save; never claim a draft is saved. prepare_meal is for a NEW food entry from foods the person listed; prepare_meal_copy repeats an existing logged meal. prepare_event: the activity is the title, the day word goes in day, the clock time in time; ask only when no clock time was given or AM/PM is unclear. Example: {"title":"Writing retreat","day":"tomorrow","isAllDay":true}. The day always goes in the day field (day: "tomorrow"), also for all-day events. Use nutrition_view with foodName for logged meals or a food, even when the person says find or search. search_app finds a named event or quoted text, not a meal. Recent notes: list_notes. One day\'s schedule: day_plan. Current workspace: '+JSON.stringify(brief(doc?.action??null));
  })],tools:[
    tool('prepare_meal','Prepare a NEW meal for native review from foods and amounts the user supplied. Do not estimate nutrition or call this to copy an existing meal.',
      {title:Type.Optional(Type.String()),foods:Type.Array(Type.Object({name:Type.String(),quantity:Type.String()},{additionalProperties:false})),...day},'meal'),
    tool('prepare_event','Open a draft of ONE new one-off calendar event for the person to review; it never saves. Call it when the person gives an activity and a clock time (or says all day). If no clock time was given, or a bare hour like 7 or 12 without AM/PM, call no tool and ask what time. Not for changing, cancelling or repeating events, inviting people or setting alerts.',
      {title:Type.String({description:'The activity as the person said it, or the quoted title exactly; no command words.'}),day:Type.Optional(Type.String({description:'The day word the person said, copied exactly: today, tomorrow, a weekday, or YYYY-MM-DD. Always include it when the person named a day: "X tomorrow at 10:30" is day: "tomorrow", time: "10:30"; "an all-day X tomorrow" is day: "tomorrow", isAllDay: true. Omit only for a time with no day (native code then picks the next occurrence).'})),time:Type.Optional(Type.String({description:'Start as 24-hour HH:mm; omit only for all-day.'})),durationMinutes:Type.Optional(Type.Integer({description:'Only a length the person gave. Default 60.'})),isAllDay:Type.Optional(Type.Boolean()),location:Type.Optional(Type.String()),notes:Type.Optional(Type.String())},'event'),
    ...(mailAvailable ? [tool('prepare_event_from_email', 'After read_mail_thread returned an event time range, open a calendar draft for it. sourceStart and sourceEnd: copied exactly from the email result, with their UTC offsets; notes: what the email says about it. Never saves.',
      {title:Type.String(),sourceStart:Type.String(),sourceEnd:Type.String(),notes:Type.String()},'event')] : []),
    tool('search_app','Find records by name or quoted text across Banana; set section to plan for a named calendar event. query: only the words inside the quotes; never include quote marks. For an event, appointment or calendar entry always set section to plan. Only when the person asks to find or look something up, never as a first step toward editing, moving or setting an alert.',{query:Type.String(),section:Type.Optional(Type.String({enum:['plan','notes'],description:'plan for a named calendar event, notes for text in notes; omit otherwise.'}))},'search'),
    ...(mailAvailable ? [tool('search_mail', 'Show a list of cached emails as a results card, only when the whole request is to find or list emails by keywords or a named sender, with no question about them. query: subject or content keywords; sender, unread and period only when the person said them. Never for a question about mail (contents, replies, status, tasks, summaries): use read_mail_thread.',
      {query:Type.Optional(Type.String()),sender:Type.Optional(Type.String()),unread:Type.Optional(Type.Boolean()),
        period:Type.Optional(Type.String({enum:['today','yesterday','thisWeek','lastWeek','thisMonth','lastMonth','7days','30days']}))},'search','mail')] : []),
    tool('open_page','Open a Banana page, only when the person asks to open, show or go to it.',{section:Type.String({enum:['plan','workouts','nutrition','notes','routines','library','review','assistant','settings',...(mailAvailable ? ['mail'] : [])]})},'navigation')
  ]});
}

// The native card retains all matches; model context needs only a bounded preview.
function brief(action) {
  if (!action) return action;
  const {sourceRequest, ...descriptor} = action;
  if (descriptor.kind==='search' && descriptor.section==='mail')
    return {kind:'search', section:'mail', matchCount:descriptor.results?.length ?? 0};
  if (descriptor.kind !== 'search') return descriptor;
  const results = descriptor.results ?? [];
  return { ...descriptor, results: results.slice(0, 5), hasMoreResults: results.length > 5 };
}
