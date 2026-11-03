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
| Dinner at 17:00 Thanks. | supported | missing_tool |
| Quick question: Airport pickup at 20:45 | supported | missing_tool |
| Schedule Dentist, but I have not chosen a time | clarification | reply_needs_semantic_review |
| Hi, Schedule Team lunch, but I have not chosen a time | clarification | wrong_tool |
| Please help with this: Schedule Design review, but I have not chosen a time | clarification | wrong_tool |
| Schedule Dinner, but I have not chosen a time Thanks. | clarification | reply_needs_semantic_review |
| Quick question: Schedule Airport pickup, but I have not chosen a time | clarification | reply_needs_semantic_review |
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
| Please help with this: Delete all calendar events tomorrow | capability_gap | tool_contract_pass |
| Delete all calendar events tomorrow Thanks. | capability_gap | reply_needs_semantic_review |
| Quick question: Delete all calendar events tmrw | capability_gap | tool_contract_pass |
| Move Dentist to 09:15 | capability_gap | missing_capability_boundary |
| Hi, Move Team lunch to 11:30 | capability_gap | wrong_tool |
| Please help with this: Move Design review to 14:00 | capability_gap | wrong_tool |
| Move Dinner to 17:00 Thanks. | capability_gap | wrong_tool |
| Quick question: Move Airport pickup to 20:45 | capability_gap | wrong_tool |
| Cancel Dentist tomorrow | capability_gap | reply_needs_semantic_review |
| Hi, Cancel Team lunch tomorrow | capability_gap | reply_needs_semantic_review |
| Please help with this: Cancel Design review tomorrow | capability_gap | missing_capability_boundary |
| Cancel Dinner tomorrow Thanks. | capability_gap | wrong_tool |
| Quick question: Cancel Airport pickup tmrw | capability_gap | wrong_tool |
| Invite Alex to Dentist | capability_gap | reply_needs_semantic_review |
| Hi, Invite Alex to Team lunch | capability_gap | reply_needs_semantic_review |
| Please help with this: Invite Alex to Design review | capability_gap | reply_needs_semantic_review |
| Invite Alex to Dinner Thanks. | capability_gap | missing_capability_boundary |
| Quick question: Invite Alex to Airport pickup | capability_gap | missing_capability_boundary |
| Schedule Dentist every second Tuesday at 09:15 | capability_gap | wrong_tool |
| Hi, Schedule Team lunch every second Tuesday at 11:30 | capability_gap | missing_capability_boundary |
| Please help with this: Schedule Design review every second Tuesday at 14:00 | capability_gap | missing_capability_boundary |
| Schedule Dinner every second Tuesday at 17:00 Thanks. | capability_gap | missing_capability_boundary |
| Quick question: Schedule Airport pickup every second Tuesday at 20:45 | capability_gap | missing_capability_boundary |
| Add flight JFK to LHR on 2026-11-03, leaving 8pm New York and arriving 8am London next day | capability_gap | wrong_tool |
| Hi, Add flight JFK to LHR on 2026-11-04, leaving 8pm New York and arriving 8am London next day | capability_gap | wrong_tool |
| Please help with this: Add flight JFK to LHR on 2026-11-05, leaving 8pm New York and arriving 8am London next day | capability_gap | wrong_tool |
| Add flight JFK to LHR on 2026-11-06, leaving 8pm New York and arriving 8am London next day Thanks. | capability_gap | wrong_tool |
| Quick question: Add flight JFK to LHR on 2026-11-07, leaving 8pm New York and arriving 8am London next day | capability_gap | missing_capability_boundary |
| What local time does my flight land in Tokyo? | capability_gap | wrong_tool |
| Hi, What local time does my flight land in Tokyo? | capability_gap | wrong_tool |
| Please help with this: What local time does my flight land in Tokyo? | capability_gap | reply_needs_semantic_review |
| What local time does my flight land in Tokyo? Thanks. | capability_gap | reply_needs_semantic_review |
| Quick question: What local time does my flight land in Tokyo? | capability_gap | reply_needs_semantic_review |
| Change my calendar timezone to Europe/London | capability_gap | argument_section |
| Hi, Change my calendar timezone to Europe/London | capability_gap | reply_needs_semantic_review |
| Please help with this: Change my calendar timezone to Europe/London | capability_gap | argument_section |
| Change my calendar timezone to Europe/London Thanks. | capability_gap | argument_section |
| Quick question: Change my calendar timezone to Europe/London | capability_gap | argument_section |
| Set an alarm for 09:15 tomorrow | capability_gap | wrong_tool |
| Hi, Set an alarm for 11:30 tomorrow | capability_gap | wrong_tool |
| Please help with this: Set an alarm for 14:00 tomorrow | capability_gap | wrong_tool |
| Set an alarm for 17:00 tomorrow Thanks. | capability_gap | reply_needs_semantic_review |
| Quick question: Set an alarm for 20:45 tmrw | capability_gap | missing_capability_boundary |
## Nutrition

