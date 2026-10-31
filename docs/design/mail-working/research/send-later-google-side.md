# Can a serverless native Gmail client get Google to send later, with every device off?

Checked 2026-10-06 against current documentation. No Gmail or Google account was available to this research (the `gmail-user` and `gmail-z0` MCP servers failed to connect), so **nothing below was exercised against a live mailbox or a live Apps Script project.** Every behavioural claim is tagged.

| Tag | Meaning |
|---|---|
| `[doc]` | Stated on the Google page given beside it. |
| `[disc]` | Read from Google's machine-readable discovery document, fetched today (Gmail rev 20260928, Apps Script API rev 20260927). |
| `[probe]` | I observed it myself today. |
| `[2nd]` | Non-Google source. Corroboration only. |
| `INFERENCE` | My deduction from verified premises, premises stated. |
| `UNVERIFIED` | Not confirmed from a primary source. Needs the live experiment named in section 10. |

---

## 0. The answer in five lines

1. **Not through the Gmail API and not through SMTP.** The API has no scheduled-send or snooze field, label or method (discovery rev 20260928, release notes to June 2026), and Gmail's SMTP server advertises neither `FUTURERELEASE` nor `DELIVERBY` (probed today). Gmail's own "Schedule send" can only be created by a person in Gmail's own UI.
2. **Yes, with a setup step: a small Apps Script project in the user's own Google account.** One recurring time-driven trigger (every 1 to 5 minutes) sends Gmail drafts that are due. Google runs it server-side with every device off. Each component is documented, but the combination is unproven live, and **the trigger cannot be installed by API** (Google: "The API cannot create Apps Script triggers"), so the user must open the script once in a browser, press Run, and approve an "unverified app" consent screen.
3. **Timing is "within minutes, never early", not "at 8:00".** Lateness is roughly the poll interval plus undocumented jitter. Gmail's own Schedule send also says "may be sent a few minutes after".
4. **Cost to the user:** a script in their Drive that holds a Gmail permission and keeps running after the app's own access is revoked; a one-time Apps Script API toggle; an unverified-app click-through; consumer quotas (90 min/day of trigger runtime, 100 email recipients/day through Apps Script mail); Workspace admins can switch it off; Advanced Protection accounts may be blocked.
5. **Verdict: WORKS WITH SETUP, UNVERIFIED end to end.** Snooze-return and "remind me if no reply" ride the same mechanism but need the broader `gmail.modify` permission in the script. Keep the device-held send as the backstop, and do not promise "sends even if everything is off" until section 10's experiments E4 to E9 pass.

---

## 1. Avenue 1: Gmail's own scheduled send (and snooze)

### 1.1 What the API exposes (re-checked)

- **Release notes.** Entries run May 2025 to June 2026. None mentions scheduled send, snooze, a `SCHEDULED`/`SNOOZED` label, or any new field on `messages.send`, `drafts.send`, `Message`, `Label` or settings. The only relevant-sounding ones are the Gmail MCP server developer preview (22 Apr 2026) and quota-tiering changes (1 May 2026). `[doc]` https://developers.google.com/workspace/gmail/api/release-notes
- **Discovery document, rev 20260928**, fetched today. `[disc]` https://gmail.googleapis.com/$discovery/rest?version=v1
  - Zero occurrences of "schedul" or "snooze" in its 217 KB.
  - `messages.send` and `drafts.send` take only the path parameter `userId` (plus the media-upload variants). No `sendAt`.
  - The only time fields on any mail resource are `Message.internalDate` and `VacationSettings.startTime`/`endTime`. Those two only gate automatic replies to mail Gmail *receives*, so they are not a send-later mechanism.
  - There is no `v1beta` discovery document (HTTP 404 `[probe]`), so the "beta" claim below has nothing behind it.
- **A claim that contradicts the above.** `openclaw/gogcli` issue #1006 (20 Aug 2026) says "`users.messages.send` supports the `sendAt` query parameter (beta)". It cites no Google page, the reference page for `messages.send` lists no query parameters at all `[doc]` https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages/send, and the discovery document has no such parameter. Issue #1082 in `taylorwilsdon/google_workspace_mcp` (30 Aug 2026) says the opposite: the API "does not document a first-class schedule-send parameter". I could not test it: an unauthenticated POST with `?sendAt=` returns the same 401 as `?foo=bar` `[probe]`. **Treat `sendAt` as nonexistent**, and settle it with experiment E1b (a one-line authenticated call). Sources: https://github.com/openclaw/gogcli/issues/1006 and https://github.com/taylorwilsdon/google_workspace_mcp/issues/1082 `[2nd]`.
- **System labels.** The labels guide lists INBOX, SPAM, TRASH, UNREAD, STARRED, IMPORTANT, SENT, DRAFT and the CATEGORY_* labels, and says the list "isn't exhaustive". It does not mention SNOOZED or SCHEDULED. It also says "You can't apply labels to draft messages." `[doc]` https://developers.google.com/workspace/gmail/api/guides/labels
- **Gmail MCP server (developer preview).** Tools: `create_draft`, `get_thread`, `label_message`, `label_thread`, `list_drafts`, `list_labels`, `search_threads`, `unlabel_message`, `unlabel_thread`. Scopes `gmail.readonly` and `gmail.compose`. No send tool, no scheduling. `[doc]` https://developers.google.com/workspace/gmail/api/guides/configure-mcp-server

### 1.2 What the Gmail apps do, and how it looks through the API

