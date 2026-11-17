const datasets = {
  personalPlan: ['Routines & reminders', 'All retained synced routines, alarms, day-plan items and overrides, and wake plans.', 'plan.routine, plan.alarm, plan.extra, plan.override, core.wakePlan'],
  workouts: ['Workouts', 'Recorded workouts, workout plans and completions, plus visible workout history from the Health snapshot’s data.workouts field.', 'health.workout, health.workoutPlan, health.workoutCompletion, health.snapshot'],
  health: ['Health trends', 'The synced trend measurements in the Health snapshot’s data.trends field.', 'health.snapshot'],
  nutrition: ['Food', 'All retained synced meals, saved foods and meal-photo links.', 'food.meal, food.myFood, food.mealPhoto'],
  taken: ['Taken', 'Synced supplements, medications and dose history.', 'food.supplement, food.dose'],
  notes: ['Notes', 'Synced voice notes, recordings and their available transcripts.', 'notes.voiceNote'],
  listening: ['Listening', 'Synced shows, listening history, progress and available transcripts.', 'podcast.show, podcast.listen, podcast.progress, podcast.transcript'],
};
const shell = value => "'" + value.replaceAll("'", "'\"'\"'") + "'";

export function feedGuide({ access, url = '', preview = false, escape: esc }) {
  const sample = url || '<FEED_URL>';
  const bearer = url ? new URL(url) : null;
  bearer?.searchParams.delete('signature');
  const rows = (access?.sections ?? []).filter(k => datasets[k]).map(k => datasets[k]);
  const calendars = access?.calendars;
  return `<section class="feed-guide" aria-labelledby="feed-guide-title"><h2 id="feed-guide-title">Use this feed</h2>
    <ol><li>Name a connection and create it.</li><li>Select the data types and JSON or CSV, then copy the feed URL.</li><li>Make an HTTP GET request from your system. No Banana sign-in is needed for the private feed URL.</li></ol>
    ${preview ? '<p>This is an owner preview. The response preview uses the selected share permissions; no recipient connection or token is created. Example feed URLs do not grant access. Preview page and image links require your signed-in owner session.</p>' : ''}
    <h3>What is included</h3>
    ${rows.length ? `<dl>${rows.map(([name, description, types]) => `<dt>${esc(name)}</dt><dd>${esc(description)} <code>${esc(types)}</code></dd>`).join('')}</dl>` : '<p>The included types are limited to the access selected for this connection.</p>'}
    ${calendars?.busy || calendars?.details ? `<p>Calendars: ${calendars.details} with full details; ${calendars.busy} with busy time only. Only the selected calendars are included.</p>` : '<p>Calendar events are not included.</p>'}
    <p>The feed covers retained synced records in the shared sections, not just the current screen or day. A data-type parameter filters that access; it cannot add another section or calendar. Health data still requires the owner’s sync consent.</p>
    <h3>Request</h3><pre tabindex="0"><code>${esc('curl --fail --silent --show-error '+shell(sample))}</code></pre>
    <h3>Parameters</h3><div class="feed-doc-table"><table><thead><tr><th>Parameter</th><th>Meaning</th></tr></thead><tbody>
      <tr><td><code>types</code></td><td><code>all</code> or comma-separated permitted types, such as <code>food.meal,food.myFood</code>.</td></tr>
      <tr><td><code>format</code></td><td><code>json</code> or <code>csv</code>.</td></tr>
      <tr><td><code>limit</code></td><td>1–100 records per page; default 100.</td></tr>
      <tr><td><code>calendarDays</code></td><td>Next 1–8 UTC days; default 7. Only when Calendar is selected. This rolling window advances for recurring imports.</td></tr>
      <tr><td><code>from</code>, <code>to</code></td><td>Optional fixed calendar window in Unix milliseconds, at most eight days, instead of <code>calendarDays</code>.</td></tr>
    </tbody></table></div>
    <h3>Pages and images</h3><p>JSON contains <code>records</code> with <code>type</code>, <code>id</code>, <code>data</code> and <code>assets</code>. Follow <code>next</code> until it is null, including after an empty page. CSV has type/id columns; follow the HTTP <code>Link</code> header with <code>rel="next"</code>. Send the same credentials on each page. Reconcile records by type and ID; deleted records may disappear between imports.</p>
    <p>Meal-photo links are in <code>assets</code>; download the image from its URL. Private feed image links expire within an hour. Fetch the record again for fresh links. Source field names, units and date encodings are preserved; calendar bounds use Unix milliseconds.</p>
    <h3>Credentials</h3><p>The long <code>signature</code> value is a URL credential, not the API token. The copied private URL works on its own. Alternatively, remove <code>signature</code> and send the separately copied API token in an <code>Authorization: Bearer</code> header. Both authorize the same read-only connection. Revoking it disables both. Keep either credential private.</p>
    <pre tabindex="0"><code>${esc("curl --fail -H 'Authorization: Bearer <API_TOKEN>' "+shell(bearer?.href || '<FEED_URL_WITHOUT_SIGNATURE>'))}</code></pre>
    <h3>Errors</h3><dl><dt>400</dt><dd>Invalid, repeated or unsupported query parameters.</dd><dt>401</dt><dd>Missing or invalid credential.</dd><dt>403</dt><dd>A requested type is outside the current access or consent.</dd><dt>404</dt><dd>The connection, share or image is unavailable, revoked or expired.</dd><dt>409</dt><dd>The query, permissions or calendar changed while paging. Restart from the original feed URL.</dd><dt>413</dt><dd>The page is too large or too wide for CSV. Reduce the limit or calendar window, or use JSON.</dd><dt>429</dt><dd>Rate limited. Wait for the <code>Retry-After</code> interval.</dd><dt>503</dt><dd>Data or a selected calendar is temporarily unavailable. Retry later; the feed does not silently omit the failed calendar.</dd></dl>
  </section>`;
}
