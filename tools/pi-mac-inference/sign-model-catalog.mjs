// Sign public catalog metadata offline. The Worker and blob store never need the signing key.
import { createPrivateKey, createPublicKey, sign } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const [channel, sequenceText, modelsPath, outputPath] = process.argv.slice(2);
const sequence = Number(sequenceText);
if (!['beta', 'production'].includes(channel) || !Number.isSafeInteger(sequence) || sequence < 1 || !modelsPath || !outputPath) {
  console.error('Usage: node tools/pi-mac-inference/sign-model-catalog.mjs beta|production SEQUENCE MODELS_JSON OUTPUT');
  process.exit(2);
}

const models = JSON.parse(readFileSync(modelsPath, 'utf8'));
if (!Array.isArray(models) || models.length > 12) throw new Error('Expected an array of up to twelve model entries.');
const payload = Buffer.from(JSON.stringify({schema: 1, channel, sequence, models}));
const pinnedKey = readFileSync(new URL('../../Banana/Pi/ModelCatalog.swift', import.meta.url), 'utf8')
  .match(/static let publicKey = Data\(base64Encoded: "([^"]+)"\)/)?.[1];
const keyPath = process.env.BANANA_MODEL_CATALOG_SIGNING_KEY ?? join(homedir(), '.config/banana/model-catalog-ed25519.pem');
const key = createPrivateKey(readFileSync(keyPath));
if (key.asymmetricKeyType !== 'ed25519' ||
    createPublicKey(key).export({type: 'spki', format: 'der'}).subarray(-32).toString('base64') !== pinnedKey) {
  throw new Error('Signing key does not match the public key pinned in Banana.');
}
const envelope = JSON.stringify({payload: payload.toString('base64'), signature: sign(null, payload, key).toString('base64')});
if (Buffer.byteLength(envelope) > 128 * 1024) throw new Error('Signed catalog exceeds the client limit.');
writeFileSync(outputPath, envelope, {flag: 'wx'});
