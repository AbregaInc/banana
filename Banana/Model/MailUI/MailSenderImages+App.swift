#if !BANANA_PUBLIC
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Where sender images meet the app: Banana Cloud through the signed-in account, and the folder
/// they are kept in. The sample mailbox asks no one; `--mail-sender-images` (Debug) gives it drawn
/// stand-ins, for pictures of the list.
extension MailSenderImages {
    static let shared: MailSenderImages = {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mail-sender-images", isDirectory: true)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--mail-sender-images") {
            return MailSenderImages(directory: folder.appendingPathComponent("fixture", isDirectory: true), service: .fixture)
        }
        #endif
        return MailSenderImages(directory: folder, service: .cloud)
    }()
}

extension MailSenderImages.Service {
    /// `POST /v1/mail/senders` and `GET /v1/mail/sender-image/<id>`.
    static let cloud = MailSenderImages.Service(
        lookup: { addresses in
            let body = try JSONSerialization.data(withJSONObject: ["addresses": addresses])
            guard let (data, status) = await BananaAccount.shared.senderImagesRequest(.mailSenders(body)), status == 200
            else { throw URLError(.cannotLoadFromNetwork) }
            return try MailSenderImages.answers(from: data)
        },
        bytes: { id in
            guard let (data, status) = await BananaAccount.shared.senderImagesRequest(.mailSenderImage(id: id)) else {
                throw URLError(.cannotLoadFromNetwork)
            }
            return status == 200 ? data : nil
        })

    #if DEBUG
    /// The sample mailbox's senders, every third one with a drawn picture: a disc of colour with a
    /// mark, made here. Nothing leaves the device.
    static let fixture = MailSenderImages.Service(
        lookup: { addresses in
            Dictionary(uniqueKeysWithValues: addresses.map { address in
                (address, MailFace.hue(address) % 3 == 0 ? .image(MailSenderImages.fixtureID(address)) : .none)
            })
        },
        bytes: { id in MailSenderImages.fixturePNG(id) })
    #endif
}

extension MailSenderImages {
    /// The service's `{"senders": [{address, image} | {address, pending: true}]}`, by address.
    static func answers(from data: Data) throws -> [String: Answer] {
        struct Body: Decodable {
            struct Sender: Decodable { var address: String; var image: String?; var pending: Bool? }
            var senders: [Sender]
        }
        var out: [String: Answer] = [:]
        for sender in try JSONDecoder().decode(Body.self, from: data).senders {
            out[key(sender.address)] = sender.pending == true ? .pending : sender.image.map(Answer.image) ?? .none
        }
        return out
    }

    #if DEBUG
    static func fixtureID(_ address: String) -> String {
        let hex = String(format: "%08x", UInt32(truncatingIfNeeded: MailFace.hue(address) &* 2_654_435_761 &+ address.utf8.count))
        return String(repeating: hex, count: 8)
    }

    /// A 128 px picture: a diagonal of two colours, so it reads as a picture and not a monogram.
    static func fixturePNG(_ id: String) -> Data? {
        let seed = Int(id.prefix(8), radix: 16) ?? 0
        let size = 128
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let hue = CGFloat(seed % 360) / 360
        func color(_ h: CGFloat, _ b: CGFloat) -> CGColor {
            let r = abs(h * 6 - 3) - 1, g = 2 - abs(h * 6 - 2), bl = 2 - abs(h * 6 - 4)
            return CGColor(srgbRed: min(max(r, 0), 1) * b, green: min(max(g, 0), 1) * b, blue: min(max(bl, 0), 1) * b, alpha: 1)
        }
        context.setFillColor(color(hue, 0.85))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(color((hue + 0.5).truncatingRemainder(dividingBy: 1), 0.95))
        context.move(to: .zero); context.addLine(to: CGPoint(x: size, y: 0)); context.addLine(to: CGPoint(x: size, y: size))
        context.closePath(); context.fillPath()
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
    #endif
}

#endif
