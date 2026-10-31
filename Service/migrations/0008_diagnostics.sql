-- Crash, hang and performance reports from the apps' MetricKit (docs/design/DIAGNOSTICS.md).
-- Anonymous: no account, device or address is kept with them. Deleted after 90 days.
CREATE TABLE diagnostics (
  id          TEXT   PRIMARY KEY,
  received_at BIGINT NOT NULL,
  kind        TEXT   NOT NULL,     -- crash | hang | cpu | disk | metrics
  signature   TEXT,                -- what groups like reports: exception type, signal, reason
  platform    TEXT   NOT NULL,
  channel     TEXT   NOT NULL,
  version     TEXT   NOT NULL,
  os          TEXT,
  payload     TEXT   NOT NULL      -- MetricKit's own JSON, at most 64 KB
);
CREATE INDEX diagnostics_received ON diagnostics (received_at);