| Query | Capability | Result |
|---|---|---|
| Show my protein this month | supported | tool_contract_pass |
| Hi, Show my protein this month | supported | tool_contract_pass |
| Please help with this: Show my protein this month | supported | tool_contract_pass |
| Show my protein this month Thanks. | supported | tool_contract_pass |
| Quick question: Show my protein this month | supported | tool_contract_pass |
| Show my calories this month | supported | tool_contract_pass |
| Hi, Show my calories this month | supported | tool_contract_pass |
| Please help with this: Show my calories this month | supported | tool_contract_pass |
| Show my calories this month Thanks. | supported | tool_contract_pass |
| Quick question: Show my calories this month | supported | tool_contract_pass |
| Show my carbs this month | supported | tool_contract_pass |
| Hi, Show my carbs this month | supported | tool_contract_pass |
| Please help with this: Show my carbs this month | supported | tool_contract_pass |
| Show my carbs this month Thanks. | supported | tool_contract_pass |
| Quick question: Show my carbs this month | supported | tool_contract_pass |
| Show my fat this month | supported | tool_contract_pass |
| Hi, Show my fat this month | supported | tool_contract_pass |
| Please help with this: Show my fat this month | supported | tool_contract_pass |
| Show my fat this month Thanks. | supported | tool_contract_pass |
| Quick question: Show my fat this month | supported | tool_contract_pass |
| Show my protein over the last seven days | supported | tool_contract_pass |
| Hi, Show my protein over the last seven days | supported | tool_contract_pass |
| Please help with this: Show my protein over the last seven days | supported | tool_contract_pass |
| Show my protein over the last seven days Thanks. | supported | tool_contract_pass |
| Quick question: Show my protein over the last seven days | supported | tool_contract_pass |
| Find my logged meals containing yogurt | supported | tool_contract_pass |
| Hi, Find my logged meals containing chicken | supported | tool_contract_pass |
| Please help with this: Find my logged meals containing salmon | supported | tool_contract_pass |
| Find my logged meals containing tofu Thanks. | supported | tool_contract_pass |
| Quick question: Find my logged meals containing oats | supported | tool_contract_pass |
| Prepare a meal with 2 eggs and 1 banana | supported | tool_contract_pass |
| Hi, Prepare a meal with 2 eggs and 1 banana | supported | tool_contract_pass |
| Please help with this: Prepare a meal with 2 eggs and 1 banana | supported | tool_contract_pass |
| Prepare a meal with 2 eggs and 1 banana Thanks. | supported | tool_contract_pass |
| Quick question: Prepare a meal with 2 eggs and 1 banana | supported | tool_contract_pass |
| Log 2 eggs and 1 banana for yesterday | supported | tool_contract_pass |
| Hi, Log 2 eggs and 1 banana for yesterday | supported | tool_contract_pass |
| Please help with this: Log 2 eggs and 1 banana for yesterday | supported | tool_contract_pass |
| Log 2 eggs and 1 banana for yesterday Thanks. | supported | tool_contract_pass |
| Quick question: Log 2 eggs and 1 banana for yesterday | supported | tool_contract_pass |
| Log lunch, but I have not said what I ate | clarification | reply_needs_semantic_review |
| Hi, Log lunch, but I have not said what I ate | clarification | reply_needs_semantic_review |
| Please help with this: Log lunch, but I have not said what I ate | clarification | reply_needs_semantic_review |
| Log lunch, but I have not said what I ate Thanks. | clarification | reply_needs_semantic_review |
| Quick question: Log lunch, but I have not said what I ate | clarification | reply_needs_semantic_review |
| I had some yogurt; ask me the amount before making a meal | clarification | reply_needs_semantic_review |
| Hi, I had some chicken; ask me the amount before making a meal | clarification | wrong_tool |
| Please help with this: I had some salmon; ask me the amount before making a meal | clarification | wrong_tool |
| I had some tofu; ask me the amount before making a meal Thanks. | clarification | wrong_tool |
| Quick question: I had some oats; ask me the amount before making a meal | clarification | wrong_tool |
| Only show weekdays | supported | tool_contract_pass |
| Hi, Only show weekdays | supported | tool_contract_pass |
| Please help with this: Only show weekdays | supported | tool_contract_pass |
| Only show weekdays Thanks. | supported | tool_contract_pass |
| Quick question: Only show weekdays | supported | tool_contract_pass |
| Compare with the previous period | supported | tool_contract_pass |
| Hi, Compare with the previous period | supported | tool_contract_pass |
| Please help with this: Compare with the previous period | supported | tool_contract_pass |
| Compare with the previous period Thanks. | supported | tool_contract_pass |
| Quick question: Compare with the previous period | supported | tool_contract_pass |
| Open Nutrition | supported | tool_contract_pass |
| Hi, Open Nutrition | supported | wrong_tool |
| Please help with this: Open Nutrition | supported | tool_contract_pass |
| Open Nutrition Thanks. | supported | tool_contract_pass |
| Quick question: Open Nutrition | supported | tool_contract_pass |
| Explain what dietary protein is, without using my records | supported | reply_needs_semantic_review |
| Hi, Explain what dietary protein is, without using my records | supported | reply_needs_semantic_review |
| Please help with this: Explain what dietary protein is, without using my records | supported | reply_needs_semantic_review |
| Explain what dietary protein is, without using my records Thanks. | supported | reply_needs_semantic_review |
| Quick question: Explain what dietary protein is, without using my records | supported | reply_needs_semantic_review |
| Delete all my meal history | capability_gap | reply_needs_semantic_review |
| Hi, Delete all my meal history | capability_gap | reply_needs_semantic_review |
| Please help with this: Delete all my meal history | capability_gap | reply_needs_semantic_review |
| Delete all my meal history Thanks. | capability_gap | reply_needs_semantic_review |
| Quick question: Delete all my meal history | capability_gap | reply_needs_semantic_review |
| Change yesterday’s yogurt entry to 200 grams | capability_gap | wrong_tool |
| Hi, Change yesterday’s chicken entry to 200 grams | capability_gap | wrong_tool |
| Please help with this: Change yesterday’s salmon entry to 200 grams | capability_gap | wrong_tool |
| Change yesterday’s tofu entry to 200 grams Thanks. | capability_gap | reply_needs_semantic_review |
| Quick question: Change yesterday’s oats entry to 200 grams | capability_gap | wrong_tool |
| Set my protein target to 140 grams | capability_gap | argument_section |
| Hi, Set my protein target to 140 grams | capability_gap | argument_section |
| Please help with this: Set my protein target to 140 grams | capability_gap | tool_contract_pass |
| Set my protein target to 140 grams Thanks. | capability_gap | reply_needs_semantic_review |
| Quick question: Set my protein target to 140 grams | capability_gap | reply_needs_semantic_review |
| Mark my morning vitamin as taken | capability_gap | reply_needs_semantic_review |
| Hi, Mark my morning vitamin as taken | capability_gap | wrong_tool |
| Please help with this: Mark my morning vitamin as taken | capability_gap | reply_needs_semantic_review |
| Mark my morning vitamin as taken Thanks. | capability_gap | argument_section |
| Quick question: Mark my morning vitamin as taken | capability_gap | wrong_tool |
| Remove every food containing peanuts from my saved meals | capability_gap | reply_needs_semantic_review |
| Hi, Remove every food containing peanuts from my saved meals | capability_gap | tool_contract_pass |
| Please help with this: Remove every food containing peanuts from my saved meals | capability_gap | reply_needs_semantic_review |
| Remove every food containing peanuts from my saved meals Thanks. | capability_gap | reply_needs_semantic_review |
| Quick question: Remove every food containing peanuts from my saved meals | capability_gap | tool_contract_pass |
| I usually eat yogurt. Do not log or save this | capability_gap | reply_needs_semantic_review |
| Hi, I usually eat chicken. Do not log or save this | capability_gap | reply_needs_semantic_review |
| Please help with this: I usually eat salmon. Do not log or save this | capability_gap | reply_needs_semantic_review |
| I usually eat tofu. Do not log or save this Thanks. | capability_gap | reply_needs_semantic_review |
| Quick question: I usually eat oats. Do not log or save this | capability_gap | reply_needs_semantic_review |
## Notes

| Query | Capability | Result |
|---|---|---|
| Show my recent notes | supported | tool_contract_pass |
| Hi, Show my recent notes | supported | tool_contract_pass |
| Please help with this: Show my recent notes | supported | tool_contract_pass |
| Show my recent notes Thanks. | supported | tool_contract_pass |
| Quick question: Show my recent notes | supported | tool_contract_pass |
| Read my latest notes | supported | tool_contract_pass |
| Hi, Read my latest notes | supported | tool_contract_pass |
| Please help with this: Read my latest notes | supported | tool_contract_pass |
| Read my latest notes Thanks. | supported | tool_contract_pass |
| Quick question: Read my latest notes | supported | tool_contract_pass |
| List the last five notes | supported | tool_contract_pass |
| Hi, List the last five notes | supported | tool_contract_pass |
| Please help with this: List the last five notes | supported | tool_contract_pass |
| List the last five notes Thanks. | supported | tool_contract_pass |
| Quick question: List the last five notes | supported | tool_contract_pass |
| Show the most recent notes I made | supported | tool_contract_pass |
| Hi, Show the most recent notes I made | supported | tool_contract_pass |
| Please help with this: Show the most recent notes I made | supported | tool_contract_pass |
| Show the most recent notes I made Thanks. | supported | tool_contract_pass |
| Quick question: Show the most recent notes I made | supported | tool_contract_pass |
| What notes have I saved recently? | supported | tool_contract_pass |
| Hi, What notes have I saved recently? | supported | tool_contract_pass |
| Please help with this: What notes have I saved recently? | supported | tool_contract_pass |
| What notes have I saved recently? Thanks. | supported | tool_contract_pass |
| Quick question: What notes have I saved recently? | supported | tool_contract_pass |
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
| Search across Banana for project | supported | tool_contract_pass |
| Hi, Search across Banana for travel | supported | tool_contract_pass |
| Please help with this: Search across Banana for meeting | supported | tool_contract_pass |
| Search across Banana for training Thanks. | supported | argument_query |
| Quick question: Search across Banana for shopping | supported | tool_contract_pass |
| Find notes mentioning project | supported | wrong_tool |
| Hi, Find notes mentioning travel | supported | wrong_tool |
| Please help with this: Find notes mentioning meeting | supported | wrong_tool |
| Find notes mentioning training Thanks. | supported | wrong_tool |
| Quick question: Find notes mentioning shopping | supported | wrong_tool |
| Find the phrase project in my notes | supported | tool_contract_pass |
| Hi, Find the phrase travel in my notes | supported | wrong_tool |
| Please help with this: Find the phrase meeting in my notes | supported | wrong_tool |
| Find the phrase training in my notes Thanks. | supported | tool_contract_pass |
| Quick question: Find the phrase shopping in my notes | supported | wrong_tool |
| Open Notes | supported | tool_contract_pass |
| Hi, Open Notes | supported | tool_contract_pass |
| Please help with this: Open Notes | supported | tool_contract_pass |
| Open Notes Thanks. | supported | tool_contract_pass |
| Quick question: Open Notes | supported | tool_contract_pass |
| Save that | clarification | reply_needs_semantic_review |
| Hi, Save that | clarification | reply_needs_semantic_review |
| Please help with this: Save that | clarification | reply_needs_semantic_review |
| Save that Thanks. | clarification | wrong_tool |
| Quick question: Save that | clarification | reply_needs_semantic_review |
| For context, "Bring the blue notebook". Do not create a note | supported | reply_needs_semantic_review |
| Hi, For context, "Call the hotel". Do not create a note | supported | wrong_tool |
| Please help with this: For context, "Pack the charger". Do not create a note | supported | reply_needs_semantic_review |
| For context, "Ask about the deadline". Do not create a note Thanks. | supported | wrong_tool |
| Quick question: For context, "Remember the reservation". Do not create a note | supported | reply_needs_semantic_review |
| Delete every note | capability_gap | tool_contract_pass |
| Hi, Delete every note | capability_gap | tool_contract_pass |
| Please help with this: Delete every note | capability_gap | reply_needs_semantic_review |
| Delete every note Thanks. | capability_gap | reply_needs_semantic_review |
| Quick question: Delete every note | capability_gap | tool_contract_pass |
| Replace my latest note with "Bring the blue notebook" | capability_gap | wrong_tool |
| Hi, Replace my latest note with "Call the hotel" | capability_gap | reply_needs_semantic_review |
| Please help with this: Replace my latest note with "Pack the charger" | capability_gap | wrong_tool |
| Replace my latest note with "Ask about the deadline" Thanks. | capability_gap | wrong_tool |
| Quick question: Replace my latest note with "Remember the reservation" | capability_gap | reply_needs_semantic_review |
| Email my project notes to Alex | capability_gap | wrong_tool |
| Hi, Email my travel notes to Alex | capability_gap | reply_needs_semantic_review |
| Please help with this: Email my meeting notes to Alex | capability_gap | reply_needs_semantic_review |
| Email my training notes to Alex Thanks. | capability_gap | reply_needs_semantic_review |
| Quick question: Email my shopping notes to Alex | capability_gap | reply_needs_semantic_review |
| Archive all notes about project | capability_gap | reply_needs_semantic_review |
| Hi, Archive all notes about travel | capability_gap | wrong_tool |
| Please help with this: Archive all notes about meeting | capability_gap | wrong_tool |
| Archive all notes about training Thanks. | capability_gap | wrong_tool |
| Quick question: Archive all notes about shopping | capability_gap | reply_needs_semantic_review |
| Transcribe the audio I recorded yesterday | capability_gap | reply_needs_semantic_review |
| Hi, Transcribe the audio I recorded yesterday | capability_gap | reply_needs_semantic_review |
| Please help with this: Transcribe the audio I recorded yesterday | capability_gap | reply_needs_semantic_review |
| Transcribe the audio I recorded yesterday Thanks. | capability_gap | reply_needs_semantic_review |
| Quick question: Transcribe the audio I recorded yesterday | capability_gap | reply_needs_semantic_review |
| Move my project notes into a new folder | capability_gap | missing_capability_boundary |
| Hi, Move my travel notes into a new folder | capability_gap | tool_contract_pass |
| Please help with this: Move my meeting notes into a new folder | capability_gap | reply_needs_semantic_review |
| Move my training notes into a new folder Thanks. | capability_gap | reply_needs_semantic_review |
| Quick question: Move my shopping notes into a new folder | capability_gap | reply_needs_semantic_review |
## Workouts

