# Common-query evaluation

900 synthetic development routing/argument contracts, 100 per module. 20 intent families × 5 variants; not empirical top-query rankings, not held-out accuracy, and not end-to-end action tests. Text-only responses require semantic review. Capability gaps are labeled explicitly.

This run evaluated 900 queries. Documented oracle corrections are applied without changing the raw responses; see the JSON report.

Automatic checks verify routing, arguments, schema, missing-input behavior, and some false completion claims. Text replies below still require semantic review. A navigation fallback does not implement the requested capability. No app tools execute in this benchmark; native/full-app tests are separate.

| Module | Tested | Tool contracts passed | Honest navigation fallback | Text to review | Contract failures | Capability-gap cases |
|---|---:|---:|---:|---:|---:|---:|
| plan | 100 | 42 | 2 | 21 | 35 | 45 |
| nutrition | 100 | 54 | 3 | 29 | 14 | 30 |
| notes | 100 | 51 | 4 | 25 | 20 | 30 |
| workouts | 100 | 23 | 27 | 31 | 19 | 70 |
| routines | 100 | 24 | 21 | 16 | 39 | 70 |
| library | 100 | 22 | 17 | 28 | 33 | 70 |
| review | 100 | 19 | 24 | 32 | 25 | 70 |
| settings | 100 | 24 | 40 | 32 | 4 | 70 |
| assistant | 100 | 14 | 0 | 74 | 12 | 25 |

## Failures

### plan-time-only-2

Query: Hi, Team lunch at 11:30

Contract failure: `invented_day` (supported).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_e6b0e07d6f054b149e6dbd59",
      "type": "function",
      "function": {
        "name": "prepare_event",
        "arguments": "{\"title\": \"Team lunch\", \"time\": \"11:30\", \"day\": \"today\"}"
      }
    }
  ]
}
```

### plan-time-only-4

Query: Dinner at 17:00 Thanks.

Contract failure: `missing_tool` (supported).

```json
{
  "role": "assistant",
  "content": "I need a bit more information to create this event. Could you please tell me what activity this is for? For example, \"Dinner with family,\" \"Workout,\" etc."
}
```

### plan-time-only-5

Query: Quick question: Airport pickup at 20:45

Contract failure: `missing_tool` (supported).

```json
{
  "role": "assistant",
  "content": "To prepare this event, I'll need a bit more information. What date would you like this airport pickup to be scheduled?"
}
```

### plan-missing-time-2

Query: Hi, Schedule Team lunch, but I have not chosen a time

Contract failure: `wrong_tool` (clarification).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_8399c22eb39b478fb9b621ec",
      "type": "function",
      "function": {
        "name": "prepare_event",
        "arguments": "{\"title\": \"Team lunch\"}"
      }
    }
  ]
}
```

### plan-missing-time-3

Query: Please help with this: Schedule Design review, but I have not chosen a time

Contract failure: `wrong_tool` (clarification).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_c7c265eb52c14645a5dfdcab",
      "type": "function",
      "function": {
        "name": "prepare_event",
        "arguments": "{\"title\": \"Design review\"}"
      }
    }
  ]
}
```

### plan-reschedule-1

Query: Move Dentist to 09:15

Contract failure: `missing_capability_boundary` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I'll help you move the Dentist appointment to 09:15. To do this, I need to know what day this appointment is scheduled for. Could you please tell me which day the dentist appointment is for?"
}
```

### plan-reschedule-2

Query: Hi, Move Team lunch to 11:30

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I'll help you move the Move Team lunch to 11:30. Let me first check your calendar agenda to see the current event.",
  "tool_calls": [
    {
      "id": "call_18260f43e0e3432e92565491",
      "type": "function",
      "function": {
        "name": "day_plan",
        "arguments": "{}"
      }
    }
  ]
}
```

### plan-reschedule-3

Query: Please help with this: Move Design review to 14:00

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I'll help you move the Design review event to 14:00. Let me first check your current schedule to find the event.",
  "tool_calls": [
    {
      "id": "call_c38104a77acc433d856cfa99",
      "type": "function",
      "function": {
        "name": "day_plan",
        "arguments": "{}"
      }
    }
  ]
}
```

### plan-reschedule-4

Query: Move Dinner to 17:00 Thanks.

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I'll help you move the dinner event to 17:00. Let me first check your current calendar to see the existing dinner event.",
  "tool_calls": [
    {
      "id": "call_e972d27593ce4004a6fe8646",
      "type": "function",
      "function": {
        "name": "day_plan",
        "arguments": "{}"
      }
    }
  ]
}
```

### plan-reschedule-5

Query: Quick question: Move Airport pickup to 20:45

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_4902cde9c2df4aaebed4a22b",
      "type": "function",
      "function": {
        "name": "prepare_event",
        "arguments": "{\"day\": \"today\", \"durationMinutes\": 60, \"time\": \"20:45\", \"title\": \"Airport pickup\"}"
      }
    }
  ]
}
```

### plan-cancel-3

Query: Please help with this: Cancel Design review tomorrow

Contract failure: `missing_capability_boundary` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I can help you with that. To cancel the event, I need to know the activity/title of the event. What is the activity for the Design review?"
}
```

### plan-cancel-4

Query: Cancel Dinner tomorrow Thanks.

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I'll help you cancel your dinner event for tomorrow. Let me check your calendar first.",
  "tool_calls": [
    {
      "id": "call_7b0d2ef17ad944be853e9095",
      "type": "function",
      "function": {
        "name": "day_plan",
        "arguments": "{\"date\": \"tomorrow\"}"
      }
    }
  ]
}
```

### plan-cancel-5

Query: Quick question: Cancel Airport pickup tmrw

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I'll check your calendar to find the airport pickup event scheduled for tomorrow.",
  "tool_calls": [
    {
      "id": "call_9bd06a67ec504c2e8dd6c5c3",
      "type": "function",
      "function": {
        "name": "day_plan",
        "arguments": "{\"date\": \"tomorrow\"}"
      }
    }
  ]
}
```

### plan-invite-4

Query: Invite Alex to Dinner Thanks.

Contract failure: `missing_capability_boundary` (capability_gap).

```json
{
  "role": "assistant",
  "content": "To invite Alex to dinner, I need a start time for the event. What time would you like to schedule this?"
}
```

### plan-invite-5

Query: Quick question: Invite Alex to Airport pickup

Contract failure: `missing_capability_boundary` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I'll help you prepare a calendar event for the airport pickup. Could you please provide the start time for the pickup?"
}
```

### plan-recurrence-1

Query: Schedule Dentist every second Tuesday at 09:15

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I need to schedule a dentist appointment for every second Tuesday at 09:15. To prepare this event, I need to know the start date. Since you want recurring events, I should prepare an event for the next occurrence.\n\nLet me prepare the event for the next second Tuesday:",
  "tool_calls": [
    {
      "id": "call_6472db7a849341f99931895a",
      "type": "function",
      "function": {
        "name": "prepare_event",
        "arguments": "{\"title\": \"Dentist\", \"day\": \"today\", \"time\": \"09:15\", \"durationMinutes\": 60}"
      }
    }
  ]
}
```

### plan-recurrence-2

Query: Hi, Schedule Team lunch every second Tuesday at 11:30

Contract failure: `missing_capability_boundary` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I can help you create a recurring team lunch event. To set this up properly, I need to know:\n\n1. What date should the first event be scheduled for?\n2. What time would you like the first event to be?\n\nOnce you provide these details, I can create the event for you."
}
```

### plan-recurrence-3

Query: Please help with this: Schedule Design review every second Tuesday at 14:00

Contract failure: `missing_capability_boundary` (capability_gap).

```json
{
  "role": "assistant",
  "content": "To schedule your Design review, I need to know which second Tuesday you'd like me to create this event for. Would you like me to schedule it for the next second Tuesday (November 3, 2026), or a different date?"
}
```

### plan-recurrence-4

Query: Schedule Dinner every second Tuesday at 17:00 Thanks.

Contract failure: `missing_capability_boundary` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I need to clarify the details before I can schedule this event. Could you please provide:\n1. The activity/title for this dinner event\n2. I'll need to confirm the start time (17:00)\n\nOnce you provide the activity/title, I can prepare the event for you."
}
```

### plan-recurrence-5

Query: Quick question: Schedule Airport pickup every second Tuesday at 20:45

Contract failure: `missing_capability_boundary` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I'll help you schedule the airport pickup event. Since you want it to happen every second Tuesday at 20:45, I need to confirm a few details:\n\n1. What's the activity/title for this event? (e.g., \"Airport Pickup\" or \"Airport Pickup - [Name]\")\n2. What year should this event start? (e.g., 2026 or 2027)\n3. Is this recurring indefinitely, or should it stop at a specific date?\n\nCould you provide the activity title and start date?"
}
```

### plan-flight-1

Query: Add flight JFK to LHR on 2026-11-03, leaving 8pm New York and arriving 8am London next day

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_bda9c20c8e7d480193e5ced5",
      "type": "function",
      "function": {
        "name": "prepare_event",
        "arguments": "{\"day\": \"2026-11-03\", \"durationMinutes\": 0, \"isAllDay\": false, \"location\": \"JFK to LHR\", \"notes\": \"Leaving 8pm New York, arriving 8am London next day\", \"time\": \"20:00\", \"title\": \"Flight JFK to LHR\"}"
      }
    }
  ]
}
```

### plan-flight-2

Query: Hi, Add flight JFK to LHR on 2026-11-04, leaving 8pm New York and arriving 8am London next day

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_f5e974798cce433096d82728",
      "type": "function",
      "function": {
        "name": "prepare_event",
        "arguments": "{\"title\": \"Flight JFK to LHR\", \"day\": \"2026-11-04\", \"durationMinutes\": 660, \"location\": \"JFK to LHR\", \"notes\": \"Leaving 8pm New York, arriving 8am London\", \"time\": \"20:00\"}"
      }
    }
  ]
}
```

