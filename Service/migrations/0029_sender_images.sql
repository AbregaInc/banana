-- Sender images for Mail (docs/design/MAIL-UX.md, "Sender images"). No address is stored in clear:
-- every key is a SHA-256 of the lower-cased address or domain.
--
-- The shared tier: one entry per sender for every Banana user, from public sources only (a brand's
-- BIMI logo, Gravatar, a site's own icon, a person's own Google profile photo). `key` is a source
-- letter and a hash: 'p:' profile photo, 'g:' Gravatar (by address), 'b:' BIMI, 'i:' site icon (by
-- domain). `image` is the SHA-256 of the bytes at R2 `senders/shared/<image>`; NULL is "none".
CREATE TABLE sender_images (
  key TEXT PRIMARY KEY,
  image TEXT,
  checked_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
);
CREATE INDEX sender_images_image ON sender_images (image) WHERE image IS NOT NULL;

-- The per-user tier: what one person's Google contacts say about an address. A 'contact' photo (one
-- the person set on a contact) is stored for them alone, at R2 `senders/u/<account>/<image>`, and
-- never enters the shared tier. A 'profile' photo is the contact's own public Google photo: its
-- bytes go to the shared tier. Rows go with the Google link, Mail access, or the account.
CREATE TABLE sender_contacts (
  account_id TEXT NOT NULL,
  google_sub TEXT NOT NULL,
  address_hash TEXT NOT NULL,
  source TEXT NOT NULL,              -- 'contact' | 'profile'
  photo_url TEXT NOT NULL,
  image TEXT,                        -- contact photos only: the stored copy
  image_checked_at INTEGER,
  PRIMARY KEY (account_id, google_sub, address_hash, source)
);
CREATE INDEX sender_contacts_address ON sender_contacts (account_id, address_hash);
CREATE INDEX sender_contacts_image ON sender_contacts (account_id, image) WHERE image IS NOT NULL;

-- When each Google account's contacts were last read for photos.
CREATE TABLE sender_contact_syncs (
  account_id TEXT NOT NULL,
  google_sub TEXT NOT NULL,
  synced_at INTEGER NOT NULL,
  PRIMARY KEY (account_id, google_sub)
);