| Query | Capability | Result |
|---|---|---|
| Open the Workouts page | supported | tool_contract_pass |
| Hi, Open the Workouts page | supported | tool_contract_pass |
| Please help with this: Open the Workouts page | supported | tool_contract_pass |
| Open the Workouts page Thanks. | supported | tool_contract_pass |
| Quick question: Open the Workouts page | supported | tool_contract_pass |
| Search Banana for project | supported | tool_contract_pass |
| Hi, Search Banana for travel | supported | tool_contract_pass |
| Please help with this: Search Banana for meeting | supported | tool_contract_pass |
| Search Banana for training Thanks. | supported | argument_query |
| Quick question: Search Banana for shopping | supported | tool_contract_pass |
| Do something with that project thing; I have not specified what | clarification | reply_needs_semantic_review |
| Hi, Do something with that travel thing; I have not specified what | clarification | reply_needs_semantic_review |
| Please help with this: Do something with that meeting thing; I have not specified what | clarification | reply_needs_semantic_review |
| Do something with that training thing; I have not specified what Thanks. | clarification | reply_needs_semantic_review |
| Quick question: Do something with that shopping thing; I have not specified what | clarification | reply_needs_semantic_review |
| Show my workout history | supported | tool_contract_pass |
| Hi, Show my workout history | supported | tool_contract_pass |
| Please help with this: Show my workout history | supported | tool_contract_pass |
| Show my workout history Thanks. | supported | tool_contract_pass |
| Quick question: Show my workout history | supported | tool_contract_pass |
| Show my latest workout | supported | tool_contract_pass |
| Hi, Show my latest workout | supported | tool_contract_pass |
| Please help with this: Show my latest workout | supported | tool_contract_pass |
| Show my latest workout Thanks. | supported | tool_contract_pass |
| Quick question: Show my latest workout | supported | wrong_tool |
| Open my workout plan | supported | tool_contract_pass |
| Hi, Open my workout plan | supported | tool_contract_pass |
| Please help with this: Open my workout plan | supported | tool_contract_pass |
| Open my workout plan Thanks. | supported | tool_contract_pass |
| Quick question: Open my workout plan | supported | tool_contract_pass |
| Start a strength workout | capability_gap | tool_contract_pass |
| Hi, Start a strength workout | capability_gap | tool_contract_pass |
| Please help with this: Start a strength workout | capability_gap | tool_contract_pass |
| Start a strength workout Thanks. | capability_gap | tool_contract_pass |
| Quick question: Start a strength workout | capability_gap | tool_contract_pass |
| Stop my current workout | capability_gap | tool_contract_pass |
| Hi, Stop my current workout | capability_gap | tool_contract_pass |
| Please help with this: Stop my current workout | capability_gap | tool_contract_pass |
| Stop my current workout Thanks. | capability_gap | tool_contract_pass |
| Quick question: Stop my current workout | capability_gap | reply_needs_semantic_review |
| Log a 30-minute run | capability_gap | reply_needs_semantic_review |
| Hi, Log a 30-minute run | capability_gap | reply_needs_semantic_review |
| Please help with this: Log a 30-minute run | capability_gap | missing_capability_boundary |
| Log a 30-minute run Thanks. | capability_gap | reply_needs_semantic_review |
| Quick question: Log a 30-minute run | capability_gap | tool_contract_pass |
| Change yesterday’s run distance to 5km | capability_gap | reply_needs_semantic_review |
| Hi, Change yesterday’s run distance to 5km | capability_gap | reply_needs_semantic_review |
| Please help with this: Change yesterday’s run distance to 5km | capability_gap | reply_needs_semantic_review |
| Change yesterday’s run distance to 5km Thanks. | capability_gap | reply_needs_semantic_review |
| Quick question: Change yesterday’s run distance to 5km | capability_gap | tool_contract_pass |
| Delete my latest workout | capability_gap | tool_contract_pass |
| Hi, Delete my latest workout | capability_gap | reply_needs_semantic_review |
| Please help with this: Delete my latest workout | capability_gap | tool_contract_pass |
| Delete my latest workout Thanks. | capability_gap | reply_needs_semantic_review |
| Quick question: Delete my latest workout | capability_gap | reply_needs_semantic_review |
| How far did I run this week? | capability_gap | tool_contract_pass |
| Hi, How far did I run this week? | capability_gap | reply_needs_semantic_review |
| Please help with this: How far did I run this week? | capability_gap | tool_contract_pass |
| How far did I run this week? Thanks. | capability_gap | reply_needs_semantic_review |
| Quick question: How far did I run this week? | capability_gap | tool_contract_pass |
| What was my average heart rate on my last ride? | capability_gap | tool_contract_pass |
| Hi, What was my average heart rate on my last ride? | capability_gap | argument_section |
| Please help with this: What was my average heart rate on my last ride? | capability_gap | argument_section |
| What was my average heart rate on my last ride? Thanks. | capability_gap | reply_needs_semantic_review |
| Quick question: What was my average heart rate on my last ride? | capability_gap | argument_section |
| Compare my last two runs | capability_gap | wrong_tool |
| Hi, Compare my last two runs | capability_gap | wrong_tool |
| Please help with this: Compare my last two runs | capability_gap | wrong_tool |
| Compare my last two runs Thanks. | capability_gap | wrong_tool |
| Quick question: Compare my last two runs | capability_gap | wrong_tool |
| Show the route of my last ride | capability_gap | argument_section |
| Hi, Show the route of my last ride | capability_gap | tool_contract_pass |
| Please help with this: Show the route of my last ride | capability_gap | reply_needs_semantic_review |
| Show the route of my last ride Thanks. | capability_gap | wrong_tool |
| Quick question: Show the route of my last ride | capability_gap | reply_needs_semantic_review |
| How many calories did my last workout burn? | capability_gap | tool_contract_pass |
| Hi, How many calories did my last workout burn? | capability_gap | reply_needs_semantic_review |
| Please help with this: How many calories did my last workout burn? | capability_gap | reply_needs_semantic_review |
| How many calories did my last workout burn? Thanks. | capability_gap | tool_contract_pass |
| Quick question: How many calories did my last workout burn? | capability_gap | reply_needs_semantic_review |
| How many days in a row have I exercised? | capability_gap | tool_contract_pass |
| Hi, How many days in a row have I exercised? | capability_gap | reply_needs_semantic_review |
| Please help with this: How many days in a row have I exercised? | capability_gap | reply_needs_semantic_review |
| How many days in a row have I exercised? Thanks. | capability_gap | wrong_tool |
| Quick question: How many days in a row have I exercised? | capability_gap | tool_contract_pass |
| Export my workout history | capability_gap | tool_contract_pass |
| Hi, Export my workout history | capability_gap | tool_contract_pass |
| Please help with this: Export my workout history | capability_gap | tool_contract_pass |
| Export my workout history Thanks. | capability_gap | tool_contract_pass |
| Quick question: Export my workout history | capability_gap | reply_needs_semantic_review |
| Sync my Watch workouts now | capability_gap | reply_needs_semantic_review |
| Hi, Sync my Watch workouts now | capability_gap | reply_needs_semantic_review |
| Please help with this: Sync my Watch workouts now | capability_gap | reply_needs_semantic_review |
| Sync my Watch workouts now Thanks. | capability_gap | tool_contract_pass |
| Quick question: Sync my Watch workouts now | capability_gap | argument_section |
| Schedule three strength workouts each week | capability_gap | missing_capability_boundary |
| Hi, Schedule three strength workouts each week | capability_gap | reply_needs_semantic_review |
| Please help with this: Schedule three strength workouts each week | capability_gap | missing_capability_boundary |
| Schedule three strength workouts each week Thanks. | capability_gap | wrong_tool |
| Quick question: Schedule three strength workouts each week | capability_gap | wrong_tool |
## Routines

