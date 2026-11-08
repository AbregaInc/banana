-- What each device can take pushes about (src/device-features.js, 8 Nov 2026): a JSON array of
-- feature names ('["mail"]'), reported at every registration. NULL: the device registered from a
-- build that doesn't report them; it takes no feature's pushes but the documented transition's.
ALTER TABLE devices ADD COLUMN capabilities TEXT;
