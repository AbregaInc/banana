# 900 common-query development cases

Twenty intent families × five variants per module. Synthetic, not ranked by actual usage.

## Plan

| Query | Capability | Result |
|---|---|---|
| What is going on today? | supported | tool_contract_pass |
| Hi, What is going on today? | supported | tool_contract_pass |
| Please help with this: What is going on today? | supported | tool_contract_pass |
| What is going on today? Thanks. | supported | tool_contract_pass |
| Quick question: What is going on today? | supported | tool_contract_pass |
| What is going on tomorrow? | supported | tool_contract_pass |
| Hi, What is going on tomorrow? | supported | tool_contract_pass |
| Please help with this: What is going on tomorrow? | supported | tool_contract_pass |
| What is going on tomorrow? Thanks. | supported | tool_contract_pass |
| Quick question: What is going on tmrw? | supported | tool_contract_pass |
| Show my appointments tomorrow | supported | tool_contract_pass |
| Hi, Show my appointments tomorrow | supported | tool_contract_pass |
| Please help with this: Show my appointments tomorrow | supported | tool_contract_pass |
| Show my appointments tomorrow Thanks. | supported | tool_contract_pass |
| Quick question: Show my appointments tmrw | supported | tool_contract_pass |
| Give me today’s agenda | supported | tool_contract_pass |
| Hi, Give me today’s agenda | supported | tool_contract_pass |
| Please help with this: Give me today’s agenda | supported | tool_contract_pass |
| Give me today’s agenda Thanks. | supported | tool_contract_pass |
| Quick question: Give me today’s agenda | supported | tool_contract_pass |
| What is happening on 2026-11-03? | supported | tool_contract_pass |
| Hi, What is happening on 2026-11-04? | supported | tool_contract_pass |
| Please help with this: What is happening on 2026-11-05? | supported | tool_contract_pass |
| What is happening on 2026-11-06? Thanks. | supported | tool_contract_pass |
| Quick question: What is happening on 2026-11-07? | supported | tool_contract_pass |
| Prepare Dentist tomorrow at 09:15 for 15 minutes | supported | tool_contract_pass |
| Hi, Prepare Team lunch tomorrow at 11:30 for 30 minutes | supported | tool_contract_pass |
| Please help with this: Prepare Design review tomorrow at 14:00 for 45 minutes | supported | tool_contract_pass |
| Prepare Dinner tomorrow at 17:00 for 60 minutes Thanks. | supported | tool_contract_pass |
| Quick question: Prepare Airport pickup tmrw at 20:45 for 90 minutes | supported | tool_contract_pass |
| Prepare Dentist on 2026-11-03 at 09:15 | supported | tool_contract_pass |
| Hi, Prepare Team lunch on 2026-11-04 at 11:30 | supported | tool_contract_pass |
| Please help with this: Prepare Design review on 2026-11-05 at 14:00 | supported | tool_contract_pass |
| Prepare Dinner on 2026-11-06 at 17:00 Thanks. | supported | tool_contract_pass |
| Quick question: Prepare Airport pickup on 2026-11-07 at 20:45 | supported | tool_contract_pass |
| Dentist at 09:15 | supported | tool_contract_pass |
| Hi, Team lunch at 11:30 | supported | invented_day |
| Please help with this: Design review at 14:00 | supported | tool_contract_pass |
| Dinner at 17:00 Thanks. | supported | tool_contract_pass |
| Quick question: Airport pickup at 20:45 | supported | tool_contract_pass |
| Schedule Dentist, but I have not chosen a time | clarification | wrong_tool |
| Hi, Schedule Team lunch, but I have not chosen a time | clarification | wrong_tool |
| Please help with this: Schedule Design review, but I have not chosen a time | clarification | wrong_tool |
| Schedule Dinner, but I have not chosen a time Thanks. | clarification | wrong_tool |
| Quick question: Schedule Airport pickup, but I have not chosen a time | clarification | wrong_tool |
| Move that to later | clarification | reply_needs_semantic_review |
| Hi, Move that to later | clarification | reply_needs_semantic_review |
| Please help with this: Move that to later | clarification | reply_needs_semantic_review |
| Move that to later Thanks. | clarification | reply_needs_semantic_review |
| Quick question: Move that to later | clarification | reply_needs_semantic_review |
| Open my calendar | supported | tool_contract_pass |
| Hi, Open my calendar | supported | tool_contract_pass |
| Please help with this: Open my calendar | supported | tool_contract_pass |
| Open my calendar Thanks. | supported | tool_contract_pass |
| Quick question: Open my calendar | supported | tool_contract_pass |
| Delete all calendar events tomorrow | capability_gap | reply_needs_semantic_review |
| Hi, Delete all calendar events tomorrow | capability_gap | reply_needs_semantic_review |
| Please help with this: Delete all calendar events tomorrow | capability_gap | reply_needs_semantic_review |
| Delete all calendar events tomorrow Thanks. | capability_gap | reply_needs_semantic_review |
| Quick question: Delete all calendar events tmrw | capability_gap | reply_needs_semantic_review |
| Move Dentist to 09:15 | capability_gap | wrong_tool |
| Hi, Move Team lunch to 11:30 | capability_gap | wrong_tool |
| Please help with this: Move Design review to 14:00 | capability_gap | wrong_tool |
| Move Dinner to 17:00 Thanks. | capability_gap | wrong_tool |
| Quick question: Move Airport pickup to 20:45 | capability_gap | wrong_tool |
| Cancel Dentist tomorrow | capability_gap | reply_needs_semantic_review |
| Hi, Cancel Team lunch tomorrow | capability_gap | wrong_tool |
| Please help with this: Cancel Design review tomorrow | capability_gap | wrong_tool |
| Cancel Dinner tomorrow Thanks. | capability_gap | reply_needs_semantic_review |
| Quick question: Cancel Airport pickup tmrw | capability_gap | wrong_tool |
| Invite Alex to Dentist | capability_gap | reply_needs_semantic_review |
| Hi, Invite Alex to Team lunch | capability_gap | reply_needs_semantic_review |
| Please help with this: Invite Alex to Design review | capability_gap | reply_needs_semantic_review |
| Invite Alex to Dinner Thanks. | capability_gap | wrong_tool |
| Quick question: Invite Alex to Airport pickup | capability_gap | wrong_tool |
| Schedule Dentist every second Tuesday at 09:15 | capability_gap | wrong_tool |
| Hi, Schedule Team lunch every second Tuesday at 11:30 | capability_gap | missing_capability_boundary |
| Please help with this: Schedule Design review every second Tuesday at 14:00 | capability_gap | wrong_tool |
| Schedule Dinner every second Tuesday at 17:00 Thanks. | capability_gap | wrong_tool |
| Quick question: Schedule Airport pickup every second Tuesday at 20:45 | capability_gap | wrong_tool |
| Add flight JFK to LHR on 2026-11-03, leaving 8pm New York and arriving 8am London next day | capability_gap | wrong_tool |
| Hi, Add flight JFK to LHR on 2026-11-04, leaving 8pm New York and arriving 8am London next day | capability_gap | wrong_tool |
| Please help with this: Add flight JFK to LHR on 2026-11-05, leaving 8pm New York and arriving 8am London next day | capability_gap | wrong_tool |
| Add flight JFK to LHR on 2026-11-06, leaving 8pm New York and arriving 8am London next day Thanks. | capability_gap | wrong_tool |
| Quick question: Add flight JFK to LHR on 2026-11-07, leaving 8pm New York and arriving 8am London next day | capability_gap | wrong_tool |
| What local time does my flight land in Tokyo? | capability_gap | reply_needs_semantic_review |
| Hi, What local time does my flight land in Tokyo? | capability_gap | wrong_tool |
| Please help with this: What local time does my flight land in Tokyo? | capability_gap | reply_needs_semantic_review |
| What local time does my flight land in Tokyo? Thanks. | capability_gap | reply_needs_semantic_review |
| Quick question: What local time does my flight land in Tokyo? | capability_gap | wrong_tool |
| Change my calendar timezone to Europe/London | capability_gap | reply_needs_semantic_review |
| Hi, Change my calendar timezone to Europe/London | capability_gap | argument_section |
| Please help with this: Change my calendar timezone to Europe/London | capability_gap | argument_section |
| Change my calendar timezone to Europe/London Thanks. | capability_gap | argument_section |
| Quick question: Change my calendar timezone to Europe/London | capability_gap | reply_needs_semantic_review |
| Set an alarm for 09:15 tomorrow | capability_gap | wrong_tool |
| Hi, Set an alarm for 11:30 tomorrow | capability_gap | wrong_tool |
| Please help with this: Set an alarm for 14:00 tomorrow | capability_gap | wrong_tool |
| Set an alarm for 17:00 tomorrow Thanks. | capability_gap | wrong_tool |
| Quick question: Set an alarm for 20:45 tmrw | capability_gap | wrong_tool |
## Nutrition