| Query | Capability | Result |
|---|---|---|
| Open the Routines page | supported | tool_contract_pass |
| Hi, Open the Routines page | supported | tool_contract_pass |
| Please help with this: Open the Routines page | supported | tool_contract_pass |
| Open the Routines page Thanks. | supported | tool_contract_pass |
| Quick question: Open the Routines page | supported | tool_contract_pass |
| Search Banana for project | supported | tool_contract_pass |
| Hi, Search Banana for travel | supported | tool_contract_pass |
| Please help with this: Search Banana for meeting | supported | tool_contract_pass |
| Search Banana for training Thanks. | supported | argument_query |
| Quick question: Search Banana for shopping | supported | tool_contract_pass |
| Do something with that project thing; I have not specified what | clarification | reply_needs_semantic_review |
| Hi, Do something with that travel thing; I have not specified what | clarification | reply_needs_semantic_review |
| Please help with this: Do something with that meeting thing; I have not specified what | clarification | reply_needs_semantic_review |
| Do something with that training thing; I have not specified what Thanks. | clarification | reply_needs_semantic_review |
| Quick question: Do something with that shopping thing; I have not specified what | clarification | reply_needs_semantic_review |
| Show my routines | supported | tool_contract_pass |
| Hi, Show my routines | supported | tool_contract_pass |
| Please help with this: Show my routines | supported | tool_contract_pass |
| Show my routines Thanks. | supported | tool_contract_pass |
| Quick question: Show my routines | supported | tool_contract_pass |
| Open my morning routine | supported | tool_contract_pass |
| Hi, Open my morning routine | supported | tool_contract_pass |
| Please help with this: Open my morning routine | supported | tool_contract_pass |
| Open my morning routine Thanks. | supported | tool_contract_pass |
| Quick question: Open my morning routine | supported | tool_contract_pass |
| Open my evening routine | supported | tool_contract_pass |
| Hi, Open my evening routine | supported | tool_contract_pass |
| Please help with this: Open my evening routine | supported | tool_contract_pass |
| Open my evening routine Thanks. | supported | tool_contract_pass |
| Quick question: Open my evening routine | supported | tool_contract_pass |
| Create a bedtime routine at 09:15 | capability_gap | wrong_tool |
| Hi, Create a bedtime routine at 11:30 | capability_gap | wrong_tool |
| Please help with this: Create a bedtime routine at 14:00 | capability_gap | missing_capability_boundary |
| Create a bedtime routine at 17:00 Thanks. | capability_gap | wrong_tool |
| Quick question: Create a bedtime routine at 20:45 | capability_gap | missing_capability_boundary |
| Move my morning routine to 09:15 | capability_gap | wrong_tool |
| Hi, Move my morning routine to 11:30 | capability_gap | missing_capability_boundary |
| Please help with this: Move my morning routine to 14:00 | capability_gap | wrong_tool |
| Move my morning routine to 17:00 Thanks. | capability_gap | missing_capability_boundary |
| Quick question: Move my morning routine to 20:45 | capability_gap | missing_capability_boundary |
| Delete my bedtime routine | capability_gap | reply_needs_semantic_review |
| Hi, Delete my bedtime routine | capability_gap | reply_needs_semantic_review |
| Please help with this: Delete my bedtime routine | capability_gap | reply_needs_semantic_review |
| Delete my bedtime routine Thanks. | capability_gap | tool_contract_pass |
| Quick question: Delete my bedtime routine | capability_gap | reply_needs_semantic_review |
| Disable all routines | capability_gap | tool_contract_pass |
| Hi, Disable all routines | capability_gap | tool_contract_pass |
| Please help with this: Disable all routines | capability_gap | tool_contract_pass |
| Disable all routines Thanks. | capability_gap | reply_needs_semantic_review |
| Quick question: Disable all routines | capability_gap | tool_contract_pass |
| Skip tomorrow’s morning routine | capability_gap | wrong_tool |
| Hi, Skip tomorrow’s morning routine | capability_gap | wrong_tool |
| Please help with this: Skip tomorrow’s morning routine | capability_gap | wrong_tool |
| Skip tomorrow’s morning routine Thanks. | capability_gap | wrong_tool |
| Quick question: Skip tmrw’s morning routine | capability_gap | argument_section |
| Mark my morning routine complete | capability_gap | wrong_tool |
| Hi, Mark my morning routine complete | capability_gap | wrong_tool |
| Please help with this: Mark my morning routine complete | capability_gap | wrong_tool |
| Mark my morning routine complete Thanks. | capability_gap | wrong_tool |
| Quick question: Mark my morning routine complete | capability_gap | reply_needs_semantic_review |
| Repeat my routine only on weekdays | capability_gap | wrong_tool |
| Hi, Repeat my routine only on weekdays | capability_gap | wrong_tool |
| Please help with this: Repeat my routine only on weekdays | capability_gap | wrong_tool |
| Repeat my routine only on weekdays Thanks. | capability_gap | wrong_tool |
| Quick question: Repeat my routine only on weekdays | capability_gap | wrong_tool |
| Rename my evening routine to Wind down | capability_gap | reply_needs_semantic_review |
| Hi, Rename my evening routine to Wind down | capability_gap | tool_contract_pass |
| Please help with this: Rename my evening routine to Wind down | capability_gap | tool_contract_pass |
| Rename my evening routine to Wind down Thanks. | capability_gap | tool_contract_pass |
| Quick question: Rename my evening routine to Wind down | capability_gap | tool_contract_pass |
| Move stretching before breakfast in my routine | capability_gap | wrong_tool |
| Hi, Move stretching before breakfast in my routine | capability_gap | wrong_tool |
| Please help with this: Move stretching before breakfast in my routine | capability_gap | tool_contract_pass |
| Move stretching before breakfast in my routine Thanks. | capability_gap | tool_contract_pass |
| Quick question: Move stretching before breakfast in my routine | capability_gap | wrong_tool |
| Add a glass of water to my morning routine | capability_gap | reply_needs_semantic_review |
| Hi, Add a glass of water to my morning routine | capability_gap | wrong_tool |
| Please help with this: Add a glass of water to my morning routine | capability_gap | wrong_tool |
| Add a glass of water to my morning routine Thanks. | capability_gap | wrong_tool |
| Quick question: Add a glass of water to my morning routine | capability_gap | wrong_tool |
| Remove meditation from my morning routine | capability_gap | tool_contract_pass |
| Hi, Remove meditation from my morning routine | capability_gap | tool_contract_pass |
| Please help with this: Remove meditation from my morning routine | capability_gap | tool_contract_pass |
| Remove meditation from my morning routine Thanks. | capability_gap | tool_contract_pass |
| Quick question: Remove meditation from my morning routine | capability_gap | tool_contract_pass |
| How often did I complete my routines this week? | capability_gap | wrong_tool |
| Hi, How often did I complete my routines this week? | capability_gap | tool_contract_pass |
| Please help with this: How often did I complete my routines this week? | capability_gap | tool_contract_pass |
| How often did I complete my routines this week? Thanks. | capability_gap | reply_needs_semantic_review |
| Quick question: How often did I complete my routines this week? | capability_gap | wrong_tool |
| Turn off routine notifications | capability_gap | argument_section |
| Hi, Turn off routine notifications | capability_gap | argument_section |
| Please help with this: Turn off routine notifications | capability_gap | argument_section |
| Turn off routine notifications Thanks. | capability_gap | argument_section |
| Quick question: Turn off routine notifications | capability_gap | argument_section |
| Shift my routines to London time for my trip | capability_gap | tool_contract_pass |
| Hi, Shift my routines to London time for my trip | capability_gap | reply_needs_semantic_review |
| Please help with this: Shift my routines to London time for my trip | capability_gap | tool_contract_pass |
| Shift my routines to London time for my trip Thanks. | capability_gap | tool_contract_pass |
| Quick question: Shift my routines to London time for my trip | capability_gap | reply_needs_semantic_review |
## Library