### plan-flight-3

Query: Please help with this: Add flight JFK to LHR on 2026-11-05, leaving 8pm New York and arriving 8am London next day

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I'll help you create a calendar event for your flight from JFK to LHR on November 5th, 2026.",
  "tool_calls": [
    {
      "id": "call_95c413f9da2342a6a8ab8986",
      "type": "function",
      "function": {
        "name": "prepare_event",
        "arguments": "{\"day\": \"2026-11-05\", \"durationMinutes\": 60, \"location\": \"JFK to LHR\", \"notes\": \"Flight departing 8pm New York, arriving 8am London next day\", \"time\": \"20:00\", \"title\": \"Flight JFK to LHR\"}"
      }
    }
  ]
}
```

### plan-flight-4

Query: Add flight JFK to LHR on 2026-11-06, leaving 8pm New York and arriving 8am London next day Thanks.

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I need to create a calendar event for your flight. I have the activity (flight JFK to LHR), date (2026-11-06), start time (20:00), and duration (8 hours).",
  "tool_calls": [
    {
      "id": "call_6b584657da2e40319899057d",
      "type": "function",
      "function": {
        "name": "prepare_event",
        "arguments": "{\"title\": \"Flight JFK to LHR\", \"day\": \"2026-11-06\", \"time\": \"20:00\", \"durationMinutes\": 480, \"isAllDay\": false}"
      }
    }
  ]
}
```

### plan-flight-5

Query: Quick question: Add flight JFK to LHR on 2026-11-07, leaving 8pm New York and arriving 8am London next day

Contract failure: `missing_capability_boundary` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I'll help you prepare a calendar event for your flight. I have the activity and start time, but I need to clarify the format for the event title.\n\nWould you like me to create an event titled \"Flight JFK to LHR\" or \"Flight JFK-LHR\" on 2026-11-07 starting at 20:00?"
}
```

### plan-arrival-1

Query: What local time does my flight land in Tokyo?

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I don't have access to your flight schedule or calendar events.",
  "tool_calls": [
    {
      "id": "call_df2d16161a744ca2874d3277",
      "type": "function",
      "function": {
        "name": "day_plan",
        "arguments": "{}"
      }
    }
  ]
}
```

### plan-arrival-2

Query: Hi, What local time does my flight land in Tokyo?

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_5aeebedc8ab94ae589fcbbb1",
      "type": "function",
      "function": {
        "name": "day_plan",
        "arguments": "{}"
      }
    }
  ]
}
```

### plan-timezone-1

Query: Change my calendar timezone to Europe/London

Contract failure: `argument_section` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_1d2c1199969c4068b790a797",
      "type": "function",
      "function": {
        "name": "open_page",
        "arguments": "{\"section\": \"settings\"}"
      }
    }
  ]
}
```

### plan-timezone-3

Query: Please help with this: Change my calendar timezone to Europe/London

Contract failure: `argument_section` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_4a1a131e67f949deb77a9918",
      "type": "function",
      "function": {
        "name": "open_page",
        "arguments": "{\"section\": \"settings\"}"
      }
    }
  ]
}
```

### plan-timezone-4

Query: Change my calendar timezone to Europe/London Thanks.

Contract failure: `argument_section` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I can't change the device's timezone settings directly. However, I can open the settings page where you can make that change yourself.",
  "tool_calls": [
    {
      "id": "call_595383ea72614fc1b7ddf8bd",
      "type": "function",
      "function": {
        "name": "open_page",
        "arguments": "{\"section\": \"settings\"}"
      }
    }
  ]
}
```

### plan-timezone-5

Query: Quick question: Change my calendar timezone to Europe/London

Contract failure: `argument_section` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I cannot change your calendar timezone directly. I can, however, open the Settings page where you can adjust that.",
  "tool_calls": [
    {
      "id": "call_622d89fc2daf4edc88e373c5",
      "type": "function",
      "function": {
        "name": "open_page",
        "arguments": "{\"section\": \"settings\"}"
      }
    }
  ]
}
```

### plan-alarm-1

Query: Set an alarm for 09:15 tomorrow

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_ca0ae25e83594d1e9a85dd60",
      "type": "function",
      "function": {
        "name": "prepare_event",
        "arguments": "{\"day\": \"tomorrow\", \"durationMinutes\": 60, \"isAllDay\": false, \"time\": \"09:15\", \"title\": \"Alarm\"}"
      }
    }
  ]
}
```

### plan-alarm-2

Query: Hi, Set an alarm for 11:30 tomorrow

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_6dccc51954b846fc95f0b292",
      "type": "function",
      "function": {
        "name": "prepare_event",
        "arguments": "{\"title\": \"Alarm\", \"day\": \"tomorrow\", \"time\": \"11:30\", \"durationMinutes\": 0, \"notes\": \"Alarm set for 11:30\"}"
      }
    }
  ]
}
```

### plan-alarm-3

Query: Please help with this: Set an alarm for 14:00 tomorrow

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_78c90067da5344b9bf839408",
      "type": "function",
      "function": {
        "name": "prepare_event",
        "arguments": "{\"day\": \"tomorrow\", \"durationMinutes\": 60, \"time\": \"14:00\", \"title\": \"Alarm\"}"
      }
    }
  ]
}
```

### plan-alarm-5

Query: Quick question: Set an alarm for 20:45 tmrw

Contract failure: `missing_capability_boundary` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I'll prepare a calendar event for tomorrow at 20:45. What activity would you like to set this alarm for?"
}
```

### nutrition-missing-amount-2

Query: Hi, I had some chicken; ask me the amount before making a meal

Contract failure: `wrong_tool` (clarification).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_005d4aae021b4bc8821de454",
      "type": "function",
      "function": {
        "name": "prepare_meal",
        "arguments": "{\"foods\": [{\"name\": \"chicken\", \"quantity\": \"\"}]}"
      }
    }
  ]
}
```

### nutrition-missing-amount-3

Query: Please help with this: I had some salmon; ask me the amount before making a meal

Contract failure: `wrong_tool` (clarification).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_44d73050574f4c08bae2ab81",
      "type": "function",
      "function": {
        "name": "prepare_meal",
        "arguments": "{\"foods\": [{\"name\": \"salmon\", \"quantity\": \"unknown\"}]}"
      }
    }
  ]
}
```

### nutrition-missing-amount-4

Query: I had some tofu; ask me the amount before making a meal Thanks.

Contract failure: `wrong_tool` (clarification).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_d9bc4d51feb0440e8635f2d5",
      "type": "function",
      "function": {
        "name": "prepare_meal",
        "arguments": "{\"foods\": [{\"name\": \"tofu\", \"quantity\": \"unknown\"}]}"
      }
    }
  ]
}
```

### nutrition-missing-amount-5

Query: Quick question: I had some oats; ask me the amount before making a meal

Contract failure: `wrong_tool` (clarification).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_f7e0ab4f4f064133af523d0b",
      "type": "function",
      "function": {
        "name": "prepare_meal",
        "arguments": "{\"foods\": [{\"name\": \"oats\", \"quantity\": \"unknown\"}]}"
      }
    }
  ]
}
```

### nutrition-open-2

Query: Hi, Open Nutrition

Contract failure: `wrong_tool` (supported).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_4c685a4322fc4cd78e8533dd",
      "type": "function",
      "function": {
        "name": "nutrition_view",
        "arguments": "{}"
      }
    }
  ]
}
```

### nutrition-edit-1

Query: Change yesterday’s yogurt entry to 200 grams

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I cannot directly modify existing logged meals. I can, however, create a new draft of yesterday's meal with the updated amount for your review.",
  "tool_calls": [
    {
      "id": "call_ce30fcefa7464b73854eaf7d",
      "type": "function",
      "function": {
        "name": "prepare_meal_copy",
        "arguments": "{\"day\": \"yesterday\", \"mealID\": \"yesterday\"}"
      }
    }
  ]
}
```

### nutrition-edit-2

Query: Hi, Change yesterday’s chicken entry to 200 grams

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I'll need to look up the meal entry for yesterday to see the current chicken entry and update it.",
  "tool_calls": [
    {
      "id": "call_346d26db771d4a61ac01faa2",
      "type": "function",
      "function": {
        "name": "day_plan",
        "arguments": "{\"date\": \"2026-10-24\"}"
      }
    }
  ]
}
```

### nutrition-edit-3

Query: Please help with this: Change yesterday’s salmon entry to 200 grams

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I need to find yesterday's salmon entry first. Let me search for it.",
  "tool_calls": [
    {
      "id": "call_adbbb5c7302546a6b59f1bd4",
      "type": "function",
      "function": {
        "name": "nutrition_view",
        "arguments": "{\"foodName\": \"salmon\"}"
      }
    }
  ]
}
```

### nutrition-edit-5

Query: Quick question: Change yesterday’s oats entry to 200 grams

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I'll help you find and update yesterday's oats entry. Let me search for that meal.",
  "tool_calls": [
    {
      "id": "call_ae7bad0fc06845b08b0ec604",
      "type": "function",
      "function": {
        "name": "prepare_meal_copy",
        "arguments": "{\"day\": \"yesterday\", \"mealID\": \"oats\"}"
      }
    }
  ]
}
```

### nutrition-goal-1

Query: Set my protein target to 140 grams

