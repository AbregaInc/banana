#if os(iOS)
import UIKit

/// Refcounted screen-awake assertion.
///
/// `isIdleTimerDisabled` is one global flag, and it had independent owners (a bedside clock that
/// has since been removed, and a foreground transcription) writing it last-wins: the clock going
/// away mid-transcription re-enabled sleep out from under the job, the phone locked, and the
/// transcription froze.
/// Acquire/release instead — the flag reflects "any holder alive".
@MainActor
enum KeepAwake {
    private static var holders = 0

    static func acquire() {
        holders += 1
        UIApplication.shared.isIdleTimerDisabled = true
    }

    static func release() {
        assert(holders > 0, "KeepAwake.release() without a matching acquire() — an unbalanced release would clear another holder's assertion")
        holders = max(0, holders - 1)
        if holders == 0 { UIApplication.shared.isIdleTimerDisabled = false }
    }
}
#endif