| Query | Capability | Result |
|---|---|---|
| Show my protein this month | supported | not run |
| Hi, Show my protein this month | supported | not run |
| Please help with this: Show my protein this month | supported | not run |
| Show my protein this month Thanks. | supported | not run |
| Quick question: Show my protein this month | supported | not run |
| Show my calories this month | supported | not run |
| Hi, Show my calories this month | supported | not run |
| Please help with this: Show my calories this month | supported | not run |
| Show my calories this month Thanks. | supported | not run |
| Quick question: Show my calories this month | supported | not run |
| Show my carbs this month | supported | not run |
| Hi, Show my carbs this month | supported | not run |
| Please help with this: Show my carbs this month | supported | not run |
| Show my carbs this month Thanks. | supported | not run |
| Quick question: Show my carbs this month | supported | not run |
| Show my fat this month | supported | not run |
| Hi, Show my fat this month | supported | not run |
| Please help with this: Show my fat this month | supported | not run |
| Show my fat this month Thanks. | supported | not run |
| Quick question: Show my fat this month | supported | not run |
| Show my protein over the last seven days | supported | not run |
| Hi, Show my protein over the last seven days | supported | not run |
| Please help with this: Show my protein over the last seven days | supported | not run |
| Show my protein over the last seven days Thanks. | supported | not run |
| Quick question: Show my protein over the last seven days | supported | not run |
| Find my logged meals containing yogurt | supported | not run |
| Hi, Find my logged meals containing chicken | supported | not run |
| Please help with this: Find my logged meals containing salmon | supported | not run |
| Find my logged meals containing tofu Thanks. | supported | not run |
| Quick question: Find my logged meals containing oats | supported | not run |
| Prepare a meal with 2 eggs and 1 banana | supported | tool_contract_pass |
| Hi, Prepare a meal with 2 eggs and 1 banana | supported | tool_contract_pass |
| Please help with this: Prepare a meal with 2 eggs and 1 banana | supported | tool_contract_pass |
| Prepare a meal with 2 eggs and 1 banana Thanks. | supported | tool_contract_pass |
| Quick question: Prepare a meal with 2 eggs and 1 banana | supported | tool_contract_pass |
| Log 2 eggs and 1 banana for yesterday | supported | tool_contract_pass |
| Hi, Log 2 eggs and 1 banana for yesterday | supported | tool_contract_pass |
| Please help with this: Log 2 eggs and 1 banana for yesterday | supported | tool_contract_pass |
| Log 2 eggs and 1 banana for yesterday Thanks. | supported | tool_contract_pass |
| Quick question: Log 2 eggs and 1 banana for yesterday | supported | missing_tool |
| Log lunch, but I have not said what I ate | clarification | reply_needs_semantic_review |
| Hi, Log lunch, but I have not said what I ate | clarification | reply_needs_semantic_review |
| Please help with this: Log lunch, but I have not said what I ate | clarification | reply_needs_semantic_review |
| Log lunch, but I have not said what I ate Thanks. | clarification | reply_needs_semantic_review |
| Quick question: Log lunch, but I have not said what I ate | clarification | reply_needs_semantic_review |
| I had some yogurt; ask me the amount before making a meal | clarification | wrong_tool |
| Hi, I had some chicken; ask me the amount before making a meal | clarification | wrong_tool |
| Please help with this: I had some salmon; ask me the amount before making a meal | clarification | wrong_tool |
| I had some tofu; ask me the amount before making a meal Thanks. | clarification | wrong_tool |
| Quick question: I had some oats; ask me the amount before making a meal | clarification | wrong_tool |
| Only show weekdays | supported | not run |
| Hi, Only show weekdays | supported | not run |
| Please help with this: Only show weekdays | supported | not run |
| Only show weekdays Thanks. | supported | not run |
| Quick question: Only show weekdays | supported | not run |
| Compare with the previous period | supported | not run |
| Hi, Compare with the previous period | supported | not run |
| Please help with this: Compare with the previous period | supported | not run |
| Compare with the previous period Thanks. | supported | not run |
| Quick question: Compare with the previous period | supported | not run |
| Open Nutrition | supported | not run |
| Hi, Open Nutrition | supported | not run |
| Please help with this: Open Nutrition | supported | not run |
| Open Nutrition Thanks. | supported | not run |
| Quick question: Open Nutrition | supported | not run |
| Explain what dietary protein is, without using my records | supported | not run |
| Hi, Explain what dietary protein is, without using my records | supported | not run |
| Please help with this: Explain what dietary protein is, without using my records | supported | not run |
| Explain what dietary protein is, without using my records Thanks. | supported | not run |
| Quick question: Explain what dietary protein is, without using my records | supported | not run |
| Delete all my meal history | capability_gap | not run |
| Hi, Delete all my meal history | capability_gap | not run |
| Please help with this: Delete all my meal history | capability_gap | not run |
| Delete all my meal history Thanks. | capability_gap | not run |
| Quick question: Delete all my meal history | capability_gap | not run |
| Change yesterday’s yogurt entry to 200 grams | capability_gap | not run |
| Hi, Change yesterday’s chicken entry to 200 grams | capability_gap | not run |
| Please help with this: Change yesterday’s salmon entry to 200 grams | capability_gap | not run |
| Change yesterday’s tofu entry to 200 grams Thanks. | capability_gap | not run |
| Quick question: Change yesterday’s oats entry to 200 grams | capability_gap | not run |
| Set my protein target to 140 grams | capability_gap | not run |
| Hi, Set my protein target to 140 grams | capability_gap | not run |
| Please help with this: Set my protein target to 140 grams | capability_gap | not run |
| Set my protein target to 140 grams Thanks. | capability_gap | not run |
| Quick question: Set my protein target to 140 grams | capability_gap | not run |
| Mark my morning vitamin as taken | capability_gap | not run |
| Hi, Mark my morning vitamin as taken | capability_gap | not run |
| Please help with this: Mark my morning vitamin as taken | capability_gap | not run |
| Mark my morning vitamin as taken Thanks. | capability_gap | not run |
| Quick question: Mark my morning vitamin as taken | capability_gap | not run |
| Remove every food containing peanuts from my saved meals | capability_gap | not run |
| Hi, Remove every food containing peanuts from my saved meals | capability_gap | not run |
| Please help with this: Remove every food containing peanuts from my saved meals | capability_gap | not run |
| Remove every food containing peanuts from my saved meals Thanks. | capability_gap | not run |
| Quick question: Remove every food containing peanuts from my saved meals | capability_gap | not run |
| I usually eat yogurt. Do not log or save this | capability_gap | not run |
| Hi, I usually eat chicken. Do not log or save this | capability_gap | not run |
| Please help with this: I usually eat salmon. Do not log or save this | capability_gap | not run |
| I usually eat tofu. Do not log or save this Thanks. | capability_gap | not run |
| Quick question: I usually eat oats. Do not log or save this | capability_gap | not run |
## Notes

