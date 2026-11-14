# Google Contacts setup for Banana Beta

Use the existing Google Cloud project that owns Banana's sign-in clients. Match
Google Auth Platform → Clients against the local `BANANA_GOOGLE_CLIENT`,
`BANANA_GOOGLE_CLIENT_BETA` and `BANANA_GOOGLE_SERVER_CLIENT` settings in
`Config/Local.xcconfig`. Credentials stay in the private configuration.

1. Open **APIs & Services → Library → Google People API** and enable it in that project.
2. Open **Google Auth Platform → Data Access → Add or remove scopes**. Add:

   ```text
   https://www.googleapis.com/auth/contacts.readonly
   https://www.googleapis.com/auth/contacts.other.readonly
   ```

   Save the selection alongside the app's existing scopes.
3. In **Audience**, if the project is in Testing, add every Google account used for
   Beta testing under Test users. If it is already in Production, retain that status.
4. Review **Verification Center** for any requirements introduced by the additional
   scopes. The current implemented use is reading contact email addresses and photos
   to match senders with saved contact images. Contacts are not edited. Use that
   description for the current feature; recipient search is separate app work.
5. In the updated Banana Beta, use the existing **Settings → Google account → Reconnect**
   action for connected Mail accounts. It requests the current permissions for enabled
   features in one Google consent flow. A reusable permission-upgrade prompt also offers
   that same Reconnect action when Mail's required Contacts access is missing. Approve
   Contacts access on Google's screen; refreshing calendars alone does not add scopes.
   Existing grants do not automatically gain scopes when console configuration changes.
6. Verify sender photos on the phone, iPad and Mac using the same linked account.
   Some contacts have no photo. Negative image/contact caches can delay a newly
   available photo; inspect the grant and service lookup before resetting anything.

The cloud service already reads contacts for sender photos, and the Mail consent
flow already requests these two read-only scopes. Current recipient autocomplete
searches prior mail correspondents, not Google Contacts. Enabling the API does not
by itself add Google Contacts recipient suggestions.

The existing native and web client IDs remain in place. If Beta uses a separate
Cloud project, repeat API and consent configuration there as well. A client secret
belongs only in the service's private configuration.

References: [People API setup](https://developers.google.com/people/v1/getting-started),
[OAuth consent configuration](https://developers.google.com/workspace/guides/configure-oauth-consent),
[contact search](https://developers.google.com/people/api/rest/v1/people/searchContacts).
