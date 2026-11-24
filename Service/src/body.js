// Request bodies, read with a byte limit while reading.

export const TOO_LARGE = Symbol("too large");

/**
 * The request body as text, at most `limit` bytes: read a chunk at a time and given up past the
 * limit, so a body without Content-Length (chunked) is never held whole first.
 */
export async function readText(c, limit) {
  const body = c.req.raw.bodyUsed ? null : c.req.raw.body;
  if (!body) {
    const text = await c.req.text();
    return new TextEncoder().encode(text).byteLength > limit ? TOO_LARGE : text;
  }
  const reader = body.getReader();
  const chunks = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > limit) { await reader.cancel().catch(() => {}); return TOO_LARGE; }
    chunks.push(value);
  }
  const bytes = new Uint8Array(size);
  let at = 0;
  for (const chunk of chunks) { bytes.set(chunk, at); at += chunk.byteLength; }
  return new TextDecoder().decode(bytes);
}
