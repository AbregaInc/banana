/** A growable byte buffer for decompressor output. */
export class OutBuffer {
    buf;
    length = 0;
    constructor(capacity = 1 << 16) {
        this.buf = new Uint8Array(Math.min(64 * 1024 * 1024, Math.max(16, capacity)));
    }
    /** Makes room for `n` more bytes. Callers re-read `buf` afterwards, since it may be replaced. */
    reserve(n) {
        const need = this.length + n;
        if (need > 64 * 1024 * 1024) throw new Error("Decoded file exceeds 64 MB");
        if (need <= this.buf.length)
            return;
        let cap = this.buf.length * 2;
        while (cap < need)
            cap *= 2;
        const b = new Uint8Array(cap);
        b.set(this.buf.subarray(0, this.length));
        this.buf = b;
    }
    append(data) {
        this.reserve(data.length);
        this.buf.set(data, this.length);
        this.length += data.length;
    }
    result() {
        return this.buf.subarray(0, this.length);
    }
}