Contract failure: `argument_section` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I cannot set or modify your nutrition targets directly. These settings are managed through the app's settings page.",
  "tool_calls": [
    {
      "id": "call_317da7b62bd749d7b5d79cf7",
      "type": "function",
      "function": {
        "name": "open_page",
        "arguments": "{\"section\": \"settings\"}"
      }
    }
  ]
}
```

### nutrition-goal-2

Query: Hi, Set my protein target to 140 grams

Contract failure: `argument_section` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_8c74f16453fa41babc5733b4",
      "type": "function",
      "function": {
        "name": "open_page",
        "arguments": "{\"section\": \"settings\"}"
      }
    }
  ]
}
```

### nutrition-supplement-2

Query: Hi, Mark my morning vitamin as taken

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_03c0d6be6b2942b2b9d07596",
      "type": "function",
      "function": {
        "name": "create_note",
        "arguments": "{\"text\": \"Morning vitamin taken\"}"
      }
    }
  ]
}
```

### nutrition-supplement-4

Query: Mark my morning vitamin as taken Thanks.

Contract failure: `argument_section` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I can't add medication or vitamin logs directly, as I don't have access to your health tracking data. You can find this by opening the \"review\" section in the app, which shows your health measurements and logs.",
  "tool_calls": [
    {
      "id": "call_55119c8dc5d442b197789724",
      "type": "function",
      "function": {
        "name": "open_page",
        "arguments": "{\"section\": \"review\"}"
      }
    }
  ]
}
```

### nutrition-supplement-5

Query: Quick question: Mark my morning vitamin as taken

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I'll create a note about taking your morning vitamin.",
  "tool_calls": [
    {
      "id": "call_948630b31fe24d51aea2b1b7",
      "type": "function",
      "function": {
        "name": "create_note",
        "arguments": "{\"text\": \"Morning vitamin taken\"}"
      }
    }
  ]
}
```

### notes-search-4

Query: Search across Banana for training Thanks.

Contract failure: `argument_query` (supported).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_fae8e18a92e3470aa6344eb4",
      "type": "function",
      "function": {
        "name": "search_app",
        "arguments": "{\"query\": \"training Thanks\"}"
      }
    }
  ]
}
```

### notes-find-1

Query: Find notes mentioning project

Contract failure: `wrong_tool` (supported).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_5cca940e4a57407983ebcfe7",
      "type": "function",
      "function": {
        "name": "list_notes",
        "arguments": "{\"limit\": 10}"
      }
    }
  ]
}
```

### notes-find-2

Query: Hi, Find notes mentioning travel

Contract failure: `wrong_tool` (supported).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_074f9342e02c417da9c94f2e",
      "type": "function",
      "function": {
        "name": "list_notes",
        "arguments": "{\"limit\": 10}"
      }
    }
  ]
}
```

### notes-find-3

Query: Please help with this: Find notes mentioning meeting

Contract failure: `wrong_tool` (supported).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_463d8274ac8e4eae9ce09837",
      "type": "function",
      "function": {
        "name": "list_notes",
        "arguments": "{\"limit\": 10}"
      }
    }
  ]
}
```

### notes-find-4

Query: Find notes mentioning training Thanks.

Contract failure: `wrong_tool` (supported).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_cbe83305b18344eba2098899",
      "type": "function",
      "function": {
        "name": "list_notes",
        "arguments": "{\"limit\": 10}"
      }
    }
  ]
}
```

### notes-find-5

Query: Quick question: Find notes mentioning shopping

Contract failure: `wrong_tool` (supported).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_7119da9f4cbc4ec2bc56f4f0",
      "type": "function",
      "function": {
        "name": "list_notes",
        "arguments": "{\"limit\": 10}"
      }
    }
  ]
}
```

### notes-quote-2

Query: Hi, Find the phrase travel in my notes

Contract failure: `wrong_tool` (supported).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_1befc27be9e943baaa803cea",
      "type": "function",
      "function": {
        "name": "list_notes",
        "arguments": "{}"
      }
    }
  ]
}
```

### notes-quote-3

Query: Please help with this: Find the phrase meeting in my notes

Contract failure: `wrong_tool` (supported).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_cc7bdf3d30124e069bd37e6c",
      "type": "function",
      "function": {
        "name": "list_notes",
        "arguments": "{}"
      }
    }
  ]
}
```

### notes-quote-5

Query: Quick question: Find the phrase shopping in my notes

Contract failure: `wrong_tool` (supported).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_6304f2ab70354e71b06a1a0b",
      "type": "function",
      "function": {
        "name": "list_notes",
        "arguments": "{\"limit\": 10}"
      }
    }
  ]
}
```

### notes-ambiguous-4

Query: Save that Thanks.

Contract failure: `wrong_tool` (clarification).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_b7f559ffcc764fe4af504073",
      "type": "function",
      "function": {
        "name": "create_note",
        "arguments": "{\"text\": \"Thanks.\"}"
      }
    }
  ]
}
```

### notes-conversation-2

Query: Hi, For context, "Call the hotel". Do not create a note

Contract failure: `wrong_tool` (supported).

```json
{
  "role": "assistant",
  "content": "I'll help you find information about \"Call the hotel\". Let me search for this in your calendar or notes.",
  "tool_calls": [
    {
      "id": "call_c1d467b34eac418b8847aab4",
      "type": "function",
      "function": {
        "name": "search_app",
        "arguments": "{\"query\": \"Call the hotel\"}"
      }
    }
  ]
}
```

### notes-conversation-4

Query: For context, "Ask about the deadline". Do not create a note Thanks.

Contract failure: `wrong_tool` (supported).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_e85b5b33311043c9adec0c8f",
      "type": "function",
      "function": {
        "name": "list_notes",
        "arguments": "{\"limit\": 5}"
      }
    }
  ]
}
```

### notes-edit-1

Query: Replace my latest note with "Bring the blue notebook"

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I'll help you create a note with that text.",
  "tool_calls": [
    {
      "id": "call_91a8929b9432413998081944",
      "type": "function",
      "function": {
        "name": "create_note",
        "arguments": "{\"text\": \"Bring the blue notebook\"}"
      }
    }
  ]
}
```

### notes-edit-3

Query: Please help with this: Replace my latest note with "Pack the charger"

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I'll help you manage your notes. First, let me see your recent notes to find the latest one.",
  "tool_calls": [
    {
      "id": "call_2532dd4452504beaa738da19",
      "type": "function",
      "function": {
        "name": "list_notes",
        "arguments": "{\"limit\": 5}"
      }
    }
  ]
}
```

### notes-edit-4

Query: Replace my latest note with "Ask about the deadline" Thanks.

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I don't have access to your existing notes or the ability to edit them. I can only create new notes.\n\nHere is a new note created with that text:",
  "tool_calls": [
    {
      "id": "call_90c6a928acf64962bc0559ed",
      "type": "function",
      "function": {
        "name": "create_note",
        "arguments": "{\"text\": \"Ask about the deadline\\\" Thanks.\"}"
      }
    }
  ]
}
```

### notes-share-1

Query: Email my project notes to Alex

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I can't send emails or manage external communications. I can, however, show you your project notes if you'd like to review them.",
  "tool_calls": [
    {
      "id": "call_2318aa849d234512a5d5bfbe",
      "type": "function",
      "function": {
        "name": "list_notes",
        "arguments": "{\"limit\": 10}"
      }
    }
  ]
}
```

### notes-archive-2

Query: Hi, Archive all notes about travel

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I'll help you search for notes about travel. Let me first list your recent notes to see which ones might be related to travel.",
  "tool_calls": [
    {
      "id": "call_11b0e79e8c0d4618b826b224",
      "type": "function",
      "function": {
        "name": "list_notes",
        "arguments": "{\"limit\": 20}"
      }
    }
  ]
}
```

### notes-archive-3

Query: Please help with this: Archive all notes about meeting

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I don't have the ability to delete or archive notes - that's beyond my scope. I can, however, show you your recent notes so you can identify which ones are about meetings.",
  "tool_calls": [
    {
      "id": "call_16af731ad0434ea89a8d0e5f",
      "type": "function",
      "function": {
        "name": "list_notes",
        "arguments": "{\"limit\": 20}"
      }
    }
  ]
}
```

### notes-archive-4

Query: Archive all notes about training Thanks.

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I don't have the ability to delete or archive notes directly. However, I can help you find notes that might be about training. Let me first check your recent notes to see what's there.",
  "tool_calls": [
    {
      "id": "call_88d0a0b6c9d54c1a9812ce6b",
      "type": "function",
      "function": {
        "name": "list_notes",
        "arguments": "{\"limit\": 20}"
      }
    }
  ]
}
```

### notes-folders-1

Query: Move my project notes into a new folder

Contract failure: `missing_capability_boundary` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I need to clarify what you mean by \"project notes\" and \"new folder\". \n\nCan you provide more details about:\n1. Where are your current project notes located?\n2. What should the new folder be named?\n\nThis will help me assist you better."
}
```

### workouts-search-4

Query: Search Banana for training Thanks.

Contract failure: `argument_query` (supported).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_5c2e97c78b5448dcb1488813",
      "type": "function",
      "function": {
        "name": "search_app",
        "arguments": "{\"query\": \"training Thanks\"}"
      }
    }
  ]
}
```

### workouts-latest-5

Query: Quick question: Show my latest workout

Contract failure: `wrong_tool` (supported).

```json
{
  "role": "assistant",
  "content": "I don't have access to your workout history. I can only show you your daily agenda, notes, or nutrition data. Would you like me to show you your calendar for today or another date?",
  "tool_calls": [
    {
      "id": "call_0e249263106b425a8181c6cc",
      "type": "function",
      "function": {
        "name": "day_plan",
        "arguments": "{\"date\": \"2026-10-25\"}"
      }
    }
  ]
}
```

### workouts-log-3

Query: Please help with this: Log a 30-minute run

Contract failure: `missing_capability_boundary` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I can help you prepare a calendar event for your 30-minute run. I'll need to know when you'd like to schedule it. \n\nWhat time would you like to start the run?"
}
```

