// Native functions are supplied by AppleRuntimeHost on one JavaScriptCore thread.
globalThis.self = globalThis;
globalThis.console = Object.fromEntries(['log', 'info', 'warn', 'error', 'debug'].map((level) => [level,
  (...args) => nativeLog(args.map(String).join(' '))]));
globalThis.console.assert = (condition, ...args) => { if (!condition) nativeLog(`Assertion failed: ${args.map(String).join(' ')}`); };
globalThis.reportError = (error) => nativeReportError(`${String(error)}${error?.stack ? `\n${error.stack}` : ''}`);
globalThis.setTimeout = (callback, delay = 0, ...args) => {
  if (typeof callback !== 'function') throw new TypeError('The Apple Pi host accepts function timers only');
  const milliseconds = Number(delay);
  return nativeSetTimeout(() => callback(...args), Number.isFinite(milliseconds) ? Math.max(0, Math.min(2147483647, milliseconds)) : 0);
};
globalThis.clearTimeout = (id) => nativeClearTimeout(Number(id));
globalThis.performance = Object.freeze({ now: () => nativeMonotonicMilliseconds() });
globalThis.crypto = Object.freeze({
  getRandomValues(array) {
    const integerViews = ['Int8Array', 'Uint8Array', 'Uint8ClampedArray', 'Int16Array', 'Uint16Array', 'Int32Array', 'Uint32Array', 'BigInt64Array', 'BigUint64Array'];
    const valid = ArrayBuffer.isView(array) && integerViews.some((name) => array instanceof globalThis[name]);
    if (!valid) throw new DOMException('Expected an integer typed array', 'TypeMismatchError');
    if (array.byteLength > 65536) throw new DOMException('Random values exceed 65536 bytes', 'QuotaExceededError');
    const bytes = JSON.parse(nativeRandom(array.byteLength));
    if (bytes.error) throw new Error(bytes.error);
    new Uint8Array(array.buffer, array.byteOffset, array.byteLength).set(bytes);
    return array;
  }
});
