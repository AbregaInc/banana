import test from 'node:test';
import assert from 'node:assert/strict';
import {nutritionCommand,requestsUnsupportedAction} from './command-contracts.js';
test('native metric vocabulary and periods produce structured chart controls',()=>{
 for(const metric of ['protein','calories','carbs','fat']){
  assert.deepEqual(nutritionCommand(`Hi, Show my ${metric} this month`,false),{name:'nutrition_view',arguments:{metric,period:'this_month'}});
  assert.deepEqual(nutritionCommand(`Please show ${metric} over the last seven days. Thanks.`,false),{name:'nutrition_view',arguments:{metric,period:'last_7_days'}});
 }
});
test('chart filters require an existing chart and cannot become routine actions',()=>{
 assert.equal(nutritionCommand('Only show weekdays',false),null);
 assert.deepEqual(nutritionCommand('Quick question: Only show weekdays',true),{name:'filter_nutrition',arguments:{changes:['weekdays_only']}});
 assert.deepEqual(nutritionCommand('Compare with the previous period',true),{name:'filter_nutrition',arguments:{changes:['compare_previous']}});
 for(const words of ['Repeat my routine only on weekdays','Compare calories burned with food intake','Show my body fat this month','Create a note: "Only show weekdays"','Do not show calories this month'])assert.equal(nutritionCommand(words,true),null,words);
});
test('a create operation cannot stand in for an explicit stored-record mutation',()=>{
 for(const words of ['Replace my latest note with "hello"','Change yesterday’s chicken entry to 200 grams','Please invite Morgan to Dinner','Please help with this: Change my calendar timezone to Europe/London','Download a different model','Delete my meal history','Move my morning routine to 8am'])assert.equal(requestsUnsupportedAction(words),true,words);
});
test('quoted data, draft refinement and supplied prose are not stored-record mutations',()=>{
 for(const words of ['Create a note: "Replace my latest note"','Find notes containing "Delete my history"','Replace the word calendar with agenda in this sentence','Change the title of this draft note','Prepare a meeting to invite Morgan tomorrow at noon','Replace the air filter at 5pm'])assert.equal(requestsUnsupportedAction(words),false,words);
});
test('stored prose edits and playback or workout control cannot be conversation promises',()=>{
 for(const words of ['Rewrite my newest note to say hello','Fast forward this episode by a minute','Skip ahead 30 seconds Thanks.','Hi, Start a strength workout'])assert.equal(requestsUnsupportedAction(words),true,words);
 for(const words of ['Rewrite this sentence','Start a note about my workout','Explain how to pause playback','Create a note: "Pause my podcast"'])assert.equal(requestsUnsupportedAction(words),false,words);
});
