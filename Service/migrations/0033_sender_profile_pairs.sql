-- Profile photos were paired with every address on a contact, including addresses the user typed
-- in, and the pairing went into the tier every user reads. The pairs made under that rule go; the
-- next contacts read makes them again under the new one (public only for an address Google ties
-- to the profile).
DELETE FROM sender_images WHERE key LIKE 'p:%';
DELETE FROM sender_contacts WHERE source = 'profile';
DELETE FROM sender_contact_syncs;