- **Schedule send in the apps.** Works in the Gmail iPhone/iPad app; scheduled mail sits in a "Scheduled" folder; up to 100 scheduled emails; "Cancel send" turns a scheduled email back into a draft; "may be sent a few minutes after the scheduled time"; sent in the timezone it was scheduled in. The help page says nothing about the API, third-party clients or devices being off. `[doc]` https://support.google.com/mail/answer/9214606
- **That a scheduled message is held on Google's servers** is how every account behaves (it is sent while the phone is off), but I found no Google sentence that says so. INFERENCE, very high confidence.
- **How it appears to the API.** Nylas support (updated 2 Feb 2026): "scheduled emails can be identified using … `search_query_native` … `in:scheduled`", and "Google treats it like any other non-draft message from an API perspective" so it can show up in ordinary inbox/sent listings and webhooks do not flag it. `[2nd]` https://support.nylas.com/hc/en-us/articles/33676452303005-How-can-I-identify-scheduled-emails-from-Gmail-UI-when-using-the-Nylas-API
  - A third-party project (`dsmorgan/netkeeper` PR #308) models a `SCHEDULED` system label and searches `in:scheduled rfc822msgid:<id>`, but it states this "has not been tested live" and cites no Google page. `[2nd]` https://github.com/dsmorgan/netkeeper/pull/308 So: **`q=in:scheduled` finding them is reported by a vendor; a label named `SCHEDULED` is UNVERIFIED.**
  - Whether the API sees a scheduled message as a draft, whether it carries `DRAFT`, `SENT` or neither, whether `labels.list` shows a scheduled/snoozed label, and whether `messages.trash/delete/modify` on it cancels it: all UNVERIFIED (E1).
- **Snooze.** Mimestream, the most mature native Gmail client: "the Gmail API does not expose snooze functionality, so it is not possible for Mimestream to provide a snooze feature that is integrated with Gmail", and links Google Issue Tracker bug 109952618 (page needs sign-in; I could not read its status). Its snooze is local ("Labs"), and at the time a notification appears and the message moves to the top of the Inbox. `[2nd]` https://mimestream.com/help/user-guide/snoozing Its release notes through 1.10.8 (4 Sep 2026) list fixes such as "Delayed unsnooze operations after system sleep" and no scheduled send. `[2nd]` https://mimestream.com/releases
- **Creating a native scheduled send by undocumented means.** I found no report of one that works with an OAuth token. Gmail's web client uses private endpoints with browser cookies, which are not reachable with an installed-app OAuth token and would breach the API terms. A message inserted with `messages.insert`/`import` is never delivered, so a "SCHEDULED" label on an inserted message would not send anything (INFERENCE; system labels cannot be applied freely anyway).

### 1.3 Verdict

| Capability | Status |
|---|---|
| Create a Gmail-native scheduled send through the API | **NOT POSSIBLE** (documented absence; no workaround found) |
| See messages scheduled in Gmail's apps through the API | **FRAGILE-UNDOCUMENTED** (`in:scheduled`, vendor-reported; label name unverified) |
| Cancel one through the API | **UNVERIFIED** (E1) |
| Create one by handing the draft to Gmail's own UI and letting the user press Schedule send | **WORKS, manually.** Needs no extra scope and no script; true Google-side queue with Gmail's own cancel, list and 100-message cap. Deep link to open a draft in Gmail web (`https://mail.google.com/mail/u/0/#drafts?compose=<id>`) is UNVERIFIED and undocumented. |
| Snooze the Gmail-native way | **NOT POSSIBLE** |

**Design consequence regardless of the rest:** a client that lists mail must expect Gmail-scheduled messages to look like ordinary sent-ish mail, and should query `in:scheduled` (once E1 confirms it) to show them as "Scheduled in Gmail" rather than "Sent".

---

## 2. Avenue 2: Google Apps Script in the user's own account

### 2.1 Facts, each with its source

**Creating the project and its code from a native app**

- `projects.create` "Creates a new, empty script project with no script files and a base manifest file"; takes `title` and optional `parentId`; scope `script.projects`. `[doc]` https://developers.google.com/apps-script/api/reference/rest/v1/projects/create
- `projects.updateContent`: "This content is stored as the HEAD version, and is used when the script is executed as a trigger, in the script editor, in add-on preview mode, or as a web app or Apps Script API in development mode. This clears all the existing files in the project." One file must be the manifest, named `appsscript`, type JSON. Scope `script.projects`. `[doc]` https://developers.google.com/apps-script/api/reference/rest/v1/projects/updateContent
  - **Consequence:** triggers run the HEAD content, so no deployment is needed for a trigger. Each update must resend every file.
- REST paths `[disc]` https://script.googleapis.com/$discovery/rest?version=v1: `POST /v1/projects`, `PUT /v1/projects/{scriptId}/content`, `POST /v1/scripts/{scriptId}:run`, `GET /v1/processes:listScriptProcesses`. File types are `SERVER_JS`, `HTML`, `JSON`. No trigger method exists in the API. The `Project` resource has no field for a Cloud project.
- **Per-user switch.** The Apps Script API "cannot access your script projects by default. You must explicitly grant the API access before you can use any application that creates or modifies scripts or deployments"; it is turned on in the Apps Script dashboard (https://script.google.com/home/usersettings); "An error results if you attempt to run an affected application without first granting the API access. This error occurs after you authorize the application." Executing functions (`scripts.run`) does not need it. `[doc]` https://developers.google.com/apps-script/api/how-tos/enable A native app cannot flip this for the user.
- Enabling the API in the app's Cloud project is separate and also required. `[doc]` same page.

**Installing the trigger: this is the blocking step**

- `scripts.run` can only run a function; "No triggers. The API cannot create Apps Script triggers." `[doc]` https://developers.google.com/apps-script/api/how-tos/execute (Limitations, item 4). The sentence is ambiguous (the REST surface has no trigger resource, or `ScriptApp.newTrigger` inside a `scripts.run` execution fails), and I found no primary or secondary source that settles it. **Treat as NOT POSSIBLE until E5.**
- `scripts.run` additionally requires: the script deployed as an "API executable"; "the script and the calling application's OAuth2 client share a common Google Cloud project", which "must be a standard Cloud project; default projects created for Apps Script projects are insufficient"; the calling token must "cover all the scopes used by the script, not just the ones used by the called function"; and the script must require at least one scope. `[doc]` same page.
  - A script made by `projects.create` is on a default project. Switching to a standard project is done in the editor's Project Settings (paste the project number); you can switch from default to standard but never back. `[doc]` https://developers.google.com/apps-script/guides/cloud-platform-projects The API has no call for it `[disc]`. So `scripts.run` implies another manual editor step on top of the trigger problem. For the owner, who owns both the app's Cloud project and the account, that is one paste; for any other user it is a barrier (whether a user can attach a project they have no role in is UNVERIFIED).
- **Manual creation is documented**: "To manually create an installable trigger in the script editor…". `[doc]` https://developers.google.com/apps-script/guides/triggers/installable A script can also create its own triggers in code with `ScriptApp.newTrigger(fn).timeBased()…create()`, which needs scope `https://www.googleapis.com/auth/script.scriptapp`. `[doc]` https://developers.google.com/apps-script/reference/script/script-app
- So the **only documented route** is: the app uploads a script that contains an `install()` function; the user opens the script in a browser, picks `install`, presses Run, and approves the script's consent screen; `install()` creates the trigger. A web-app endpoint (`doPost`) that creates the trigger is a possible alternative, but it still needs the owner to authorize the script in a browser first, so it saves nothing. UNVERIFIED.
- `ScriptApp.requireScopes()` is recommended "during trigger setup or installation" so the user grants every scope before the trigger exists. `[doc]` https://developers.google.com/apps-script/concepts/scopes

**Scopes and how Google classifies them**

| Step | Scope | Class |
|---|---|---|
| Create script, write code, `projects.get/getContent` | `https://www.googleapis.com/auth/script.projects` | UNVERIFIED. Google's scope list names it ("Create and update Google Apps Script projects") but does not print a class. My recollection is *sensitive*; read it in the Cloud Console consent-screen scope picker. `[doc]` https://developers.google.com/identity/protocols/oauth2/scopes |
| Read run history | `script.processes` ("View Google Apps Script processes"), `script.metrics` | UNVERIFIED, likewise |
| Script's own Gmail access, narrow (Advanced Gmail service) | `gmail.compose` (drafts CRUD, `drafts.send`, `drafts.get`; cannot read the inbox) | **restricted** `[doc]` per the earlier dossier §12.1 and `[disc]` scopes for `drafts.*` |
| Script's own Gmail access, for snooze and reminders | `gmail.modify` | **restricted** |
| Script's own Gmail access, if it uses the built-in `GmailApp` | `https://mail.google.com/` (every `GmailDraft` method lists only this scope) | **restricted**, and the widest Gmail scope (includes permanent delete). `[doc]` https://developers.google.com/apps-script/reference/gmail/gmail-draft |
| Script creating its own trigger | `script.scriptapp` | UNVERIFIED |

- Explicit scopes: set `oauthScopes` in the manifest; otherwise Apps Script auto-detects them from the code. `[doc]` https://developers.google.com/apps-script/concepts/scopes So **using `GmailApp` forces `mail.google.com`; using the Advanced Gmail service (`Gmail.Users.Drafts.send`) permits `gmail.compose`.** The Advanced service must be declared in the manifest (`dependencies.enabledAdvancedServices`), and for a default Cloud project "The API is enabled automatically when you add the service". `[doc]` https://developers.google.com/apps-script/guides/services/advanced Whether that auto-enable happens for a project made via `updateContent` rather than the editor is UNVERIFIED (E8).
- **The script's own Gmail authorization cannot be granted from inside the native app.** The app's token never authorizes the script's triggers; the script has its own consent, given in the editor. (`scripts.run` is the one case where the calling token authorizes execution, and that is the route that cannot create triggers.) `[doc]` execute page.
- Consent screen: the script requests restricted/sensitive scopes, so a gmail.com owner who authorizes it sees the unverified-app screen: Google's own table lists "Publisher is a Gmail account / User is a Gmail account" as "Unverified auth flow". `[doc]` https://developers.google.com/apps-script/guides/client-verification During development "you can continue past this warning by selecting Advanced > Go to {Project Name} (unsafe)." `[doc]` https://developers.google.com/apps-script/api/troubleshoot-authentication-authorization The unverified-user cap is irrelevant for one user. "You can use restricted scopes freely for non-public apps." `[doc]` https://developers.google.com/apps-script/concepts/scopes
- Granular consent lets the user untick scopes; an unticked scope makes the later trigger run fail "immediately with an 'Authorization is required to perform that action.' error". `[doc]` same page.

**One-off versus recurring triggers: timing**

- `ClockTriggerBuilder.at(date)`: "Specifies when the trigger runs." No precision stated. `after(ms)`: "The actual duration might vary, but won't be less than your specified minimum." (never early). `atDate`: "by default near midnight (+/- 15 minutes)". `nearMinute`: "plus or minus 15 minutes", and "If `nearMinute()` is not called, a random minute value is used." `everyMinutes(n)`: n must be 1, 5, 10, 15 or 30. `[doc]` https://developers.google.com/apps-script/reference/script/clock-trigger-builder (updated 2026-04-13)
- Time-driven triggers "as frequently as every minute"; "The time might be slightly randomized—for example, if you create a recurring 9 AM trigger, Apps Script chooses a time between 9 AM and 10 AM". `[doc]` https://developers.google.com/apps-script/guides/triggers/installable
- Observed by one developer: a trigger set for 00:00:00 ran at about 00:00:10, and sometimes 00:01:30. `[2nd]` https://github.com/tanaikech/TriggerApp
- INFERENCE: a recurring `everyMinutes(5)` poll sends a due draft between 0 and 5 minutes late plus jitter; a one-off `at()` trigger is probably a minute or two late but has no documented bound. The poller is the more predictable choice and avoids the 20-trigger ceiling.
- Triggers created from inside another trigger's function have been reported to fail in V8 (a Medium post I could not open: HTTP 403). UNVERIFIED, so do not daisy-chain triggers.

**Quotas that matter** `[doc]` https://developers.google.com/apps-script/guides/services/quotas (updated 2026-09-03)

| Quota | Consumer (gmail.com) | Workspace |
|---|---|---|
| Triggers per user per script | 20 | 20 |
| Triggers total runtime | **90 min/day** | 6 hr/day |
| Email recipients per day ("for example, with MailApp") | **100/day** | 1,500/day |
| Script runtime per execution | 6 min | 6 min |
| Apps Script projects created | 50/day | 50/day |

- The page says "Using a product's Apps Script service counts toward all associated quota reserves." So a send through `GmailApp` also counts toward Gmail's own limit (over 500 emails or recipients a day gives a 1 to 24 hour block `[doc]` https://support.google.com/mail/answer/22839). Whether `GmailDraft.send()` or `Gmail.Users.Drafts.send` counts toward the Apps Script "email recipients" quota at all is UNVERIFIED (E8). Gmail API cost of `drafts.send` is 100 units. `[doc]` https://developers.google.com/workspace/gmail/api/reference/quota
- INFERENCE for the 90-minute budget: a tick that touches no Google service (queue held in the script source) should cost a fraction of a second; 288 ticks/day at 5 minutes is far under the cap, 1,440/day at 1 minute is probably under it, but run time is metered in a way the page does not describe (E7).
- No documented daily limit for `scripts.run` or `projects.updateContent` calls; UNVERIFIED.

**Failure behaviour**

- A failed trigger run shows no on-screen error; Apps Script emails "Summary of failures for Apps Script" from `noreply-apps-scripts-notifications@google.com`, with a link to deactivate or reconfigure the trigger; "While a trigger is active, you can only adjust the frequency of these notifications." `[doc]` https://developers.google.com/apps-script/guides/triggers/installable The default frequency for a code-created trigger is UNVERIFIED.
- No automatic retry is documented. UNVERIFIED.
- **The client can find out.** `processes.listScriptProcesses` (scope `script.processes`) returns every run with `functionName`, `startTime`, `duration`, `processType` (`TIME_DRIVEN` for a clock trigger) and `processStatus` (`RUNNING`, `COMPLETED`, `FAILED`, `TIMED_OUT`, `CANCELED`, `PAUSED`, `UNKNOWN`, and **`DELAYED`: "waiting for quota"**), with filters on function, type, status and time. `[doc]` https://developers.google.com/apps-script/api/reference/rest/v1/processes History retention is not stated. `projects.getMetrics` (scope `script.metrics`) returns active users, total executions and failed executions, daily or weekly. `[doc]` https://developers.google.com/apps-script/api/reference/rest/v1/projects/getMetrics

**What administrators can block** (Workspace only)

- Turning Apps Script off for users: "People in your organization can't create or edit scripts." and "Script and trigger executions are blocked … Blocked trigger executions include simple triggers and installable triggers." On by default; changes take up to about 24 hours. `[doc]` https://knowledge.workspace.google.com/admin/users/access/turn-apps-script-on-or-off-for-users
- API-permission settings control scripts that request Gmail, Calendar or Drive scopes, plus separate "Apps Script Runtime" and "Apps Script API" controls. `[doc, 2018]` https://workspaceupdates.googleblog.com/2018/08/apps-script-projects.html Admins can also restrict nine Gmail scopes for third-party apps (includes `mail.google.com`), and "Trust internal apps" lets org-built apps use restricted APIs. `[doc]` https://knowledge.workspace.google.com/admin/apps/control-which-apps-access-google-workspace-data Whether a user's own script counts as a third-party app under those rules is not stated in what I fetched. UNVERIFIED.
- Apps Script projects whose owner and users are in the same Workspace domain are exempt from OAuth client verification. `[doc]` client-verification page.
- Deleting the associated Cloud project stops all executions of a script. `[doc]` https://developers.google.com/apps-script/guides/admin/monitor-use

**Consumer versus Workspace; protected accounts**

- Both work in principle: the quota tables and the unverified-flow table cover gmail.com and Workspace.
- **Advanced Protection Program:** "Only verified third-party apps can access sensitive data on your Google Account" and "If scripts request access to certain data in your account, like emails … they may be blocked." `[doc]` https://support.google.com/accounts/answer/7539956 An account in that program would also block this native client itself (unverified OAuth client).

**Prior art that this pattern works without a server.** Apps Script Gmail schedulers exist and describe themselves as running "entirely on Google's infrastructure": `easy-gmail-scheduler` (needs the user to deploy it and enable the Gmail API by hand) `[2nd]` https://github.com/flyboy101/easy-gmail-scheduler; a Google Workspace Marketplace "Email Scheduler for Gmail" add-on exists (not examined). Google itself published "Gmail Snooze with Apps Script" on 27 Jul 2011 (page body did not load; title and date only). https://gsuite-developers.googleblog.com/2011/07/gmail-snooze-with-apps-script.html

### 2.2 What it costs the user in trust

- A script in their Drive with a Gmail permission. With the narrow design it is `gmail.compose`: it can read their drafts and **send mail as them**, but cannot read the inbox. With `GmailApp` it is `mail.google.com`: read, send and permanently delete everything. With snooze and reminders it is `gmail.modify`: read and relabel everything.
- It keeps running as a **persistent server-side agent that survives revocation of the app's own OAuth access.** Revoking the app in Google Account settings does not stop the script's trigger; the user must delete the trigger (script.google.com, "My Triggers"), delete the script, or revoke the script's own permission. `[doc]` https://developers.google.com/apps-script/guides/triggers/installable ("To review all of the triggers… script.google.com")
- If the app holds `script.projects`, a stolen app token can rewrite that script and therefore run code with the script's scopes. Google states the same worry: an authorized malicious app "proceeds to create more malicious scripts or modify the behavior of scripts you already have". `[doc]` enable page.
- Three browser visits the user would not otherwise make: the Apps Script settings toggle, the editor Run, the "unverified app" warning.

### 2.3 Verdict

**WORKS WITH SETUP** for the poller. **UNVERIFIED end to end.** The documented pieces: create the project, write the code, trigger runs HEAD, trigger created by hand in the editor, `drafts.send` from the script, `processes` readable by the app. The undocumented or contradicted pieces: whether the script's Advanced Gmail service works in an API-created project, whether a gmail.com consent for these scopes completes, how late a 5-minute tick actually is, whether the authorization lapses (weekly or on password change). Variants:

| Variant | Verdict |
|---|---|
| Recurring poller trigger (every 5 min, or 1 min), queue held in the script or in Gmail | **WORKS WITH SETUP** (recommended) |
| One trigger per scheduled message (`at(date)`) | **WORKS WITH SETUP, worse**: at most 20 outstanding per script, precision undocumented, cleanup of fired triggers UNVERIFIED |
| `scripts.run` installs the trigger | **NOT POSSIBLE per documentation**; plus needs a manual Cloud-project switch (E5 to confirm) |
| Web-app endpoint installs the trigger | **UNVERIFIED**, and still needs a browser authorization first |
| Fully automatic setup with no browser step | **NOT POSSIBLE** |

### 2.4 The exact sequence ("never set up" to "scheduled for tomorrow 8 am")

Design A below keeps the queue in the script's own source. Every step is documented. Design B (end of this section) trades that for less standing authority.

**One-time setup**

1. User turns on the **Google Apps Script API** at https://script.google.com/home/usersettings. *(user, browser, cannot be automated)*
2. App runs an installed-app OAuth flow (PKCE) for `script.projects` and `script.processes`. Incremental authorization is not supported for installed apps, so this is a fresh consent that returns its own refresh token. (Earlier dossier §12.5.) The app's Cloud project must have the Apps Script API enabled and these scopes on its consent screen.
3. `POST https://script.googleapis.com/v1/projects` with `{"title":"Banana scheduled send"}` returns `scriptId`.
4. `PUT https://script.googleapis.com/v1/projects/{scriptId}/content` with three files: the manifest, `Code.gs`, `queue.gs`.

   ```json
   // appsscript (type JSON)
   {"timeZone":"Etc/UTC","runtimeVersion":"V8","exceptionLogging":"STACKDRIVER",
    "dependencies":{"enabledAdvancedServices":[{"userSymbol":"Gmail","version":"v1","serviceId":"gmail"}]},
    "oauthScopes":["https://www.googleapis.com/auth/gmail.compose",
                   "https://www.googleapis.com/auth/script.scriptapp"]}
   ```
   ```javascript
   // Code.gs (type SERVER_JS). Static; the app uploads it unchanged. Sketch, signatures UNVERIFIED.
   function install() {                       // the user runs this once, in the editor
     ScriptApp.getProjectTriggers().forEach(function (t) { ScriptApp.deleteTrigger(t); });
     ScriptApp.newTrigger('tick').timeBased().everyMinutes(5).create();
   }
   function tick() {
     var now = Date.now();
     QUEUE.forEach(function (e) {             // QUEUE is defined in queue.gs
       if (e.at > now) return;                // not due
       if (now - e.at > e.maxLateMs) return;  // too late: leave the draft; the app will ask
       try { Gmail.Users.Drafts.send({ id: e.draft }, 'me'); }
       catch (err) { if (!/not found|404/i.test(String(err))) throw err; }  // spent or deleted: fine
     });
   }
   // queue.gs, rewritten by the app on every change:  var QUEUE = [{draft:"r-123",at:1791446400000,maxLateMs:1800000}];
   ```
5. App shows a link to `https://script.google.com/d/{scriptId}/edit`. User opens it, selects `install` in the toolbar, presses **Run**, then **Review permissions**, picks the account, **Advanced**, **Go to "Banana scheduled send" (unsafe)**, **Allow**. The script now has its own authorization and one `tick` trigger. *(user, browser, cannot be automated)*
6. App verifies after about 6 minutes: `GET https://script.googleapis.com/v1/processes:listScriptProcesses?scriptId={scriptId}&scriptProcessFilter.functionName=tick&scriptProcessFilter.types=TIME_DRIVEN` shows a `COMPLETED` process. Until it does, the UI says "Send later is not active on Google's side" and uses the device-held path.

**Schedule a message for tomorrow 8:00**

7. App saves the final draft with `drafts.create` or `drafts.update` (existing flow), keeping `draftId` and the draft message's `Message-ID`.
8. App rewrites `queue.gs` with the entry `{draft, at: epoch ms, maxLateMs}` by resending all three files through `PUT .../content`. It also stores the schedule on the device and in the draft headers as now.
9. At 08:00 plus up to one tick plus jitter, Google runs `tick`; it calls `drafts.send`; the draft is consumed; the message goes to Sent.

**Cancel or edit before then**

- *Edit text:* `drafts.update` on the same draft id; the script sends whatever the draft holds when it fires. *Edit the time:* rewrite `queue.gs`.
- *Cancel and keep a draft:* `drafts.create` a copy (new id), then `drafts.delete` the old id, then drop the entry from `queue.gs`. A tick that fires in between hits a deleted draft id and does nothing. Rewriting the queue alone is racy, because a tick can already be running.
- *Cancel and discard:* `drafts.delete`, then rewrite the queue.
- Both rely on a draft id being spendable once, which the current design already assumes (MAIL-ENGINE §7.6, probe W4/D8).

**Learn afterwards whether it was sent**

1. The draft id is gone **and** a message with the draft's `Message-ID` is in Sent (`messages.list q=rfc822msgid:<id> in:sent`), which the design already uses. Whether Gmail preserves the draft's `Message-ID` on send is UNVERIFIED (E13).
2. `processes.listScriptProcesses` for `FAILED`, `TIMED_OUT`, `DELAYED` or `CANCELED` runs of `tick` around the due time.
3. The failure-summary email from `noreply-apps-scripts-notifications@google.com` (search for it in the inbox the client already reads).
4. **Backstop:** if the draft still exists 10 to 15 minutes after `at`, the device that scheduled it (or any device) shows "Not sent yet" and offers Send now. Because the script sends first, the device must not also send inside the script's window, otherwise it risks the double-send in D8.

**Design B (less standing authority).** Keep the queue in one JSON "queue draft" the app updates with `drafts.update`; the script reads it with `drafts.get` each tick (scope `gmail.compose` already covers it). The app then needs `script.projects` only during setup and can drop it, and a stolen app token can no longer rewrite the script. Costs: a visible draft in everyone's Drafts, one Gmail call per tick, and last-writer-wins when two devices edit the queue at once. Which is better is a live decision (E3, E7).

---

## 3. Avenue 3: other things that run on Google's side

### 3.1 Cloud Scheduler, Cloud Tasks, Cloud Run in a project the user owns

This is a backend; it is only "serverless" in that Google operates it.

- **Smallest honest version:** one Cloud Run function with two endpoints (`schedule`, `send`), a Cloud Tasks queue, and Secret Manager holding the user's Gmail **refresh token**. The app calls `schedule` with `{draftId, sendAt}`; the function creates a Cloud Task with `scheduleTime`; at that time the task calls `send`, which refreshes the token, calls `drafts.send`, and returns an error so Cloud Tasks retries. A service account cannot act for a consumer gmail.com user (domain-wide delegation is Workspace-only), so a stored refresh token is unavoidable. Failures appear in Cloud Logging and in the task's attempt history.
- Cloud Tasks: "Maximum schedule time for a task: 30 days from current date and time". `[doc]` https://docs.cloud.google.com/tasks/docs/quotas Free tier 1,000,000 operations/month. `[doc]` https://cloud.google.com/tasks/pricing
- Cloud Scheduler: "Each Google billing account gets 3 jobs per month free." `[doc]` https://cloud.google.com/scheduler/pricing (a job is a fixed cron entry, not a one-off timer, so Tasks fits better).
- Cloud Run: 2 million requests/month free (instance-based billing differs; see the page). `[doc]` https://cloud.google.com/run/pricing Secret Manager: 10,000 free access operations/month. `[doc]` https://cloud.google.com/secret-manager/pricing
- Needs a Cloud project with a billing account (the free tiers are applied per billing account); exact wording on a card being mandatory not checked. UNVERIFIED. Cost at one person's volume: effectively zero.
- Trust cost: a refresh token for `gmail.compose` or wider sits in Secret Manager; the HTTPS endpoint is internet-facing and needs its own authentication. Whether Google's restricted-scope review wording ("from or through a third-party server") applies to a single-user, self-run server is UNVERIFIED (the earlier dossier §12.2 raised the same question).
- Cloud Tasks can attach an `Authorization` header to its HTTP call, but a Gmail access token lives about an hour, so a task for "tomorrow 8 am" cannot carry one; a refresh-token holder is required.
- **Verdict: WORKS WITH SETUP, but it is a server we would run.** The user's own phrase was "queue that up on the google side"; this is on Google's infrastructure but under our account and our code.

### 3.2 Workspace Studio (formerly Flows), AppSheet, Calendar, Tasks, Events APIs

| Product | Finding | Verdict |
|---|---|---|
| **Google Workspace Studio** | Schedule starter plus a Gmail "Send an email" step ("compose and send a new email"). "Draft an email" only drafts a reply. No step sends an existing draft. Developer docs cover custom steps/starters (add-ons), not creating or triggering flows externally. `[doc]` https://support.google.com/workspace-studio/table/17176961 and https://developers.google.com/workspace/add-ons/workflows | **NOT POSSIBLE** for this (no API, no draft send) |
| Studio availability | Work and school: Business Starter/Standard/Plus, Enterprise Standard/Plus, Education editions; "Personal accounts: currently available for users with Google Workspace Experiments". `[doc]` https://support.google.com/workspace-studio/answer/16444479 | not for ordinary gmail.com |
| **AppSheet automation** | Emails are "sent individually to each recipient from amp-noreply@appsheet.com" (the From field is only a display address). `[doc]` https://support.google.com/appsheet/answer/11511240 Schedule events and email sending "are not fully supported until you purchase a subscription". `[doc]` https://support.google.com/appsheet/answer/11432969 | **NOT POSSIBLE** (wrong sender, paid) |
| **Google Calendar as a timer** | Push notifications fire "whenever a watched resource changes", not at event start; webhook must be HTTPS; channels expire and must be renewed. `[doc]` https://developers.google.com/workspace/calendar/api/guides/push Apps Script's Calendar trigger fires "when a calendar entry is created, updated, or deleted". `[doc]` https://developers.google.com/apps-script/reference/script/calendar-trigger-builder | **NOT POSSIBLE** as a trigger |
| Calendar as a *notifier* | `reminders.overrides[].method` may be `email` or `popup`, 0 to 40320 minutes before, at most 5 overrides. `[doc]` https://developers.google.com/workspace/calendar/api/v3/reference/events This can tell the user at a set time on Google's side, but cannot send or check anything. | **WORKS for "remind me" as a plain notification only** |
| **Google Tasks** | `due` stores date only: "the time portion of the timestamp is discarded … It isn't possible to read or write the time that a task is scheduled for using the API." `[doc]` https://developers.google.com/workspace/tasks/reference/rest/v1/tasks | **NOT POSSIBLE** as a timer |
| **Workspace Events API** | Sources are Chat, Drive and Meet only (Calendar, Gmail, Tasks not listed); delivery by Pub/Sub; no time-based event type. `[doc]` https://developers.google.com/workspace/events | **NOT POSSIBLE** |
| **Gmail `users.watch`** | Push on mailbox change through Pub/Sub; not a clock; "poll-based … is still the recommended approach" for user devices; renew at least every 7 days. `[doc]` https://developers.google.com/workspace/gmail/api/guides/push | **NOT POSSIBLE** as a timer |
| Gmail vacation responder | Has `startTime`/`endTime`, but only replies to mail received in the window. `[disc]` | **NOT POSSIBLE** for sending |
| People API | Contacts data only. | **NOT POSSIBLE** (no timer surface found) |

---

## 4. Avenue 4: mail protocols

- I opened a TLS session to `smtp.gmail.com` on ports 587 (STARTTLS) and 465 on 2026-10-06 and read the EHLO reply. No authentication, no mail sent. `[probe]`

  ```
  250 smtp.gmail.com at your service
  SIZE 35882577 / 8BITMIME / AUTH LOGIN PLAIN XOAUTH2 PLAIN-CLIENTTOKEN OAUTHBEARER XOAUTH
  ENHANCEDSTATUSCODES / PIPELINING / CHUNKING / SMTPUTF8
  ```
- **No `FUTURERELEASE` (RFC 4865), no `DELIVERBY` (RFC 2852).** Both ports gave the same list. This was the pre-authentication list; Gmail normally returns the same list after AUTH, but I did not authenticate (E18).
- A `Date` header or any custom "send at" header on a submitted message is not interpreted by Gmail as a delivery time. I found no documentation or report that any such header is honoured. UNVERIFIED but no evidence for it.
- **Verdict: NOT POSSIBLE.**

---

## 5. Avenue 5: where other clients make the message wait

Evidence of what is possible, not a recommendation.

| Client | Where the message waits | Source |
|---|---|---|
| **Gmail web and mobile** | Google's servers (Scheduled folder, 100 cap) | https://support.google.com/mail/answer/9214606 `[doc]` |
| **Mimestream** | No scheduled send in its release notes through 1.10.8 (4 Sep 2026). Snooze is local and notifies at the time. | https://mimestream.com/releases , https://mimestream.com/help/user-guide/snoozing `[2nd]` |
| **Apple Mail** | Apple's Mac guide describes a "Send Later" mailbox in the sidebar and says nothing about where it waits (UNVERIFIED from Apple). Secondary reports say it is on-device: "keep your device online to ensure email delivery"; the Mac must be on (asleep is fine through Power Nap) and online; Mail need not be open. | https://support.apple.com/guide/mail/send-email-messages-mlhlp1098/mac `[doc]` for the mailbox; https://9to5mac.com/2022/09/29/send-later-with-mail-iphone/ `[2nd]` for the rest |
| **Thunderbird "Send Later" add-on** | On the computer: "Thunderbird must be running for scheduled messages to be sent". Its documented "Server-side Send Later" is to leave a second Thunderbird running on a server you own. It also warns it "doesn't work with mail servers that discard or don't return its X-Send-Later headers". | https://extended-thunder.github.io/send-later/ `[doc]` (add-on's own docs) |
| **Spark** | Readdle's servers: "The scheduled emails are stored on our server in the encrypted form" and "the email will be sent even if Spark is closed"; up to 6 months ahead. | https://support.readdle.com/spark/sending-emails/schedule-an-email-to-send-later `[doc]` |
| **Superhuman** | Implied server-held: "If you scheduled an email to send before going offline, the email will send [at the] scheduled time." Offline-created sends go when the device reconnects. | https://help.superhuman.com/hc/en-us/articles/38458300297875-Offline-Access `[doc]` |
| **Shortwave** | Undo-send is server-held ("Even if you close your Shortwave app or go offline, your message will still send"). The blog does not say where a scheduled send waits. UNVERIFIED. | https://www.shortwave.com/blog/announcing-scheduled-send-and-undo-send/ `[doc]` |

Pattern: clients with no server of their own (Mimestream, Apple Mail, Thunderbird) hold it on the device or do not offer it; clients that offer true "device off" run a server holding the user's mail credentials.

---

## 6. Avenue 6: snooze return and "remind me if nobody replied"

The Apps Script poller handles both with the same trigger. Entries in the same queue:

- **Snooze returns:** `{type:"unsnooze", thread, at}` and the script does `Gmail.Users.Threads.modify({addLabelIds:["INBOX","UNREAD"]}, "me", thread)`. The app archived the thread (removed INBOX) when it was snoozed. `threads.modify` accepts `gmail.modify` and `mail.google.com`, not `gmail.compose`. `[disc]`
- **Remind if no reply:** `{type:"remind", thread, since, label, at}`. At the time the script reads the thread (`threads.get`, format metadata, headers From and Date; scopes `gmail.modify`, `gmail.readonly`, `gmail.metadata`, `mail.google.com`) and checks whether any message newer than `since` is from someone other than the user. If none, it does the same `threads.modify` (INBOX and UNREAD, plus a user label the app can show as "nobody replied"). If a reply came, it does nothing. `[disc]`

Differences from sending:

| | Send later | Snooze return | Remind if no reply |
|---|---|---|---|
| Minimum Gmail scope in the script | `gmail.compose` (cannot read the inbox) | `gmail.modify` | `gmail.modify` |
| Worst outcome of a wrong or duplicate firing | An email goes out, irreversible and visible to others | A thread reappears in the Inbox, reversible | A thread reappears with a label, reversible |
| If it never fires | Message not sent (severe) | Thread stays hidden (looks like a lost mail) | Reminder missing |
| Standing authority if the script is hijacked | Send as the user, read drafts | Read and relabel all mail | Read and relabel all mail |

- **The scopes are baked in at the editor consent.** Adding snooze or remind later means changing `oauthScopes` and a second browser consent. Decide up front: either ask for `gmail.modify` from the first install (it also covers `drafts.send`, `[disc]`), or run two scripts with separate consents.
- Gmail's own snooze cannot be created through the API (section 1). Whether `in:snoozed` messages are visible through the API is UNVERIFIED (E2).
- A local-only fallback is what Mimestream does (notification plus move to top of Inbox when the app runs). `[2nd]`
- **Calendar email reminders** (section 3.2) can notify the user at a set time with no script, but cannot do the "only if nobody replied" check.

---

## 7. Comparison table

"Devices off" means the user's own phone, tablet and Mac are all powered off.

| Mechanism | Works with all devices off | Timing accuracy | User setup | Extra OAuth scopes and class | Consumer and Workspace | Failure visibility | Attacker gain if compromised |
|---|---|---|---|---|---|---|---|
| **Gmail Schedule send in Gmail's own UI (hand-off)** | Yes (inference, high) | "a few minutes after" `[doc]` | Per message: open draft in Gmail, press Schedule send | None | Both | In Gmail ("Scheduled" folder); visible to API as `in:scheduled` `[2nd]` | Nothing new |
| **Gmail API scheduled send** | n/a | n/a | n/a | n/a | n/a | n/a | **Does not exist** |
| **Apps Script poller (recommended candidate)** | Yes `[doc]` triggers run server-side; UNVERIFIED live | Poll interval (1 or 5 min) plus undocumented jitter; never early | Apps Script API toggle; browser Run and "unverified app" consent; ongoing nothing | `script.projects` (+`script.processes`) UNVERIFIED class; script: `gmail.compose` or `gmail.modify` (restricted) or `mail.google.com` (restricted) and `script.scriptapp` | Consumer: 90 min/day trigger runtime, 100 recipients/day (Apps Script mail). Workspace: 6 hr, 1,500; admin can disable Apps Script or Gmail-scope apps | `processes` API (FAILED, DELAYED), failure email, draft still present after due time | Persistent code running as the user with the script's Gmail scope, surviving revocation of the app; with `script.projects` the app token can rewrite it |
| Apps Script, one `at()` trigger per message | Yes (UNVERIFIED) | Undocumented; reported 10 s to 1.5 min late `[2nd]` | Same | Same | 20 triggers per script cap | Same | Same |
| Apps Script via `scripts.run` or web app to install trigger | Only if install works | n/a | Manual Cloud-project switch plus browser authorization anyway | n/a | n/a | n/a | n/a. **Documented as impossible** ("cannot create … triggers") |
| **Cloud Tasks plus Cloud Run plus Secret Manager** | Yes | Seconds to a minute (UNVERIFIED; Tasks `scheduleTime` ≤ 30 days) | Cloud project with billing, deploy function, store refresh token, authenticate the app to it | App: none beyond Gmail; function holds a refresh token (`gmail.compose` or wider, restricted) | Both (consumer needs a stored refresh token; DWD is Workspace-only) | Cloud Logging, task retries | Refresh token plus an internet endpoint: send as the user, possibly read mail |
| Workspace Studio flows | Yes | Schedule starter (unspecified) | UI only | n/a | Workspace editions only | In Studio | n/a. **No API, cannot send a draft** |
| AppSheet automation | Yes | Unspecified | App plus paid subscription | n/a | n/a | In AppSheet | Wrong sender (amp-noreply@appsheet.com). **Not suitable** |
| Calendar or Tasks timer | No trigger at event time | n/a | n/a | n/a | n/a | n/a | **Cannot trigger anything** |
| SMTP `FUTURERELEASE` / `DELIVERBY` | n/a | n/a | n/a | n/a | n/a | n/a | **Not advertised** `[probe]` |
| **Device-held (current design)** | **No** | Next time the owner device runs | None | None | Both | Other devices show "not sent yet" | Nothing new |
| Own server (Spark, Superhuman model) | Yes | Seconds | Account at a vendor or our own server | Refresh token held server-side (restricted scopes; CASA assessment applies to third-party servers per the earlier dossier §12.2) | Both | Server logs | Everything the token allows |

---

## 8. Risks that would make it silently fail, and how the client detects each

| # | Risk | Detection by the client |
|---|---|---|
| 1 | The user deletes the script or the trigger, or turns the Apps Script API or Apps Script off (Workspace admin) | No `TIME_DRIVEN` process of `tick` in the last 2 intervals (`processes.listScriptProcesses`); `projects.get` returns 404; `scripts` calls fail. Show "Send later is not active on Google's side" and fall back to device-held. |
| 2 | Script authorization lapses or is revoked (password change, "Security checkup" removal, admin restriction, weekly expiry if it applies) | `processStatus = FAILED`; failure email; "Authorization is required to perform that action" `[doc]`. Whether the 7-day expiry applies to scripts on a default Cloud project, and whether a password change breaks triggers, is UNVERIFIED (E10, E11). |
| 3 | Daily trigger runtime (90 min consumer) or the Apps Script email-recipient quota (100 consumer) exceeded | `DELAYED` or `FAILED` processes; exception text "Service using too much computer time for one day" or "Limit exceeded: Email…" `[doc]`; a due draft still exists. |
| 4 | Trigger late beyond tolerance (jitter, Google incident) | Draft still exists more than 10 to 15 minutes after `at`; the process list shows no run near `at`. Device backstop sends or asks. |
| 5 | Bad code upload (`updateContent` replaces HEAD; a syntax error kills every tick) | `FAILED` process right after an upload; the app should wait for one `COMPLETED` tick after every upload before reporting "scheduled on Google's side". |
| 6 | Race: script and device both send the same draft | Existing risk D8; keep the device out of the script's window; confirm with probe W4/E12. |
| 7 | Draft edited or deleted in another Gmail client | Script's `drafts.send` gets 404 and skips (by design); the app sees the draft change on its next sync. |
| 8 | Queue write fails after the draft is saved (network drop) | The app keeps the entry locally as unconfirmed and re-sends the queue upload until acknowledged; the UI says "waiting to confirm with Google". |
| 9 | Advanced Gmail service missing in an API-created project, or the API not enabled in the hidden default Cloud project | First `tick` after install `FAILED`; step 6 of setup catches it before any real message is scheduled. |
| 10 | Script "disabled" by Google after repeated failures, or after long inactivity | UNVERIFIED; the same missing-ticks detection (risk 1). |
| 11 | Advanced Protection account | Script requests blocked `[doc]` https://support.google.com/accounts/answer/7539956; consent fails at setup step 5. |
| 12 | The user's timezone or DST confuses the due time | Store absolute epoch milliseconds, never a wall-clock string. |
| 13 | Gmail-side scheduled message (made in Gmail's UI) mistaken for an ordinary sent message | Query `in:scheduled`, not just SENT (E1). |

---

## 9. What to try on a live account before trusting it

Use a throwaway gmail.com account first, then a Workspace account. One experiment per uncertain fact.

| ID | Fact to settle | Smallest experiment |
|---|---|---|
| **E1** | How Gmail's native scheduled send and snooze look to the API | Schedule one message in Gmail web and one in the iOS app; snooze one thread. Call `labels.list`, `messages.list?q=in:scheduled`, `messages.get` (labelIds), `drafts.list`, `threads.list?q=in:snoozed`, `history.list`. Then try `messages.trash`, `messages.delete`, `messages.modify` on the scheduled one: does it cancel? |
| **E1b** | Does `sendAt` exist? | Authenticated `POST messages/send?sendAt=2026-10-08T08:00:00Z` with a real draft body: a 400 "Unknown name" settles it. Use a self-addressed message. |
| **E2** | Is a `SNOOZED` label present, and does an unsnoozed message gain one? | Part of E1. |
| **E3** | `projects.create` plus `updateContent` from a native client | With the toggle off, confirm the error and its timing; with it on, create a project and read it back; confirm the manifest is accepted. |
| **E4** | The trigger runs with all devices off | Do setup (steps 1 to 6); power off every device for 2 hours; then read `processes` for `tick` entries and confirm a test draft addressed to yourself was sent on time. |
| **E5** | Can `scripts.run` install a trigger? | Switch the script to the app's standard Cloud project, deploy as API executable, call `scripts.run install` with a token that includes `script.scriptapp`. Check whether the trigger exists (`ScriptApp.getProjectTriggers()`) and fires. Expected per docs: it does not. |
| **E6** | Timing | Record `startTime` of 200 or more ticks at 1 and at 5 minutes, plus 20 one-off `at()` triggers, against intended times. Report the median and 99th percentile of lateness and the earliest-ever fire. |
| **E7** | Runtime budget | Over 7 days sum `duration` of `tick` processes; compare with 90 minutes; look for `DELAYED`. Repeat with a queue of 0, 10 and 50 entries. |
| **E8** | Advanced Gmail service in an API-created project; which email quota counts | Send a draft from `tick` through `Gmail.Users.Drafts.send`; check it works with `gmail.compose` only. Then send 101 recipients' worth in a day through each of `Drafts.send` and `GmailApp.sendEmail`; see which hits "Limit exceeded". |
| **E9** | Failure behaviour | Revoke the script's authorization at myaccount.google.com/permissions; note the process status, how long the failure email takes, whether the trigger disables itself, and the exact re-authorization steps. |
| **E10** | Does authorization expire weekly? | Leave the script untouched 14 days; look for `FAILED` after day 7. |
| **E11** | Does a password change break the trigger? | Change the test account's password; watch the next ticks. |
| **E12** | Double send (D8) | Two clients call `drafts.send` on one draft id at the same instant, 20 times; count messages in Sent. |
| **E13** | `Message-ID` survives the send | Compare the draft's `Message-ID` header with the Sent message's. |
| **E14** | Custom headers survive on drafts (Design B and the existing design) | `drafts.create` with `X-Banana-Send-At`; `drafts.get format=metadata&metadataHeaders=X-Banana-Send-At`. |
| **E15** | Workspace limits | On a Workspace test domain: switch Apps Script off (expect trigger blocked); restrict Gmail scopes in API controls (does the script's consent fail?); try an Internal OAuth client. |
| **E16** | `script.projects` class and consent text | Open the Cloud Console consent-screen scope picker; note the class of `script.projects`, `script.processes`, `script.scriptapp`; screenshot the editor consent text. |
| **E18** | Post-auth SMTP capabilities | `EHLO` after `AUTH XOAUTH2`; try `MAIL FROM:<a@b> HOLDFOR=60` and expect rejection. |

---

## 10. What this means for the design (brief)

- Keep MAIL-ENGINE §7.6's device-held send as the guaranteed baseline. Do not describe it as "sends even if every device is off".
- Offer "Send later on Google's side" as an optional, per-account setup: Apps Script poller, Design A or B, off until step 6 of setup has seen a `COMPLETED` tick, with `processes` monitored and the device as the late backstop (10 to 15 minutes after `at`). Until E4 to E9 pass, nothing here should be a shipped promise.
- Independently of all this: make the client query `in:scheduled` so messages scheduled in Gmail's own apps show as scheduled, not sent (E1), and consider a "Schedule in Gmail" hand-off as the zero-scope alternative.
- If snooze return and "remind me" are in the first release and are to ride this mechanism, ask for `gmail.modify` in the script from the start, because adding scopes later costs a second browser consent.

---

## 11. Sources

**Gmail**
- https://developers.google.com/workspace/gmail/api/release-notes
- https://gmail.googleapis.com/$discovery/rest?version=v1 (rev 20260928)
- https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages/send
- https://developers.google.com/workspace/gmail/api/guides/labels
- https://developers.google.com/workspace/gmail/api/guides/push
- https://developers.google.com/workspace/gmail/api/guides/configure-mcp-server
- https://developers.google.com/workspace/gmail/api/reference/quota
- https://support.google.com/mail/answer/9214606 (Schedule send)
- https://support.google.com/mail/answer/22839 (sending limits)
- https://support.google.com/accounts/answer/7539956 (Advanced Protection)

**Apps Script**
- https://developers.google.com/apps-script/api/how-tos/execute
- https://developers.google.com/apps-script/api/how-tos/enable
- https://developers.google.com/apps-script/api/reference/rest/v1/projects/create
- https://developers.google.com/apps-script/api/reference/rest/v1/projects/updateContent
- https://developers.google.com/apps-script/api/reference/rest/v1/scripts/run
- https://developers.google.com/apps-script/api/reference/rest/v1/processes
- https://developers.google.com/apps-script/api/reference/rest/v1/projects/getMetrics
- https://script.googleapis.com/$discovery/rest?version=v1 (rev 20260927)
- https://developers.google.com/apps-script/guides/triggers/installable
- https://developers.google.com/apps-script/reference/script/clock-trigger-builder
- https://developers.google.com/apps-script/reference/script/calendar-trigger-builder
- https://developers.google.com/apps-script/reference/script/script-app
- https://developers.google.com/apps-script/reference/gmail/gmail-draft
- https://developers.google.com/apps-script/guides/services/quotas
- https://developers.google.com/apps-script/guides/services/advanced
- https://developers.google.com/apps-script/guides/cloud-platform-projects
- https://developers.google.com/apps-script/concepts/scopes
- https://developers.google.com/apps-script/guides/client-verification
- https://developers.google.com/apps-script/api/troubleshoot-authentication-authorization
- https://developers.google.com/identity/protocols/oauth2/scopes
- https://developers.google.com/apps-script/guides/admin/monitor-use
- https://knowledge.workspace.google.com/admin/users/access/turn-apps-script-on-or-off-for-users
- https://knowledge.workspace.google.com/admin/apps/control-which-apps-access-google-workspace-data
- https://workspaceupdates.googleblog.com/2018/08/apps-script-projects.html
- https://gsuite-developers.googleblog.com/2011/07/gmail-snooze-with-apps-script.html (title and date only)

**Other Google products**
- https://docs.cloud.google.com/tasks/docs/quotas , https://cloud.google.com/tasks/pricing , https://cloud.google.com/scheduler/pricing , https://cloud.google.com/run/pricing , https://cloud.google.com/secret-manager/pricing
- https://support.google.com/workspace-studio/table/17176961 , https://support.google.com/workspace-studio/answer/16444479 , https://developers.google.com/workspace/add-ons/workflows
- https://support.google.com/appsheet/answer/11511240 , https://support.google.com/appsheet/answer/11432969
- https://developers.google.com/workspace/calendar/api/guides/push , https://developers.google.com/workspace/calendar/api/v3/reference/events
- https://developers.google.com/workspace/tasks/reference/rest/v1/tasks
- https://developers.google.com/workspace/events

**Other clients and third parties** `[2nd]` unless noted
- https://mimestream.com/help/user-guide/snoozing , https://mimestream.com/releases
- https://support.apple.com/guide/mail/send-email-messages-mlhlp1098/mac , https://9to5mac.com/2022/09/29/send-later-with-mail-iphone/
- https://extended-thunder.github.io/send-later/ (the add-on's own documentation)
- https://support.readdle.com/spark/sending-emails/schedule-an-email-to-send-later
- https://help.superhuman.com/hc/en-us/articles/38458300297875-Offline-Access
- https://www.shortwave.com/blog/announcing-scheduled-send-and-undo-send/
- https://support.nylas.com/hc/en-us/articles/33676452303005-How-can-I-identify-scheduled-emails-from-Gmail-UI-when-using-the-Nylas-API
- https://github.com/dsmorgan/netkeeper/pull/308 , https://github.com/openclaw/gogcli/issues/1006 , https://github.com/taylorwilsdon/google_workspace_mcp/issues/1082 , https://github.com/tanaikech/TriggerApp , https://github.com/flyboy101/easy-gmail-scheduler

**Probes run today (2026-10-06), reproducible**
- `EHLO` to `smtp.gmail.com:587` (STARTTLS) and `:465` (TLS), no auth.
- Unauthenticated `POST https://gmail.googleapis.com/gmail/v1/users/me/messages/send?sendAt=…` returned 401 (same as an unknown parameter).
- `https://gmail.googleapis.com/$discovery/rest?version=v1beta` returned 404.
- Raw copies of the fetched pages and discovery documents are in `send-later-evidence/` next to this file.

**Earlier dossier this builds on:** ~/orca/workspaces/gtfuwgth/stingray/docs/design/mail-working/research/gmail-api.md (§6.6, §10, §12) and MAIL-ENGINE.md §7.6.