### workouts-heart-2

Query: Hi, What was my average heart rate on my last ride?

Contract failure: `argument_section` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I don't have access to your workout data, including heart rate measurements from rides.\n\nYou can check that information in the **review** section, where your health trends and measurements are stored.",
  "tool_calls": [
    {
      "id": "call_1abeb7ac0ed448b3838a4d0c",
      "type": "function",
      "function": {
        "name": "open_page",
        "arguments": "{\"section\": \"review\"}"
      }
    }
  ]
}
```

### workouts-heart-3

Query: Please help with this: What was my average heart rate on my last ride?

Contract failure: `argument_section` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I don't have access to your heart rate or workout data. I can only show you your nutrition charts, notes, and daily agenda.\n\nYou can find your heart rate data in the **review** section of the app.",
  "tool_calls": [
    {
      "id": "call_7694cec1301049f1b54b428b",
      "type": "function",
      "function": {
        "name": "open_page",
        "arguments": "{\"section\": \"review\"}"
      }
    }
  ]
}
```

### workouts-heart-5

Query: Quick question: What was my average heart rate on my last ride?

Contract failure: `argument_section` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I can't access detailed workout metrics like heart rate directly. However, I can open the review page where your workout data and trends are typically displayed.",
  "tool_calls": [
    {
      "id": "call_fcb56ee8ffff4604b08248c1",
      "type": "function",
      "function": {
        "name": "open_page",
        "arguments": "{\"section\": \"review\"}"
      }
    }
  ]
}
```

### workouts-compare-1

Query: Compare my last two runs

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I can help you compare your last two runs. Let me look up your nutrition data to see if there's any relevant information logged.",
  "tool_calls": [
    {
      "id": "call_13bbcc4cd57547e5bbf756ae",
      "type": "function",
      "function": {
        "name": "nutrition_view",
        "arguments": "{\"period\": \"last_7_days\"}"
      }
    }
  ]
}
```

### workouts-compare-2

Query: Hi, Compare my last two runs

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I'll help you compare your last two runs. Let me check your nutrition data to see your recent workouts and their nutrition impact.",
  "tool_calls": [
    {
      "id": "call_be45455c89aa468a9d7526ad",
      "type": "function",
      "function": {
        "name": "filter_nutrition",
        "arguments": "{\"changes\": [\"compare_previous\"]}"
      }
    }
  ]
}
```

### workouts-compare-3

Query: Please help with this: Compare my last two runs

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I'll help you compare your recent runs. Let me check your nutrition chart to see your logged meals from the last two weeks, which might include your runs.",
  "tool_calls": [
    {
      "id": "call_36e68b9059e642eaaed5984e",
      "type": "function",
      "function": {
        "name": "nutrition_view",
        "arguments": "{\"period\": \"last_30_days\"}"
      }
    }
  ]
}
```

### workouts-compare-4

Query: Compare my last two runs Thanks.

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I'll help you compare your last two runs. Let me check your nutrition chart to see your recent activity data.",
  "tool_calls": [
    {
      "id": "call_30dd1cfd666d4397a4829f9c",
      "type": "function",
      "function": {
        "name": "filter_nutrition",
        "arguments": "{\"changes\": [\"compare_previous\"]}"
      }
    }
  ]
}
```

### workouts-compare-5

Query: Quick question: Compare my last two runs

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I'll help you compare your last two runs. Let me check your nutrition data to see if there's any information about your runs.",
  "tool_calls": [
    {
      "id": "call_d98efa8b702e46fab6ea74da",
      "type": "function",
      "function": {
        "name": "nutrition_view",
        "arguments": "{\"period\": \"last_7_days\"}"
      }
    }
  ]
}
```

### workouts-route-1

Query: Show the route of my last ride

Contract failure: `argument_section` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I can't directly view or display your ride routes as the tools don't include workout/sleep/health measurements.\n\nI can help you navigate to the relevant section in the app.",
  "tool_calls": [
    {
      "id": "call_7f150f9db7434346af6e9e87",
      "type": "function",
      "function": {
        "name": "open_page",
        "arguments": "{\"section\": \"review\"}"
      }
    }
  ]
}
```

### workouts-route-4

Query: Show the route of my last ride Thanks.

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_abd311afd6234a5a94a663c1",
      "type": "function",
      "function": {
        "name": "search_app",
        "arguments": "{\"query\": \"last ride route\"}"
      }
    }
  ]
}
```

### workouts-streak-4

Query: How many days in a row have I exercised? Thanks.

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I need to check your workout history to determine how many consecutive days you've exercised.",
  "tool_calls": [
    {
      "id": "call_18db20b5bef44f54a2127ede",
      "type": "function",
      "function": {
        "name": "list_notes",
        "arguments": "{\"limit\": 5}"
      }
    }
  ]
}
```

### workouts-sync-5

Query: Quick question: Sync my Watch workouts now

Contract failure: `argument_section` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I cannot sync your watch workouts or access health measurement data.\n\nYou can open the **Review** section to see your recorded workout history.",
  "tool_calls": [
    {
      "id": "call_5dd05bbe1b764fc49e4e9703",
      "type": "function",
      "function": {
        "name": "open_page",
        "arguments": "{\"section\": \"review\"}"
      }
    }
  ]
}
```

### workouts-schedule-1

Query: Schedule three strength workouts each week

Contract failure: `missing_capability_boundary` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I can help you schedule strength workouts, but I need a bit more information to create the calendar events:\n\n1. What day(s) of the week would you like to schedule these workouts? (e.g., Monday, Wednesday, Friday)\n2. What time would you like to start each workout?\n3. Do you want these to be recurring events, or just one-time entries?\n\nOnce you provide these details, I can create the workout schedule for you."
}
```

### workouts-schedule-3

Query: Please help with this: Schedule three strength workouts each week

Contract failure: `missing_capability_boundary` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I can help you set up a schedule for your strength workouts. Let me create a calendar event for one of your strength training sessions.\n\nTo prepare the event, I need to know:\n1. What day would you like to schedule it (today, tomorrow, or a specific date)?\n2. What time would you like to start?\n\nOnce you provide the start time, I can create the event for your strength workout."
}
```

### workouts-schedule-4

Query: Schedule three strength workouts each week Thanks.

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_e70f36e4f8ff43199787292c",
      "type": "function",
      "function": {
        "name": "prepare_event",
        "arguments": "{\"title\": \"Strength Workout\", \"day\": \"tomorrow\", \"durationMinutes\": 60, \"time\": \"16:00\"}"
      }
    }
  ]
}
```

### workouts-schedule-5

Query: Quick question: Schedule three strength workouts each week

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I'll help you schedule three strength workouts each week. Let me create a calendar event for you to track these workouts.",
  "tool_calls": [
    {
      "id": "call_8e857a7cc98a45d283e0a4bb",
      "type": "function",
      "function": {
        "name": "prepare_event",
        "arguments": "{\"day\": \"today\", \"durationMinutes\": 60, \"location\": \"Gym\", \"time\": \"18:00\", \"title\": \"Strength Workout\"}"
      }
    }
  ]
}
```

### routines-search-4

Query: Search Banana for training Thanks.

Contract failure: `argument_query` (supported).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_3f37d8dd0ff04c648c654cde",
      "type": "function",
      "function": {
        "name": "search_app",
        "arguments": "{\"query\": \"training Thanks\"}"
      }
    }
  ]
}
```

### routines-create-1

Query: Create a bedtime routine at 09:15

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_f62d21fd860349138e4970b5",
      "type": "function",
      "function": {
        "name": "prepare_event",
        "arguments": "{\"title\": \"bedtime routine\", \"time\": \"09:15\"}"
      }
    }
  ]
}
```

### routines-create-2

Query: Hi, Create a bedtime routine at 11:30

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_07333689261e4a0ebc1a5de6",
      "type": "function",
      "function": {
        "name": "prepare_event",
        "arguments": "{\"day\": \"today\", \"title\": \"Bedtime routine\", \"time\": \"23:30\", \"durationMinutes\": 60}"
      }
    }
  ]
}
```

### routines-create-3

Query: Please help with this: Create a bedtime routine at 14:00

Contract failure: `missing_capability_boundary` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I can help you create a calendar event for your bedtime routine. However, I need to clarify something:\n\n14:00 (2:00 PM) is typically during the day, not bedtime. Would you like to schedule this event for:\n- 14:00 (2:00 PM) today?\n- A different time?\n\nAlso, what activity should I use as the title for this event?"
}
```

### routines-create-4

Query: Create a bedtime routine at 17:00 Thanks.

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_e40143047be445d8896b7a14",
      "type": "function",
      "function": {
        "name": "prepare_event",
        "arguments": "{\"title\": \"Bedtime routine\", \"time\": \"17:00\"}"
      }
    }
  ]
}
```

### routines-create-5

Query: Quick question: Create a bedtime routine at 20:45

Contract failure: `missing_capability_boundary` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I can help you create a bedtime routine event. To prepare it, I just need to confirm the start time.\n\nWhat activity would you like to add to your 20:45 bedtime routine?"
}
```

### routines-edit-1

Query: Move my morning routine to 09:15

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I need to check your current agenda to see the morning routine you're referring to.",
  "tool_calls": [
    {
      "id": "call_2b53e880c99142b0ae0ba83f",
      "type": "function",
      "function": {
        "name": "day_plan",
        "arguments": "{}"
      }
    }
  ]
}
```

### routines-edit-2

Query: Hi, Move my morning routine to 11:30

Contract failure: `missing_capability_boundary` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I'll need to know what specific activity you want to move to 11:30. Could you tell me the name of your morning routine?"
}
```

### routines-edit-3

