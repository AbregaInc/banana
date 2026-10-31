#if !BANANA_PUBLIC
#if DEBUG || MAIL_FIXTURES
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// The sample mailbox's files: small stand-ins for the attachments its conversations list, made in
/// code and plainly marked as samples (a one-page PDF, a small PNG, a short CSV, a spreadsheet, a
/// zip, a text file), and the place they are kept.
///
/// **Where they live.** In a folder of their own under the system's temporary directory, one
/// folder for each launch, and never under the app's real data directory. A launch sweeps every
/// other launch's folder (`sweepPreviousLaunches`), so a relaunch starts clean.
///
/// **How they are written.** Everything through `MailFiles`, the engine's one door for writing
/// files: a temporary file beside the destination and an atomic move; a file from someone else is
/// written with its quarantine, and under the engine's safe name (`MailFileName`). All of it off
/// the main thread: `MailFiles` stops a Debug build that does it on the main thread, and a file
/// may be megabytes.
enum MailSampleFiles {

    /// A different value in every process.
    nonisolated static let launchID = UUID().uuidString

    nonisolated static var root: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("BananaMailSample", isDirectory: true)
    }

    nonisolated static var launchFolder: URL {
        root.appendingPathComponent(launchID, isDirectory: true)
    }

    /// Where the files of one draft are kept.
    nonisolated static func folder(forDraft draft: MailDraftID) -> URL {
        launchFolder.appendingPathComponent("draft-" + draft.raw, isDirectory: true)
    }

    /// Where the files of one received message are kept.
    nonisolated static func folder(forMessage message: MailMessageID) -> URL {
        launchFolder.appendingPathComponent("message-" + message.message, isDirectory: true)
    }

    /// Removes what every earlier launch left. This launch's own folder stays.
    nonisolated static func sweepPreviousLaunches() async {
        await Task.detached {
            let keep = launchID
            let folders = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            for name in folders where name != keep {
                try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
            }
        }.value
    }

    // MARK: - What a message's attachment is

    /// The contract's facts about a sample attachment: the type of what its bytes are, and whether
    /// that is not what its name says. `actually` is the extension of the bytes, for a sample that
    /// is not what it says.
    nonisolated static func attachment(id: MailAttachmentID, name: String, bytes: Int,
                                       actually: String?) -> MailAttachment {
        let real = actually.flatMap { UTType(filenameExtension: $0) } ?? MailAttachmentKind.type(ofName: name)
        return MailAttachment(id: id, name: name, mimeType: real?.preferredMIMEType ?? "application/octet-stream",
                              typeMismatch: actually != nil, bytes: bytes, localFile: nil,
                              isInline: false, isExecutable: false)
    }

    // MARK: - Making a stand-in

    /// The bytes of a stand-in, and the type they are. The type is the name's, unless `actually`
    /// says the bytes are of another.
    nonisolated static func standIn(named name: String, actually: String? = nil) -> (data: Data, type: UTType) {
        let ext = (actually ?? (name as NSString).pathExtension).lowercased()
        let title = MailFileName.safe(name)
        switch ext {
        case "pdf": return (pdf(title: title), .pdf)
        case "png": return (bitmap(title: title, type: .png), .png)
        case "jpg", "jpeg": return (bitmap(title: title, type: .jpeg), .jpeg)
        case "csv": return (Data(csv.utf8), .commaSeparatedText)
        case "xlsx": return (spreadsheet(), UTType(filenameExtension: "xlsx") ?? .data)
        case "zip": return (zip([("README.txt", Data(note(for: title).utf8))]), .zip)
        default: return (Data(note(for: title).utf8), .plainText)
        }
    }

    private nonisolated static func note(for title: String) -> String {
        "Sample file\n\nBanana made this stand-in for \u{201C}\(title)\u{201D}. "
            + "The sample mailbox has no real attachments; nothing here was ever sent or received.\n"
    }

    private nonisolated static let csv =
        "Sample,Amount\nSample row A,120\nSample row B,85\nSample row C,40\n"

    // MARK: PDF, and a picture

    /// One page, marked SAMPLE, with the name under it.
    private nonisolated static func pdf(title: String) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1))
        context.fill(box)
        context.setFillColor(CGColor(red: 0.85, green: 0.35, blue: 0.15, alpha: 1))
        draw("SAMPLE", size: 72, at: CGPoint(x: 72, y: 600), in: context)
        context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1))
        draw(title, size: 20, at: CGPoint(x: 72, y: 550), in: context)
        draw("Banana made this one-page stand-in for the attachment.", size: 14,
             at: CGPoint(x: 72, y: 520), in: context)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    /// A small picture, marked SAMPLE.
    private nonisolated static func bitmap(title: String, type: UTType) -> Data {
        let width = 320, height = 200
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return Data() }
        context.setFillColor(CGColor(red: 0.98, green: 0.84, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1))
        draw("SAMPLE", size: 44, at: CGPoint(x: 24, y: 110), in: context)
        draw(String(title.prefix(30)), size: 14, at: CGPoint(x: 24, y: 80), in: context)
        guard let image = context.makeImage() else { return Data() }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData,
                                                                 type.identifier as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    private nonisolated static func draw(_ text: String, size: CGFloat, at point: CGPoint, in context: CGContext) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ])
        context.textPosition = point
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
    }

    // MARK: A spreadsheet, and a zip

    /// A workbook of one sheet, as the office formats write one: a zip of four small XML parts.
    private nonisolated static func spreadsheet() -> Data {
        let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        let relationships = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        func cell(_ ref: String, _ text: String) -> String {
            "<c r=\"\(ref)\" t=\"inlineStr\"><is><t>\(text)</t></is></c>"
        }
        func number(_ ref: String, _ value: Int) -> String { "<c r=\"\(ref)\"><v>\(value)</v></c>" }
        let sheet = xml + "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>"
            + "<row r=\"1\">" + cell("A1", "Sample") + cell("B1", "Amount") + "</row>"
            + "<row r=\"2\">" + cell("A2", "Sample row A") + number("B2", 120) + "</row>"
            + "<row r=\"3\">" + cell("A3", "Sample row B") + number("B3", 85) + "</row>"
            + "</sheetData></worksheet>"
        let parts: [(String, String)] = [
            ("[Content_Types].xml", xml + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
                + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
                + "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
                + "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>"
                + "<Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/></Types>"),
            ("_rels/.rels", xml + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
                + "<Relationship Id=\"rId1\" Type=\"\(relationships)/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>"),
            ("xl/workbook.xml", xml + "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" "
                + "xmlns:r=\"\(relationships)\"><sheets><sheet name=\"Sample\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>"),
            ("xl/_rels/workbook.xml.rels", xml + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
                + "<Relationship Id=\"rId1\" Type=\"\(relationships)/worksheet\" Target=\"worksheets/sheet1.xml\"/></Relationships>"),
            ("xl/worksheets/sheet1.xml", sheet),
        ]
        return zip(parts.map { ($0.0, Data($0.1.utf8)) })
    }

    /// A zip of stored (uncompressed) entries: the format is a header and the bytes for each, a
    /// directory of them, and a last record that says where the directory is. Small, fixed
    /// timestamps, so the same input is the same file.
    nonisolated static func zip(_ entries: [(name: String, data: Data)]) -> Data {
        var out = Data()
        var directory = Data()
        let dosTime: UInt16 = 9 << 11 | 41 << 5            // 9:41
        let dosDate: UInt16 = (2026 - 1980) << 9 | 10 << 5 | 5  // 5 October 2026
        func put<T: FixedWidthInteger>(_ value: T, into data: inout Data) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        for entry in entries {
            let name = Data(entry.name.utf8)
            let checksum = crc32(entry.data)
            let offset = UInt32(out.count)
            put(UInt32(0x04034b50), into: &out); put(UInt16(20), into: &out); put(UInt16(0), into: &out)
            put(UInt16(0), into: &out); put(dosTime, into: &out); put(dosDate, into: &out)
            put(checksum, into: &out); put(UInt32(entry.data.count), into: &out); put(UInt32(entry.data.count), into: &out)
            put(UInt16(name.count), into: &out); put(UInt16(0), into: &out)
            out.append(name); out.append(entry.data)

            put(UInt32(0x02014b50), into: &directory); put(UInt16(20), into: &directory); put(UInt16(20), into: &directory)
            put(UInt16(0), into: &directory); put(UInt16(0), into: &directory); put(dosTime, into: &directory)
            put(dosDate, into: &directory); put(checksum, into: &directory)
            put(UInt32(entry.data.count), into: &directory); put(UInt32(entry.data.count), into: &directory)
            put(UInt16(name.count), into: &directory); put(UInt16(0), into: &directory); put(UInt16(0), into: &directory)
            put(UInt16(0), into: &directory); put(UInt16(0), into: &directory); put(UInt32(0), into: &directory)
            put(offset, into: &directory); directory.append(name)
        }
        let start = UInt32(out.count)
        out.append(directory)
        put(UInt32(0x06054b50), into: &out); put(UInt16(0), into: &out); put(UInt16(0), into: &out)
        put(UInt16(entries.count), into: &out); put(UInt16(entries.count), into: &out)
        put(UInt32(directory.count), into: &out); put(start, into: &out); put(UInt16(0), into: &out)
        return out
    }

    nonisolated static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    private nonisolated static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    // MARK: - Keeping a file

    /// Writes a stand-in as a file received from someone else: under its safe name, with the
    /// quarantine on the Mac, by the engine's own door. Where `type` is not what the name's
    /// extension says (a file that is not what it says), the name takes the type's extension, so
    /// that Quick Look opens what the bytes are. Nil if it could not be written.
    nonisolated static func stage(_ data: Data, named name: String, type: UTType, in folder: URL,
                                  from sender: String?) async -> URL? {
        await Task.detached { () -> URL? in
            let name = corrected(MailFileName.safe(name), for: type)
            do {
                let directory = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let destination = directory.appendingPathComponent(name)
                try MailFiles.install(data, at: destination, protection: .completeUntilFirstUserAuthentication,
                                      quarantine: MailQuarantine(origin: sender.flatMap { URL(string: "mailto:" + $0) }),
                                      durability: .atomic)
                return destination
            } catch {
                return nil
            }
        }.value
    }

    /// Copies a file he chose into the draft's folder, a megabyte at a time, and returns where it
    /// is, what it is called and how big it is. His own file: no quarantine.
    nonisolated static func stage(copyOf source: URL, in folder: URL) async -> (url: URL, name: String, bytes: Int)? {
        await Task.detached { try? MailIntake.copy(source, into: folder) }.value
    }

    /// The name, with the extension of `type` when the name's own is of another kind.
    nonisolated static func corrected(_ name: String, for type: UTType) -> String {
        if let byName = MailAttachmentKind.type(ofName: name), byName.conforms(to: type) || type.conforms(to: byName) {
            return name
        }
        guard let ext = type.preferredFilenameExtension else { return name }
        let base = (name as NSString).deletingPathExtension
        return (base.isEmpty ? MailFileName.fallback : base) + "." + ext
    }
}
#endif

#endif
