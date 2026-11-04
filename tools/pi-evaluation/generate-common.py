#!/usr/bin/env python3
"""100 development queries per module: 20 intent families × five entity/phrasing variants.
Not a frequency-ranked or held-out corpus. Expectations describe current capabilities,
not a claim that those capabilities are sufficient for the product.
"""
import copy,json,pathlib,hashlib
ROOT=pathlib.Path(__file__).resolve().parent
base=json.loads((ROOT/'cases.json').read_text())['cases']
clean=next(c['request'] for c in base if c['id']=='greeting')
active=next(c['request'] for c in base if c['id']=='weekdays')
rows=[]
entities=['Dentist','Team lunch','Design review','Dinner','Airport pickup']
terms=['yogurt','chicken','salmon','tofu','oats']
notes=['Bring the blue notebook','Call the hotel','Pack the charger','Ask about the deadline','Remember the reservation']

def add(module,family,pattern,tool=None,args=None,reply=False,status='supported',active_context=False,**extra):
    for i in range(5):
        values={'event':entities[i],'food':terms[i],'note':notes[i], 'hour':['09:15','11:30','14:00','17:00','20:45'][i],
                'minutes':[15,30,45,60,90][i],'topic':['project','travel','meeting','training','shopping'][i],
                'date':['2026-11-03','2026-11-04','2026-11-05','2026-11-06','2026-11-07'][i]}
        prompt=pattern.replace('{note}', '\"{note}\"').format(**values)
        # Spread speech style independently from the entity and time variation.
        prompt=[prompt, 'Hi, '+prompt, 'Please help with this: '+prompt,
                prompt+' Thanks.', 'Quick question: '+prompt.replace('tomorrow','tmrw')][i]
        request=copy.deepcopy(active if active_context else clean)
        request['messages']=[{'role':'user','text':prompt}]
        arguments={k:(v.format(**values) if isinstance(v,str) else v) for k,v in (args or {}).items()}
        if 'durationMinutes' in arguments: arguments['durationMinutes']=values['minutes']
        expected={'tools':{tool:arguments} if tool else {},'reply':reply,**extra}
        rows.append({'id':f'{module}-{family}-{i+1}','module':module,'family':family,'variant':i+1,
                     'contractVersion':1,'capability':status,'expected':expected,'request':request})

def gap(module,family,text):
    # Opening the correct UI is an honest fallback, not completion of the missing capability.
    if module != 'assistant' and family != 'no-write':
        add(module,family,text,'open_page',{'section':module},reply=True,status='capability_gap')
    else:
        add(module,family,text,reply=True,status='capability_gap')
def nav(module,family,text,section): add(module,family,text,'open_page',{'section':section})
def search(module,family,text): add(module,family,text,'search_app',{'query':'{topic}'})

# Plan: reading, drafting, ambiguity, travel and unsupported calendar writes.
for family,text,date in [('today','What is going on today?', 'today'),('tomorrow','What is going on tomorrow?','tomorrow'),('appointments','Show my appointments tomorrow','tomorrow'),('agenda','Give me today’s agenda','today')]:
    add('plan',family,text,'day_plan',{'date':date})
add('plan','dated','What is happening on {date}?','day_plan',{'date':'{date}'})
add('plan','create','Prepare {event} tomorrow at {hour} for {minutes} minutes','prepare_event',{'title':'{event}','time':'{hour}','durationMinutes':30,'day':'tomorrow'})
add('plan','explicit-date','Prepare {event} on {date} at {hour}','prepare_event',{'title':'{event}','time':'{hour}','day':'{date}'})
add('plan','time-only','{event} at {hour}','prepare_event',{'title':'{event}','time':'{hour}'},omitDay=True)
add('plan','missing-time','Schedule {event}, but I have not chosen a time',reply=True,status='clarification')
add('plan','ambiguous','Move that to later',reply=True,status='clarification')
nav('plan','open','Open my calendar','plan')
for f,q in [('delete','Delete all calendar events tomorrow'),('reschedule','Move {event} to {hour}'),('cancel','Cancel {event} tomorrow'),('invite','Invite Alex to {event}'),('recurrence','Schedule {event} every second Tuesday at {hour}'),('flight','Add flight JFK to LHR on {date}, leaving 8pm New York and arriving 8am London next day'),('arrival','What local time does my flight land in Tokyo?'),('timezone','Change my calendar timezone to Europe/London'),('alarm','Set an alarm for {hour} tomorrow')]: gap('plan',f,q)

