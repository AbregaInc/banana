#if !BANANA_PUBLIC
import Foundation

/// The face drawn for a person in the list and on a message: their initial on a colour of their
/// own. No picture is fetched for it (a sender would learn when the mail was read); the same
/// address always has the same colour, on every device, so a person is found by colour too.
struct MailFace: Equatable, Hashable, Sendable {
    /// One letter, upper-cased; "?" when neither the name nor the address has one.
    var initial: String
    /// Which of the faces' colours (`Monogram.hues`), from the address.
    var hue: Int

    static let hueCount = 10

    init(_ person: MailPerson) {
        initial = Self.initial(name: person.name, address: person.address)
        hue = Self.hue(person.address)
    }

    init(initial: String, hue: Int) {
        self.initial = initial
        self.hue = hue
    }

    /// The first letter of the name ("[Slack] Ann" is A), else of the address.
    static func initial(name: String?, address: String) -> String {
        for text in [name ?? "", address] {
            if let letter = text.first(where: \.isLetter) { return String(letter).uppercased() }
        }
        return "?"
    }

    /// A number from the address alone, the same in every process (not `hashValue`).
    static func hue(_ address: String) -> Int {
        var hash: UInt32 = 5381
        for byte in address.lowercased().utf8 { hash = (hash &* 33) ^ UInt32(byte) }
        return Int(hash % UInt32(hueCount))
    }

    /// Whose face a row shows: the first person in it who isn't him, or him when it is only him.
    static func of(_ people: [MailPerson]) -> MailFace? {
        guard let person = people.first(where: { !$0.isMe }) ?? people.first else { return nil }
        return MailFace(person)
    }
}

#endif
