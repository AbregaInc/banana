// Silent (and booking alert) pushes to every device of an account, through the APNs port. Used by
// the routes (src/app.js), the booking jobs and the shared cloud mailboxes (src/mailbox.js).

/** A push to every device of the account (but `except`), recording what APNs said of each
 * (`devices.pushed_at`, `push_status`): the evidence that a push went out, and where. Silent unless
 * `pushType` is "alert" (a booking's news to its host). */
export async function pushTo(deps, account, { payload, collapseId, except = null, label = "push", pushType, priority }) {
  const { db, now } = deps;
  const devices = await db.all(
    "SELECT id, platform, push_token, push_env, bundle FROM devices WHERE account_id = ? AND push_token IS NOT NULL AND id <> ?", account, except ?? "");
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
  console.log(`${label}: ${devices.length} device(s): ${outcomes.join(", ") || "none"}`);
}