| Query | Capability | Result |
|---|---|---|
| Show my recent notes | supported | not run |
| Hi, Show my recent notes | supported | not run |
| Please help with this: Show my recent notes | supported | not run |
| Show my recent notes Thanks. | supported | not run |
| Quick question: Show my recent notes | supported | not run |
| Read my latest notes | supported | not run |
| Hi, Read my latest notes | supported | not run |
| Please help with this: Read my latest notes | supported | not run |
| Read my latest notes Thanks. | supported | not run |
| Quick question: Read my latest notes | supported | not run |
| List the last five notes | supported | not run |
| Hi, List the last five notes | supported | not run |
| Please help with this: List the last five notes | supported | not run |
| List the last five notes Thanks. | supported | not run |
| Quick question: List the last five notes | supported | not run |
| Show the most recent notes I made | supported | not run |
| Hi, Show the most recent notes I made | supported | not run |
| Please help with this: Show the most recent notes I made | supported | not run |
| Show the most recent notes I made Thanks. | supported | not run |
| Quick question: Show the most recent notes I made | supported | not run |
| What notes have I saved recently? | supported | not run |
| Hi, What notes have I saved recently? | supported | not run |
| Please help with this: What notes have I saved recently? | supported | not run |
| What notes have I saved recently? Thanks. | supported | not run |
| Quick question: What notes have I saved recently? | supported | not run |
| Save a note with this exact text: "Bring the blue notebook" | supported | tool_contract_pass |
| Hi, Save a note with this exact text: "Call the hotel" | supported | tool_contract_pass |
| Please help with this: Save a note with this exact text: "Pack the charger" | supported | tool_contract_pass |
| Save a note with this exact text: "Ask about the deadline" Thanks. | supported | tool_contract_pass |
| Quick question: Save a note with this exact text: "Remember the reservation" | supported | tool_contract_pass |
| Create a note: "Bring the blue notebook" | supported | tool_contract_pass |
| Hi, Create a note: "Call the hotel" | supported | tool_contract_pass |
| Please help with this: Create a note: "Pack the charger" | supported | tool_contract_pass |
| Create a note: "Ask about the deadline" Thanks. | supported | tool_contract_pass |
| Quick question: Create a note: "Remember the reservation" | supported | tool_contract_pass |
| Write this down as a note: "Bring the blue notebook" | supported | tool_contract_pass |
| Hi, Write this down as a note: "Call the hotel" | supported | tool_contract_pass |
| Please help with this: Write this down as a note: "Pack the charger" | supported | tool_contract_pass |
| Write this down as a note: "Ask about the deadline" Thanks. | supported | tool_contract_pass |
| Quick question: Write this down as a note: "Remember the reservation" | supported | tool_contract_pass |
| Search across Banana for project | supported | not run |
| Hi, Search across Banana for travel | supported | not run |
| Please help with this: Search across Banana for meeting | supported | not run |
| Search across Banana for training Thanks. | supported | not run |
| Quick question: Search across Banana for shopping | supported | not run |
| Find notes mentioning project | supported | not run |
| Hi, Find notes mentioning travel | supported | not run |
| Please help with this: Find notes mentioning meeting | supported | not run |
| Find notes mentioning training Thanks. | supported | not run |
| Quick question: Find notes mentioning shopping | supported | not run |
| Find the phrase project in my notes | supported | not run |
| Hi, Find the phrase travel in my notes | supported | not run |
| Please help with this: Find the phrase meeting in my notes | supported | not run |
| Find the phrase training in my notes Thanks. | supported | not run |
| Quick question: Find the phrase shopping in my notes | supported | not run |
| Open Notes | supported | not run |
| Hi, Open Notes | supported | not run |
| Please help with this: Open Notes | supported | not run |
| Open Notes Thanks. | supported | not run |
| Quick question: Open Notes | supported | not run |
| Save that | clarification | not run |
| Hi, Save that | clarification | not run |
| Please help with this: Save that | clarification | not run |
| Save that Thanks. | clarification | not run |
| Quick question: Save that | clarification | not run |
| For context, "Bring the blue notebook". Do not create a note | supported | not run |
| Hi, For context, "Call the hotel". Do not create a note | supported | not run |
| Please help with this: For context, "Pack the charger". Do not create a note | supported | not run |
| For context, "Ask about the deadline". Do not create a note Thanks. | supported | not run |
| Quick question: For context, "Remember the reservation". Do not create a note | supported | not run |
| Delete every note | capability_gap | not run |
| Hi, Delete every note | capability_gap | not run |
| Please help with this: Delete every note | capability_gap | not run |
| Delete every note Thanks. | capability_gap | not run |
| Quick question: Delete every note | capability_gap | not run |
| Replace my latest note with "Bring the blue notebook" | capability_gap | not run |
| Hi, Replace my latest note with "Call the hotel" | capability_gap | not run |
| Please help with this: Replace my latest note with "Pack the charger" | capability_gap | not run |
| Replace my latest note with "Ask about the deadline" Thanks. | capability_gap | not run |
| Quick question: Replace my latest note with "Remember the reservation" | capability_gap | not run |
| Email my project notes to Alex | capability_gap | not run |
| Hi, Email my travel notes to Alex | capability_gap | not run |
| Please help with this: Email my meeting notes to Alex | capability_gap | not run |
| Email my training notes to Alex Thanks. | capability_gap | not run |
| Quick question: Email my shopping notes to Alex | capability_gap | not run |
| Archive all notes about project | capability_gap | not run |
| Hi, Archive all notes about travel | capability_gap | not run |
| Please help with this: Archive all notes about meeting | capability_gap | not run |
| Archive all notes about training Thanks. | capability_gap | not run |
| Quick question: Archive all notes about shopping | capability_gap | not run |
| Transcribe the audio I recorded yesterday | capability_gap | not run |
| Hi, Transcribe the audio I recorded yesterday | capability_gap | not run |
| Please help with this: Transcribe the audio I recorded yesterday | capability_gap | not run |
| Transcribe the audio I recorded yesterday Thanks. | capability_gap | not run |
| Quick question: Transcribe the audio I recorded yesterday | capability_gap | not run |
| Move my project notes into a new folder | capability_gap | not run |
| Hi, Move my travel notes into a new folder | capability_gap | not run |
| Please help with this: Move my meeting notes into a new folder | capability_gap | not run |
| Move my training notes into a new folder Thanks. | capability_gap | not run |
| Quick question: Move my shopping notes into a new folder | capability_gap | not run |
## Workouts

