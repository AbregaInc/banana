import './globals.js';
import 'core-js/actual/dom-exception/index.js';
import 'core-js/actual/structured-clone.js';
import 'core-js/actual/url/index.js';
import 'core-js/actual/url-search-params/index.js';
import 'core-js/actual/queue-microtask.js';
import { TextDecoder, TextEncoder as Encoder } from '@kayahr/text-encoding';
import './abort.js';

// Web TextEncoder is always UTF-8; the dependency additionally accepts other encodings.
globalThis.TextEncoder = class TextEncoder extends Encoder { constructor() { super('utf-8'); } };
globalThis.TextDecoder = TextDecoder;

// Bare JSContext has no browser uncaught-exception event. Report errors rather than losing them as promise rejections.
const enqueue = globalThis.queueMicrotask;
globalThis.queueMicrotask = function (callback) {
  if (typeof callback !== 'function') throw new TypeError('Expected a microtask callback');
  enqueue(() => { try { callback(); } catch (error) { reportError(error); } });
};
