// An in-memory Gmail for the shared mailbox tests: messages, labels, a history log and the read
// resources /v1/mail/read and the mailbox use, answering as Google does ({status, body}). It
// counts every read, so a test can say how many times a message was downloaded, and every write.

const SYSTEM = ["INBOX", "UNREAD", "STARRED", "DRAFT", "SENT", "IMPORTANT", "TRASH", "SPAM", "CATEGORY_PERSONAL"];
const notFound = { error: { code: 404, status: "NOT_FOUND", errors: [{ reason: "notFound" }], message: "Not Found" } };

export function fakeGmail({ email = "noor@plan.example", userLabels = ["Label_1"] } = {}) {
  const messages = new Map();
  const history = [];
  let hist = 1000, date = Date.UTC(2026, 8, 1), nextLabel = 100;
  // Labels by id: system labels are named by their id; user labels have their own names.
  const labels = new Map([...SYSTEM, ...userLabels].map((id) => [id, { id, name: id, type: SYSTEM.includes(id) ? "system" : "user" }]));
  const gmail = {
    email, messages, history, labels, calls: [], writes: [], created: [], oldest: 0,
    /** A user label with a name (Gmail picks the id); returns the id. */
    label(name, extra = {}) {
      const id = `Label_${nextLabel++}`;
      labels.set(id, { id, name, type: "user", ...extra });
      return id;
    },
    labelID(name) { return [...labels.values()].find((l) => l.name === name)?.id ?? null; },
    /** Listing hooks: `skip` hides ids from a label's listing; `stale` answers from a saved copy. */
    skip: new Map(), stale: new Map(), afterList: null,
    get historyId() { return hist; },
    add(id, ids = ["INBOX", "UNREAD"], thread = `t-${id}`) {
      hist++; date += 60_000;
      messages.set(id, { id, threadId: thread, labels: new Set(ids), internalDate: date, hist, subject: `Subject ${id}` });
      history.push({ id: String(hist), messagesAdded: [{ message: { id, threadId: thread, labelIds: [...ids] } }] });
      return hist;
    },
    modify(id, add = [], remove = []) {
      const m = messages.get(id);
      hist++;
      for (const l of add) m.labels.add(l);
      for (const l of remove) m.labels.delete(l);
      m.hist = hist;
      const record = { id: String(hist) };
      if (add.length) record.labelsAdded = [{ message: { id, threadId: m.threadId }, labelIds: add }];
      if (remove.length) record.labelsRemoved = [{ message: { id, threadId: m.threadId }, labelIds: remove }];
      history.push(record);
      return hist;
    },
    remove(id) {
      const m = messages.get(id);
      messages.delete(id);
      hist++;
      history.push({ id: String(hist), messagesDeleted: [{ message: { id, threadId: m.threadId } }] });
    },
    reads(resource, id = null, format = null) {
      return gmail.calls.filter((c) => c.resource === resource && (id === null || c.id === id) && (format === null || c.format === format)).length;
    },
    wire(m, format) {
      const out = { id: m.id, threadId: m.threadId, labelIds: [...m.labels].sort(), historyId: String(m.hist), internalDate: String(m.internalDate), snippet: `snippet ${m.id}`, sizeEstimate: 100 };
      if (format === "full") out.payload = { mimeType: "text/plain", headers: [{ name: "Subject", value: m.subject }], body: { size: 5, data: "aGVsbG8" } };
      return out;
    },
    async mailRead(token, request) {
      const query = Object.fromEntries(request.query.map(({ name, value }) => [name, value]));
      const format = query.format ?? (["message", "thread"].includes(request.resource) ? "full" : null);
      gmail.calls.push({ resource: request.resource, id: request.id ?? null, format, label: query.labelIds ?? null, token, pageToken: query.pageToken ?? null });
      switch (request.resource) {
      case "profile": return { status: 200, body: { emailAddress: email, historyId: String(hist), messagesTotal: messages.size } };
      case "labels": return { status: 200, body: { labels: [...labels.values()].map((l) => ({ ...l })) } };
      case "messages": {
        const label = query.labelIds ?? null, size = Number(query.maxResults ?? 100), offset = Number(query.pageToken ?? 0);
        const spamTrash = query.includeSpamTrash === "true";
        let list = gmail.stale.get(label ?? "") ?? [...messages.values()]
          .filter((m) => (label ? m.labels.has(label) : true))
          .filter((m) => spamTrash || label === "SPAM" || label === "TRASH" || (!m.labels.has("SPAM") && !m.labels.has("TRASH")))
          .sort((a, b) => b.internalDate - a.internalDate)
          .map((m) => ({ id: m.id, threadId: m.threadId }));
        const hidden = gmail.skip.get(label ?? "");
        if (hidden) list = list.filter((m) => !hidden.has(m.id));
        const page = list.slice(offset, offset + size);
        const body = { messages: page, resultSizeEstimate: list.length };
        if (offset + size < list.length) body.nextPageToken = String(offset + size);
        gmail.afterList?.(label, offset);
        return { status: 200, body };
      }
      case "history": {
        const start = Number(query.startHistoryId);
        if (start < gmail.oldest) return { status: 404, body: notFound };
        const size = Number(query.maxResults ?? 100), offset = Number(query.pageToken ?? 0);
        const records = history.filter((r) => Number(r.id) > start);
        const page = records.slice(offset, offset + size);
        const body = { historyId: String(hist) };
        if (page.length) body.history = page;
        if (offset + size < records.length) body.nextPageToken = String(offset + size);
        return { status: 200, body };
      }
      case "message": {
        const m = messages.get(request.id);
        return m ? { status: 200, body: gmail.wire(m, format) } : { status: 404, body: notFound };
      }
      case "thread": {
        const list = [...messages.values()].filter((m) => m.threadId === request.id).sort((a, b) => a.internalDate - b.internalDate);
        if (!list.length) return { status: 404, body: notFound };
        return { status: 200, body: { id: request.id, historyId: String(Math.max(...list.map((m) => m.hist))), messages: list.map((m) => gmail.wire(m, format)) } };
      }
      case "attachment": {
        const m = messages.get(request.id);
        return m ? { status: 200, body: { size: 3, data: "YWJj" } } : { status: 404, body: notFound };
      }
      default: return { status: 400, body: { error: { code: 400, message: "unsupported" } } };
      }
    },
    // The operation route's two calls (mail-operation.js).
    async mailMessage(token, id) {
      gmail.calls.push({ resource: "message", id, format: "minimal", token });
      const m = messages.get(id);
      if (!m) { const e = new Error("mail message unavailable"); e.status = 404; throw e; }
      return gmail.wire(m, "minimal");
    },
    async mailMutation(token, request) {
      gmail.writes.push({ id: request.id, action: request.action, add: request.add ?? [], remove: request.remove ?? [] });
      const m = messages.get(request.id);
      if (!m) return { status: 404, body: notFound };
      if ([...(request.add ?? []), ...(request.remove ?? [])].some((l) => !labels.has(l)))
        return { status: 400, body: { error: { code: 400, message: "Invalid label", errors: [{ reason: "invalidArgument" }] } } };
      if (request.action === "trash") gmail.modify(request.id, ["TRASH"], ["INBOX"]);
      else if (request.action === "untrash") gmail.modify(request.id, [], ["TRASH"]);
      else gmail.modify(request.id, request.add, request.remove);
      return { status: 200, body: { id: m.id, threadId: m.threadId, labelIds: [...m.labels].sort() } };
    },
    // Labels for the createLabel operation and the mailbox (google.js mailLabels, mailCreateLabel).
    async mailLabels(token) {
      gmail.calls.push({ resource: "labels", id: null, format: null, token });
      return [...labels.values()].map((l) => ({ ...l }));
    },
    async mailCreateLabel(token, body) {
      gmail.created.push({ ...body });
      if ([...labels.values()].some((l) => l.name === body.name))
        return { status: 409, body: { error: { code: 409, message: "Label name exists or conflicts", status: "ALREADY_EXISTS" } } };
      const id = gmail.label(body.name, { labelListVisibility: body.labelListVisibility, messageListVisibility: body.messageListVisibility });
      return { status: 200, body: { ...labels.get(id) } };
    },
  };
  return gmail;
}
