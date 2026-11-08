// Silent (and booking alert) pushes to every device of an account, through the APNs port. Used by
// the routes (src/app.js), the booking jobs and the shared cloud mailboxes (src/mailbox.js).

import { DEVICE_FEATURES, deviceHas } from "./device-features.js";

/** A push to every device of the account (but `except`), recording what APNs said of each
 * (`devices.pushed_at`, `push_status`): the evidence that a push went out, and where. Silent unless
 * `pushType` is "alert" (a booking's news to its host). A push about a `feature` (one of
 * DEVICE_FEATURES, src/device-features.js) goes only to the devices that have it: built in and
 * switched on. Without one it is about the app itself (calendars, sync, booking) and goes to all. */
export async function pushTo(deps, account, { payload, collapseId, except = null, label = "push", pushType, priority, feature = null }) {
  const { db, now } = deps;
  if (feature !== null && !DEVICE_FEATURES.includes(feature)) throw new Error(`push about an unknown feature: ${feature}`);
  const rows = await db.all(
    "SELECT id, platform, push_token, push_env, bundle, capabilities FROM devices WHERE account_id = ? AND push_token IS NOT NULL AND id <> ?", account, except ?? "");
  const devices = feature === null ? rows : rows.filter((d) => deviceHas(d, feature));
  const outcomes = await Promise.all(devices.map(async (d) => {
    let status;
    try {
      const answer = await deps.apns.send({ token: d.push_token, env: d.push_env, topic: d.bundle, payload, collapseId,
        ...(pushType ? { pushType } : {}), ...(priority ? { priority } : {}) });
      status = `${answer.status}${answer.reason ? ` ${answer.reason}` : ""}`;
      const gone = answer.status === 410
        || (answer.status === 400 && (answer.reason === "BadDeviceToken" || answer.reason === "DeviceTokenNotForTopic"));
      if (gone) await db.run("UPDATE devices SET push_token = NULL WHERE id = ? AND push_token = ?", d.id, d.push_token);
    } catch (error) {
      status = `failed ${error.name}`;
    }
    await db.run("UPDATE devices SET pushed_at = ?, push_status = ? WHERE id = ?", now(), status, d.id);
    return `${d.platform ?? ""}${d.push_env === "development" ? "(dev)" : ""} ${status}`.trim();
  }));
  const skipped = rows.length - devices.length;
  console.log(`${label}: ${devices.length} device(s): ${outcomes.join(", ") || "none"}${skipped ? `; ${skipped} without ${feature}` : ""}`);
}