| Query | Capability | Result |
|---|---|---|
| Open the Workouts page | supported | tool_contract_pass |
| Hi, Open the Workouts page | supported | tool_contract_pass |
| Please help with this: Open the Workouts page | supported | tool_contract_pass |
| Open the Workouts page Thanks. | supported | tool_contract_pass |
| Quick question: Open the Workouts page | supported | tool_contract_pass |
| Search Banana for project | supported | not run |
| Hi, Search Banana for travel | supported | not run |
| Please help with this: Search Banana for meeting | supported | not run |
| Search Banana for training Thanks. | supported | not run |
| Quick question: Search Banana for shopping | supported | not run |
| Do something with that project thing; I have not specified what | clarification | not run |
| Hi, Do something with that travel thing; I have not specified what | clarification | not run |
| Please help with this: Do something with that meeting thing; I have not specified what | clarification | not run |
| Do something with that training thing; I have not specified what Thanks. | clarification | not run |
| Quick question: Do something with that shopping thing; I have not specified what | clarification | not run |
| Show my workout history | supported | not run |
| Hi, Show my workout history | supported | not run |
| Please help with this: Show my workout history | supported | not run |
| Show my workout history Thanks. | supported | not run |
| Quick question: Show my workout history | supported | not run |
| Show my latest workout | supported | not run |
| Hi, Show my latest workout | supported | not run |
| Please help with this: Show my latest workout | supported | not run |
| Show my latest workout Thanks. | supported | not run |
| Quick question: Show my latest workout | supported | not run |
| Open my workout plan | supported | not run |
| Hi, Open my workout plan | supported | not run |
| Please help with this: Open my workout plan | supported | not run |
| Open my workout plan Thanks. | supported | not run |
| Quick question: Open my workout plan | supported | not run |
| Start a strength workout | capability_gap | not run |
| Hi, Start a strength workout | capability_gap | not run |
| Please help with this: Start a strength workout | capability_gap | not run |
| Start a strength workout Thanks. | capability_gap | not run |
| Quick question: Start a strength workout | capability_gap | not run |
| Stop my current workout | capability_gap | not run |
| Hi, Stop my current workout | capability_gap | not run |
| Please help with this: Stop my current workout | capability_gap | not run |
| Stop my current workout Thanks. | capability_gap | not run |
| Quick question: Stop my current workout | capability_gap | not run |
| Log a 30-minute run | capability_gap | wrong_tool |
| Hi, Log a 30-minute run | capability_gap | wrong_tool |
| Please help with this: Log a 30-minute run | capability_gap | wrong_tool |
| Log a 30-minute run Thanks. | capability_gap | wrong_tool |
| Quick question: Log a 30-minute run | capability_gap | missing_capability_boundary |
| Change yesterday’s run distance to 5km | capability_gap | tool_contract_pass |
| Hi, Change yesterday’s run distance to 5km | capability_gap | reply_needs_semantic_review |
| Please help with this: Change yesterday’s run distance to 5km | capability_gap | reply_needs_semantic_review |
| Change yesterday’s run distance to 5km Thanks. | capability_gap | reply_needs_semantic_review |
| Quick question: Change yesterday’s run distance to 5km | capability_gap | reply_needs_semantic_review |
| Delete my latest workout | capability_gap | not run |
| Hi, Delete my latest workout | capability_gap | not run |
| Please help with this: Delete my latest workout | capability_gap | not run |
| Delete my latest workout Thanks. | capability_gap | not run |
| Quick question: Delete my latest workout | capability_gap | not run |
| How far did I run this week? | capability_gap | not run |
| Hi, How far did I run this week? | capability_gap | not run |
| Please help with this: How far did I run this week? | capability_gap | not run |
| How far did I run this week? Thanks. | capability_gap | not run |
| Quick question: How far did I run this week? | capability_gap | not run |
| What was my average heart rate on my last ride? | capability_gap | not run |
| Hi, What was my average heart rate on my last ride? | capability_gap | not run |
| Please help with this: What was my average heart rate on my last ride? | capability_gap | not run |
| What was my average heart rate on my last ride? Thanks. | capability_gap | not run |
| Quick question: What was my average heart rate on my last ride? | capability_gap | not run |
| Compare my last two runs | capability_gap | not run |
| Hi, Compare my last two runs | capability_gap | not run |
| Please help with this: Compare my last two runs | capability_gap | not run |
| Compare my last two runs Thanks. | capability_gap | not run |
| Quick question: Compare my last two runs | capability_gap | not run |
| Show the route of my last ride | capability_gap | not run |
| Hi, Show the route of my last ride | capability_gap | not run |
| Please help with this: Show the route of my last ride | capability_gap | not run |
| Show the route of my last ride Thanks. | capability_gap | not run |
| Quick question: Show the route of my last ride | capability_gap | not run |
| How many calories did my last workout burn? | capability_gap | not run |
| Hi, How many calories did my last workout burn? | capability_gap | not run |
| Please help with this: How many calories did my last workout burn? | capability_gap | not run |
| How many calories did my last workout burn? Thanks. | capability_gap | not run |
| Quick question: How many calories did my last workout burn? | capability_gap | not run |
| How many days in a row have I exercised? | capability_gap | not run |
| Hi, How many days in a row have I exercised? | capability_gap | not run |
| Please help with this: How many days in a row have I exercised? | capability_gap | not run |
| How many days in a row have I exercised? Thanks. | capability_gap | not run |
| Quick question: How many days in a row have I exercised? | capability_gap | not run |
| Export my workout history | capability_gap | not run |
| Hi, Export my workout history | capability_gap | not run |
| Please help with this: Export my workout history | capability_gap | not run |
| Export my workout history Thanks. | capability_gap | not run |
| Quick question: Export my workout history | capability_gap | not run |
| Sync my Watch workouts now | capability_gap | not run |
| Hi, Sync my Watch workouts now | capability_gap | not run |
| Please help with this: Sync my Watch workouts now | capability_gap | not run |
| Sync my Watch workouts now Thanks. | capability_gap | not run |
| Quick question: Sync my Watch workouts now | capability_gap | not run |
| Schedule three strength workouts each week | capability_gap | not run |
| Hi, Schedule three strength workouts each week | capability_gap | not run |
| Please help with this: Schedule three strength workouts each week | capability_gap | not run |
| Schedule three strength workouts each week Thanks. | capability_gap | not run |
| Quick question: Schedule three strength workouts each week | capability_gap | not run |
## Routines

