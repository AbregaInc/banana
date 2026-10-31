import Foundation

/// Developer reports written where only this user can read them. `/tmp` is shared by every process
/// on the Mac, and a probe's report holds calendar data: the file is created with mode 0600, and a
/// symlink in its place is refused rather than followed.
enum PrivateReport {
    static func write(_ data: Data, toPath path: String) {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        fchmod(fd, 0o600)   // a file that already existed keeps its old mode otherwise
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
                if n <= 0 { return }
                offset += n
            }
        }
    }

    static func write(_ text: String, toPath path: String) { write(Data(text.utf8), toPath: path) }
}
