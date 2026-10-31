// Settings and secrets, from environment variables on every host (Worker vars/secrets, process.env).

/** @param {Record<string, string|undefined>} env */
export function configFrom(env) {
  return {
    /** Public archive for this exact deployed Git revision, never a moving branch. */
    sourceRevision: env.SOURCE_REVISION ?? "",
    sourceArchiveUrl: env.SOURCE_ARCHIVE_URL ?? "",
    /** Where Google sends change notices: `${publicUrl}/v1/google/notify`. Must be https. */
    publicUrl: String(env.PUBLIC_URL ?? "").replace(/\/+$/, ""),
    /** The browser app's own host; OAuth still returns through the API's registered callback. */
    webUrl: String(env.WEB_URL ?? "").replace(/\/+$/, ""),
    /** base64 of 32 bytes; encrypts Google refresh tokens. */
    tokenKey: env.TOKEN_KEY ?? "",
    /** The web OAuth client the app names as serverClientID. */
    googleClientId: env.GOOGLE_CLIENT_ID ?? "",
    googleClientSecret: env.GOOGLE_CLIENT_SECRET ?? "",
    /** Empty for codes from iOS Google Sign-In (to be confirmed at the first real sign-in). */
    googleRedirectUri: env.GOOGLE_REDIRECT_URI ?? "",
    /** The app's own OAuth clients (iOS, which the Mac shares), whose Google identity tokens sign
     * a device in without a sign-in sheet: full ids, comma-separated. Not secret. */
    googleAppClientIds: String(env.GOOGLE_APP_CLIENT_IDS ?? "").split(",").map((s) => s.trim()).filter(Boolean),
    /** The .p8 key's PEM text, its key id, and the team id. */
    apnsKey: env.APNS_KEY ?? "",
    apnsKeyId: env.APNS_KEY_ID ?? "",
    apnsTeamId: env.APNS_TEAM_ID ?? "",
    /** Event alerts from the service (docs/design/EVENT-ALERTS.md): "on" reads calendars and rings.
     * Off, the service reads no event and sends no alert; the devices' own alerts carry on. */
    eventAlerts: env.EVENT_ALERTS === "on",
    /** Keys the space ids in the change stream (DATA-PLATFORM.md §9). Unset: derived from TOKEN_KEY. */
    analyticsKey: env.ANALYTICS_KEY ?? "",
    /** The booking pages' address (docs/design/BOOKING.md §8): https://book.bananatheapp.com, or the
     * beta's. Unset: no booking routes. Its host is the only one the pages answer on (app.js). */
    bookUrl: String(env.BOOK_URL ?? "").replace(/\/+$/, ""),
    /** "book": every request is a booking one (a local run on one port). */
    serveAs: env.SERVE_AS ?? "",
    /** Turnstile's site key (public, on the page) and secret. No secret: unknown browsers are refused,
     * unless TURNSTILE_SKIP=1 says this is a local run (dev, tests). */
    turnstileSiteKey: env.TURNSTILE_SITE_KEY ?? "",
    turnstileSecret: env.TURNSTILE_SECRET ?? "",
    turnstileRequired: env.TURNSTILE_SKIP !== "1",
    /** Node behind a proxy that sets x-forwarded-for: TRUST_FORWARDED_FOR=1. Workers use Cloudflare's header. */
    trustForwardedFor: env.TRUST_FORWARDED_FOR === "1",
    /** Sender on the Cloudflare Email Sending domain (shared by booking and guest invitations). */
    emailFrom: env.EMAIL_FROM ?? "Banana <book@ce.bananatheapp.com>",
  };
}
