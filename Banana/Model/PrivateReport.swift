import Foundation

/// Developer reports written where only this user can read them. `/tmp` is shared by every process
/// on the Mac, and a probe's report holds calendar data: the file is created with mode 0600, a
/// symlink in its place is refused rather than followed, and a file someone else made there first
/// (theirs to read) is refused too: nothing is written into it.
enum PrivateReport {
    static func write(_ data: Data, toPath path: String) {
        let fd = open(path, O_WRONLY | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        // Ours, a plain file with one name, and 0600 — checked on the open file, before a byte goes in.
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
              fchmod(fd, 0o600) == 0, ftruncate(fd, 0) == 0 else { return }
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
