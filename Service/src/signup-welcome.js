// Claim before contacting the provider. A lost acknowledgement must not send a second welcome.
export async function deliverSignupWelcomes({ db, config, email, now }) {
  if (!config.welcomeReplyTo || !email?.enabled) return;
  const rows = await db.all(
    `SELECT w.account_id, g.email FROM signup_welcomes w JOIN google_links g
       ON g.sub = w.google_sub AND g.account_id = w.account_id
     WHERE w.state = 'pending' AND w.available_at <= ? AND g.status <> 'unlinked'
     ORDER BY w.available_at LIMIT 25`, now());
  for (const row of rows) {
    const claim = await db.run("UPDATE signup_welcomes SET state = 'sending' WHERE account_id = ? AND state = 'pending' AND available_at <= ?", row.account_id, now());
    if (!claim.changes) continue;
    const paragraphs = [
      config.welcomeFounderName
        ? `Thanks for trying Banana. I’m ${config.welcomeFounderName}, the founder.`
        : "Thanks for trying Banana. I’m the founder.",
      "What was happening with your calendar that made you try Banana today?",
      "Hit reply and tell me. Your reply comes straight to me, and it helps me decide what to improve next.",
    ];
    try {
      await email.send({
        kind: "signup_welcome", from: config.emailFrom, to: row.email, replyTo: config.welcomeReplyTo,
        subject: "Welcome to Banana", text: paragraphs.join("\n\n"),
      });
    } catch (error) {
      // An explicit rate limit means the provider rejected the send. Other outcomes may be ambiguous.
      const retry = Number(error?.status ?? error?.statusCode) === 429;
      await db.run("UPDATE signup_welcomes SET state = ?, available_at = ? WHERE account_id = ?",
        retry ? "pending" : "unknown", now() + 15 * 60_000, row.account_id);
      console.log(retry ? "signup welcome: rate limited" : "signup welcome: delivery unconfirmed");
      continue;
    }
    await db.run("DELETE FROM signup_welcomes WHERE account_id = ?", row.account_id);
  }
}