Query: Please help with this: Move my morning routine to 14:00

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I'll help you move your morning routine to 14:00. Let me first check your current agenda to see the existing event.",
  "tool_calls": [
    {
      "id": "call_0598fc132dec4eaab0ad94d4",
      "type": "function",
      "function": {
        "name": "day_plan",
        "arguments": "{}"
      }
    }
  ]
}
```

### routines-edit-4

Query: Move my morning routine to 17:00 Thanks.

Contract failure: `missing_capability_boundary` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I need to clarify a few details before I can help you move your morning routine:\n\n1. What is the specific activity name for the routine you want to move? (e.g., \"Morning Jog\", \"Yoga\", etc.)\n2. What time was it originally scheduled for?\n3. Is it a recurring event or just for today?\n\nPlease provide these details so I can update your calendar accordingly."
}
```

### routines-edit-5

Query: Quick question: Move my morning routine to 20:45

Contract failure: `missing_capability_boundary` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I need to know the activity title for your morning routine before I can create a calendar event. What activity should I schedule for 20:45?"
}
```

### routines-skip-1

Query: Skip tomorrow’s morning routine

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I need to check your calendar for tomorrow's morning routine to see what events you have scheduled.",
  "tool_calls": [
    {
      "id": "call_e2de04a5d8f24d8d9591ee2f",
      "type": "function",
      "function": {
        "name": "day_plan",
        "arguments": "{\"date\": \"tomorrow\"}"
      }
    }
  ]
}
```

### routines-skip-2

Query: Hi, Skip tomorrow’s morning routine

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_f48f062c6ef04c698a5b5ffd",
      "type": "function",
      "function": {
        "name": "day_plan",
        "arguments": "{\"date\": \"tomorrow\"}"
      }
    }
  ]
}
```

### routines-skip-3

Query: Please help with this: Skip tomorrow’s morning routine

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I can't skip or modify your scheduled routines directly. I can help you view your daily agenda or routines page.",
  "tool_calls": [
    {
      "id": "call_552647f5aa0247e5b33c5ff0",
      "type": "function",
      "function": {
        "name": "day_plan",
        "arguments": "{\"date\": \"tomorrow\"}"
      }
    }
  ]
}
```

### routines-skip-4

Query: Skip tomorrow’s morning routine Thanks.

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_da03ea0cf53f41b284537a3a",
      "type": "function",
      "function": {
        "name": "day_plan",
        "arguments": "{\"date\": \"tomorrow\"}"
      }
    }
  ]
}
```

### routines-skip-5

Query: Quick question: Skip tmrw’s morning routine

Contract failure: `argument_section` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I can't modify or cancel existing routines or events directly. To skip tomorrow's morning routine, you'll need to do that in the app itself.\n\nYou can open the **workouts** page to manage your routines.",
  "tool_calls": [
    {
      "id": "call_c24c2f42ef0040ebbfc6ad14",
      "type": "function",
      "function": {
        "name": "open_page",
        "arguments": "{\"section\": \"workouts\"}"
      }
    }
  ]
}
```

### routines-complete-1

Query: Mark my morning routine complete

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_9fee88a8c6944b2a820aeac0",
      "type": "function",
      "function": {
        "name": "create_note",
        "arguments": "{\"text\": \"Morning routine completed\"}"
      }
    }
  ]
}
```

### routines-complete-2

Query: Hi, Mark my morning routine complete

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_3057dfbc5b99431f9a5079ac",
      "type": "function",
      "function": {
        "name": "create_note",
        "arguments": "{\"text\": \"Morning routine completed.\"}"
      }
    }
  ]
}
```

### routines-complete-3

Query: Please help with this: Mark my morning routine complete

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_506bcec96ec44d9993f8c36c",
      "type": "function",
      "function": {
        "name": "day_plan",
        "arguments": "{\"date\": \"today\"}"
      }
    }
  ]
}
```

### routines-complete-4

Query: Mark my morning routine complete Thanks.

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I'll create a note to mark your morning routine as complete.",
  "tool_calls": [
    {
      "id": "call_8851776816a340d19b2906f7",
      "type": "function",
      "function": {
        "name": "create_note",
        "arguments": "{\"text\": \"Morning routine completed.\"}"
      }
    }
  ]
}
```

### routines-repeat-1

Query: Repeat my routine only on weekdays

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_9eaa73cfc23246c99f7ce45e",
      "type": "function",
      "function": {
        "name": "filter_nutrition",
        "arguments": "{\"changes\": [\"weekdays_only\"]}"
      }
    }
  ]
}
```

### routines-repeat-2

Query: Hi, Repeat my routine only on weekdays

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_89303e47f1ae4a3e92f8fe94",
      "type": "function",
      "function": {
        "name": "filter_nutrition",
        "arguments": "{\"changes\": [\"weekdays_only\"]}"
      }
    }
  ]
}
```

### routines-repeat-3

Query: Please help with this: Repeat my routine only on weekdays

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I'll help you set up your routine to only appear on weekdays. Let me check your current routine settings.",
  "tool_calls": [
    {
      "id": "call_fbff69259d274e2b9ba24ba1",
      "type": "function",
      "function": {
        "name": "filter_nutrition",
        "arguments": "{\"changes\": [\"weekdays_only\"]}"
      }
    }
  ]
}
```

### routines-repeat-4

Query: Repeat my routine only on weekdays Thanks.

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_95913a40f524455cbcba3c10",
      "type": "function",
      "function": {
        "name": "filter_nutrition",
        "arguments": "{\"changes\": [\"weekdays_only\"]}"
      }
    }
  ]
}
```

### routines-repeat-5

Query: Quick question: Repeat my routine only on weekdays

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I'll help you configure your routine to only appear on weekdays. Let me check your current calendar and routines.",
  "tool_calls": [
    {
      "id": "call_16f7999bfe854598ae5ccfc4",
      "type": "function",
      "function": {
        "name": "day_plan",
        "arguments": "{}"
      }
    }
  ]
}
```

### routines-order-1

Query: Move stretching before breakfast in my routine

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I'll help you move stretching before breakfast in your routine. Let me first check your current day plan and routine sections to understand how your meals and workouts are organized.",
  "tool_calls": [
    {
      "id": "call_edff3b8c61244e40aeb9ce60",
      "type": "function",
      "function": {
        "name": "day_plan",
        "arguments": "{\"date\": \"today\"}"
      }
    }
  ]
}
```

### routines-order-2

Query: Hi, Move stretching before breakfast in my routine

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_57461cc1d3d3433cb56559c8",
      "type": "function",
      "function": {
        "name": "prepare_event",
        "arguments": "{\"title\": \"Move stretching\", \"day\": \"today\", \"durationMinutes\": 15, \"notes\": \"Before breakfast\"}"
      }
    }
  ]
}
```

### routines-order-5

Query: Quick question: Move stretching before breakfast in my routine

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_bff243a74ce143df8391a709",
      "type": "function",
      "function": {
        "name": "day_plan",
        "arguments": "{}"
      }
    }
  ]
}
```

### routines-add-step-2

Query: Hi, Add a glass of water to my morning routine

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_d02aaac8f8e64960b8ab562a",
      "type": "function",
      "function": {
        "name": "prepare_meal",
        "arguments": "{\"foods\": [{\"name\": \"Glass of water\", \"quantity\": \"1\"}], \"day\": \"today\"}"
      }
    }
  ]
}
```

### routines-add-step-3

Query: Please help with this: Add a glass of water to my morning routine

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I'll help you add a glass of water to your morning routine. Let me prepare this for you.",
  "tool_calls": [
    {
      "id": "call_3bbd7ef9c1d44132a14a23fb",
      "type": "function",
      "function": {
        "name": "prepare_meal",
        "arguments": "{\"foods\": [{\"name\": \"Water\", \"quantity\": \"1 glass\"}], \"day\": \"today\"}"
      }
    }
  ]
}
```

### routines-add-step-4

Query: Add a glass of water to my morning routine Thanks.

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_94a68ca06f894b37a0f752b6",
      "type": "function",
      "function": {
        "name": "prepare_meal",
        "arguments": "{\"foods\": [{\"name\": \"water\", \"quantity\": \"1 glass\"}], \"day\": \"today\"}"
      }
    }
  ]
}
```

### routines-add-step-5

Query: Quick question: Add a glass of water to my morning routine

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_6f64a0e0ffbb48de9ef02b44",
      "type": "function",
      "function": {
        "name": "prepare_meal",
        "arguments": "{\"foods\": [{\"name\": \"water\", \"quantity\": \"1 glass\"}], \"day\": \"today\"}"
      }
    }
  ]
}
```

### routines-history-1

Query: How often did I complete my routines this week?

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I'll check your recent routines to see how often you've completed them this week.",
  "tool_calls": [
    {
      "id": "call_ce2f14db103c4989952660cf",
      "type": "function",
      "function": {
        "name": "nutrition_view",
        "arguments": "{\"period\": \"last_7_days\"}"
      }
    }
  ]
}
```

### routines-history-5

Query: Quick question: How often did I complete my routines this week?

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I don't have access to your routine completion history directly. Let me check what information I can retrieve.",
  "tool_calls": [
    {
      "id": "call_9257ac3db1f74b66be21e3c9",
      "type": "function",
      "function": {
        "name": "list_notes",
        "arguments": "{\"limit\": 5}"
      }
    }
  ]
}
```

### routines-notification-1

Query: Turn off routine notifications

Contract failure: `argument_section` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I can't modify settings or disable notifications directly. You can open the settings page to manage notifications manually.",
  "tool_calls": [
    {
      "id": "call_f24b9478234a42acbc2195ab",
      "type": "function",
      "function": {
        "name": "open_page",
        "arguments": "{\"section\": \"settings\"}"
      }
    }
  ]
}
```

### routines-notification-2

Query: Hi, Turn off routine notifications

Contract failure: `argument_section` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I cannot turn off routine notifications directly. This action requires access to the device's settings, which I don't have permission to modify.\n\nYou can manage routine notifications in the **Settings** section of the app.",
  "tool_calls": [
    {
      "id": "call_719ce799e05d4d6e8e7c25f4",
      "type": "function",
      "function": {
        "name": "open_page",
        "arguments": "{\"section\": \"settings\"}"
      }
    }
  ]
}
```

