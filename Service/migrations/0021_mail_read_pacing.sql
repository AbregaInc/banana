-- One shared read schedule per Google identity, across devices and Worker instances.
CREATE TABLE mail_read_pacing (
 google_sub TEXT PRIMARY KEY REFERENCES google_links(sub) ON DELETE CASCADE,
 next_at INTEGER NOT NULL
);
