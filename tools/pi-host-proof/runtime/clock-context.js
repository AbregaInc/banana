// A new clock snapshot belongs to each submitted turn, never to conversation creation.
export function clockInstructions(clock) {
  return '<current-clock>'+JSON.stringify(clock)+'</current-clock>\nResolve today/tomorrow/yesterday against this turn’s device date and timezone, even if the conversation began on an earlier day. Prior agenda dates are historical results. Preserve relative day names for native tools; do not calculate an ISO date.';
}
export function requestClock(request) {
  return request.instructions.match(/<current-clock>[\s\S]*?<\/current-clock>/)?.[0] ?? '';
}
export function relativeDay(value) {
  const words=value.replace(/"[^"\n]*"|“[^”\n]*”/g,'');
  const days=[...new Set((words.toLowerCase().match(/\b(today|tomorrow|tmrw|yesterday)\b/g)??[]).map(d=>d==='tmrw'?'tomorrow':d))];
  return days.length===1 && !/\b\d{4}-\d{2}-\d{2}\b/.test(words) ? days[0] : undefined;
}