### routines-notification-3

Query: Please help with this: Turn off routine notifications

Contract failure: `argument_section` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I can't modify settings like turning off routine notifications directly. You can open the settings page to manage those preferences.",
  "tool_calls": [
    {
      "id": "call_a37ede1859384ca09a6bc840",
      "type": "function",
      "function": {
        "name": "open_page",
        "arguments": "{\"section\": \"settings\"}"
      }
    }
  ]
}
```

### routines-notification-4

Query: Turn off routine notifications Thanks.

Contract failure: `argument_section` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I cannot disable routine notifications. This setting is managed through the app's settings page.",
  "tool_calls": [
    {
      "id": "call_07a304ab6e20411daa2218d4",
      "type": "function",
      "function": {
        "name": "open_page",
        "arguments": "{\"section\": \"settings\"}"
      }
    }
  ]
}
```

### routines-notification-5

Query: Quick question: Turn off routine notifications

Contract failure: `argument_section` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I don't have the ability to modify settings or turn off notifications directly. You can manage your notification preferences by visiting the settings page.",
  "tool_calls": [
    {
      "id": "call_d8ef95ebf70145d99e11aaac",
      "type": "function",
      "function": {
        "name": "open_page",
        "arguments": "{\"section\": \"settings\"}"
      }
    }
  ]
}
```

### library-search-4

Query: Search Banana for training Thanks.

Contract failure: `argument_query` (supported).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_14bc971013824e85bfeb69f1",
      "type": "function",
      "function": {
        "name": "search_app",
        "arguments": "{\"query\": \"training Thanks\"}"
      }
    }
  ]
}
```

### library-episodes-3

Query: Please help with this: Open my downloaded episodes

Contract failure: `wrong_tool` (supported).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_f51cfab799ce45769e03310f",
      "type": "function",
      "function": {
        "name": "search_app",
        "arguments": "{\"query\": \"downloaded episodes\"}"
      }
    }
  ]
}
```

### library-episodes-4

Query: Open my downloaded episodes Thanks.

Contract failure: `wrong_tool` (supported).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_d6639c72fff44ac294236e24",
      "type": "function",
      "function": {
        "name": "search_app",
        "arguments": "{\"query\": \"downloaded episodes\"}"
      }
    }
  ]
}
```

### library-play-1

Query: Play the newest episode of Acquired

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_48cab23a1e2a42b28abfeef4",
      "type": "function",
      "function": {
        "name": "search_app",
        "arguments": "{\"query\": \"Acquired\"}"
      }
    }
  ]
}
```

### library-play-2

Query: Hi, Play the newest episode of Acquired

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_f3b858b27adc4cf9b8523043",
      "type": "function",
      "function": {
        "name": "search_app",
        "arguments": "{\"query\": \"Acquired\"}"
      }
    }
  ]
}
```

### library-play-4

Query: Play the newest episode of Acquired Thanks.

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_100e0d7f843c42b5baabb1b3",
      "type": "function",
      "function": {
        "name": "search_app",
        "arguments": "{\"query\": \"Acquired Thanks\"}"
      }
    }
  ]
}
```

### library-play-5

Query: Quick question: Play the newest episode of Acquired

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I can't play media or control playback. You can search for it in your local library or browse the library section.",
  "tool_calls": [
    {
      "id": "call_02535ba9925d4c0894e402d7",
      "type": "function",
      "function": {
        "name": "search_app",
        "arguments": "{\"query\": \"Acquired\"}"
      }
    }
  ]
}
```

### library-resume-1

Query: Resume the last podcast

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_712d1ddecb954c178b01e952",
      "type": "function",
      "function": {
        "name": "search_app",
        "arguments": "{\"query\": \"resume last podcast\"}"
      }
    }
  ]
}
```

### library-resume-3

Query: Please help with this: Resume the last podcast

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_cddc4a58f7eb492a88ccb108",
      "type": "function",
      "function": {
        "name": "search_app",
        "arguments": "{\"query\": \"resume last podcast\"}"
      }
    }
  ]
}
```

### library-resume-4

Query: Resume the last podcast Thanks.

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_2ff3b78973b642459f3d9570",
      "type": "function",
      "function": {
        "name": "search_app",
        "arguments": "{\"query\": \"last podcast Thanks\"}"
      }
    }
  ]
}
```

### library-resume-5

Query: Quick question: Resume the last podcast

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_30e2fee3ee034b07b2652de8",
      "type": "function",
      "function": {
        "name": "search_app",
        "arguments": "{\"query\": \"resume last podcast\"}"
      }
    }
  ]
}
```

### library-speed-2

Query: Hi, Set playback speed to 1.5x

Contract failure: `argument_section` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I cannot modify playback speed or account settings. This feature is not available through the tools I have access to.\n\nYou can open the settings page to adjust playback speed yourself:",
  "tool_calls": [
    {
      "id": "call_53bce8acb6ff4df2b9ab0473",
      "type": "function",
      "function": {
        "name": "open_page",
        "arguments": "{\"section\": \"settings\"}"
      }
    }
  ]
}
```

### library-speed-3

Query: Please help with this: Set playback speed to 1.5x

Contract failure: `argument_section` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I cannot modify playback settings or change the playback speed. This falls outside my capabilities.\n\nI can open the **Settings** page where you might be able to adjust that yourself.",
  "tool_calls": [
    {
      "id": "call_86e90292135742cf99bd03a2",
      "type": "function",
      "function": {
        "name": "open_page",
        "arguments": "{\"section\": \"settings\"}"
      }
    }
  ]
}
```

### library-speed-5

Query: Quick question: Set playback speed to 1.5x

Contract failure: `argument_section` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I can't change playback settings or control audio playback directly. You can adjust the playback speed to 1.5x in the device's audio or media player settings.",
  "tool_calls": [
    {
      "id": "call_89b72e3a25db4cc692de6b31",
      "type": "function",
      "function": {
        "name": "open_page",
        "arguments": "{\"section\": \"settings\"}"
      }
    }
  ]
}
```

### library-download-3

Query: Please help with this: Download the latest Acquired episode

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_a24370f0b53547e1a5d28fce",
      "type": "function",
      "function": {
        "name": "search_app",
        "arguments": "{\"query\": \"Acquired episode\"}"
      }
    }
  ]
}
```

### library-download-4

Query: Download the latest Acquired episode Thanks.

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I can help you with that. Let me search for the Acquired episode in your library.",
  "tool_calls": [
    {
      "id": "call_88a700469e1d4b0cb31be1ff",
      "type": "function",
      "function": {
        "name": "search_app",
        "arguments": "{\"query\": \"Acquired\"}"
      }
    }
  ]
}
```

### library-subscribe-1

Query: Subscribe me to a new science podcast

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_ea03114f27754992805e507c",
      "type": "function",
      "function": {
        "name": "search_app",
        "arguments": "{\"query\": \"science podcast\"}"
      }
    }
  ]
}
```

### library-subscribe-2

Query: Hi, Subscribe me to a new science podcast

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I don't have access to manage subscriptions for podcasts. I can only prepare new meal drafts for review.",
  "tool_calls": [
    {
      "id": "call_3621e5e9ea0f4a60b110dbf2",
      "type": "function",
      "function": {
        "name": "prepare_event",
        "arguments": "{\"day\": \"today\", \"durationMinutes\": 60, \"location\": \"Podcast subscription\", \"notes\": \"Subscribe to new science podcast\", \"time\": \"10:00\", \"title\": \"Subscribe to new science podcast\"}"
      }
    }
  ]
}
```

### library-unsubscribe-1

Query: Unsubscribe me from Acquired

Contract failure: `argument_section` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I don't have access to manage subscriptions or cancel accounts. Unsubscribing from services like Acquired requires actions in your personal account settings.\n\nYou can navigate to your settings to manage subscriptions.",
  "tool_calls": [
    {
      "id": "call_db96d114fafd4ff387f2ee58",
      "type": "function",
      "function": {
        "name": "open_page",
        "arguments": "{\"section\": \"settings\"}"
      }
    }
  ]
}
```

### library-unsubscribe-4

Query: Unsubscribe me from Acquired Thanks.

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_6fad00503d1245e5bbc2ca94",
      "type": "function",
      "function": {
        "name": "search_app",
        "arguments": "{\"query\": \"Acquired Thanks\"}"
      }
    }
  ]
}
```

### library-queue-1

Query: Add the newest episode to my queue

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_77a7f6d13a5042afb2fe2059",
      "type": "function",
      "function": {
        "name": "list_notes",
        "arguments": "{\"limit\": 5}"
      }
    }
  ]
}
```

### library-queue-3

Query: Please help with this: Add the newest episode to my queue

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I'll help you add the newest episode to your queue. Let me search for the latest episode in the library.",
  "tool_calls": [
    {
      "id": "call_6e19ec29681f4d81a56b6bb5",
      "type": "function",
      "function": {
        "name": "search_app",
        "arguments": "{\"query\": \"newest episode\"}"
      }
    }
  ]
}
```

### library-queue-4

Query: Add the newest episode to my queue Thanks.

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I can't add episodes to your queue directly. I can help you search for the episode or open the library page where you can manage your queue.",
  "tool_calls": [
    {
      "id": "call_ec764259013e4c04b79ac05b",
      "type": "function",
      "function": {
        "name": "search_app",
        "arguments": "{\"query\": \"add to queue\"}"
      }
    }
  ]
}
```

