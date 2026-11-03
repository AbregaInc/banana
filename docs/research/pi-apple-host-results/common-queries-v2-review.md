# Common-query evaluation

900 synthetic development routing/argument contracts, 100 per module. 20 intent families × 5 variants; not empirical top-query rankings, not held-out accuracy, and not end-to-end action tests. Text-only responses require semantic review. Capability gaps are labeled explicitly.

This run evaluated 185 queries. Documented oracle corrections are applied without changing the raw responses; see the JSON report.

Automatic checks verify routing, arguments, schema, missing-input behavior, and some false completion claims. Text replies below still require semantic review. A navigation fallback does not implement the requested capability. No app tools execute in this benchmark; native/full-app tests are separate.

| Module | Tested | Tool contracts passed | Honest navigation fallback | Text to review | Contract failures | Capability-gap cases |
|---|---:|---:|---:|---:|---:|---:|
| plan | 100 | 44 | 0 | 20 | 36 | 45 |
| nutrition | 20 | 9 | 0 | 5 | 6 | 0 |
| notes | 15 | 15 | 0 | 0 | 0 | 0 |
| workouts | 15 | 5 | 1 | 4 | 5 | 10 |
| routines | 15 | 5 | 0 | 0 | 10 | 10 |
| library | 5 | 5 | 0 | 0 | 0 | 0 |
| review | 5 | 5 | 0 | 0 | 0 | 0 |
| settings | 5 | 5 | 0 | 0 | 0 | 0 |
| assistant | 5 | 5 | 0 | 0 | 0 | 0 |

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
      "id": "call_416f189002f34176abfdbfbb",
      "type": "function",
      "function": {
        "name": "prepare_event",
        "arguments": "{\"title\": \"Team lunch\", \"day\": \"today\", \"time\": \"11:30\", \"durationMinutes\": 60}"
      }
    }
  ]
}
```

### plan-missing-time-1

Query: Schedule Dentist, but I have not chosen a time

Contract failure: `wrong_tool` (clarification).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_fad0d3f95cba4cd4b47d98ad",
      "type": "function",
      "function": {
        "name": "prepare_event",
        "arguments": "{\"title\": \"Dentist\"}"
      }
    }
  ]
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
      "id": "call_f8287c56b0b346d08f94ff69",
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
      "id": "call_933bf2ab742b46a0afe9617f",
      "type": "function",
      "function": {
        "name": "prepare_event",
        "arguments": "{\"title\": \"Design review\"}"
      }
    }
  ]
}
```

### plan-missing-time-4

Query: Schedule Dinner, but I have not chosen a time Thanks.

Contract failure: `wrong_tool` (clarification).

```json
{
  "role": "assistant",
  "content": "I'll help you schedule Dinner. Since you didn't specify a time, I'll ask for it.",
  "tool_calls": [
    {
      "id": "call_24b95d2e50224c9d83e84dc6",
      "type": "function",
      "function": {
        "name": "prepare_event",
        "arguments": "{\"title\": \"Dinner\"}"
      }
    }
  ]
}
```

### plan-missing-time-5

Query: Quick question: Schedule Airport pickup, but I have not chosen a time

Contract failure: `wrong_tool` (clarification).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_37ffe4b9c4184f009c3fb0ca",
      "type": "function",
      "function": {
        "name": "prepare_event",
        "arguments": "{\"title\": \"Airport pickup\"}"
      }
    }
  ]
}
```

### plan-reschedule-1

Query: Move Dentist to 09:15

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_bea859de767345f993618df9",
      "type": "function",
      "function": {
        "name": "prepare_event",
        "arguments": "{\"title\": \"Dentist\", \"time\": \"09:15\"}"
      }
    }
  ]
}
```

### plan-reschedule-2