# Nutrition: grounded views/drafts and unsupported mutation/health claims.
for metric in ['protein','calories','carbs','fat']:
    add('nutrition',metric,'Show my '+metric+' this month','nutrition_view',{'metric':metric,'period':'this_month'})
add('nutrition','week','Show my protein over the last seven days','nutrition_view',{'metric':'protein','period':'last_7_days'})
add('nutrition','find','Find my logged meals containing {food}','nutrition_view',{'foodName':'{food}'})
add('nutrition','new','Prepare a meal with 2 eggs and 1 banana','prepare_meal',foods=['egg','banana'])
add('nutrition','dated','Log 2 eggs and 1 banana for yesterday','prepare_meal',{'day':'yesterday'},foods=['egg','banana'])
add('nutrition','missing-food','Log lunch, but I have not said what I ate',reply=True,status='clarification')
add('nutrition','missing-amount','I had some {food}; ask me the amount before making a meal',reply=True,status='clarification')
add('nutrition','weekdays','Only show weekdays','filter_nutrition',{'changes':['weekdays_only']},active_context=True)
add('nutrition','comparison','Compare with the previous period','filter_nutrition',{'changes':['compare_previous']},active_context=True)
nav('nutrition','open','Open Nutrition','nutrition')
add('nutrition','general','Explain what dietary protein is, without using my records',reply=True)
for f,q in [('delete','Delete all my meal history'),('edit','Change yesterday’s {food} entry to 200 grams'),('goal','Set my protein target to 140 grams'),('supplement','Mark my morning vitamin as taken'),('allergy','Remove every food containing peanuts from my saved meals'),('no-write','I usually eat {food}. Do not log or save this')]: gap('nutrition',f,q)

# Notes: actual reads, explicit writes, retrieval limits and mutation boundaries.
for f,q in [('recent','Show my recent notes'),('latest','Read my latest notes'),('list','List the last five notes'),('today','Show the most recent notes I made'),('browse','What notes have I saved recently?')]: add('notes',f,q,'list_notes')
for f,q in [('save','Save a note with this exact text: {note}'),('create','Create a note: {note}'),('capture','Write this down as a note: {note}')]: add('notes',f,q,'create_note',{'text':'{note}'})
for f,q in [('search','Search across Banana for {topic}'),('find','Find notes mentioning {topic}'),('quote','Find the phrase {topic} in my notes')]: search('notes',f,q)
nav('notes','open','Open Notes','notes')
add('notes','ambiguous','Save that',reply=True,status='clarification')
add('notes','conversation','For context, {note}. Do not create a note',reply=True)
for f,q in [('delete','Delete every note'),('edit','Replace my latest note with {note}'),('share','Email my {topic} notes to Alex'),('archive','Archive all notes about {topic}'),('audio','Transcribe the audio I recorded yesterday'),('folders','Move my {topic} notes into a new folder')]: gap('notes',f,q)