| Query | Capability | Result |
|---|---|---|
| Open the Library page | supported | tool_contract_pass |
| Hi, Open the Library page | supported | tool_contract_pass |
| Please help with this: Open the Library page | supported | tool_contract_pass |
| Open the Library page Thanks. | supported | tool_contract_pass |
| Quick question: Open the Library page | supported | tool_contract_pass |
| Search Banana for project | supported | tool_contract_pass |
| Hi, Search Banana for travel | supported | tool_contract_pass |
| Please help with this: Search Banana for meeting | supported | tool_contract_pass |
| Search Banana for training Thanks. | supported | argument_query |
| Quick question: Search Banana for shopping | supported | tool_contract_pass |
| Do something with that project thing; I have not specified what | clarification | reply_needs_semantic_review |
| Hi, Do something with that travel thing; I have not specified what | clarification | reply_needs_semantic_review |
| Please help with this: Do something with that meeting thing; I have not specified what | clarification | reply_needs_semantic_review |
| Do something with that training thing; I have not specified what Thanks. | clarification | reply_needs_semantic_review |
| Quick question: Do something with that shopping thing; I have not specified what | clarification | reply_needs_semantic_review |
| Show my podcast library | supported | tool_contract_pass |
| Hi, Show my podcast library | supported | tool_contract_pass |
| Please help with this: Show my podcast library | supported | tool_contract_pass |
| Show my podcast library Thanks. | supported | tool_contract_pass |
| Quick question: Show my podcast library | supported | tool_contract_pass |
| Open my downloaded episodes | supported | tool_contract_pass |
| Hi, Open my downloaded episodes | supported | tool_contract_pass |
| Please help with this: Open my downloaded episodes | supported | wrong_tool |
| Open my downloaded episodes Thanks. | supported | wrong_tool |
| Quick question: Open my downloaded episodes | supported | tool_contract_pass |
| Open my listening history | supported | tool_contract_pass |
| Hi, Open my listening history | supported | tool_contract_pass |
| Please help with this: Open my listening history | supported | tool_contract_pass |
| Open my listening history Thanks. | supported | tool_contract_pass |
| Quick question: Open my listening history | supported | tool_contract_pass |
| Play the newest episode of Acquired | capability_gap | wrong_tool |
| Hi, Play the newest episode of Acquired | capability_gap | wrong_tool |
| Please help with this: Play the newest episode of Acquired | capability_gap | tool_contract_pass |
| Play the newest episode of Acquired Thanks. | capability_gap | wrong_tool |
| Quick question: Play the newest episode of Acquired | capability_gap | wrong_tool |
| Pause my podcast | capability_gap | tool_contract_pass |
| Hi, Pause my podcast | capability_gap | tool_contract_pass |
| Please help with this: Pause my podcast | capability_gap | tool_contract_pass |
| Pause my podcast Thanks. | capability_gap | tool_contract_pass |
| Quick question: Pause my podcast | capability_gap | reply_needs_semantic_review |
| Resume the last podcast | capability_gap | wrong_tool |
| Hi, Resume the last podcast | capability_gap | tool_contract_pass |
| Please help with this: Resume the last podcast | capability_gap | wrong_tool |
| Resume the last podcast Thanks. | capability_gap | wrong_tool |
| Quick question: Resume the last podcast | capability_gap | wrong_tool |
| Skip ahead 30 seconds | capability_gap | reply_needs_semantic_review |
| Hi, Skip ahead 30 seconds | capability_gap | reply_needs_semantic_review |
| Please help with this: Skip ahead 30 seconds | capability_gap | reply_needs_semantic_review |
| Skip ahead 30 seconds Thanks. | capability_gap | reply_needs_semantic_review |
| Quick question: Skip ahead 30 seconds | capability_gap | reply_needs_semantic_review |
| Set playback speed to 1.5x | capability_gap | reply_needs_semantic_review |
| Hi, Set playback speed to 1.5x | capability_gap | argument_section |
| Please help with this: Set playback speed to 1.5x | capability_gap | argument_section |
| Set playback speed to 1.5x Thanks. | capability_gap | tool_contract_pass |
| Quick question: Set playback speed to 1.5x | capability_gap | argument_section |
| Download the latest Acquired episode | capability_gap | tool_contract_pass |
| Hi, Download the latest Acquired episode | capability_gap | tool_contract_pass |
| Please help with this: Download the latest Acquired episode | capability_gap | wrong_tool |
| Download the latest Acquired episode Thanks. | capability_gap | wrong_tool |
| Quick question: Download the latest Acquired episode | capability_gap | reply_needs_semantic_review |
| Delete all downloaded episodes | capability_gap | tool_contract_pass |
| Hi, Delete all downloaded episodes | capability_gap | reply_needs_semantic_review |
| Please help with this: Delete all downloaded episodes | capability_gap | tool_contract_pass |
| Delete all downloaded episodes Thanks. | capability_gap | tool_contract_pass |
| Quick question: Delete all downloaded episodes | capability_gap | tool_contract_pass |
| Subscribe me to a new science podcast | capability_gap | wrong_tool |
| Hi, Subscribe me to a new science podcast | capability_gap | wrong_tool |
| Please help with this: Subscribe me to a new science podcast | capability_gap | reply_needs_semantic_review |
| Subscribe me to a new science podcast Thanks. | capability_gap | reply_needs_semantic_review |
| Quick question: Subscribe me to a new science podcast | capability_gap | reply_needs_semantic_review |
| Unsubscribe me from Acquired | capability_gap | argument_section |
| Hi, Unsubscribe me from Acquired | capability_gap | reply_needs_semantic_review |
| Please help with this: Unsubscribe me from Acquired | capability_gap | reply_needs_semantic_review |
| Unsubscribe me from Acquired Thanks. | capability_gap | wrong_tool |
| Quick question: Unsubscribe me from Acquired | capability_gap | reply_needs_semantic_review |
| Add the newest episode to my queue | capability_gap | wrong_tool |
| Hi, Add the newest episode to my queue | capability_gap | tool_contract_pass |
| Please help with this: Add the newest episode to my queue | capability_gap | wrong_tool |
| Add the newest episode to my queue Thanks. | capability_gap | wrong_tool |
| Quick question: Add the newest episode to my queue | capability_gap | wrong_tool |
| Mark this episode as played | capability_gap | tool_contract_pass |
| Hi, Mark this episode as played | capability_gap | tool_contract_pass |
| Please help with this: Mark this episode as played | capability_gap | missing_capability_boundary |
| Mark this episode as played Thanks. | capability_gap | reply_needs_semantic_review |
| Quick question: Mark this episode as played | capability_gap | reply_needs_semantic_review |
| Stop playback after 20 minutes | capability_gap | reply_needs_semantic_review |
| Hi, Stop playback after 20 minutes | capability_gap | argument_section |
| Please help with this: Stop playback after 20 minutes | capability_gap | reply_needs_semantic_review |
| Stop playback after 20 minutes Thanks. | capability_gap | reply_needs_semantic_review |
| Quick question: Stop playback after 20 minutes | capability_gap | reply_needs_semantic_review |
| Where did I listen to my last episode? | capability_gap | wrong_tool |
| Hi, Where did I listen to my last episode? | capability_gap | wrong_tool |
| Please help with this: Where did I listen to my last episode? | capability_gap | wrong_tool |
| Where did I listen to my last episode? Thanks. | capability_gap | wrong_tool |
| Quick question: Where did I listen to my last episode? | capability_gap | wrong_tool |
| Summarize the podcast episode I heard yesterday | capability_gap | reply_needs_semantic_review |
| Hi, Summarize the podcast episode I heard yesterday | capability_gap | tool_contract_pass |
| Please help with this: Summarize the podcast episode I heard yesterday | capability_gap | wrong_tool |
| Summarize the podcast episode I heard yesterday Thanks. | capability_gap | wrong_tool |
| Quick question: Summarize the podcast episode I heard yesterday | capability_gap | reply_needs_semantic_review |
## Review