Query: Hi, Move Team lunch to 11:30

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_f1027238cfee4b6081c29fd8",
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
  "content": "I'll help you move the Design review event to 14:00. Let me first check your calendar to find the event.",
  "tool_calls": [
    {
      "id": "call_78d3a18cfb5f4d899ee92034",
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
  "content": "",
  "tool_calls": [
    {
      "id": "call_aa6370e907674dbb8d28c94b",
      "type": "function",
      "function": {
        "name": "day_plan",
        "arguments": "{\"date\": \"2026-10-25\"}"
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
      "id": "call_9ebae998587d4247b5b60728",
      "type": "function",
      "function": {
        "name": "prepare_event",
        "arguments": "{\"title\": \"Move Airport pickup\", \"time\": \"20:45\"}"
      }
    }
  ]
}
```

### plan-cancel-2

Query: Hi, Cancel Team lunch tomorrow

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I cannot cancel calendar events or make changes to your calendar. I can only view your current agenda.",
  "tool_calls": [
    {
      "id": "call_135d8f14c92d4de3997c42ef",
      "type": "function",
      "function": {
        "name": "day_plan",
        "arguments": "{\"date\": \"tomorrow\"}"
      }
    }
  ]
}
```

### plan-cancel-3

Query: Please help with this: Cancel Design review tomorrow

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_1d740d940ccf417bbaaafae2",
      "type": "function",
      "function": {
        "name": "prepare_event",
        "arguments": "{\"day\": \"tomorrow\", \"durationMinutes\": 60, \"location\": \"Design review\", \"notes\": \"Cancel this event\", \"revision\": 0, \"title\": \"Design review\"}"
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
      "id": "call_44014fca85004b228667d43d",
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

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_04ebdca906244f9583270730",
      "type": "function",
      "function": {
        "name": "prepare_event",
        "arguments": "{\"title\": \"Invite Alex to Dinner Thanks\"}"
      }
    }
  ]
}
```

### plan-invite-5

Query: Quick question: Invite Alex to Airport pickup

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_b974e3497a31411eb2b30242",
      "type": "function",
      "function": {
        "name": "prepare_event",
        "arguments": "{\"title\": \"Invite Alex to Airport pickup\"}"
      }
    }
  ]
}
```

### plan-recurrence-1

