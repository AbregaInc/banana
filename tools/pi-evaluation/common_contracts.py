"""Conservative, auditable contracts; a pass is not a judgment of answer quality."""
import json,re
from jsonschema import Draft7Validator

def score_common(case,raw):
    choices=raw.get('choices',[])
    if len(choices)!=1 or choices[0].get('finish_reason') not in ('stop','tool_calls'): return False,'incomplete'
    msg=choices[0]['message']; calls=msg.get('tool_calls') or []; text=msg.get('content') or ''; expected=case['expected']
    if re.search(r"\b(I(?:'ve| have)?|successfully)\s+(?:deleted|removed|updated|booked|scheduled|cancelled|canceled|sent|changed|saved|logged|set your|downloaded)\b",text,re.I): return False,'unverified_action_claim'
    if not calls:
        if not text.strip(): return False,'empty_reply'
        if expected.get('reply'):
            if case.get('capability') == 'capability_gap' and case.get('family') != 'no-write':
                if not re.search(r"can't|cannot|can’t|unable|not able|don't have|do not have|don’t have|no access|not (?:currently )?(?:supported|available)|only (?:help|show|prepare|access)|manually|in (?:the )?(?:app|settings|calendar)|open (?:the |your )?",text,re.I):
                    return False,'missing_capability_boundary'
            return True,'reply_needs_semantic_review' 
        return False,'missing_tool'
    if len(calls)!=1: return False,'multiple_tools'
    call=calls[0].get('function',{}); name=call.get('name')
    allowed=expected.get('tools',{})
    if name not in allowed: return False,'wrong_tool'
    try: args=json.loads(call.get('arguments',''))
    except (ValueError,TypeError): return False,'invalid_json'
    schema=next((t['parameters'] for t in case['request']['tools'] if t['name']==name),None)
    if schema is None or list(Draft7Validator(schema).iter_errors(args)): return False,'schema'
    for key,value in allowed[name].items():
        actual=args.get(key)
        if key in ('date','day'):
            aliases={'today':'2026-10-25','tomorrow':'2026-10-26','yesterday':'2026-10-24'}
            actual=aliases.get(actual,actual or '2026-10-25'); value=aliases.get(value,value)
        if actual != value: return False,'argument_'+key
    if expected.get('omitDay') and args.get('day') is not None: return False,'invented_day'
    if expected.get('foods'):
        foods=args.get('foods',[])
        if len(foods)!=len(expected['foods']): return False,'food_count'
        for word in expected['foods']:
            if not any(word in f.get('name','').lower() for f in foods): return False,'food_identity'
    return True,'tool_contract_pass'


def score_reviewed(case, raw):
    choices = raw.get("choices", [])
    if len(choices) != 1 or choices[0].get("finish_reason") not in {"stop", "tool_calls"}:
        return False, "incomplete"
    message = choices[0]["message"]
    expected = case["expected"]
    calls = message.get("tool_calls") or []
    if expected["tool"] is None:
        text = (message.get("content") or "").casefold()
        if calls or not text.strip() or expected["textIncludes"].casefold() not in text:
            return False, "reply_contract"
        if any(value.casefold() in text for value in expected.get("textExcludes", [])):
            return False, "forbidden_reply"
        return True, "reviewed_reply_pass"
    if len(calls) != 1 or calls[0].get("function", {}).get("name") != expected["tool"]:
        return False, "wrong_tool"
    try:
        arguments = json.loads(calls[0]["function"]["arguments"])
    except (KeyError, TypeError, ValueError):
        return False, "invalid_json"
    schema = next(tool["parameters"] for tool in case["request"]["tools"] if tool["name"] == expected["tool"])
    if not isinstance(arguments, dict) or not Draft7Validator(schema).is_valid(arguments):
        return False, "schema"
    for key, value in expected["arguments"].items():
        if key not in arguments or arguments[key] != value:
            return False, "argument_" + key
    return True, "reviewed_tool_pass"
