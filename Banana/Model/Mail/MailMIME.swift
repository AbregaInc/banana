#if !BANANA_PUBLIC
import Foundation

struct MIMELimits: Sendable {
    var depth = 20
    var parts = 1_000
    var bodyBytes = 2 * 1024 * 1024
}
struct MIMEExtraction: Sendable {
    var structure: MIMEStructure
    var html: String?
    var plain: String?
    /// Body data can be absent because Gmail requires attachments.get. Do not call that empty mail.
    var missingBodyPartIDs: [String]
    var bodyTooLarge: Bool
    var malformedBody: Bool
}

/// Gmail supplies the parsed MIME tree; this is body selection, not an RFC message parser.
/// Decoding uses Foundation and the same charset policy as message headers.
extension MIMEStructure {
    static func extract(_ payload: GmailPart, limits: MIMELimits = MIMELimits()) -> MIMEExtraction {
        var remaining = max(0, limits.parts), cut: Cut?
        var attachments: [Attachment] = [], invite: Invite?
        var missing: [String] = [], tooLarge = false, malformed = false
        var totalDecoded = 0
        func text(_ part: GmailPart, id: String) -> String? {
            guard let encoded = part.body?.data else {
                if part.body?.size == 0 { return "" }
                missing.append(id); return nil
            }
            let budget = max(0, limits.bodyBytes - totalDecoded)
            guard encoded.utf8.count <= ((budget + 2) / 3) * 4 else { tooLarge = true; return nil }
            var base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            base64 += String(repeating: "=", count: (4 - base64.utf8.count % 4) % 4)
            guard let bytes = Data(base64Encoded: base64) else { malformed = true; return nil }
            guard bytes.count <= budget else { tooLarge = true; return nil }
            totalDecoded += bytes.count
            let contentType = MessageHeaders(payload: part).value("Content-Type") ?? ""
            let charset = contentType.split(separator: ";").dropFirst().compactMap { parameter -> String? in
                let pieces = parameter.split(separator: "=", maxSplits: 1)
                guard pieces.count == 2, pieces[0].trimmingCharacters(in: .whitespaces).lowercased() == "charset" else { return nil }
                return pieces[1].trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
            }.first
            return MailCharset.text(Array(bytes), charset: charset).replacingOccurrences(of: "\0", with: "")
        }
        func walk(_ part: GmailPart, depth: Int, path: String, bodyAllowed: Bool) -> (Part, MIMEBodySelection) {
            let id = part.partId ?? path
            let mime = String((part.mimeType ?? "application/octet-stream").lowercased().split(separator: ";").first ?? "application/octet-stream")
            let headers = MessageHeaders(payload: part)
            let disposition = (headers.value("Content-Disposition") ?? "").lowercased()
            let attached = !(part.filename ?? "").isEmpty || disposition.hasPrefix("attachment")
            let inline = disposition.hasPrefix("inline")
            let contentID = headers.value("Content-ID")?.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n"))
            var result = Part(partID: id, mimeType: String(mime.prefix(127)), filename: part.filename.map { String($0.prefix(1024)) },
                size: part.body?.size, attachmentID: part.body?.attachmentId, contentID: contentID.map { String($0.prefix(255)) }, isInline: inline)
            guard depth <= max(0, limits.depth) else { cut = cut ?? .depth; return (result, MIMEBodySelection()) }
            guard remaining > 0 else { cut = cut ?? .parts; return (result, MIMEBodySelection()) }
            remaining -= 1
            if attached || mime == "text/calendar" || (!mime.hasPrefix("multipart/") && mime != "text/plain" && mime != "text/html") {
                attachments.append(Attachment(partID: id, name: MailFileName.safe(part.filename ?? "attachment"),
                    mimeType: result.mimeType, size: result.size, attachmentID: result.attachmentID,
                    contentID: result.contentID, isInline: inline, isInvite: mime == "text/calendar"))
            }
            if mime == "text/calendar", invite == nil {
                var item = Invite(partID: id)
                // Invitation metadata is optional; a large attachment must not suppress
                // the ordinary body. Bound its decode independently to 256 KiB.
                if let encoded = part.body?.data, encoded.utf8.count <= ((256 * 1024 + 2) / 3) * 4,
                   let calendar = text(part, id: id) {
                    let unfolded = calendar.replacingOccurrences(of: "\r\n ", with: "").replacingOccurrences(of: "\r\n\t", with: "")
                    for line in unfolded.prefix(256 * 1024).split(whereSeparator: \.isNewline) {
                        if line.uppercased().hasPrefix("METHOD:") { item.method = String(line.dropFirst(7)).uppercased() }
                        if line.uppercased().hasPrefix("UID:"), item.uid == nil { item.uid = String(line.dropFirst(4)) }
                    }
                }
                invite = item
            }
            let canSelect = bodyAllowed && !attached
            var selection = MIMEBodySelection()
            if canSelect && mime == "text/plain" { selection.plain = text(part, id: id); selection.plainID = id }
            if canSelect && mime == "text/html" { selection.html = text(part, id: id); selection.htmlID = id }
            let children = part.parts ?? []
            var relatedRoot = 0
            if canSelect && mime == "multipart/related", let type = headers.value("Content-Type") {
                let start = type.split(separator: ";").dropFirst().compactMap { field -> String? in
                    let pair = field.split(separator: "=", maxSplits: 1)
                    guard pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "start" else { return nil }
                    return pair[1].trimmingCharacters(in: CharacterSet(charactersIn: " \t\"<>"))
                }.first
                if let start {
                    relatedRoot = -1
                    if let index = children.firstIndex(where: {
                    MessageHeaders(payload: $0).value("Content-ID")?.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n")) == start
                }) { relatedRoot = index }
                    else { malformed = true }
                }
            }
            var selectedChildren: [MIMEBodySelection] = []
            // Attached messages/documents must never replace the enclosing message's body.
            for (index, child) in children.enumerated() {
                if cut != nil { break }
                if remaining == 0 { cut = cut ?? .parts; break }
                let selectable = canSelect && mime.hasPrefix("multipart/") && (mime != "multipart/related" || index == relatedRoot)
                let (tree, body) = walk(child, depth: depth + 1, path: path + "." + String(index), bodyAllowed: selectable)
                result.children.append(tree)
                selectedChildren.append(body)
            }
            if !selectedChildren.isEmpty {
                selection = MIMEBodySelection.combine(selectedChildren, alternative: mime == "multipart/alternative")
            }
            return (result, selection)
        }
        let (root, chosen) = walk(payload, depth: 0, path: "0", bodyAllowed: true)
        let body = cut != nil || tooLarge ? MIMEBodySelection() : chosen

        return MIMEExtraction(structure: MIMEStructure(root: root, attachments: attachments,
            htmlPartID: body.htmlID, plainPartID: body.plainID, invite: invite, cut: cut), html: body.html, plain: body.plain,
            missingBodyPartIDs: missing, bodyTooLarge: tooLarge, malformedBody: malformed)
    }
}

private struct MIMEBodySelection {
    var html: String?, plain: String?, htmlID: String?, plainID: String?

    static func combine(_ children: [Self], alternative: Bool) -> Self {
        if alternative {
            // Later alternatives supersede earlier representations of the same type.
            let html = children.last { $0.html != nil }
            let plain = children.last { $0.plain != nil }
            return Self(html: html?.html, plain: plain?.plain, htmlID: html?.htmlID, plainID: plain?.plainID)
        }
        let plainParts = children.compactMap(\.plain)
        let hasHTML = children.contains { $0.html != nil }
        let htmlParts: [String] = hasHTML ? children.compactMap { child -> String? in
            if let html = child.html { return html }
            guard let plain = child.plain else { return nil }
            let escaped = plain.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            return "<pre>" + escaped + "</pre>"
        } : []
        return Self(html: hasHTML ? htmlParts.joined(separator: "\n") : nil,
                    plain: plainParts.isEmpty ? nil : plainParts.joined(separator: "\n\n"),
                    htmlID: children.compactMap(\.htmlID).first, plainID: children.compactMap(\.plainID).first)
    }
}

#endif
