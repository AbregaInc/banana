-- Problem reports (docs/design/PROBLEM-REPORTS.md): spikes the apps catch, MetricKit diagnostics
-- with the log around them, Report a problem, and ratings on answers. Anonymous: no account,
-- device id or address. The screenshot, log, message HTML and transcript are R2 objects under
-- reports/<id>/<name>, listed in `attachments`. Deleted after 90 days.
CREATE TABLE problem_reports (
  id          TEXT   PRIMARY KEY,   -- made by the app, so a retry is the same report
  received_at BIGINT NOT NULL,
  kind        TEXT   NOT NULL,      -- problem | spike | rating
  detector    TEXT,                 -- spike: storm | cpu | power | memory | hang | metrickit-*
  signature   TEXT,                 -- what groups like spikes: the source, the top frame
  rating      TEXT,                 -- rating: up | down
  platform    TEXT   NOT NULL,
  channel     TEXT   NOT NULL,
  variant     TEXT   NOT NULL,      -- stable | beta
  version     TEXT   NOT NULL,
  os          TEXT   NOT NULL,
  device      TEXT   NOT NULL,      -- the model identifier, e.g. iPhone18,1
  page        TEXT   NOT NULL,
  note        TEXT,                 -- what the person wrote, if anything
  numbers     TEXT   NOT NULL,      -- JSON: the detector's readings
  context     TEXT   NOT NULL,      -- JSON: the page's ids and facts
  attachments TEXT   NOT NULL,      -- JSON: [{name, type, size}]
  bytes       BIGINT NOT NULL,
  pulled_at   BIGINT                -- set by tools/reports when pulled
);
CREATE INDEX problem_reports_received ON problem_reports (received_at);
CREATE INDEX problem_reports_new ON problem_reports (pulled_at, received_at);
