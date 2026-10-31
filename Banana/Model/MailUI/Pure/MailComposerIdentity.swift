#if !BANANA_PUBLIC
import Foundation

/// Who a message is from and what signs it (MAIL-UX 6.3.3, 6.3.4).
///
/// **The signature is not part of the body.** It is the draft's own part (`MailDraft.signature`),
/// drawn as a block under the text, so editing the text cannot reach it; changing From swaps it, and
/// the source does both together (`changeIdentity(of:to:)`). It can be taken off this message, and
/// put back.
extension MailComposerModel {

    /// From is shown only when there is more than one address to choose (6.3.3).
    var showsFrom: Bool { identities.count > 1 }

    /// What he could still put back: the signature of the address it is from, taken off.
    var canPutSignatureBack: Bool { signature == nil && from?.hasSignature == true }

    /// He chose another address. The row says so at once; the signature follows with the source's
    /// answer, a moment after.
    func changeFrom(to identity: MailIdentity) {
        isChoosingFrom = false
        guard identity != from, isReady else { return }
        from = identity
        draft?.from = identity
        swapSignature(for: identity.address)
    }

    /// Off this message only: the next message has it again.
    func removeSignature() {
        guard signature != nil else { return }
        signature = nil
        draft?.signature = nil
        edited()
    }

    func putSignatureBack() {
        guard let from, canPutSignatureBack else { return }
        swapSignature(for: from.address)
    }

    /// Finishes when a change of From, and its signature, has been answered. For tests.
    func waitForIdentity() async {
        await identityChange?.value
    }

    private func swapSignature(for address: String) {
        guard let id = draftID else { return }
        // What the source has is what he has written: it is told before it is asked.
        flush()
        identityChange?.cancel()
        identityChange = Task { @MainActor [weak self] in
            guard let self else { return }
            guard let changed = await self.source.changeIdentity(of: id, to: address),
                  !Task.isCancelled, self.from?.address == changed.from.address else { return }
            self.signature = changed.signature
            self.draft?.from = changed.from
            self.draft?.signature = changed.signature
            self.edited()
        }
    }
}

#endif
