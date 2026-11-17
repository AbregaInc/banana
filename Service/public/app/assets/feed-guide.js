const datasets = {
  personalPlan: ['Routines & reminders', 'All retained synced routines, alarms, day-plan items and overrides, and wake plans.'],
  workouts: ['Workouts', 'Recorded workouts, workout plans and completions, plus visible workout history from the Health snapshot’s data.workouts field.'],
  health: ['Health trends', 'The synced trend measurements in the Health snapshot’s data.trends field.'],
  nutrition: ['Food', 'All retained synced meals, saved foods and meal-photo links.'],
  taken: ['Taken', 'Synced supplements, medications and dose history.'],
  notes: ['Notes', 'Synced voice notes, recordings and their available transcripts.'],
  listening: ['Listening', 'Synced shows, listening history, progress and available transcripts.'],
};
// Descriptions are shared by the request controls and the exhaustive parameter reference.
export const FEED_TYPES = {
  'plan.routine': ['Routines', 'Synced routine definitions.'],
  'plan.alarm': ['Alarms', 'Synced alarms.'],
  'plan.extra': ['Plan items', 'Additional day-plan items.'],
  'plan.override': ['Plan adjustments', 'Overrides to planned routine items.'],
  'core.wakePlan': ['Wake plans', 'Synced wake plans.'],
  'health.workout': ['Workouts', 'Recorded workout records and their available attachments.'],
  'health.workoutPlan': ['Workout plans', 'Planned workouts.'],
  'health.workoutCompletion': ['Workout completions', 'Workout completion records.'],
  'health.snapshot': ['Health data', 'Filtered Health snapshot.'],
  'food.meal': ['Meals', 'Logged meals, with available photo links in assets.'],
  'food.mealPhoto': ['Meal photos', 'Meal-photo records with image URLs.'],
  'food.myFood': ['Saved foods', 'Saved food definitions.'],
  'food.supplement': ['Supplements', 'Supplement and medication definitions.'],
  'food.dose': ['Dose history', 'Recorded supplement and medication doses.'],
  'notes.voiceNote': ['Voice notes', 'Voice-note records with available recordings and transcripts.'],
  'podcast.show': ['Podcasts', 'Synced podcast shows.'],
  'podcast.listen': ['Listening history', 'Recorded podcast listening history.'],
  'podcast.progress': ['Listening progress', 'Saved podcast playback progress.'],
  'podcast.transcript': ['Transcripts', 'Available podcast transcript records and attachments.'],
  calendar: ['Calendar', 'Events from the selected calendars within the requested window; busy-only calendars expose busy intervals.'],
};
export function feedTypeName(type, access) {
  if (type === 'health.snapshot' && access) return [access.sections.includes('workouts') ? 'Workout history' : '', access.sections.includes('health') ? 'Health trends' : ''].filter(Boolean).join(' & ');
  return FEED_TYPES[type]?.[0] ?? type;
}
const typeDescription = (type, access) => type === 'health.snapshot' && access
  ? [access.sections.includes('workouts') ? 'Visible workout history in data.workouts.' : '', access.sections.includes('health') ? 'Synced trend measurements in data.trends.' : ''].filter(Boolean).join(' ')
  : FEED_TYPES[type]?.[1] ?? 'Shared synced records of this type.';
const shell = value => "'" + value.replaceAll("'", "'\"'\"'") + "'";

