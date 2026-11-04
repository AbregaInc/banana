import {sha256Hex} from '../crypto.js';
// Opaque token: never disclose a sequence that counts changes to somebody's private types.
export async function contentVersion(status,types) {
  return sha256Hex(JSON.stringify([status.epoch,[...new Set(types)].sort().map(type=>[type,status.revisions[type]??0])]));
}
