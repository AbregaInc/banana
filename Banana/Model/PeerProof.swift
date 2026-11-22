import Foundation

/// What the LAN peer proof signs (`PodcastPeerTransfer`): the nonce, then the challenger's and the
/// responder's names, each with its length first, so no two different pairs of names spell the
/// same bytes. v3: phone and Mac update together (a v2 peer's proof no longer verifies).
enum PeerProof {
    static func message(nonce: Data, challenger: String, responder: String) -> Data {
        var message = Data("banana-peer-proof-v3|".utf8)
        message.append(nonce)
        for name in [challenger, responder] {
            let bytes = Data(name.utf8)
            withUnsafeBytes(of: UInt32(bytes.count).bigEndian) { message.append(contentsOf: $0) }
            message.append(bytes)
        }
        return message
    }
}