Query: Schedule Dentist every second Tuesday at 09:15

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I'll help you schedule your dentist appointment for the second Tuesday. To do this, I need to determine which month you're referring to. Since today is October 25, 2026, the next second Tuesday of a month would be in November.\n\nLet me create this calendar event for you:",
  "tool_calls": [
    {
      "id": "call_ae39eb0485404fb7b81c07ea",
      "type": "function",
      "function": {
        "name": "prepare_event",
        "arguments": "{\"day\": \"tomorrow\", \"durationMinutes\": 60, \"isAllDay\": false, \"location\": \"Dentist\", \"notes\": \"Second Tuesday appointment\", \"revision\": 0, \"time\": \"09:15\", \"title\": \"Dentist\"}"
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
  "content": "I'll help you schedule a team lunch. You mentioned \"every second Tuesday,\" but I need to know what month you'd like to start this recurring event. Could you please specify which month?"
}
```

### plan-recurrence-3

Query: Please help with this: Schedule Design review every second Tuesday at 14:00

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_cf517fa06d484f50b6629e20",
      "type": "function",
      "function": {
        "name": "prepare_event",
        "arguments": "{\"title\": \"Design review\", \"day\": \"tomorrow\", \"time\": \"14:00\", \"durationMinutes\": 60}"
      }
    }
  ]
}
```

### plan-recurrence-4

Query: Schedule Dinner every second Tuesday at 17:00 Thanks.

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I'll help you schedule a recurring dinner event for every second Tuesday at 17:00. Let me create this calendar event for you.",
  "tool_calls": [
    {
      "id": "call_67ae32dce98949bc9a8576cc",
      "type": "function",
      "function": {
        "name": "prepare_event",
        "arguments": "{\"title\": \"Dinner\", \"time\": \"17:00\"}"
      }
    }
  ]
}
```

### plan-recurrence-5

Query: Quick question: Schedule Airport pickup every second Tuesday at 20:45

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I'll help you schedule an airport pickup event. Since you haven't specified which second Tuesday, I'll assume you mean the next second Tuesday. Let me set up this event with a default time of 20:45.",
  "tool_calls": [
    {
      "id": "call_94a930367e9f4cc39a7c24a8",
      "type": "function",
      "function": {
        "name": "prepare_event",
        "arguments": "{\"day\": \"tomorrow\", \"durationMinutes\": 60, \"location\": \"Airport\", \"notes\": \"Second Tuesday pickup\", \"revision\": 0, \"time\": \"20:45\", \"title\": \"Airport pickup\"}"
      }
    }
  ]
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
      "id": "call_1cebd5e257ec4f9a819485a5",
      "type": "function",
      "function": {
        "name": "prepare_event",
        "arguments": "{\"title\": \"Flight JFK to LHR\", \"day\": \"2026-11-03\", \"time\": \"20:00\", \"durationMinutes\": 540, \"location\": \"JFK to LHR\"}"
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
      "id": "call_5cd100bed5a540a993787b35",
      "type": "function",
      "function": {
        "name": "prepare_event",
        "arguments": "{\"title\": \"Flight JFK to LHR\", \"day\": \"2026-11-04\", \"time\": \"20:00\", \"durationMinutes\": 600, \"location\": \"New York (JFK) to London (LHR)\"}"
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
  "content": "",
  "tool_calls": [
    {
      "id": "call_f6f1840713e7433d9711ea25",
      "type": "function",
      "function": {
        "name": "prepare_event",
        "arguments": "{\"day\": \"2026-11-05\", \"durationMinutes\": 0, \"isAllDay\": false, \"location\": \"JFK to LHR\", \"notes\": \"Leaving 8pm New York, arriving 8am London next day\", \"time\": \"20:00\", \"title\": \"Flight JFK to LHR\"}"
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
  "content": "",
  "tool_calls": [
    {
      "id": "call_02be7a038187485785ee201d",
      "type": "function",
      "function": {
        "name": "prepare_event",
        "arguments": "{\"day\": \"2026-11-06\", \"title\": \"Flight JFK to LHR\", \"durationMinutes\": 600, \"location\": \"JFK to LHR\", \"notes\": \"Leaving 8pm New York, arriving 8am London next day\", \"time\": \"20:00\"}"
      }
    }
  ]
}
```

### plan-flight-5

Query: Quick question: Add flight JFK to LHR on 2026-11-07, leaving 8pm New York and arriving 8am London next day

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_f11c30d42dda46bc9ec0e088",
      "type": "function",
      "function": {
        "name": "prepare_event",
        "arguments": "{\"title\": \"Flight JFK to LHR\", \"day\": \"2026-11-07\", \"durationMinutes\": 600, \"location\": \"JFK to LHR\", \"notes\": \"Leaving 8pm New York, arriving 8am London next day\"}"
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
  "content": "I don't have access to your flight schedules or travel information. I can only show you your local calendar events, which would include any flights you've scheduled.",
  "tool_calls": [
    {
      "id": "call_24445c08ed794085bd7f287a",
      "type": "function",
      "function": {
        "name": "day_plan",
        "arguments": "{}"
      }
    }
  ]
}
```

### plan-arrival-5

Query: Quick question: What local time does my flight land in Tokyo?

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I don't have access to your flight schedule or calendar events. You'll need to check your flight details directly with the airline or your travel itinerary.",
  "tool_calls": [
    {
      "id": "call_066f24a0534e423b9836efae",
      "type": "function",
      "function": {
        "name": "day_plan",
        "arguments": "{}"
      }
    }
  ]
}
```

### plan-timezone-2

Query: Hi, Change my calendar timezone to Europe/London

Contract failure: `argument_section` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_114df2136d5a43d881873495",
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
  "content": "I cannot change the device settings or timezone directly. However, I can open the settings page where you can make that change.",
  "tool_calls": [
    {
      "id": "call_472f78a0037c4951af1c63c6",
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
  "content": "",
  "tool_calls": [
    {
      "id": "call_efaf6e5f022742ef8f19836b",
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
      "id": "call_5d9f4ebe41f74691b240cf68",
      "type": "function",
      "function": {
        "name": "prepare_event",
        "arguments": "{\"day\": \"tomorrow\", \"time\": \"09:15\", \"title\": \"Alarm\"}"
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
      "id": "call_af19e5c079e6443cbbe9d330",
      "type": "function",
      "function": {
        "name": "prepare_event",
        "arguments": "{\"day\": \"tomorrow\", \"time\": \"11:30\", \"title\": \"Alarm\"}"
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
      "id": "call_6a4a6905fd574248badf804c",
      "type": "function",
      "function": {
        "name": "prepare_event",
        "arguments": "{\"day\": \"tomorrow\", \"durationMinutes\": 60, \"time\": \"14:00\", \"title\": \"Alarm\"}"
      }
    }
  ]
}
```

### plan-alarm-4

Query: Set an alarm for 17:00 tomorrow Thanks.

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_df3b19c8fa954151a82a12c0",
      "type": "function",
      "function": {
        "name": "prepare_event",
        "arguments": "{\"day\": \"tomorrow\", \"durationMinutes\": 60, \"location\": \"Alarm\", \"notes\": \"Alarm set for 17:00\", \"revision\": 0, \"time\": \"17:00\", \"title\": \"Alarm\"}"
      }
    }
  ]
}
```

### plan-alarm-5

Query: Quick question: Set an alarm for 20:45 tmrw

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_7cf0ba6c4e1944538eb36b43",
      "type": "function",
      "function": {
        "name": "prepare_event",
        "arguments": "{\"day\": \"tomorrow\", \"durationMinutes\": 60, \"location\": \"Device\", \"notes\": \"Alarm set for 20:45\", \"revision\": 0, \"time\": \"20:45\", \"title\": \"Alarm\"}"
      }
    }
  ]
}
```

### nutrition-dated-5

Query: Quick question: Log 2 eggs and 1 banana for yesterday

Contract failure: `missing_tool` (supported).

```json
{
  "role": "assistant",
  "content": "I can't log meals for a past date. I can only prepare new meal drafts for future dates or add existing logged meals.\n\nWould you like me to prepare a draft for today instead?"
}
```

### nutrition-missing-amount-1

Query: I had some yogurt; ask me the amount before making a meal

Contract failure: `wrong_tool` (clarification).

```json
{
  "role": "assistant",
  "content": "I need to see what yogurt you logged to get the amount. Let me check your nutrition data.",
  "tool_calls": [
    {
      "id": "call_c27cc23a1b4642d88b206a07",
      "type": "function",
      "function": {
        "name": "nutrition_view",
        "arguments": "{\"foodName\": \"yogurt\"}"
      }
    }
  ]
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
      "id": "call_4d4a2dc10b5d45f2bf2386ed",
      "type": "function",
      "function": {
        "name": "prepare_meal",
        "arguments": "{\"foods\": [{\"name\": \"chicken\", \"quantity\": \"unknown\"}]}"
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
      "id": "call_40721c07275b4eacba10a2fa",
      "type": "function",
      "function": {
        "name": "prepare_meal",
        "arguments": "{\"foods\": [{\"name\": \"salmon\", \"quantity\": \"\"}]}"
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
      "id": "call_266b2cf7e7494faaab86766c",
      "type": "function",
      "function": {
        "name": "prepare_meal",
        "arguments": "{\"foods\": [{\"name\": \"Tofu\", \"quantity\": \"\"}]}"
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
      "id": "call_18f58555bba3455fb1e745b4",
      "type": "function",
      "function": {
        "name": "nutrition_view",
        "arguments": "{\"foodName\": \"oats\"}"
      }
    }
  ]
}
```

### workouts-log-1

Query: Log a 30-minute run

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_b20b7fd84b734e68a3dfdfa1",
      "type": "function",
      "function": {
        "name": "prepare_event",
        "arguments": "{\"title\": \"30-minute run\", \"durationMinutes\": 30}"
      }
    }
  ]
}
```

### workouts-log-2

Query: Hi, Log a 30-minute run

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_069d148af82340a6b60c8a27",
      "type": "function",
      "function": {
        "name": "prepare_event",
        "arguments": "{\"title\": \"30-minute run\", \"durationMinutes\": 30}"
      }
    }
  ]
}
```

### workouts-log-3

Query: Please help with this: Log a 30-minute run

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_8f6f467241c242ac98ca6bf3",
      "type": "function",
      "function": {
        "name": "prepare_event",
        "arguments": "{\"title\": \"30-minute run\", \"durationMinutes\": 30}"
      }
    }
  ]
}
```

