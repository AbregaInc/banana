import test from 'node:test';
import assert from 'node:assert/strict';
import {directPageCommand,directConversationCommand,hideQuotedData,searchWithoutCourtesy} from './request-language.js';
test('direct navigation grammar applies to every page and polite wrappers',()=>{
 for(const page of ['plan','workouts','nutrition','notes','routines','library','review','assistant','settings']){
  for(const command of [`Open ${page}`,`Hello, please open the ${page} page.`,`Could you take me to ${page}?`,`Please help with this: Open ${page}`,`Show the ${page} screen, thank you.`])assert.equal(directPageCommand(command),page,command);
 }
});
test('navigation shortcut does not execute negation, quoted commands or compound actions',()=>{
 for(const command of ['Do not open Notes','Create a note: "Open Notes"','Search for Open Notes','Open Notes and delete them','If I ask later, open Notes','Show my notes','Open Notes tomorrow','Please do not open Notes'])assert.equal(directPageCommand(command),null,command);
});
test('quoted data is hidden only from capability selection',()=>{
 assert.equal(hideQuotedData('For context, "Ask about the deadline". Do not create a note.'),'For context, [quoted text]. Do not create a note.');
 assert.equal(hideQuotedData('Create a note: “Cancel my flight”'),'Create a note: [quoted text]');
});
test('courtesy removal preserves literal searches and standalone titles',()=>{
 assert.equal(searchWithoutCourtesy('training Thanks','Search for training Thanks.'),'training');
 assert.equal(searchWithoutCourtesy('project thank you','Find project, thank you.'),'project');
 assert.equal(searchWithoutCourtesy('Giving Thanks','Find "Giving Thanks"'),'Giving Thanks');
 assert.equal(searchWithoutCourtesy('Giving Thanks','Find “Giving Thanks”, please'),'Giving Thanks');
 assert.equal(searchWithoutCourtesy('Thanks','Find Thanks'),'Thanks');
 assert.equal(searchWithoutCourtesy('please','Find "please"'),'please');
});

test('conversation command grammar distinguishes new threads from quoted or negated data',()=>{
 for(const words of ['Start a new conversation','Please begin a fresh chat, thanks','Quick question: Open a new thread'])assert.equal(directConversationCommand(words),'new');
 for(const words of ['Do not start a new conversation','Create a note: "Start a new conversation"','Start a new conversation and delete the old one'])assert.equal(directConversationCommand(words),null);
});