export function feedGuide({ access, types = null, url = '', manifestURL = '', preview = false, escape: esc }) {
  const sample = url || '<FEED_URL>';
  const bearer = url ? new URL(url) : null;
  bearer?.searchParams.delete('signature');
  const rows = (access?.sections ?? []).filter(k => datasets[k]).map(k => datasets[k]);
  const calendars = access?.calendars;
  const validTypes = types == null ? null : [...new Set(types)];
  return `<section class="feed-guide" aria-labelledby="feed-guide-title"><h2 id="feed-guide-title">Use this feed</h2>
    <ol><li>Name a connection and create it.</li><li>Select the data types and JSON or CSV, then copy the feed URL.</li><li>Make an HTTP GET request from your system. No Banana sign-in is needed for the private feed URL.</li></ol>
    ${preview ? '<p>This is an owner preview. The response preview uses the selected share permissions; no recipient connection or token is created. Example feed URLs do not grant access. Preview page and image links require your signed-in owner session.</p>' : ''}
    <h3>What is included</h3>
    ${rows.length ? `<dl>${rows.map(([name, description]) => `<dt>${esc(name)}</dt><dd>${esc(description)}</dd>`).join('')}</dl>` : '<p>The included types are limited to the access selected for this connection.</p>'}
    ${calendars?.busy || calendars?.details ? `<p>Calendars: ${calendars.details} with full details; ${calendars.busy} with busy time only. Only the selected calendars are included.</p>` : '<p>Calendar events are not included.</p>'}
    <p>The feed covers retained synced records in the shared sections, not just the current screen or day. A data-type parameter filters that access; it cannot add another section or calendar. Health data still requires the owner’s sync consent.</p>
    <h3>Request</h3><pre tabindex="0"><code>${esc('curl --fail --silent --show-error '+shell(sample))}</code></pre>
    <h3>Parameters</h3><div class="feed-doc-table"><table><thead><tr><th>Parameter</th><th>Meaning</th></tr></thead><tbody>
      <tr><td><code>types</code></td><td><code>all</code> (default) includes every currently permitted type listed below. Or use one or more exact identifiers from that list, separated by commas without spaces. Identifiers are case-sensitive; duplicates are invalid. An unavailable type returns 403.</td></tr>
      <tr><td><code>format</code></td><td><code>json</code> or <code>csv</code>.</td></tr>
      <tr><td><code>limit</code></td><td>1–100 records per page; default 100.</td></tr>
      <tr><td><code>calendarDays</code></td><td>Next 1–8 UTC days; default 7. Only when Calendar is selected. This rolling window advances for recurring imports.</td></tr>
      <tr><td><code>from</code>, <code>to</code></td><td>Optional fixed calendar window in Unix milliseconds, at most eight days, instead of <code>calendarDays</code>.</td></tr>
    </tbody></table></div>
    <h3>Valid types for this connection</h3>
    ${validTypes == null ? '<p>Create a connection to load its complete, permission- and consent-checked type list.</p>' : validTypes.length ? `<div class="feed-doc-table"><table><thead><tr><th>Type identifier</th><th>Returns</th></tr></thead><tbody>${validTypes.map(type => `<tr><td><code>${esc(type)}</code></td><td><strong>${esc(feedTypeName(type, access))}</strong> — ${esc(typeDescription(type, access))}</td></tr>`).join('')}</tbody></table></div>
      <p>Complete comma-separated value:</p><pre tabindex="0"><code>${esc(validTypes.join(','))}</code></pre><button class="text-button" data-feed-copy="types">Copy valid types</button>` : '<p>No types are currently available under this connection’s permissions and consent.</p>'}
    <p>This list is the complete set currently accepted for this access, including permitted types with no records yet. It can shrink when access or consent is removed. A connection never gains access beyond its original grant. Use the checkboxes above to build a filtered URL.</p>
    ${manifestURL ? `<p>For programmatic discovery, GET <a href="${esc(manifestURL)}" target="_blank" rel="noreferrer noopener">the connection manifest</a>. Read <code>types[].type</code>; also allow <code>calendar</code> only when <code>calendar</code> is non-null. Re-fetch metadata after a 403.</p>` : ''}
    <h3>Pages and images</h3><p>JSON contains <code>records</code> with <code>type</code>, <code>id</code>, <code>data</code> and <code>assets</code>. Follow <code>next</code> until it is null, including after an empty page. CSV has type/id columns; follow the HTTP <code>Link</code> header with <code>rel="next"</code>. Send the same credentials on each page. Reconcile records by type and ID; deleted records may disappear between imports.</p>
    <p>Meal-photo links are in <code>assets</code>; download the image from its URL. Private feed image links expire within an hour. Fetch the record again for fresh links. Source field names, units and date encodings are preserved; calendar bounds use Unix milliseconds.</p>
    <h3>Credentials</h3><p>The long <code>signature</code> value is a URL credential, not the API token. The copied private URL works on its own. Alternatively, remove <code>signature</code> and send the separately copied API token in an <code>Authorization: Bearer</code> header. Both authorize the same read-only connection. Revoking it disables both. Keep either credential private.</p>
    <pre tabindex="0"><code>${esc("curl --fail -H 'Authorization: Bearer <API_TOKEN>' "+shell(bearer?.href || '<FEED_URL_WITHOUT_SIGNATURE>'))}</code></pre>
    <h3>Errors</h3><dl><dt>400</dt><dd>Invalid, repeated or unsupported query parameters.</dd><dt>401</dt><dd>Missing or invalid credential.</dd><dt>403</dt><dd>A requested type is outside the current access or consent.</dd><dt>404</dt><dd>The connection, share or image is unavailable, revoked or expired.</dd><dt>409</dt><dd>The query, permissions or calendar changed while paging. Restart from the original feed URL.</dd><dt>413</dt><dd>The page is too large or too wide for CSV. Reduce the limit or calendar window, or use JSON.</dd><dt>429</dt><dd>Rate limited. Wait for the <code>Retry-After</code> interval.</dd><dt>503</dt><dd>Data or a selected calendar is temporarily unavailable. Retry later; the feed does not silently omit the failed calendar.</dd></dl>
  </section>`;
}
