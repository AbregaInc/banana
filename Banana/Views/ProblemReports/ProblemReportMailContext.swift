#if !BANANA_PUBLIC
import SwiftUI

/// A message's prepared body as a report carries it: what the reader drew, for a renderer
/// regression case (tools/reports/mail_case.py).
struct MailPreparedReport: Encodable {
    var kind: String
    var text: MailText?
    var quoteStartsAt: Int?
    var notices: [String]
    var document: String?
    var preparerVersion = MailHTMLPreparer.version

    init?(_ body: MailBody) {
        switch body {
        case .notOnDevice: return nil
        case .text(let text, let quote, let notices):
            (kind, self.text, quoteStartsAt, self.notices, document) = ("text", text, quote, notices.map(\.rawValue), nil)
        case .designed(let document, _, _, let plain, let notices):
            (kind, text, quoteStartsAt, self.notices, self.document) = ("designed", plain, nil, notices.map(\.rawValue), document)
        }
    }
}

extension ProblemReportPageContext {
    /// The conversation in the reader: every message's id, and for the newest one with a body,
    /// that body as prepared and the HTML it came from. The email is his: it goes only while
    /// "Email" is on (on by default in the Beta), and only to the Banana service.
    @MainActor
    static func mail(reader: MailReaderModel, source: MailSource) -> ProblemReportPageContext? {
        // Newest first, as the reader lists them.
        guard let message = reader.messages.first(where: { reader.bodies[$0.id].map { $0 != .notOnDevice } ?? false })
                ?? reader.messages.first else { return nil }
        let id = message.id
        let prepared = reader.bodies[id].flatMap(MailPreparedReport.init)
        var context: [String: ProblemReport.Value] = [
            "messageId": .text(id.message),
            "messageIds": .list(reader.messages.map(\.id.message)),
            "preparerVersion": .number(Double(MailHTMLPreparer.version)),
        ]
        if let prepared { context["body"] = .text(prepared.kind) }
        return ProblemReportPageContext(
            row: .toggle("Email", defaultOn: AppVariant.current == .beta),
            context: context,
            attachments: {
                var out: [ProblemReport.Attachment] = []
                if let prepared, let file = ProblemReport.Attachment.json(.mailPrepared, prepared) { out.append(file) }
                // Whole or not at all: a cut HTML file is no test case.
                if let html = try? await source.originalHTML(id), html.utf8.count <= ProblemReport.Attachment.Name.mailHTML.most,
                   let file = ProblemReport.Attachment.text(.mailHTML, html, type: "text/html") {
                    out.append(file)
                }
                return out
            })
    }
}

/// Offers the conversation in the reader to Report a problem while it shows.
struct ProvidesMailReport: ViewModifier {
    let reader: MailReaderModel
    let source: MailSource

    func body(content: Content) -> some View {
        content
            .onAppear {
                let model = reader, source = source
                ProblemReportCenter.shared.provide(.mail, owner: ObjectIdentifier(model)) { [weak model] in
                    model.flatMap { ProblemReportPageContext.mail(reader: $0, source: source) }
                }
            }
            .onDisappear { ProblemReportCenter.shared.withdraw(.mail, owner: ObjectIdentifier(reader)) }
    }
}
#endif