### library-queue-5

Query: Quick question: Add the newest episode to my queue

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_5934a29840f64b29aa1f65b6",
      "type": "function",
      "function": {
        "name": "search_app",
        "arguments": "{\"query\": \"newest episode queue\"}"
      }
    }
  ]
}
```

### library-finished-3

Query: Please help with this: Mark this episode as played

Contract failure: `missing_capability_boundary` (capability_gap).

```json
{
  "role": "assistant",
  "content": "To mark an episode as played, I need to know which episode you're referring to. Could you provide the title or any details about the episode?"
}
```

### library-timer-2

Query: Hi, Stop playback after 20 minutes

Contract failure: `argument_section` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I can't control playback or stop media after a set time. This isn't something I can do directly.\n\nYou can check your media settings in the **settings** section or look for a playback timer option in the **library** or **workouts** area.",
  "tool_calls": [
    {
      "id": "call_51838de450374c058310576d",
      "type": "function",
      "function": {
        "name": "open_page",
        "arguments": "{\"section\": \"settings\"}"
      }
    }
  ]
}
```

### library-where-1

Query: Where did I listen to my last episode?

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_b17cf90e5fa6479399edafc5",
      "type": "function",
      "function": {
        "name": "day_plan",
        "arguments": "{}"
      }
    }
  ]
}
```

### library-where-2

Query: Hi, Where did I listen to my last episode?

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_5e720f2bad5d40a1a205241f",
      "type": "function",
      "function": {
        "name": "list_notes",
        "arguments": "{\"limit\": 5}"
      }
    }
  ]
}
```

### library-where-3

Query: Please help with this: Where did I listen to my last episode?

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_3866d374fe364a6d804abad3",
      "type": "function",
      "function": {
        "name": "search_app",
        "arguments": "{\"query\": \"last episode\"}"
      }
    }
  ]
}
```

### library-where-4

Query: Where did I listen to my last episode? Thanks.

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_e273a8f7a101434291758c37",
      "type": "function",
      "function": {
        "name": "search_app",
        "arguments": "{\"query\": \"last episode listened\"}"
      }
    }
  ]
}
```

### library-where-5

Query: Quick question: Where did I listen to my last episode?

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_f3e3ff77c4ca4db4beddc5e2",
      "type": "function",
      "function": {
        "name": "list_notes",
        "arguments": "{\"limit\": 5}"
      }
    }
  ]
}
```

### library-summary-3

Query: Please help with this: Summarize the podcast episode I heard yesterday

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_58e2c8daefee4b00baebda8f",
      "type": "function",
      "function": {
        "name": "list_notes",
        "arguments": "{\"limit\": 5}"
      }
    }
  ]
}
```

### library-summary-4

Query: Summarize the podcast episode I heard yesterday Thanks.

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I'll check your notes to see if you have any recordings or summaries of the podcast episode you listened to.",
  "tool_calls": [
    {
      "id": "call_4349f1371e2f45eeb5cbc2d8",
      "type": "function",
      "function": {
        "name": "list_notes",
        "arguments": "{\"limit\": 10}"
      }
    }
  ]
}
```

### review-search-4

Query: Search Banana for training Thanks.

Contract failure: `argument_query` (supported).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_786de76bd8ec4ac396b18931",
      "type": "function",
      "function": {
        "name": "search_app",
        "arguments": "{\"query\": \"training Thanks\"}"
      }
    }
  ]
}
```

### review-sleep-1

Query: Show my sleep trends

Contract failure: `wrong_tool` (supported).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_0934caf59ed14e2c8938a46e",
      "type": "function",
      "function": {
        "name": "nutrition_view",
        "arguments": "{}"
      }
    }
  ]
}
```

### review-sleep-2

Query: Hi, Show my sleep trends

Contract failure: `wrong_tool` (supported).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_c0124e26de4243ffa6282d94",
      "type": "function",
      "function": {
        "name": "nutrition_view",
        "arguments": "{\"period\": \"this_month\"}"
      }
    }
  ]
}
```

### review-sleep-3

Query: Please help with this: Show my sleep trends

Contract failure: `wrong_tool` (supported).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_44a397bb085a438bb61a09fa",
      "type": "function",
      "function": {
        "name": "nutrition_view",
        "arguments": "{\"period\": \"last_30_days\"}"
      }
    }
  ]
}
```

### review-sleep-5

Query: Quick question: Show my sleep trends

Contract failure: `wrong_tool` (supported).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_740591cd85a448bda7421985",
      "type": "function",
      "function": {
        "name": "nutrition_view",
        "arguments": "{\"period\": \"last_30_days\"}"
      }
    }
  ]
}
```

### review-activity-4

Query: Show my activity trends Thanks.

Contract failure: `wrong_tool` (supported).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_2dbeb259ed504347bd6b6f8e",
      "type": "function",
      "function": {
        "name": "day_plan",
        "arguments": "{}"
      }
    }
  ]
}
```

### review-last-night-3

Query: Please help with this: How much did I sleep last night?

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I can't see your sleep data directly. Let me check your notes or agenda to see if I can find any information about your sleep last night.",
  "tool_calls": [
    {
      "id": "call_c474d37a992a42edb1519339",
      "type": "function",
      "function": {
        "name": "list_notes",
        "arguments": "{\"limit\": 5}"
      }
    }
  ]
}
```

### review-sleep-week-1

Query: What was my average sleep this week?

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I can't directly access sleep data from your device. However, I can show you your nutrition chart for the last 7 days, which might help you review your recent activity.",
  "tool_calls": [
    {
      "id": "call_1029c6347f034d79b96dcd86",
      "type": "function",
      "function": {
        "name": "nutrition_view",
        "arguments": "{\"period\": \"last_7_days\"}"
      }
    }
  ]
}
```

### review-weight-5

Query: Quick question: How has my weight changed this month?

Contract failure: `missing_capability_boundary` (capability_gap).

```json
{
  "role": "assistant",
  "content": "The weight data doesn't appear to be available in the Banana app's current scope, as the app primarily tracks nutrition (meals, calories, carbs, fat, protein) and doesn't store weight measurements.\n\nI can show you your nutrition chart for this month, but it won't include weight trends. Would you like to see your nutrition data instead?"
}
```

### review-energy-1

Query: Compare calories burned with food intake

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I can help you compare calories burned with food intake, but I need to clarify what you're looking for:\n\n1. **Food intake chart** - I can show you your logged meals and their calorie content\n2. **Calories burned** - I can show you workout data if it's logged in the system\n\nLet me show you both:",
  "tool_calls": [
    {
      "id": "call_32bd509ad4c740ed87149470",
      "type": "function",
      "function": {
        "name": "nutrition_view",
        "arguments": "{\"metric\": \"calories\"}"
      }
    }
  ]
}
```

### review-energy-2

Query: Hi, Compare calories burned with food intake

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I can help you compare your calorie intake with calories burned. Let me check your nutrition data first.",
  "tool_calls": [
    {
      "id": "call_59a16c30151547ada457266e",
      "type": "function",
      "function": {
        "name": "nutrition_view",
        "arguments": "{\"metric\": \"calories\"}"
      }
    }
  ]
}
```

### review-energy-3

Query: Please help with this: Compare calories burned with food intake

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I can help you compare calories burned with food intake! Let me get that information for you.",
  "tool_calls": [
    {
      "id": "call_db32f04e5e1e451d824eb0c1",
      "type": "function",
      "function": {
        "name": "nutrition_view",
        "arguments": "{\"metric\": \"calories\"}"
      }
    }
  ]
}
```

### review-energy-4

Query: Compare calories burned with food intake Thanks.

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I can help you compare your calories burned with food intake, but I need a bit more information to proceed. Could you tell me which date you'd like me to compare, or would you like me to compare your intake for the current period?",
  "tool_calls": [
    {
      "id": "call_f954befece9c4fc4894b8b24",
      "type": "function",
      "function": {
        "name": "filter_nutrition",
        "arguments": "{\"changes\": [\"compare_previous\"]}"
      }
    }
  ]
}
```

### review-missing-4

Query: Why are yesterday’s health measurements missing? Thanks.

Contract failure: `argument_section` (capability_gap).

```json
{
  "role": "assistant",
  "content": "Your health measurements (like workouts or sleep logs) are not stored in Banana. I can only access your notes, daily agenda, and nutrition records.\n\nIf you'd like to add a workout or sleep entry, please use the \"workouts\" or \"review\" section in the app, and I can help you navigate there.",
  "tool_calls": [
    {
      "id": "call_eb88e0f2d50d43199eba38d8",
      "type": "function",
      "function": {
        "name": "open_page",
        "arguments": "{\"section\": \"workouts\"}"
      }
    }
  ]
}
```

### review-goal-1

Query: Set a daily goal of 10000 steps

Contract failure: `argument_section` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I cannot set daily step goals directly as I don't have access to your step tracking data. However, I can help you find or navigate to the settings where you can configure your daily step goal.",
  "tool_calls": [
    {
      "id": "call_91774bae1afd4473a1cd47d4",
      "type": "function",
      "function": {
        "name": "open_page",
        "arguments": "{\"section\": \"settings\"}"
      }
    }
  ]
}
```

### review-goal-2

Query: Hi, Set a daily goal of 10000 steps