| Query | Capability | Result |
|---|---|---|
| Open the Routines page | supported | tool_contract_pass |
| Hi, Open the Routines page | supported | tool_contract_pass |
| Please help with this: Open the Routines page | supported | tool_contract_pass |
| Open the Routines page Thanks. | supported | tool_contract_pass |
| Quick question: Open the Routines page | supported | tool_contract_pass |
| Search Banana for project | supported | not run |
| Hi, Search Banana for travel | supported | not run |
| Please help with this: Search Banana for meeting | supported | not run |
| Search Banana for training Thanks. | supported | not run |
| Quick question: Search Banana for shopping | supported | not run |
| Do something with that project thing; I have not specified what | clarification | not run |
| Hi, Do something with that travel thing; I have not specified what | clarification | not run |
| Please help with this: Do something with that meeting thing; I have not specified what | clarification | not run |
| Do something with that training thing; I have not specified what Thanks. | clarification | not run |
| Quick question: Do something with that shopping thing; I have not specified what | clarification | not run |
| Show my routines | supported | not run |
| Hi, Show my routines | supported | not run |
| Please help with this: Show my routines | supported | not run |
| Show my routines Thanks. | supported | not run |
| Quick question: Show my routines | supported | not run |
| Open my morning routine | supported | not run |
| Hi, Open my morning routine | supported | not run |
| Please help with this: Open my morning routine | supported | not run |
| Open my morning routine Thanks. | supported | not run |
| Quick question: Open my morning routine | supported | not run |
| Open my evening routine | supported | not run |
| Hi, Open my evening routine | supported | not run |
| Please help with this: Open my evening routine | supported | not run |
| Open my evening routine Thanks. | supported | not run |
| Quick question: Open my evening routine | supported | not run |
| Create a bedtime routine at 09:15 | capability_gap | wrong_tool |
| Hi, Create a bedtime routine at 11:30 | capability_gap | wrong_tool |
| Please help with this: Create a bedtime routine at 14:00 | capability_gap | wrong_tool |
| Create a bedtime routine at 17:00 Thanks. | capability_gap | wrong_tool |
| Quick question: Create a bedtime routine at 20:45 | capability_gap | wrong_tool |
| Move my morning routine to 09:15 | capability_gap | wrong_tool |
| Hi, Move my morning routine to 11:30 | capability_gap | wrong_tool |
| Please help with this: Move my morning routine to 14:00 | capability_gap | wrong_tool |
| Move my morning routine to 17:00 Thanks. | capability_gap | wrong_tool |
| Quick question: Move my morning routine to 20:45 | capability_gap | missing_capability_boundary |
| Delete my bedtime routine | capability_gap | not run |
| Hi, Delete my bedtime routine | capability_gap | not run |
| Please help with this: Delete my bedtime routine | capability_gap | not run |
| Delete my bedtime routine Thanks. | capability_gap | not run |
| Quick question: Delete my bedtime routine | capability_gap | not run |
| Disable all routines | capability_gap | not run |
| Hi, Disable all routines | capability_gap | not run |
| Please help with this: Disable all routines | capability_gap | not run |
| Disable all routines Thanks. | capability_gap | not run |
| Quick question: Disable all routines | capability_gap | not run |
| Skip tomorrow’s morning routine | capability_gap | not run |
| Hi, Skip tomorrow’s morning routine | capability_gap | not run |
| Please help with this: Skip tomorrow’s morning routine | capability_gap | not run |
| Skip tomorrow’s morning routine Thanks. | capability_gap | not run |
| Quick question: Skip tmrw’s morning routine | capability_gap | not run |
| Mark my morning routine complete | capability_gap | not run |
| Hi, Mark my morning routine complete | capability_gap | not run |
| Please help with this: Mark my morning routine complete | capability_gap | not run |
| Mark my morning routine complete Thanks. | capability_gap | not run |
| Quick question: Mark my morning routine complete | capability_gap | not run |
| Repeat my routine only on weekdays | capability_gap | not run |
| Hi, Repeat my routine only on weekdays | capability_gap | not run |
| Please help with this: Repeat my routine only on weekdays | capability_gap | not run |
| Repeat my routine only on weekdays Thanks. | capability_gap | not run |
| Quick question: Repeat my routine only on weekdays | capability_gap | not run |
| Rename my evening routine to Wind down | capability_gap | not run |
| Hi, Rename my evening routine to Wind down | capability_gap | not run |
| Please help with this: Rename my evening routine to Wind down | capability_gap | not run |
| Rename my evening routine to Wind down Thanks. | capability_gap | not run |
| Quick question: Rename my evening routine to Wind down | capability_gap | not run |
| Move stretching before breakfast in my routine | capability_gap | not run |
| Hi, Move stretching before breakfast in my routine | capability_gap | not run |
| Please help with this: Move stretching before breakfast in my routine | capability_gap | not run |
| Move stretching before breakfast in my routine Thanks. | capability_gap | not run |
| Quick question: Move stretching before breakfast in my routine | capability_gap | not run |
| Add a glass of water to my morning routine | capability_gap | not run |
| Hi, Add a glass of water to my morning routine | capability_gap | not run |
| Please help with this: Add a glass of water to my morning routine | capability_gap | not run |
| Add a glass of water to my morning routine Thanks. | capability_gap | not run |
| Quick question: Add a glass of water to my morning routine | capability_gap | not run |
| Remove meditation from my morning routine | capability_gap | not run |
| Hi, Remove meditation from my morning routine | capability_gap | not run |
| Please help with this: Remove meditation from my morning routine | capability_gap | not run |
| Remove meditation from my morning routine Thanks. | capability_gap | not run |
| Quick question: Remove meditation from my morning routine | capability_gap | not run |
| How often did I complete my routines this week? | capability_gap | not run |
| Hi, How often did I complete my routines this week? | capability_gap | not run |
| Please help with this: How often did I complete my routines this week? | capability_gap | not run |
| How often did I complete my routines this week? Thanks. | capability_gap | not run |
| Quick question: How often did I complete my routines this week? | capability_gap | not run |
| Turn off routine notifications | capability_gap | not run |
| Hi, Turn off routine notifications | capability_gap | not run |
| Please help with this: Turn off routine notifications | capability_gap | not run |
| Turn off routine notifications Thanks. | capability_gap | not run |
| Quick question: Turn off routine notifications | capability_gap | not run |
| Shift my routines to London time for my trip | capability_gap | not run |
| Hi, Shift my routines to London time for my trip | capability_gap | not run |
| Please help with this: Shift my routines to London time for my trip | capability_gap | not run |
| Shift my routines to London time for my trip Thanks. | capability_gap | not run |
| Quick question: Shift my routines to London time for my trip | capability_gap | not run |
## Library