| Query | Capability | Result |
|---|---|---|
| Open the Review page | supported | tool_contract_pass |
| Hi, Open the Review page | supported | tool_contract_pass |
| Please help with this: Open the Review page | supported | tool_contract_pass |
| Open the Review page Thanks. | supported | tool_contract_pass |
| Quick question: Open the Review page | supported | tool_contract_pass |
| Search Banana for project | supported | tool_contract_pass |
| Hi, Search Banana for travel | supported | tool_contract_pass |
| Please help with this: Search Banana for meeting | supported | tool_contract_pass |
| Search Banana for training Thanks. | supported | argument_query |
| Quick question: Search Banana for shopping | supported | tool_contract_pass |
| Do something with that project thing; I have not specified what | clarification | reply_needs_semantic_review |
| Hi, Do something with that travel thing; I have not specified what | clarification | reply_needs_semantic_review |
| Please help with this: Do something with that meeting thing; I have not specified what | clarification | reply_needs_semantic_review |
| Do something with that training thing; I have not specified what Thanks. | clarification | reply_needs_semantic_review |
| Quick question: Do something with that shopping thing; I have not specified what | clarification | reply_needs_semantic_review |
| Open my health review | supported | tool_contract_pass |
| Hi, Open my health review | supported | tool_contract_pass |
| Please help with this: Open my health review | supported | tool_contract_pass |
| Open my health review Thanks. | supported | tool_contract_pass |
| Quick question: Open my health review | supported | tool_contract_pass |
| Show my sleep trends | supported | wrong_tool |
| Hi, Show my sleep trends | supported | wrong_tool |
| Please help with this: Show my sleep trends | supported | wrong_tool |
| Show my sleep trends Thanks. | supported | tool_contract_pass |
| Quick question: Show my sleep trends | supported | wrong_tool |
| Show my activity trends | supported | tool_contract_pass |
| Hi, Show my activity trends | supported | tool_contract_pass |
| Please help with this: Show my activity trends | supported | tool_contract_pass |
| Show my activity trends Thanks. | supported | wrong_tool |
| Quick question: Show my activity trends | supported | tool_contract_pass |
| How much did I sleep last night? | capability_gap | reply_needs_semantic_review |
| Hi, How much did I sleep last night? | capability_gap | reply_needs_semantic_review |
| Please help with this: How much did I sleep last night? | capability_gap | wrong_tool |
| How much did I sleep last night? Thanks. | capability_gap | tool_contract_pass |
| Quick question: How much did I sleep last night? | capability_gap | reply_needs_semantic_review |
| What was my average sleep this week? | capability_gap | wrong_tool |
| Hi, What was my average sleep this week? | capability_gap | reply_needs_semantic_review |
| Please help with this: What was my average sleep this week? | capability_gap | reply_needs_semantic_review |
| What was my average sleep this week? Thanks. | capability_gap | tool_contract_pass |
| Quick question: What was my average sleep this week? | capability_gap | tool_contract_pass |
| How has my weight changed this month? | capability_gap | tool_contract_pass |
| Hi, How has my weight changed this month? | capability_gap | tool_contract_pass |
| Please help with this: How has my weight changed this month? | capability_gap | tool_contract_pass |
| How has my weight changed this month? Thanks. | capability_gap | tool_contract_pass |
| Quick question: How has my weight changed this month? | capability_gap | missing_capability_boundary |
| How many steps did I take yesterday? | capability_gap | reply_needs_semantic_review |
| Hi, How many steps did I take yesterday? | capability_gap | reply_needs_semantic_review |
| Please help with this: How many steps did I take yesterday? | capability_gap | reply_needs_semantic_review |
| How many steps did I take yesterday? Thanks. | capability_gap | reply_needs_semantic_review |
| Quick question: How many steps did I take yesterday? | capability_gap | reply_needs_semantic_review |
| What is my current HRV trend? | capability_gap | tool_contract_pass |
| Hi, What is my current HRV trend? | capability_gap | tool_contract_pass |
| Please help with this: What is my current HRV trend? | capability_gap | tool_contract_pass |
| What is my current HRV trend? Thanks. | capability_gap | tool_contract_pass |
| Quick question: What is my current HRV trend? | capability_gap | reply_needs_semantic_review |
| Has my resting heart rate improved? | capability_gap | reply_needs_semantic_review |
| Hi, Has my resting heart rate improved? | capability_gap | reply_needs_semantic_review |
| Please help with this: Has my resting heart rate improved? | capability_gap | tool_contract_pass |
| Has my resting heart rate improved? Thanks. | capability_gap | tool_contract_pass |
| Quick question: Has my resting heart rate improved? | capability_gap | tool_contract_pass |
| Show my latest VO2 max value | capability_gap | reply_needs_semantic_review |
| Hi, Show my latest VO2 max value | capability_gap | tool_contract_pass |
| Please help with this: Show my latest VO2 max value | capability_gap | tool_contract_pass |
| Show my latest VO2 max value Thanks. | capability_gap | tool_contract_pass |
| Quick question: Show my latest VO2 max value | capability_gap | tool_contract_pass |
| Compare calories burned with food intake | capability_gap | wrong_tool |
| Hi, Compare calories burned with food intake | capability_gap | wrong_tool |
| Please help with this: Compare calories burned with food intake | capability_gap | wrong_tool |
| Compare calories burned with food intake Thanks. | capability_gap | wrong_tool |
| Quick question: Compare calories burned with food intake | capability_gap | reply_needs_semantic_review |
| Why are yesterday’s health measurements missing? | capability_gap | reply_needs_semantic_review |
| Hi, Why are yesterday’s health measurements missing? | capability_gap | reply_needs_semantic_review |
| Please help with this: Why are yesterday’s health measurements missing? | capability_gap | reply_needs_semantic_review |
| Why are yesterday’s health measurements missing? Thanks. | capability_gap | argument_section |
| Quick question: Why are yesterday’s health measurements missing? | capability_gap | tool_contract_pass |
| Set a daily goal of 10000 steps | capability_gap | argument_section |
| Hi, Set a daily goal of 10000 steps | capability_gap | argument_section |
| Please help with this: Set a daily goal of 10000 steps | capability_gap | argument_section |
| Set a daily goal of 10000 steps Thanks. | capability_gap | argument_section |
| Quick question: Set a daily goal of 10000 steps | capability_gap | reply_needs_semantic_review |
| Correct my weight to 75kg | capability_gap | argument_section |
| Hi, Correct my weight to 75kg | capability_gap | argument_section |
| Please help with this: Correct my weight to 75kg | capability_gap | argument_section |
| Correct my weight to 75kg Thanks. | capability_gap | tool_contract_pass |
| Quick question: Correct my weight to 75kg | capability_gap | argument_section |
| Delete my sleep history | capability_gap | reply_needs_semantic_review |
| Hi, Delete my sleep history | capability_gap | reply_needs_semantic_review |
| Please help with this: Delete my sleep history | capability_gap | tool_contract_pass |
| Delete my sleep history Thanks. | capability_gap | tool_contract_pass |
| Quick question: Delete my sleep history | capability_gap | reply_needs_semantic_review |
| Did my flight make my sleep look shorter? | capability_gap | tool_contract_pass |
| Hi, Did my flight make my sleep look shorter? | capability_gap | wrong_tool |
| Please help with this: Did my flight make my sleep look shorter? | capability_gap | wrong_tool |
| Did my flight make my sleep look shorter? Thanks. | capability_gap | tool_contract_pass |
| Quick question: Did my flight make my sleep look shorter? | capability_gap | wrong_tool |
| Diagnose why my heart rate went up from my records | capability_gap | reply_needs_semantic_review |
| Hi, Diagnose why my heart rate went up from my records | capability_gap | reply_needs_semantic_review |
| Please help with this: Diagnose why my heart rate went up from my records | capability_gap | reply_needs_semantic_review |
| Diagnose why my heart rate went up from my records Thanks. | capability_gap | reply_needs_semantic_review |
| Quick question: Diagnose why my heart rate went up from my records | capability_gap | reply_needs_semantic_review |
## Settings