### workouts-log-4

Query: Log a 30-minute run Thanks.

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_4003f3fb7e6640f093604f6b",
      "type": "function",
      "function": {
        "name": "prepare_event",
        "arguments": "{\"title\": \"30-minute run\", \"durationMinutes\": 30}"
      }
    }
  ]
}
```

### workouts-log-5

Query: Quick question: Log a 30-minute run

Contract failure: `missing_capability_boundary` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I can help you prepare a calendar event for your 30-minute run. Since you didn't specify a time, I'll need to know when you'd like to schedule it. Would you like to set it for today or another day?"
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
      "id": "call_11ddc0f764c14ffb98f361d2",
      "type": "function",
      "function": {
        "name": "prepare_event",
        "arguments": "{\"day\": \"today\", \"durationMinutes\": 60, \"isAllDay\": false, \"location\": \"\", \"notes\": \"\", \"revision\": 0, \"time\": \"09:15\", \"title\": \"Bedtime routine\"}"
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
      "id": "call_eebd57b60bab409888756027",
      "type": "function",
      "function": {
        "name": "prepare_event",
        "arguments": "{\"time\": \"23:30\", \"title\": \"Bedtime routine\"}"
      }
    }
  ]
}
```

### routines-create-3

Query: Please help with this: Create a bedtime routine at 14:00

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_c67faed2a044400a8eece9aa",
      "type": "function",
      "function": {
        "name": "prepare_event",
        "arguments": "{\"title\": \"Bedtime routine\", \"time\": \"14:00\", \"durationMinutes\": 60}"
      }
    }
  ]
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
      "id": "call_97cda8b5e3074678b211b63a",
      "type": "function",
      "function": {
        "name": "prepare_event",
        "arguments": "{\"title\": \"Bedtime routine\", \"day\": \"today\", \"time\": \"17:00\", \"durationMinutes\": 60}"
      }
    }
  ]
}
```

### routines-create-5

Query: Quick question: Create a bedtime routine at 20:45

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_b78d4cd4dcbe45cea8d844fc",
      "type": "function",
      "function": {
        "name": "prepare_event",
        "arguments": "{\"title\": \"Bedtime routine\", \"time\": \"20:45\", \"durationMinutes\": 60}"
      }
    }
  ]
}
```