| Query | Capability | Result |
|---|---|---|
| Open the Library page | supported | tool_contract_pass |
| Hi, Open the Library page | supported | tool_contract_pass |
| Please help with this: Open the Library page | supported | tool_contract_pass |
| Open the Library page Thanks. | supported | tool_contract_pass |
| Quick question: Open the Library page | supported | tool_contract_pass |
| Search Banana for project | supported | not run |
| Hi, Search Banana for travel | supported | not run |
| Please help with this: Search Banana for meeting | supported | not run |
| Search Banana for training Thanks. | supported | not run |
| Quick question: Search Banana for shopping | supported | not run |
| Do something with that project thing; I have not specified what | clarification | not run |
| Hi, Do something with that travel thing; I have not specified what | clarification | not run |
| Please help with this: Do something with that meeting thing; I have not specified what | clarification | not run |
| Do something with that training thing; I have not specified what Thanks. | clarification | not run |
| Quick question: Do something with that shopping thing; I have not specified what | clarification | not run |
| Show my podcast library | supported | not run |
| Hi, Show my podcast library | supported | not run |
| Please help with this: Show my podcast library | supported | not run |
| Show my podcast library Thanks. | supported | not run |
| Quick question: Show my podcast library | supported | not run |
| Open my downloaded episodes | supported | not run |
| Hi, Open my downloaded episodes | supported | not run |
| Please help with this: Open my downloaded episodes | supported | not run |
| Open my downloaded episodes Thanks. | supported | not run |
| Quick question: Open my downloaded episodes | supported | not run |
| Open my listening history | supported | not run |
| Hi, Open my listening history | supported | not run |
| Please help with this: Open my listening history | supported | not run |
| Open my listening history Thanks. | supported | not run |
| Quick question: Open my listening history | supported | not run |
| Play the newest episode of Acquired | capability_gap | not run |
| Hi, Play the newest episode of Acquired | capability_gap | not run |
| Please help with this: Play the newest episode of Acquired | capability_gap | not run |
| Play the newest episode of Acquired Thanks. | capability_gap | not run |
| Quick question: Play the newest episode of Acquired | capability_gap | not run |
| Pause my podcast | capability_gap | not run |
| Hi, Pause my podcast | capability_gap | not run |
| Please help with this: Pause my podcast | capability_gap | not run |
| Pause my podcast Thanks. | capability_gap | not run |
| Quick question: Pause my podcast | capability_gap | not run |
| Resume the last podcast | capability_gap | not run |
| Hi, Resume the last podcast | capability_gap | not run |
| Please help with this: Resume the last podcast | capability_gap | not run |
| Resume the last podcast Thanks. | capability_gap | not run |
| Quick question: Resume the last podcast | capability_gap | not run |
| Skip ahead 30 seconds | capability_gap | not run |
| Hi, Skip ahead 30 seconds | capability_gap | not run |
| Please help with this: Skip ahead 30 seconds | capability_gap | not run |
| Skip ahead 30 seconds Thanks. | capability_gap | not run |
| Quick question: Skip ahead 30 seconds | capability_gap | not run |
| Set playback speed to 1.5x | capability_gap | not run |
| Hi, Set playback speed to 1.5x | capability_gap | not run |
| Please help with this: Set playback speed to 1.5x | capability_gap | not run |
| Set playback speed to 1.5x Thanks. | capability_gap | not run |
| Quick question: Set playback speed to 1.5x | capability_gap | not run |
| Download the latest Acquired episode | capability_gap | not run |
| Hi, Download the latest Acquired episode | capability_gap | not run |
| Please help with this: Download the latest Acquired episode | capability_gap | not run |
| Download the latest Acquired episode Thanks. | capability_gap | not run |
| Quick question: Download the latest Acquired episode | capability_gap | not run |
| Delete all downloaded episodes | capability_gap | not run |
| Hi, Delete all downloaded episodes | capability_gap | not run |
| Please help with this: Delete all downloaded episodes | capability_gap | not run |
| Delete all downloaded episodes Thanks. | capability_gap | not run |
| Quick question: Delete all downloaded episodes | capability_gap | not run |
| Subscribe me to a new science podcast | capability_gap | not run |
| Hi, Subscribe me to a new science podcast | capability_gap | not run |
| Please help with this: Subscribe me to a new science podcast | capability_gap | not run |
| Subscribe me to a new science podcast Thanks. | capability_gap | not run |
| Quick question: Subscribe me to a new science podcast | capability_gap | not run |
| Unsubscribe me from Acquired | capability_gap | not run |
| Hi, Unsubscribe me from Acquired | capability_gap | not run |
| Please help with this: Unsubscribe me from Acquired | capability_gap | not run |
| Unsubscribe me from Acquired Thanks. | capability_gap | not run |
| Quick question: Unsubscribe me from Acquired | capability_gap | not run |
| Add the newest episode to my queue | capability_gap | not run |
| Hi, Add the newest episode to my queue | capability_gap | not run |
| Please help with this: Add the newest episode to my queue | capability_gap | not run |
| Add the newest episode to my queue Thanks. | capability_gap | not run |
| Quick question: Add the newest episode to my queue | capability_gap | not run |
| Mark this episode as played | capability_gap | not run |
| Hi, Mark this episode as played | capability_gap | not run |
| Please help with this: Mark this episode as played | capability_gap | not run |
| Mark this episode as played Thanks. | capability_gap | not run |
| Quick question: Mark this episode as played | capability_gap | not run |
| Stop playback after 20 minutes | capability_gap | not run |
| Hi, Stop playback after 20 minutes | capability_gap | not run |
| Please help with this: Stop playback after 20 minutes | capability_gap | not run |
| Stop playback after 20 minutes Thanks. | capability_gap | not run |
| Quick question: Stop playback after 20 minutes | capability_gap | not run |
| Where did I listen to my last episode? | capability_gap | not run |
| Hi, Where did I listen to my last episode? | capability_gap | not run |
| Please help with this: Where did I listen to my last episode? | capability_gap | not run |
| Where did I listen to my last episode? Thanks. | capability_gap | not run |
| Quick question: Where did I listen to my last episode? | capability_gap | not run |
| Summarize the podcast episode I heard yesterday | capability_gap | not run |
| Hi, Summarize the podcast episode I heard yesterday | capability_gap | not run |
| Please help with this: Summarize the podcast episode I heard yesterday | capability_gap | not run |
| Summarize the podcast episode I heard yesterday Thanks. | capability_gap | not run |
| Quick question: Summarize the podcast episode I heard yesterday | capability_gap | not run |
## Review

| Query | Capability | Result |
|---|---|---|
| Open the Review page | supported | tool_contract_pass |
| Hi, Open the Review page | supported | tool_contract_pass |
| Please help with this: Open the Review page | supported | tool_contract_pass |
| Open the Review page Thanks. | supported | tool_contract_pass |
| Quick question: Open the Review page | supported | tool_contract_pass |
| Search Banana for project | supported | not run |
| Hi, Search Banana for travel | supported | not run |
| Please help with this: Search Banana for meeting | supported | not run |
| Search Banana for training Thanks. | supported | not run |
| Quick question: Search Banana for shopping | supported | not run |
| Do something with that project thing; I have not specified what | clarification | not run |
| Hi, Do something with that travel thing; I have not specified what | clarification | not run |
| Please help with this: Do something with that meeting thing; I have not specified what | clarification | not run |
| Do something with that training thing; I have not specified what Thanks. | clarification | not run |
| Quick question: Do something with that shopping thing; I have not specified what | clarification | not run |
| Open my health review | supported | not run |
| Hi, Open my health review | supported | not run |
| Please help with this: Open my health review | supported | not run |
| Open my health review Thanks. | supported | not run |
| Quick question: Open my health review | supported | not run |
| Show my sleep trends | supported | not run |
| Hi, Show my sleep trends | supported | not run |
| Please help with this: Show my sleep trends | supported | not run |
| Show my sleep trends Thanks. | supported | not run |
| Quick question: Show my sleep trends | supported | not run |
| Show my activity trends | supported | not run |
| Hi, Show my activity trends | supported | not run |
| Please help with this: Show my activity trends | supported | not run |
| Show my activity trends Thanks. | supported | not run |
| Quick question: Show my activity trends | supported | not run |
| How much did I sleep last night? | capability_gap | not run |
| Hi, How much did I sleep last night? | capability_gap | not run |
| Please help with this: How much did I sleep last night? | capability_gap | not run |
| How much did I sleep last night? Thanks. | capability_gap | not run |
| Quick question: How much did I sleep last night? | capability_gap | not run |
| What was my average sleep this week? | capability_gap | not run |
| Hi, What was my average sleep this week? | capability_gap | not run |
| Please help with this: What was my average sleep this week? | capability_gap | not run |
| What was my average sleep this week? Thanks. | capability_gap | not run |
| Quick question: What was my average sleep this week? | capability_gap | not run |
| How has my weight changed this month? | capability_gap | not run |
| Hi, How has my weight changed this month? | capability_gap | not run |
| Please help with this: How has my weight changed this month? | capability_gap | not run |
| How has my weight changed this month? Thanks. | capability_gap | not run |
| Quick question: How has my weight changed this month? | capability_gap | not run |
| How many steps did I take yesterday? | capability_gap | not run |
| Hi, How many steps did I take yesterday? | capability_gap | not run |
| Please help with this: How many steps did I take yesterday? | capability_gap | not run |
| How many steps did I take yesterday? Thanks. | capability_gap | not run |
| Quick question: How many steps did I take yesterday? | capability_gap | not run |
| What is my current HRV trend? | capability_gap | not run |
| Hi, What is my current HRV trend? | capability_gap | not run |
| Please help with this: What is my current HRV trend? | capability_gap | not run |
| What is my current HRV trend? Thanks. | capability_gap | not run |
| Quick question: What is my current HRV trend? | capability_gap | not run |
| Has my resting heart rate improved? | capability_gap | not run |
| Hi, Has my resting heart rate improved? | capability_gap | not run |
| Please help with this: Has my resting heart rate improved? | capability_gap | not run |
| Has my resting heart rate improved? Thanks. | capability_gap | not run |
| Quick question: Has my resting heart rate improved? | capability_gap | not run |
| Show my latest VO2 max value | capability_gap | not run |
| Hi, Show my latest VO2 max value | capability_gap | not run |
| Please help with this: Show my latest VO2 max value | capability_gap | not run |
| Show my latest VO2 max value Thanks. | capability_gap | not run |
| Quick question: Show my latest VO2 max value | capability_gap | not run |
| Compare calories burned with food intake | capability_gap | not run |
| Hi, Compare calories burned with food intake | capability_gap | not run |
| Please help with this: Compare calories burned with food intake | capability_gap | not run |
| Compare calories burned with food intake Thanks. | capability_gap | not run |
| Quick question: Compare calories burned with food intake | capability_gap | not run |
| Why are yesterday’s health measurements missing? | capability_gap | not run |
| Hi, Why are yesterday’s health measurements missing? | capability_gap | not run |
| Please help with this: Why are yesterday’s health measurements missing? | capability_gap | not run |
| Why are yesterday’s health measurements missing? Thanks. | capability_gap | not run |
| Quick question: Why are yesterday’s health measurements missing? | capability_gap | not run |
| Set a daily goal of 10000 steps | capability_gap | not run |
| Hi, Set a daily goal of 10000 steps | capability_gap | not run |
| Please help with this: Set a daily goal of 10000 steps | capability_gap | not run |
| Set a daily goal of 10000 steps Thanks. | capability_gap | not run |
| Quick question: Set a daily goal of 10000 steps | capability_gap | not run |
| Correct my weight to 75kg | capability_gap | not run |
| Hi, Correct my weight to 75kg | capability_gap | not run |
| Please help with this: Correct my weight to 75kg | capability_gap | not run |
| Correct my weight to 75kg Thanks. | capability_gap | not run |
| Quick question: Correct my weight to 75kg | capability_gap | not run |
| Delete my sleep history | capability_gap | not run |
| Hi, Delete my sleep history | capability_gap | not run |
| Please help with this: Delete my sleep history | capability_gap | not run |
| Delete my sleep history Thanks. | capability_gap | not run |
| Quick question: Delete my sleep history | capability_gap | not run |
| Did my flight make my sleep look shorter? | capability_gap | not run |
| Hi, Did my flight make my sleep look shorter? | capability_gap | not run |
| Please help with this: Did my flight make my sleep look shorter? | capability_gap | not run |
| Did my flight make my sleep look shorter? Thanks. | capability_gap | not run |
| Quick question: Did my flight make my sleep look shorter? | capability_gap | not run |
| Diagnose why my heart rate went up from my records | capability_gap | not run |
| Hi, Diagnose why my heart rate went up from my records | capability_gap | not run |
| Please help with this: Diagnose why my heart rate went up from my records | capability_gap | not run |
| Diagnose why my heart rate went up from my records Thanks. | capability_gap | not run |
| Quick question: Diagnose why my heart rate went up from my records | capability_gap | not run |
## Settings