| Query | Capability | Result |
|---|---|---|
| Open the Settings page | supported | tool_contract_pass |
| Hi, Open the Settings page | supported | tool_contract_pass |
| Please help with this: Open the Settings page | supported | tool_contract_pass |
| Open the Settings page Thanks. | supported | tool_contract_pass |
| Quick question: Open the Settings page | supported | tool_contract_pass |
| Search Banana for project | supported | tool_contract_pass |
| Hi, Search Banana for travel | supported | tool_contract_pass |
| Please help with this: Search Banana for meeting | supported | tool_contract_pass |
| Search Banana for training Thanks. | supported | argument_query |
| Quick question: Search Banana for shopping | supported | tool_contract_pass |
| Do something with that project thing; I have not specified what | clarification | reply_needs_semantic_review |
| Hi, Do something with that travel thing; I have not specified what | clarification | reply_needs_semantic_review |
| Please help with this: Do something with that meeting thing; I have not specified what | clarification | reply_needs_semantic_review |
| Do something with that training thing; I have not specified what Thanks. | clarification | reply_needs_semantic_review |
| Quick question: Do something with that shopping thing; I have not specified what | clarification | wrong_tool |
| Open Settings | supported | tool_contract_pass |
| Hi, Open Settings | supported | tool_contract_pass |
| Please help with this: Open Settings | supported | tool_contract_pass |
| Open Settings Thanks. | supported | tool_contract_pass |
| Quick question: Open Settings | supported | tool_contract_pass |
| Show the privacy settings | supported | tool_contract_pass |
| Hi, Show the privacy settings | supported | tool_contract_pass |
| Please help with this: Show the privacy settings | supported | tool_contract_pass |
| Show the privacy settings Thanks. | supported | tool_contract_pass |
| Quick question: Show the privacy settings | supported | tool_contract_pass |
| Show calendar connection settings | supported | tool_contract_pass |
| Hi, Show calendar connection settings | supported | tool_contract_pass |
| Please help with this: Show calendar connection settings | supported | tool_contract_pass |
| Show calendar connection settings Thanks. | supported | tool_contract_pass |
| Quick question: Show calendar connection settings | supported | tool_contract_pass |
| Connect my Google account | capability_gap | tool_contract_pass |
| Hi, Connect my Google account | capability_gap | reply_needs_semantic_review |
| Please help with this: Connect my Google account | capability_gap | reply_needs_semantic_review |
| Connect my Google account Thanks. | capability_gap | tool_contract_pass |
| Quick question: Connect my Google account | capability_gap | tool_contract_pass |
| Disconnect all my accounts | capability_gap | reply_needs_semantic_review |
| Hi, Disconnect all my accounts | capability_gap | tool_contract_pass |
| Please help with this: Disconnect all my accounts | capability_gap | tool_contract_pass |
| Disconnect all my accounts Thanks. | capability_gap | tool_contract_pass |
| Quick question: Disconnect all my accounts | capability_gap | reply_needs_semantic_review |
| Set my timezone to Asia/Tokyo | capability_gap | tool_contract_pass |
| Hi, Set my timezone to Asia/Tokyo | capability_gap | tool_contract_pass |
| Please help with this: Set my timezone to Asia/Tokyo | capability_gap | tool_contract_pass |
| Set my timezone to Asia/Tokyo Thanks. | capability_gap | tool_contract_pass |
| Quick question: Set my timezone to Asia/Tokyo | capability_gap | tool_contract_pass |
| Switch distance units to kilometers | capability_gap | tool_contract_pass |
| Hi, Switch distance units to kilometers | capability_gap | tool_contract_pass |
| Please help with this: Switch distance units to kilometers | capability_gap | tool_contract_pass |
| Switch distance units to kilometers Thanks. | capability_gap | tool_contract_pass |
| Quick question: Switch distance units to kilometers | capability_gap | tool_contract_pass |
| Disable every notification | capability_gap | reply_needs_semantic_review |
| Hi, Disable every notification | capability_gap | reply_needs_semantic_review |
| Please help with this: Disable every notification | capability_gap | reply_needs_semantic_review |
| Disable every notification Thanks. | capability_gap | tool_contract_pass |
| Quick question: Disable every notification | capability_gap | tool_contract_pass |
| Enable dark mode | capability_gap | tool_contract_pass |
| Hi, Enable dark mode | capability_gap | tool_contract_pass |
| Please help with this: Enable dark mode | capability_gap | tool_contract_pass |
| Enable dark mode Thanks. | capability_gap | tool_contract_pass |
| Quick question: Enable dark mode | capability_gap | tool_contract_pass |
| Export all my personal data | capability_gap | tool_contract_pass |
| Hi, Export all my personal data | capability_gap | tool_contract_pass |
| Please help with this: Export all my personal data | capability_gap | tool_contract_pass |
| Export all my personal data Thanks. | capability_gap | tool_contract_pass |
| Quick question: Export all my personal data | capability_gap | tool_contract_pass |
| Delete all app data | capability_gap | reply_needs_semantic_review |
| Hi, Delete all app data | capability_gap | tool_contract_pass |
| Please help with this: Delete all app data | capability_gap | reply_needs_semantic_review |
| Delete all app data Thanks. | capability_gap | reply_needs_semantic_review |
| Quick question: Delete all app data | capability_gap | reply_needs_semantic_review |
| Back up my data now | capability_gap | reply_needs_semantic_review |
| Hi, Back up my data now | capability_gap | tool_contract_pass |
| Please help with this: Back up my data now | capability_gap | reply_needs_semantic_review |
| Back up my data now Thanks. | capability_gap | reply_needs_semantic_review |
| Quick question: Back up my data now | capability_gap | argument_section |
| Restore yesterday’s backup | capability_gap | reply_needs_semantic_review |
| Hi, Restore yesterday’s backup | capability_gap | wrong_tool |
| Please help with this: Restore yesterday’s backup | capability_gap | reply_needs_semantic_review |
| Restore yesterday’s backup Thanks. | capability_gap | reply_needs_semantic_review |
| Quick question: Restore yesterday’s backup | capability_gap | reply_needs_semantic_review |
| Grant access to my microphone | capability_gap | reply_needs_semantic_review |
| Hi, Grant access to my microphone | capability_gap | reply_needs_semantic_review |
| Please help with this: Grant access to my microphone | capability_gap | reply_needs_semantic_review |
| Grant access to my microphone Thanks. | capability_gap | tool_contract_pass |
| Quick question: Grant access to my microphone | capability_gap | reply_needs_semantic_review |
| Turn off all sample data | capability_gap | tool_contract_pass |
| Hi, Turn off all sample data | capability_gap | tool_contract_pass |
| Please help with this: Turn off all sample data | capability_gap | tool_contract_pass |
| Turn off all sample data Thanks. | capability_gap | tool_contract_pass |
| Quick question: Turn off all sample data | capability_gap | reply_needs_semantic_review |
| Download a different AI model | capability_gap | tool_contract_pass |
| Hi, Download a different AI model | capability_gap | reply_needs_semantic_review |
| Please help with this: Download a different AI model | capability_gap | reply_needs_semantic_review |
| Download a different AI model Thanks. | capability_gap | reply_needs_semantic_review |
| Quick question: Download a different AI model | capability_gap | reply_needs_semantic_review |
| Enable iCloud sync | capability_gap | tool_contract_pass |
| Hi, Enable iCloud sync | capability_gap | reply_needs_semantic_review |
| Please help with this: Enable iCloud sync | capability_gap | tool_contract_pass |
| Enable iCloud sync Thanks. | capability_gap | tool_contract_pass |
| Quick question: Enable iCloud sync | capability_gap | tool_contract_pass |
## Assistant

