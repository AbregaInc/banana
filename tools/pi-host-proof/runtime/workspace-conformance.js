import { BACKGROUND_CONTEXT as ctx } from '@earendil-works/chord/context';
import { Harness, createRegistry } from '@earendil-works/pi-durable';
import { createModels } from '@earendil-works/pi-ai/models';
import { fauxProvider, fauxAssistantMessage, fauxToolCall } from '@earendil-works/pi-ai/providers/faux';
import { SqliteStorage } from '@earendil-works/pi-durable/storage/sqlite';
import { NativeDatabase } from './database.js';
import { WorkspaceDoc, updateWorkspace, workspaceExtension, workspaceRequestText } from './workspace.js';

export async function runWorkspaceConformance() {
  const results=[];
  const check=(ok,name)=>{if(!ok)throw new Error(name);results.push(name);};
  const models=createModels(),registry=createRegistry();
  let validations=0;
  const native=async({arguments:fields,operationId:id})=>{validations++;return {id,kind:fields.kind,title:fields.title??fields.query,...(fields.sourceRequest ? {sourceRequest:fields.sourceRequest} : {})};};
  const extension=workspaceExtension(native,()=> 'a3a38a30-85ce-4bdb-8740-205576446310',(api,context)=>workspaceRequestText(harness,api,context));
  registry.install(extension);
  const open=async()=>Harness.open(await SqliteStorage.open(new NativeDatabase()),{models,registry},ctx);
  let harness=await open();
  try {
    check(extension.tools.every(t=>JSON.parse(nativeModelValidateSchema(JSON.stringify(t.parameters))).ok),'All workspace tool schemas translate for Apple models');
    const root=await harness.root(ctx),id=root.id;
    await updateWorkspace(harness,id,{revision:0,kind:'meal',title:'Breakfast'},'meal-1',native,ctx);
    const first=await harness.snapshot(WorkspaceDoc,id,ctx);
    check(first.revision===1&&first.action.id==='meal-1','Pi commits the native draft and its stable review identity');
    await updateWorkspace(harness,id,{revision:0,kind:'meal',title:'Breakfast'},'meal-1',native,ctx);
    check(validations===1&&(await harness.snapshot(WorkspaceDoc,id,ctx)).revision===1,'Acknowledgement retry neither validates nor commits twice');
    let rejected=false;
    try{await updateWorkspace(harness,id,{revision:0,kind:'event',title:'Wrong'},'old',native,ctx);}catch{rejected=true;}
    check(rejected,'Stale revision cannot replace an active draft');
    rejected=false;
    try{await updateWorkspace(harness,id,{revision:1,kind:'event'},'invalid',async()=>{throw new Error('Invalid date');},ctx);}catch{rejected=true;}
    check(rejected&&(await harness.snapshot(WorkspaceDoc,id,ctx)).action.id==='meal-1','Native validation failure preserves the previous workspace');
    await harness.close(ctx);harness=await open();
    check((await harness.snapshot(WorkspaceDoc,id,ctx)).action.id==='meal-1','Cold SQLite reopen restores the review draft');
    const other=await harness.createConversation({ownership:{kind:'ownerless'}},ctx);
    check(!await harness.snapshot(WorkspaceDoc,other.id,ctx),'Another conversation does not inherit the draft');
    let release,began;
    const started=new Promise(resolve=>{began=resolve;});
    const late=updateWorkspace(harness,id,{revision:1,kind:'event',title:'Late'},'late',async r=>{began();await new Promise(resolve=>{release=resolve;});return native(r);},ctx).then(()=>false,()=>true);
    await started;
    await updateWorkspace(harness,id,{revision:1,kind:'dismiss'},'dismiss',native,ctx);
    release();check(await late,'An inference result cannot resurrect a draft dismissed during validation');
    check((await harness.snapshot(WorkspaceDoc,id,ctx)).action===null,'Dismiss is persisted by Pi');
    const faux=fauxProvider();models.setProvider(faux.provider);
    const conversation=await harness.conversation(id,ctx);
    await conversation.configure({model:{provider:'faux',modelId:'faux-1'}},ctx);
    let calls=0;
    faux.setResponses([()=>{calls++;return fauxAssistantMessage([fauxToolCall('search_app',{query:'breakfast',revision:999})],{stopReason:'toolUse'});},()=>{calls++;return fauxAssistantMessage('Extra');}]);
    await(await conversation.submit({type:'input',content:'Find breakfast',requestId:'workspace-hook'},ctx)).wait(ctx);
    const final=await harness.snapshot(WorkspaceDoc,id,ctx);
    check(final.revision===3&&final.action.kind==='search','Generation hook supplies host revision rather than trusting model metadata');
    check(calls===1,'Native workspace publication ends the turn without another inference');
    check(final.action.sourceRequest==='Find breakfast','A draft retains the exact user request from its own tool invocation');
    await harness.close(ctx);harness=await open();
    check((await harness.snapshot(WorkspaceDoc,id,ctx)).action.sourceRequest==='Find breakfast','Draft provenance survives cold reopen');
    return {passed:true,total:results.length,results};
  }finally{await harness.close(ctx);}
}
