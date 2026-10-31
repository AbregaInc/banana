import {parse,matches,describe,records,people,criterion,rangeLabels} from './filter-engine.js';
const $=s=>document.querySelector(s),clone=x=>structuredClone(x);
const config={
 plan:{title:'Plan',noun:'events',icon:'▦',examples:['Work meetings next week, excluding declined','Meetings with Alex next week','Not work today']},
 mail:{title:'Email',noun:'conversations',icon:'✉',examples:['Unread emails from Alex Morgan','Starred emails','Emails from Alex']},
 notes:{title:'Notes',noun:'notes',icon:'≡',examples:['Unarchived notes about physical therapy','Archived notes','Notes about product review']},
 body:{title:'Workouts',noun:'workouts',icon:'↗',examples:['Strength workouts longer than 30 minutes this week','Running workouts today','Strength workouts last week']}
};
let scope='plan',draft=parse(config.plan.examples[0],'plan'),applied=[],inputDirty=false,editing=-1;
const states=new Map();
let pending;
function cancelPending(){clearTimeout(pending);pending=undefined;}
function el(tag,text,className){const n=document.createElement(tag);if(text!==undefined)n.textContent=text;if(className)n.className=className;return n;}
function saveState(){states.set(scope,{draft:clone(draft),applied:clone(applied),input:$('#query').value,inputDirty});}
function setScope(next){if(inputDirty)interpret($('#query').value);saveState();scope=next;const old=states.get(scope);draft=old?.draft||parse(config[scope].examples[0],scope);applied=old?.applied||[];inputDirty=old?.inputDirty||false;$('#query').value=old?.input??draft.source;$('#state-note').textContent='';render();}
function interpret(text){cancelPending();draft=parse(text,scope);inputDirty=false;$('#query').value=text;$('#state-note').textContent=draft.issues.length?'Choose a person to show matching results.':'Results updated.';render();}
function changed(){cancelPending();if(!inputDirty)$('#query').value='';$('#state-note').textContent='Results updated.';render();}
function render(){
 if(!inputDirty&&!draft.issues.length)applied=clone(draft.filters);
 const c=config[scope];$('#title').textContent=c.title;
 document.querySelectorAll('[data-scope]').forEach(b=>b.setAttribute('aria-pressed',b.dataset.scope===scope));
 $('#examples').replaceChildren(...c.examples.map(text=>{const b=el('button',text,'example');b.type='button';b.onclick=()=>interpret(text);return b;}));
 $('#filter-title').textContent='Filters';$('#applied-indicator').textContent=inputDirty?'Updating':draft.issues.length?'Needs clarification':'Live';
 $('#chips').replaceChildren(...draft.filters.map((f,index)=>{
  const [key,value]=describe(f),chip=el('div',undefined,'chip'),edit=el('button',undefined,'edit'),remove=el('button','×','remove');
  edit.type='button';edit.append(el('span',key+': ','key'),document.createTextNode(value));edit.setAttribute('aria-label','Edit '+key+': '+value);edit.onclick=()=>openEditor(index);
  remove.type='button';remove.setAttribute('aria-label','Remove '+key+' filter');remove.onclick=()=>{draft.filters.splice(index,1);changed();};chip.append(edit,remove);return chip;
 }));
 if(!draft.filters.length)$('#chips').append(el('span','No filters. All '+c.noun+' are included.','subtle'));
 $('#issues').replaceChildren(...draft.issues.map((issue,index)=>{
  const box=el('div',undefined,'issue');box.append(el('p',issue.message));
  if(issue.kind==='person'){
   const choices=el('div',undefined,'people');for(const p of issue.options){const b=el('button',undefined,'person');b.type='button';b.append(el('span',p.name),el('small',p.detail));b.onclick=()=>{draft.filters.push(criterion('person','is',p.id));draft.issues.splice(index,1);changed();};choices.append(b);}box.append(choices);
  }else box.append(el('small','Edit the sentence to update the filters.'));
  return box;
 }));
 $('#chips').inert=inputDirty;$('#issues').inert=inputDirty;
 const rows=draft.issues.length?[]:records[scope].filter(r=>matches(r,applied));$('#count').textContent=rows.length+' sample '+c.noun;
 $('#result-title').textContent=applied.length?'Filtered '+c.noun:'All '+c.noun;
 $('#results').replaceChildren(...rows.map(row=>{
  const n=el('article',undefined,'row'),body=el('div'),time=el('time');n.dataset.record=String(row.id);body.append(el('div',row.title,'row-title'),el('div',row.detail,'detail'));time.append(document.createTextNode(row.date.slice(5).replace('-','/')),el('br'),document.createTextNode(row.time));n.append(el('span',c.icon,'record-icon'),body,time);return n;
 }));
 if(!rows.length){const e=el('div',undefined,'empty');e.append(el('strong',draft.issues.length?'A little more detail needed':'No matching '+c.noun),el('span',draft.issues.length?'Resolve the question above to see results.':'Try removing a filter or widening the date range.'));$('#results').append(e);}
 $('#explanation').textContent=inputDirty?'Updating filters…':'Results update automatically. Tap a filter to adjust it.';
 saveState();
}
function labeled(name,control){const label=el('label',name,'field');label.append(control);return label;}
function select(name,options,value){const s=el('select');s.name=name;s.id='edit-'+name;for(const [v,label]of options){const o=el('option',label);o.value=String(v);s.append(o);}s.value=String(value);return s;}
function openEditor(index){editing=index;const f=draft.filters[index],[key]=describe(f);$('#edit-title').textContent='Edit '+key.toLowerCase();const fields=[];
 if(['calendar','status'].includes(f.field))fields.push(labeled('Condition',select('op',[['is','Is'],['not','Is not']],f.op)));
 const choices={calendar:[['work','Work'],['personal','Personal'],['family','Family']],date:Object.entries(rangeLabels),status:[['accepted','Accepted'],['declined','Declined'],['canceled','Canceled']],person:people.map(p=>[p.id,p.name]),unread:[['true','Unread'],['false','Read']],starred:[['true','Starred'],['false','Not starred']],archived:[['false','Unarchived'],['true','Archived']],kind:scope==='body'?[['strength','Strength'],['running','Running']]:[['meeting','Meeting']]};
 let control;if(choices[f.field])control=select('value',choices[f.field],f.value);else{control=el('input');control.name='value';control.id='edit-value';control.value=f.value;control.required=true;if(f.field==='duration'){control.type='number';control.min='0';}}
 fields.push(labeled(f.field==='duration'?'Longer than (minutes)':key,control));
 $('#editor-fields').replaceChildren(...fields);$('#editor').showModal();
}
function updateEditor(){const form=$('#edit-form');if(!form.checkValidity())return;const f=draft.filters[editing],data=new FormData(form),value=data.get('value');f.value=['unread','starred','archived'].includes(f.field)?value==='true':f.field==='duration'?Number(value):value;if(data.has('op'))f.op=data.get('op');changed();}
$('#edit-form').oninput=updateEditor;
$('#edit-form').onchange=updateEditor;
$('#edit-form').onsubmit=e=>{e.preventDefault();updateEditor();$('#editor').close();};
$('#cancel-edit').onclick=()=>$('#editor').close();
$('#form').onsubmit=e=>{e.preventDefault();interpret($('#query').value);};
function schedule(event){cancelPending();inputDirty=true;$('#chips').inert=true;$('#issues').inert=true;$('#explanation').textContent='Updating filters…';$('#applied-indicator').textContent='Updating';$('#state-note').textContent='';if(!event?.isComposing)pending=setTimeout(()=>interpret($('#query').value),350);}
$('#query').oninput=schedule;
$('#query').oncompositionstart=()=>schedule({isComposing:true});
$('#query').oncompositionend=()=>schedule();
$('#clear').onclick=()=>{cancelPending();draft={version:1,scope,match:'all',filters:[],issues:[],source:''};applied=[];inputDirty=false;$('#query').value='';$('#state-note').textContent='All filters cleared.';render();};
document.querySelectorAll('[data-scope]').forEach(b=>b.onclick=()=>setScope(b.dataset.scope));
$('#query').value=draft.source;render();