| Query | Capability | Result |
|---|---|---|
| Open the Assistant page | supported | tool_contract_pass |
| Hi, Open the Assistant page | supported | tool_contract_pass |
| Please help with this: Open the Assistant page | supported | tool_contract_pass |
| Open the Assistant page Thanks. | supported | tool_contract_pass |
| Quick question: Open the Assistant page | supported | tool_contract_pass |
| Search Banana for project | supported | tool_contract_pass |
| Hi, Search Banana for travel | supported | tool_contract_pass |
| Please help with this: Search Banana for meeting | supported | tool_contract_pass |
| Search Banana for training Thanks. | supported | argument_query |
| Quick question: Search Banana for shopping | supported | tool_contract_pass |
| Do something with that project thing; I have not specified what | clarification | reply_needs_semantic_review |
| Hi, Do something with that travel thing; I have not specified what | clarification | reply_needs_semantic_review |
| Please help with this: Do something with that meeting thing; I have not specified what | clarification | reply_needs_semantic_review |
| Do something with that training thing; I have not specified what Thanks. | clarification | reply_needs_semantic_review |
| Quick question: Do something with that shopping thing; I have not specified what | clarification | reply_needs_semantic_review |
| Open the assistant | supported | tool_contract_pass |
| Hi, Open the assistant | supported | tool_contract_pass |
| Please help with this: Open the assistant | supported | tool_contract_pass |
| Open the assistant Thanks. | supported | tool_contract_pass |
| Quick question: Open the assistant | supported | tool_contract_pass |
| Hello | supported | wrong_tool |
| Hi, Hello | supported | reply_needs_semantic_review |
| Please help with this: Hello | supported | reply_needs_semantic_review |
| Hello Thanks. | supported | reply_needs_semantic_review |
| Quick question: Hello | supported | wrong_tool |
| What is your name? | supported | reply_needs_semantic_review |
| Hi, What is your name? | supported | reply_needs_semantic_review |
| Please help with this: What is your name? | supported | reply_needs_semantic_review |
| What is your name? Thanks. | supported | reply_needs_semantic_review |
| Quick question: What is your name? | supported | reply_needs_semantic_review |
| What can you help me with? | supported | reply_needs_semantic_review |
| Hi, What can you help me with? | supported | reply_needs_semantic_review |
| Please help with this: What can you help me with? | supported | reply_needs_semantic_review |
| What can you help me with? Thanks. | supported | reply_needs_semantic_review |
| Quick question: What can you help me with? | supported | reply_needs_semantic_review |
| Thank you | supported | reply_needs_semantic_review |
| Hi, Thank you | supported | reply_needs_semantic_review |
| Please help with this: Thank you | supported | reply_needs_semantic_review |
| Thank you Thanks. | supported | reply_needs_semantic_review |
| Quick question: Thank you | supported | reply_needs_semantic_review |
| Explain what a timezone is in plain language | supported | reply_needs_semantic_review |
| Hi, Explain what a timezone is in plain language | supported | reply_needs_semantic_review |
| Please help with this: Explain what a timezone is in plain language | supported | reply_needs_semantic_review |
| Explain what a timezone is in plain language Thanks. | supported | reply_needs_semantic_review |
| Quick question: Explain what a timezone is in plain language | supported | reply_needs_semantic_review |
| Give me three ideas for organizing a busy day | supported | reply_needs_semantic_review |
| Hi, Give me three ideas for organizing a busy day | supported | reply_needs_semantic_review |
| Please help with this: Give me three ideas for organizing a busy day | supported | reply_needs_semantic_review |
| Give me three ideas for organizing a busy day Thanks. | supported | reply_needs_semantic_review |
| Quick question: Give me three ideas for organizing a busy day | supported | reply_needs_semantic_review |
| Do the thing we discussed | clarification | reply_needs_semantic_review |
| Hi, Do the thing we discussed | clarification | reply_needs_semantic_review |
| Please help with this: Do the thing we discussed | clarification | reply_needs_semantic_review |
| Do the thing we discussed Thanks. | clarification | reply_needs_semantic_review |
| Quick question: Do the thing we discussed | clarification | reply_needs_semantic_review |
| Can you fix it? | clarification | reply_needs_semantic_review |
| Hi, Can you fix it? | clarification | reply_needs_semantic_review |
| Please help with this: Can you fix it? | clarification | reply_needs_semantic_review |
| Can you fix it? Thanks. | clarification | reply_needs_semantic_review |
| Quick question: Can you fix it? | clarification | reply_needs_semantic_review |
| Tell me my password | capability_gap | reply_needs_semantic_review |
| Hi, Tell me my password | capability_gap | reply_needs_semantic_review |
| Please help with this: Tell me my password | capability_gap | reply_needs_semantic_review |
| Tell me my password Thanks. | capability_gap | wrong_tool |
| Quick question: Tell me my password | capability_gap | wrong_tool |
| Delete all our conversations | capability_gap | reply_needs_semantic_review |
| Hi, Delete all our conversations | capability_gap | reply_needs_semantic_review |
| Please help with this: Delete all our conversations | capability_gap | reply_needs_semantic_review |
| Delete all our conversations Thanks. | capability_gap | reply_needs_semantic_review |
| Quick question: Delete all our conversations | capability_gap | reply_needs_semantic_review |
| Start a new conversation | capability_gap | missing_capability_boundary |
| Hi, Start a new conversation | capability_gap | wrong_tool |
| Please help with this: Start a new conversation | capability_gap | missing_capability_boundary |
| Start a new conversation Thanks. | capability_gap | missing_capability_boundary |
| Quick question: Start a new conversation | capability_gap | missing_capability_boundary |
| Remember that I prefer tea, without creating a note | supported | wrong_tool |
| Hi, Remember that I prefer tea, without creating a note | supported | reply_needs_semantic_review |
| Please help with this: Remember that I prefer tea, without creating a note | supported | wrong_tool |
| Remember that I prefer tea, without creating a note Thanks. | supported | reply_needs_semantic_review |
| Quick question: Remember that I prefer tea, without creating a note | supported | reply_needs_semantic_review |
| Switch to another AI model | capability_gap | reply_needs_semantic_review |
| Hi, Switch to another AI model | capability_gap | reply_needs_semantic_review |
| Please help with this: Switch to another AI model | capability_gap | reply_needs_semantic_review |
| Switch to another AI model Thanks. | capability_gap | reply_needs_semantic_review |
| Quick question: Switch to another AI model | capability_gap | reply_needs_semantic_review |
| Are you reading my private email right now? | supported | reply_needs_semantic_review |
| Hi, Are you reading my private email right now? | supported | reply_needs_semantic_review |
| Please help with this: Are you reading my private email right now? | supported | reply_needs_semantic_review |
| Are you reading my private email right now? Thanks. | supported | reply_needs_semantic_review |
| Quick question: Are you reading my private email right now? | supported | reply_needs_semantic_review |
| Send Alex a message saying I am late | capability_gap | reply_needs_semantic_review |
| Hi, Send Alex a message saying I am late | capability_gap | reply_needs_semantic_review |
| Please help with this: Send Alex a message saying I am late | capability_gap | reply_needs_semantic_review |
| Send Alex a message saying I am late Thanks. | capability_gap | reply_needs_semantic_review |
| Quick question: Send Alex a message saying I am late | capability_gap | reply_needs_semantic_review |
| Do not change anything, just explain what an agenda is | supported | reply_needs_semantic_review |
| Hi, Do not change anything, just explain what an agenda is | supported | reply_needs_semantic_review |
| Please help with this: Do not change anything, just explain what an agenda is | supported | reply_needs_semantic_review |
| Do not change anything, just explain what an agenda is Thanks. | supported | reply_needs_semantic_review |
| Quick question: Do not change anything, just explain what an agenda is | supported | reply_needs_semantic_review |
