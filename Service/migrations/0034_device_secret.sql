-- A device row moves to another account only for the install that holds its secret: the app makes
-- one per install, keeps it in this device's keychain and sends it with the device. Only its
-- SHA-256 is kept. Rows from before have none, and move as before until the device next registers.
ALTER TABLE devices ADD COLUMN secret_hash TEXT;