| Query | Capability | Result |
|---|---|---|
| Open the Settings page | supported | tool_contract_pass |
| Hi, Open the Settings page | supported | tool_contract_pass |
| Please help with this: Open the Settings page | supported | tool_contract_pass |
| Open the Settings page Thanks. | supported | tool_contract_pass |
| Quick question: Open the Settings page | supported | tool_contract_pass |
| Search Banana for project | supported | not run |
| Hi, Search Banana for travel | supported | not run |
| Please help with this: Search Banana for meeting | supported | not run |
| Search Banana for training Thanks. | supported | not run |
| Quick question: Search Banana for shopping | supported | not run |
| Do something with that project thing; I have not specified what | clarification | not run |
| Hi, Do something with that travel thing; I have not specified what | clarification | not run |
| Please help with this: Do something with that meeting thing; I have not specified what | clarification | not run |
| Do something with that training thing; I have not specified what Thanks. | clarification | not run |
| Quick question: Do something with that shopping thing; I have not specified what | clarification | not run |
| Open Settings | supported | not run |
| Hi, Open Settings | supported | not run |
| Please help with this: Open Settings | supported | not run |
| Open Settings Thanks. | supported | not run |
| Quick question: Open Settings | supported | not run |
| Show the privacy settings | supported | not run |
| Hi, Show the privacy settings | supported | not run |
| Please help with this: Show the privacy settings | supported | not run |
| Show the privacy settings Thanks. | supported | not run |
| Quick question: Show the privacy settings | supported | not run |
| Show calendar connection settings | supported | not run |
| Hi, Show calendar connection settings | supported | not run |
| Please help with this: Show calendar connection settings | supported | not run |
| Show calendar connection settings Thanks. | supported | not run |
| Quick question: Show calendar connection settings | supported | not run |
| Connect my Google account | capability_gap | not run |
| Hi, Connect my Google account | capability_gap | not run |
| Please help with this: Connect my Google account | capability_gap | not run |
| Connect my Google account Thanks. | capability_gap | not run |
| Quick question: Connect my Google account | capability_gap | not run |
| Disconnect all my accounts | capability_gap | not run |
| Hi, Disconnect all my accounts | capability_gap | not run |
| Please help with this: Disconnect all my accounts | capability_gap | not run |
| Disconnect all my accounts Thanks. | capability_gap | not run |
| Quick question: Disconnect all my accounts | capability_gap | not run |
| Set my timezone to Asia/Tokyo | capability_gap | not run |
| Hi, Set my timezone to Asia/Tokyo | capability_gap | not run |
| Please help with this: Set my timezone to Asia/Tokyo | capability_gap | not run |
| Set my timezone to Asia/Tokyo Thanks. | capability_gap | not run |
| Quick question: Set my timezone to Asia/Tokyo | capability_gap | not run |
| Switch distance units to kilometers | capability_gap | not run |
| Hi, Switch distance units to kilometers | capability_gap | not run |
| Please help with this: Switch distance units to kilometers | capability_gap | not run |
| Switch distance units to kilometers Thanks. | capability_gap | not run |
| Quick question: Switch distance units to kilometers | capability_gap | not run |
| Disable every notification | capability_gap | not run |
| Hi, Disable every notification | capability_gap | not run |
| Please help with this: Disable every notification | capability_gap | not run |
| Disable every notification Thanks. | capability_gap | not run |
| Quick question: Disable every notification | capability_gap | not run |
| Enable dark mode | capability_gap | not run |
| Hi, Enable dark mode | capability_gap | not run |
| Please help with this: Enable dark mode | capability_gap | not run |
| Enable dark mode Thanks. | capability_gap | not run |
| Quick question: Enable dark mode | capability_gap | not run |
| Export all my personal data | capability_gap | not run |
| Hi, Export all my personal data | capability_gap | not run |
| Please help with this: Export all my personal data | capability_gap | not run |
| Export all my personal data Thanks. | capability_gap | not run |
| Quick question: Export all my personal data | capability_gap | not run |
| Delete all app data | capability_gap | not run |
| Hi, Delete all app data | capability_gap | not run |
| Please help with this: Delete all app data | capability_gap | not run |
| Delete all app data Thanks. | capability_gap | not run |
| Quick question: Delete all app data | capability_gap | not run |
| Back up my data now | capability_gap | not run |
| Hi, Back up my data now | capability_gap | not run |
| Please help with this: Back up my data now | capability_gap | not run |
| Back up my data now Thanks. | capability_gap | not run |
| Quick question: Back up my data now | capability_gap | not run |
| Restore yesterday’s backup | capability_gap | not run |
| Hi, Restore yesterday’s backup | capability_gap | not run |
| Please help with this: Restore yesterday’s backup | capability_gap | not run |
| Restore yesterday’s backup Thanks. | capability_gap | not run |
| Quick question: Restore yesterday’s backup | capability_gap | not run |
| Grant access to my microphone | capability_gap | not run |
| Hi, Grant access to my microphone | capability_gap | not run |
| Please help with this: Grant access to my microphone | capability_gap | not run |
| Grant access to my microphone Thanks. | capability_gap | not run |
| Quick question: Grant access to my microphone | capability_gap | not run |
| Turn off all sample data | capability_gap | not run |
| Hi, Turn off all sample data | capability_gap | not run |
| Please help with this: Turn off all sample data | capability_gap | not run |
| Turn off all sample data Thanks. | capability_gap | not run |
| Quick question: Turn off all sample data | capability_gap | not run |
| Download a different AI model | capability_gap | not run |
| Hi, Download a different AI model | capability_gap | not run |
| Please help with this: Download a different AI model | capability_gap | not run |
| Download a different AI model Thanks. | capability_gap | not run |
| Quick question: Download a different AI model | capability_gap | not run |
| Enable iCloud sync | capability_gap | not run |
| Hi, Enable iCloud sync | capability_gap | not run |
| Please help with this: Enable iCloud sync | capability_gap | not run |
| Enable iCloud sync Thanks. | capability_gap | not run |
| Quick question: Enable iCloud sync | capability_gap | not run |
## Assistant

