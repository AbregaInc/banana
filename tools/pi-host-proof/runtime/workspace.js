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

export function workspaceExtension(nativeTool, uuid, requestText = async () => undefined) {
  const names = new Set(['prepare_meal', 'prepare_event', 'search_app', 'open_page']);
  const day = { day: Type.Optional(Type.String({description:'today, tomorrow, yesterday, or an explicit YYYY-MM-DD date. Default today.'})) };
  const tool = (name, description, fields, kind) => defineTool({name,description,
    parameters:Type.Object({...fields,revision:Type.Optional(Type.Integer({description:'Host metadata; omit.'}))},{additionalProperties:false}),replay:'safe',
    execute:async(args,api,ctx)=>{
      const operation=await api.memo('workspace-operation',uuid(),ctx);
      const sourceRequest=await requestText(api,ctx);
      const action=await updateWorkspace(api,api.conversationId,{...args,kind,...(sourceRequest ? {sourceRequest} : {})},operation,nativeTool,ctx);
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
    return `Revision ${doc?.revision??0}\n`+'Use prepare_meal for NEW food entries, prepare_meal_copy for an existing logged meal. Use prepare_event to open the real event editor; ask for a missing start time. An event activity plus a start time is sufficient: call prepare_event immediately, using the activity as title. Do not ask for a date or a different title. Omit day when none was requested; native code chooses the next future occurrence of the clock time. Draft tools do not save. Use nutrition_view with foodName for requests explicitly about logged meals or a food, even when the user says find or search. Use search_app for cross-category Banana searches or quoted-text searches, not a meal-specific filter. Recent notes use list_notes; schedule questions use day_plan. open_page offers navigation to the actual app page. Never claim a draft is saved. Current workspace: '+JSON.stringify(brief(doc?.action??null));
  })],tools:[
    tool('prepare_meal','Prepare a NEW meal for native review from foods and amounts the user supplied. Do not estimate nutrition or call this to copy an existing meal.',
      {title:Type.Optional(Type.String()),foods:Type.Array(Type.Object({name:Type.String(),quantity:Type.String()},{additionalProperties:false})),...day},'meal'),
    tool('prepare_event','Prepare a calendar event for native review, never save. Use the stated activity as the title: an activity plus a time is enough to prepare an event. Do not ask for a separate event name or an omitted day. Use only requested date/time, duration and details. Ask if the start time is missing; default duration is 60 minutes.',
      {title:Type.String({description:'Use the activity phrase already supplied by the user. Do not request a separate or more formal event name.'}),day:Type.Optional(Type.String({description:'Only a day explicitly requested by the user: today, tomorrow, yesterday, or YYYY-MM-DD. Omit for a time-only request; native code chooses the next occurrence, never a past default.'})),time:Type.Optional(Type.String({description:'Local 24-hour HH:mm; required unless explicitly all-day.'})),durationMinutes:Type.Optional(Type.Integer()),isAllDay:Type.Optional(Type.Boolean()),location:Type.Optional(Type.String()),notes:Type.Optional(Type.String())},'event'),
    tool('search_app','Search ACROSS Banana categories or for quoted text. For searches explicitly about logged meals/foods use nutrition_view with foodName instead. Returns a native list with app links.',{query:Type.String()},'search'),
    tool('open_page','Offer a link to a Banana page.',{section:Type.String({enum:['plan','workouts','nutrition','notes','routines','library','review','assistant','settings']})},'navigation')
  ]});
}

// The native card retains all matches; model context needs only a bounded preview.
function brief(action) {
  if (!action) return action;
  const {sourceRequest, ...descriptor} = action;
  if (descriptor.kind !== 'search') return descriptor;
  const results = descriptor.results ?? [];
  return { ...descriptor, results: results.slice(0, 5), hasMoreResults: results.length > 5 };
}