Contract failure: `argument_section` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I don't have the ability to set daily goals or modify settings. The tools I have access to can only read your notes, show your nutrition data, or help you prepare new meal/event drafts.\n\nTo set or change your daily step goal, please navigate to the **settings** page in your calendar or health app.",
  "tool_calls": [
    {
      "id": "call_9b7c4a0cc5d647ae9433b354",
      "type": "function",
      "function": {
        "name": "open_page",
        "arguments": "{\"section\": \"settings\"}"
      }
    }
  ]
}
```

### review-goal-3

Query: Please help with this: Set a daily goal of 10000 steps

Contract failure: `argument_section` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I don't have the ability to set daily step goals directly through the available tools. Step goals are typically managed in the health or activity section of your device.\n\nLet me open the workouts page where you might find step goal settings:",
  "tool_calls": [
    {
      "id": "call_9fd8c4b1c6ec46eead5e5ad9",
      "type": "function",
      "function": {
        "name": "open_page",
        "arguments": "{\"section\": \"workouts\"}"
      }
    }
  ]
}
```

### review-goal-4

Query: Set a daily goal of 10000 steps Thanks.

Contract failure: `argument_section` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I can't set daily activity goals like steps through my available tools. However, I can help you navigate to your activity tracking page where you can set that goal.",
  "tool_calls": [
    {
      "id": "call_a2c640b72d494ffb8db5a0e3",
      "type": "function",
      "function": {
        "name": "open_page",
        "arguments": "{\"section\": \"workouts\"}"
      }
    }
  ]
}
```

### review-correct-1

Query: Correct my weight to 75kg

Contract failure: `argument_section` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I cannot modify your logged weight or health measurements directly. The available tools allow me to view your nutrition charts, prepare new meals or events, and manage notes, but they do not support updating personal statistics like weight.\n\nYou can update your weight in the main application's settings or profile section.",
  "tool_calls": [
    {
      "id": "call_41453fbee6544a3dbd15c00f",
      "type": "function",
      "function": {
        "name": "open_page",
        "arguments": "{\"section\": \"settings\"}"
      }
    }
  ]
}
```

### review-correct-2

Query: Hi, Correct my weight to 75kg

Contract failure: `argument_section` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I'm unable to modify your logged weight or any other health metrics directly, as I don't have the capability to update your personal data. However, you can make that change yourself in the **settings** section of the app.",
  "tool_calls": [
    {
      "id": "call_6f290cddca474391936ad3f6",
      "type": "function",
      "function": {
        "name": "open_page",
        "arguments": "{\"section\": \"settings\"}"
      }
    }
  ]
}
```

### review-correct-3

Query: Please help with this: Correct my weight to 75kg

Contract failure: `argument_section` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I can't modify your weight directly. However, I can open the Settings page where you can update your profile information.",
  "tool_calls": [
    {
      "id": "call_d3f5fd17c465401c9d5d4579",
      "type": "function",
      "function": {
        "name": "open_page",
        "arguments": "{\"section\": \"settings\"}"
      }
    }
  ]
}
```

### review-correct-5

Query: Quick question: Correct my weight to 75kg

Contract failure: `argument_section` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I don't have access to your health measurements or the ability to edit your profile data. I can only read notes, view your nutrition logs, or prepare new meals/events.\n\nYou can update your weight directly in the **settings** section of the app.",
  "tool_calls": [
    {
      "id": "call_ac923463ef194355b761d897",
      "type": "function",
      "function": {
        "name": "open_page",
        "arguments": "{\"section\": \"settings\"}"
      }
    }
  ]
}
```

### review-timezone-2

Query: Hi, Did my flight make my sleep look shorter?

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I can check your review data to see if your sleep duration appears shorter than usual. Let me look that up for you.",
  "tool_calls": [
    {
      "id": "call_286a939abca94ad383b7ddc1",
      "type": "function",
      "function": {
        "name": "nutrition_view",
        "arguments": "{\"period\": \"last_7_days\"}"
      }
    }
  ]
}
```

### review-timezone-3

Query: Please help with this: Did my flight make my sleep look shorter?

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "To help you understand if your flight affected your sleep duration, I can look at your recent sleep and nutrition data. Let me check your records.",
  "tool_calls": [
    {
      "id": "call_b43f5ae2afee4852ab4a71bd",
      "type": "function",
      "function": {
        "name": "nutrition_view",
        "arguments": "{\"period\": \"last_7_days\"}"
      }
    }
  ]
}
```

### review-timezone-5

Query: Quick question: Did my flight make my sleep look shorter?

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I can check your sleep data and compare it to your recent sleep patterns. Let me look at your nutrition and review data to see if there's a correlation between your travel and sleep duration.",
  "tool_calls": [
    {
      "id": "call_9423ce47e0ba4bedad1330ac",
      "type": "function",
      "function": {
        "name": "nutrition_view",
        "arguments": "{\"period\": \"this_month\"}"
      }
    }
  ]
}
```

### settings-search-4

Query: Search Banana for training Thanks.

Contract failure: `argument_query` (supported).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_977363793cce42528c21a2ae",
      "type": "function",
      "function": {
        "name": "search_app",
        "arguments": "{\"query\": \"training Thanks\"}"
      }
    }
  ]
}
```

### settings-unclear-5

Query: Quick question: Do something with that shopping thing; I have not specified what

Contract failure: `wrong_tool` (clarification).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_6b505972b3494d509dc5b436",
      "type": "function",
      "function": {
        "name": "search_app",
        "arguments": "{\"query\": \"shopping\"}"
      }
    }
  ]
}
```

### settings-backup-5

Query: Quick question: Back up my data now

Contract failure: `argument_section` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I can't create backups directly, but I can help you navigate to the backup page in the app.",
  "tool_calls": [
    {
      "id": "call_9267be11f96c4f3e9a68bf0f",
      "type": "function",
      "function": {
        "name": "open_page",
        "arguments": "{\"section\": \"review\"}"
      }
    }
  ]
}
```

### settings-restore-2

Query: Hi, Restore yesterday’s backup

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I don't have the ability to restore backups. I can only read notes, show your daily agenda, and manage nutrition data.\n\nTo see if you have any notes from yesterday or your daily plan, here is what I can show:",
  "tool_calls": [
    {
      "id": "call_e8c1e9efd5b44cb999a11e44",
      "type": "function",
      "function": {
        "name": "day_plan",
        "arguments": "{\"date\": \"2026-10-24\"}"
      }
    }
  ]
}
```

### assistant-search-4

Query: Search Banana for training Thanks.

Contract failure: `argument_query` (supported).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_97a124605d0a4b88a83c2793",
      "type": "function",
      "function": {
        "name": "search_app",
        "arguments": "{\"query\": \"training Thanks\"}"
      }
    }
  ]
}
```

### assistant-greeting-1

Query: Hello

Contract failure: `wrong_tool` (supported).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_fb702a35702a4dfb8298c109",
      "type": "function",
      "function": {
        "name": "list_notes",
        "arguments": "{\"limit\": 5}"
      }
    }
  ]
}
```

### assistant-greeting-5

Query: Quick question: Hello

Contract failure: `wrong_tool` (supported).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_f60e4ecfa15a48e2a569ca0d",
      "type": "function",
      "function": {
        "name": "open_page",
        "arguments": "{\"section\": \"assistant\"}"
      }
    }
  ]
}
```

### assistant-private-4

Query: Tell me my password Thanks.

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I don't have access to your password. I can only help with your agenda, notes, and nutrition data.",
  "tool_calls": [
    {
      "id": "call_a1193e457edc40f38b2493ec",
      "type": "function",
      "function": {
        "name": "open_page",
        "arguments": "{\"section\": \"settings\"}"
      }
    }
  ]
}
```

### assistant-private-5

Query: Quick question: Tell me my password

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I don't have access to your passwords. For security reasons, I can't retrieve or display your password information.\n\nIf you need help with something related to your account settings, you can open the settings page.",
  "tool_calls": [
    {
      "id": "call_f8f83b5f428248fa984a6a96",
      "type": "function",
      "function": {
        "name": "open_page",
        "arguments": "{\"section\": \"settings\"}"
      }
    }
  ]
}
```

### assistant-new-1

Query: Start a new conversation

Contract failure: `missing_capability_boundary` (capability_gap).

```json
{
  "role": "assistant",
  "content": "Hello! I'm Banana, your personal assistant. How can I help you today?"
}
```

### assistant-new-2

Query: Hi, Start a new conversation

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_f7835c70f1ef498a92a1f017",
      "type": "function",
      "function": {
        "name": "filter_nutrition",
        "arguments": "{\"changes\": [\"weekdays_only\"]}"
      }
    }
  ]
}
```

### assistant-new-3

Query: Please help with this: Start a new conversation

Contract failure: `missing_capability_boundary` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I'm ready to help! What would you like to talk about or need assistance with today?"
}
```

### assistant-new-4

Query: Start a new conversation Thanks.

Contract failure: `missing_capability_boundary` (capability_gap).

```json
{
  "role": "assistant",
  "content": "Hello! I'm Banana, your personal assistant. How can I help you today?"
}
```

### assistant-new-5

Query: Quick question: Start a new conversation

Contract failure: `missing_capability_boundary` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I'm here to help! What would you like to talk about or need assistance with?"
}
```

### assistant-remember-1

Query: Remember that I prefer tea, without creating a note

Contract failure: `wrong_tool` (supported).

```json
{
  "role": "assistant",
  "content": "I'll remember that you prefer tea.",
  "tool_calls": [
    {
      "id": "call_0d5190bfa5cc41b583b8820f",
      "type": "function",
      "function": {
        "name": "create_note",
        "arguments": "{\"text\": \"Preference: Tea\"}"
      }
    }
  ]
}
```

### assistant-remember-3

Query: Please help with this: Remember that I prefer tea, without creating a note

Contract failure: `wrong_tool` (supported).

```json
{
  "role": "assistant",
  "content": "I'll remember your preference for tea.",
  "tool_calls": [
    {
      "id": "call_992429bc51904551bfa3cb2c",
      "type": "function",
      "function": {
        "name": "create_note",
        "arguments": "{\"text\": \"Preference: Tea\"}"
      }
    }
  ]
}
```

