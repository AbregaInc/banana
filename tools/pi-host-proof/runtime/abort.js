import { AbortController as BaseController, AbortSignal } from 'abort-controller/dist/abort-controller.mjs';

// The dependency supplies EventTarget dispatch/idempotence. These are the newer DOM AbortSignal APIs Pi uses.
const reasons = new WeakMap();
const owners = new WeakMap();
const abortedGetter = Object.getOwnPropertyDescriptor(AbortSignal.prototype, 'aborted').get;
Object.defineProperty(AbortSignal.prototype, 'reason', { configurable: true, get() {
  abortedGetter.call(this); // Preserve the dependency's invalid-receiver check.
  return reasons.get(this);
} });
AbortSignal.prototype.throwIfAborted = function () { if (this.aborted) throw this.reason; };

export class AbortController extends BaseController {
  constructor() { super(); owners.set(this.signal, this); }
  abort(reason = new DOMException('This operation was aborted', 'AbortError')) {
    if (this.signal.aborted) return;
    reasons.set(this.signal, reason);
    super.abort();
  }
}
AbortSignal.abort = (reason) => { const controller = new AbortController(); controller.abort(reason); return controller.signal; };
AbortSignal.timeout = (milliseconds) => {
  if (!Number.isSafeInteger(milliseconds) || milliseconds < 0) throw new RangeError('Invalid abort timeout');
  const controller = new AbortController();
  setTimeout(() => controller.abort(new DOMException('The operation timed out', 'TimeoutError')), milliseconds);
  return controller.signal;
};
AbortSignal.any = (iterable) => {
  if (iterable == null || typeof iterable[Symbol.iterator] !== 'function') throw new TypeError('Expected iterable abort signals');
  const signals = Array.from(iterable);
  for (const signal of signals) abortedGetter.call(signal);
  const aborted = signals.find((signal) => signal.aborted);
  if (aborted) return AbortSignal.abort(aborted.reason);
  const controller = new AbortController();
  const weakController = new WeakRef(controller);
  const links = [];
  const cleanup = () => { for (const [signal, listener] of links) signal.removeEventListener('abort', listener); links.length = 0; };
  for (const signal of signals) {
    const listener = () => { weakController.deref()?.abort(signal.reason); cleanup(); };
    links.push([signal, listener]);
    signal.addEventListener('abort', listener, { once: true });
  }
  return controller.signal;
};
globalThis.AbortController = AbortController;
globalThis.AbortSignal = AbortSignal;