# Modules whose UI exists but whose detailed data/actions are not exposed to the assistant.
module_specs={
'workouts':('workouts',[
('history','Show my workout history'),('latest','Show my latest workout'),('plan','Open my workout plan'),('start','Start a strength workout'),('stop','Stop my current workout'),('log','Log a 30-minute run'),('edit','Change yesterday’s run distance to 5km'),('delete','Delete my latest workout'),('distance','How far did I run this week?'),('heart','What was my average heart rate on my last ride?'),('compare','Compare my last two runs'),('route','Show the route of my last ride'),('calories','How many calories did my last workout burn?'),('streak','How many days in a row have I exercised?'),('export','Export my workout history'),('sync','Sync my Watch workouts now'),('schedule','Schedule three strength workouts each week')]),
'routines':('routines',[
('list','Show my routines'),('morning','Open my morning routine'),('evening','Open my evening routine'),('create','Create a bedtime routine at {hour}'),('edit','Move my morning routine to {hour}'),('delete','Delete my bedtime routine'),('disable','Disable all routines'),('skip','Skip tomorrow’s morning routine'),('complete','Mark my morning routine complete'),('repeat','Repeat my routine only on weekdays'),('rename','Rename my evening routine to Wind down'),('order','Move stretching before breakfast in my routine'),('add-step','Add a glass of water to my morning routine'),('remove-step','Remove meditation from my morning routine'),('history','How often did I complete my routines this week?'),('notification','Turn off routine notifications'),('travel','Shift my routines to London time for my trip')]),
'library':('library',[
('shows','Show my podcast library'),('episodes','Open my downloaded episodes'),('listening','Open my listening history'),('play','Play the newest episode of Acquired'),('pause','Pause my podcast'),('resume','Resume the last podcast'),('seek','Skip ahead 30 seconds'),('speed','Set playback speed to 1.5x'),('download','Download the latest Acquired episode'),('remove','Delete all downloaded episodes'),('subscribe','Subscribe me to a new science podcast'),('unsubscribe','Unsubscribe me from Acquired'),('queue','Add the newest episode to my queue'),('finished','Mark this episode as played'),('timer','Stop playback after 20 minutes'),('where','Where did I listen to my last episode?'),('summary','Summarize the podcast episode I heard yesterday')]),
'review':('review',[
('dashboard','Open my health review'),('sleep','Show my sleep trends'),('activity','Show my activity trends'),('last-night','How much did I sleep last night?'),('sleep-week','What was my average sleep this week?'),('weight','How has my weight changed this month?'),('steps','How many steps did I take yesterday?'),('hrv','What is my current HRV trend?'),('resting','Has my resting heart rate improved?'),('vo2','Show my latest VO2 max value'),('energy','Compare calories burned with food intake'),('missing','Why are yesterday’s health measurements missing?'),('goal','Set a daily goal of 10000 steps'),('correct','Correct my weight to 75kg'),('delete','Delete my sleep history'),('timezone','Did my flight make my sleep look shorter?'),('diagnosis','Diagnose why my heart rate went up from my records')]),
'settings':('settings',[
('open','Open Settings'),('privacy','Show the privacy settings'),('calendar','Show calendar connection settings'),('connect','Connect my Google account'),('disconnect','Disconnect all my accounts'),('timezone','Set my timezone to Asia/Tokyo'),('units','Switch distance units to kilometers'),('notifications','Disable every notification'),('theme','Enable dark mode'),('export','Export all my personal data'),('delete','Delete all app data'),('backup','Back up my data now'),('restore','Restore yesterday’s backup'),('permissions','Grant access to my microphone'),('sample','Turn off all sample data'),('model','Download a different AI model'),('sync','Enable iCloud sync')]),
'assistant':('assistant',[
('open','Open the assistant'),('greeting','Hello'),('identity','What is your name?'),('capabilities','What can you help me with?'),('thanks','Thank you'),('explain','Explain what a timezone is in plain language'),('general','Give me three ideas for organizing a busy day'),('ambiguous','Do the thing we discussed'),('missing','Can you fix it?'),('private','Tell me my password'),('clear','Delete all our conversations'),('new','Start a new conversation'),('remember','Remember that I prefer tea, without creating a note'),('model','Switch to another AI model'),('offline','Are you reading my private email right now?'),('external','Send Alex a message saying I am late'),('no-action','Do not change anything, just explain what an agenda is')])}
for module,(section,intents) in module_specs.items():
    nav(module,'navigation','Open the '+('Review' if module=='review' else module.title())+' page',section)
    search(module,'search','Search Banana for {topic}')
    add(module,'unclear','Do something with that {topic} thing; I have not specified what',reply=True,status='clarification')
    for index,(family,prompt) in enumerate(intents):
        if index<3 and module!='assistant': nav(module,family,prompt,section)
        elif module=='assistant' and family=='open': nav(module,family,prompt,section)
        elif module=='assistant' and family in ('greeting','identity','capabilities','thanks','explain','general','ambiguous','missing','remember','offline','no-action'):
            add(module,family,prompt,reply=True,status='clarification' if family in ('ambiguous','missing') else 'supported')
        else: gap(module,family,prompt)

from collections import Counter
counts=Counter(c['module'] for c in rows)
assert len(counts)==9 and set(counts.values())=={100},counts
assert len({c['id'] for c in rows})==900
result={'version':1,'scope':'900 synthetic development routing/argument contracts, 100 per module. 20 intent families × 5 variants; not empirical top-query rankings, not held-out accuracy, and not end-to-end action tests. Text-only responses require semantic review. Capability gaps are labeled explicitly.','date':'2026-10-25','moduleCounts':dict(counts),'cases':rows}
result['sha256']=hashlib.sha256(json.dumps(rows,sort_keys=True).encode()).hexdigest()
import argparse
parser=argparse.ArgumentParser();parser.add_argument('--output',type=pathlib.Path,default=ROOT/'common-queries-v1.json')
output=parser.parse_args().output
output.write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({'counts':dict(counts),'sha256':result['sha256']}))