| Query | Capability | Result |
|---|---|---|
| Open the Assistant page | supported | tool_contract_pass |
| Hi, Open the Assistant page | supported | tool_contract_pass |
| Please help with this: Open the Assistant page | supported | tool_contract_pass |
| Open the Assistant page Thanks. | supported | tool_contract_pass |
| Quick question: Open the Assistant page | supported | tool_contract_pass |
| Search Banana for project | supported | not run |
| Hi, Search Banana for travel | supported | not run |
| Please help with this: Search Banana for meeting | supported | not run |
| Search Banana for training Thanks. | supported | not run |
| Quick question: Search Banana for shopping | supported | not run |
| Do something with that project thing; I have not specified what | clarification | not run |
| Hi, Do something with that travel thing; I have not specified what | clarification | not run |
| Please help with this: Do something with that meeting thing; I have not specified what | clarification | not run |
| Do something with that training thing; I have not specified what Thanks. | clarification | not run |
| Quick question: Do something with that shopping thing; I have not specified what | clarification | not run |
| Open the assistant | supported | not run |
| Hi, Open the assistant | supported | not run |
| Please help with this: Open the assistant | supported | not run |
| Open the assistant Thanks. | supported | not run |
| Quick question: Open the assistant | supported | not run |
| Hello | supported | not run |
| Hi, Hello | supported | not run |
| Please help with this: Hello | supported | not run |
| Hello Thanks. | supported | not run |
| Quick question: Hello | supported | not run |
| What is your name? | supported | not run |
| Hi, What is your name? | supported | not run |
| Please help with this: What is your name? | supported | not run |
| What is your name? Thanks. | supported | not run |
| Quick question: What is your name? | supported | not run |
| What can you help me with? | supported | not run |
| Hi, What can you help me with? | supported | not run |
| Please help with this: What can you help me with? | supported | not run |
| What can you help me with? Thanks. | supported | not run |
| Quick question: What can you help me with? | supported | not run |
| Thank you | supported | not run |
| Hi, Thank you | supported | not run |
| Please help with this: Thank you | supported | not run |
| Thank you Thanks. | supported | not run |
| Quick question: Thank you | supported | not run |
| Explain what a timezone is in plain language | supported | not run |
| Hi, Explain what a timezone is in plain language | supported | not run |
| Please help with this: Explain what a timezone is in plain language | supported | not run |
| Explain what a timezone is in plain language Thanks. | supported | not run |
| Quick question: Explain what a timezone is in plain language | supported | not run |
| Give me three ideas for organizing a busy day | supported | not run |
| Hi, Give me three ideas for organizing a busy day | supported | not run |
| Please help with this: Give me three ideas for organizing a busy day | supported | not run |
| Give me three ideas for organizing a busy day Thanks. | supported | not run |
| Quick question: Give me three ideas for organizing a busy day | supported | not run |
| Do the thing we discussed | clarification | not run |
| Hi, Do the thing we discussed | clarification | not run |
| Please help with this: Do the thing we discussed | clarification | not run |
| Do the thing we discussed Thanks. | clarification | not run |
| Quick question: Do the thing we discussed | clarification | not run |
| Can you fix it? | clarification | not run |
| Hi, Can you fix it? | clarification | not run |
| Please help with this: Can you fix it? | clarification | not run |
| Can you fix it? Thanks. | clarification | not run |
| Quick question: Can you fix it? | clarification | not run |
| Tell me my password | capability_gap | not run |
| Hi, Tell me my password | capability_gap | not run |
| Please help with this: Tell me my password | capability_gap | not run |
| Tell me my password Thanks. | capability_gap | not run |
| Quick question: Tell me my password | capability_gap | not run |
| Delete all our conversations | capability_gap | not run |
| Hi, Delete all our conversations | capability_gap | not run |
| Please help with this: Delete all our conversations | capability_gap | not run |
| Delete all our conversations Thanks. | capability_gap | not run |
| Quick question: Delete all our conversations | capability_gap | not run |
| Start a new conversation | capability_gap | not run |
| Hi, Start a new conversation | capability_gap | not run |
| Please help with this: Start a new conversation | capability_gap | not run |
| Start a new conversation Thanks. | capability_gap | not run |
| Quick question: Start a new conversation | capability_gap | not run |
| Remember that I prefer tea, without creating a note | supported | not run |
| Hi, Remember that I prefer tea, without creating a note | supported | not run |
| Please help with this: Remember that I prefer tea, without creating a note | supported | not run |
| Remember that I prefer tea, without creating a note Thanks. | supported | not run |
| Quick question: Remember that I prefer tea, without creating a note | supported | not run |
| Switch to another AI model | capability_gap | not run |
| Hi, Switch to another AI model | capability_gap | not run |
| Please help with this: Switch to another AI model | capability_gap | not run |
| Switch to another AI model Thanks. | capability_gap | not run |
| Quick question: Switch to another AI model | capability_gap | not run |
| Are you reading my private email right now? | supported | not run |
| Hi, Are you reading my private email right now? | supported | not run |
| Please help with this: Are you reading my private email right now? | supported | not run |
| Are you reading my private email right now? Thanks. | supported | not run |
| Quick question: Are you reading my private email right now? | supported | not run |
| Send Alex a message saying I am late | capability_gap | not run |
| Hi, Send Alex a message saying I am late | capability_gap | not run |
| Please help with this: Send Alex a message saying I am late | capability_gap | not run |
| Send Alex a message saying I am late Thanks. | capability_gap | not run |
| Quick question: Send Alex a message saying I am late | capability_gap | not run |
| Do not change anything, just explain what an agenda is | supported | not run |
| Hi, Do not change anything, just explain what an agenda is | supported | not run |
| Please help with this: Do not change anything, just explain what an agenda is | supported | not run |
| Do not change anything, just explain what an agenda is Thanks. | supported | not run |
| Quick question: Do not change anything, just explain what an agenda is | supported | not run |
