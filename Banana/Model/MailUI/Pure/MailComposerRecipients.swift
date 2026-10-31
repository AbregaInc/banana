#if !BANANA_PUBLIC
import Foundation

/// The three rows of people: who it goes to, who is copied, and who is copied without the others
/// knowing (MAIL-UX 6.3.3).
enum MailRecipientField: Hashable, Sendable {
    case to, cc, bcc

    static let all: [MailRecipientField] = [.to, .cc, .bcc]

    var label: String {
        switch self {
        case .to: "To"
        case .cc: "Cc"
        case .bcc: "Bcc"
        }
    }

    /// The composer's field for the caret.
    var field: MailComposerModel.Field {
        switch self {
        case .to: .to
        case .cc: .cc
        case .bcc: .bcc
        }
    }
}

/// What the composer's recipient rows read: who is in each, what is typed in each, and which are
/// drawn. What changes them is in `MailComposerModel`, beside the text and the draft they are saved with.
extension MailComposerModel {

    func people(in field: MailRecipientField) -> [MailPerson] {
        switch field {
        case .to: to
        case .cc: cc
        case .bcc: bcc
        }
    }

    func text(of field: MailRecipientField) -> String {
        switch field {
        case .to: toText
        case .cc: ccText
        case .bcc: bccText
        }
    }

    func setText(_ text: String, of field: MailRecipientField) {
        switch field {
        case .to: toText = text
        case .cc: ccText = text
        case .bcc: bccText = text
        }
    }

    /// The row a person is in, if they are in one.
    func field(of person: MailPerson) -> MailRecipientField? {
        let key = person.address.lowercased()
        return MailRecipientField.all.first { field in
            people(in: field).contains { $0.address.lowercased() == key }
        }
    }

    /// To is always drawn. Cc and Bcc are drawn once asked for, and while someone or something
    /// typed is in them: a reply to all that fills Cc shows it without being asked.
    func shows(_ field: MailRecipientField) -> Bool {
        field == .to || revealed.contains(field) || !people(in: field).isEmpty
            || !text(of: field).isEmpty
    }

    /// The rows still to ask for, in order: the words at the end of the To row.
    var hiddenRows: [MailRecipientField] {
        [MailRecipientField.cc, .bcc].filter { !shows($0) }
    }
}

#endif