### routines-edit-1

Query: Move my morning routine to 09:15

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I need to check your current schedule to find the morning routine event. Let me look at your day plan first.",
  "tool_calls": [
    {
      "id": "call_aaa0af6bf87f4464a9db4263",
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

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I need to find your current morning routine event to move it. Let me check your calendar agenda.",
  "tool_calls": [
    {
      "id": "call_b9a9a881b1d047beb25ad0eb",
      "type": "function",
      "function": {
        "name": "day_plan",
        "arguments": "{}"
      }
    }
  ]
}
```

### routines-edit-3

Query: Please help with this: Move my morning routine to 14:00

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I can help you with that. To move your morning routine to 14:00 (2:00 PM), I'll need to check your current calendar first to see what morning routine you have scheduled.",
  "tool_calls": [
    {
      "id": "call_b2a86cc2605e468ba6a32760",
      "type": "function",
      "function": {
        "name": "day_plan",
        "arguments": "{\"date\": \"today\"}"
      }
    }
  ]
}
```

### routines-edit-4

Query: Move my morning routine to 17:00 Thanks.

Contract failure: `wrong_tool` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I'll help you move your morning routine to 17:00. Let me first check your current schedule to see the event details.",
  "tool_calls": [
    {
      "id": "call_7db7a079f0314173ad5470a1",
      "type": "function",
      "function": {
        "name": "day_plan",
        "arguments": "{}"
      }
    }
  ]
}
```

### routines-edit-5

Query: Quick question: Move my morning routine to 20:45

Contract failure: `missing_capability_boundary` (capability_gap).

```json
{
  "role": "assistant",
  "content": "I'll help you update your morning routine to 20:45. Could you clarify if you'd like me to:\n\n1. Find your existing event and modify the time, or\n2. Create a new event with that time?\n\nAlso, what day should this event be scheduled for?"
}
```

