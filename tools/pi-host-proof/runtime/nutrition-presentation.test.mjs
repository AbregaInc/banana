import test from 'node:test';
import assert from 'node:assert/strict';
import {nutritionInputId,nutritionForInput} from './nutrition-presentation.js';
test('new questions do not display charts from an earlier input',()=>{
 const surface={metric:'protein'};
 const doc={inputId:'first',surface};
 assert.equal(nutritionForInput(doc,'first'),surface);
 assert.equal(nutritionForInput(doc,'second'),null);
 assert.equal(nutritionForInput({surface},'first'),null); // Existing saved views lack attribution.
});
test('input identity ignores tool continuations and distinguishes repeated words',()=>{
 const user=id=>({id,model:[{role:'user',content:'Same words'}]});
 assert.equal(nutritionInputId([{id:'tool',model:[{role:'toolResult'}]},user('second'),user('first')]),'second');
 assert.equal(nutritionInputId([]),null);
});
