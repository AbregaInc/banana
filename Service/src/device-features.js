// What a device can take pushes about (8 Nov 2026). The rule: a push about a feature goes only to
// the devices whose build has that feature and whose person has it switched on. Each device says
// which, when it registers (`capabilities` in PUT /v1/devices/:id and the sign-in's device), and
// says it again whenever that changes (a module switched on or off). An empty list is an answer:
// none. A device that has never said (`devices.capabilities` NULL: a build from before) takes no
// feature's pushes, except where `LEGACY` below says otherwise for a build already shipped.

/** Features a push can be about. A device may report names the service doesn't know yet (a newer
 * app); they're kept, and mean nothing here until a push is about them. */
export const DEVICE_FEATURES = Object.freeze(["mail"]);

const NAME = /^[a-z][A-Za-z0-9]{0,31}$/;
const MOST = 16;

/** The capabilities in a registration: undefined when the device didn't say (an older build),
 * a sorted list of distinct names when it did, null when what it sent is malformed. */
export function parseCapabilities(input) {
  if (input === undefined || input === null) return undefined;
  if (!Array.isArray(input) || input.length > MOST) return null;
  if (!input.every((name) => typeof name === "string" && NAME.test(name))) return null;
  return [...new Set(input)].sort();
}

/** The column's text for a registration's capabilities: NULL for a device that didn't say. */
export const capabilitiesColumn = (capabilities) => capabilities === undefined ? null : JSON.stringify(capabilities);

/** Transition only, until every device has registered from a build that reports capabilities
 * (each launch registers, so a device that has run a newer build once is past it). Mac Beta up to
 * 1.0.4 (112) and the hand-installed iPhone/iPad Betas built Mail in and reported nothing; Stable
 * never had Mail. So a silent row of a Beta bundle (the `.beta` suffix every Beta target appends to
 * the app's bundle id) keeps taking mail pushes, and every other silent row takes none. Remove this
 * when `SELECT COUNT(*) FROM devices WHERE capabilities IS NULL` is 0 on the beta service. */
const LEGACY = Object.freeze({
  mail: (device) => typeof device.bundle === "string" && device.bundle.endsWith(".beta"),
});

/** Whether this device row (`capabilities`, `bundle`) takes pushes about `feature`. */
export function deviceHas(device, feature) {
  if (device.capabilities === null || device.capabilities === undefined) return LEGACY[feature]?.(device) ?? false;
  try {
    const names = JSON.parse(device.capabilities);
    return Array.isArray(names) && names.includes(feature);
  } catch {
    return false;
  }
}
