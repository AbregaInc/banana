import Foundation
import ObjectiveC

/// Test-runner-only compatibility probe for missing SpringBoard animation notifications.
/// Appium WebDriverAgent also wraps these XCTest process selectors. No app method is changed.
/// Explicit opt-in; preserve app quiescence and measure real Instruments intervals separately.
enum PhysicalSystemIdlePolicy {
    static func installIfRequested() throws {
        guard ProcessInfo.processInfo.environment["STRESS_SYSTEM_ANIMATION_WAIT"] == "exclude" else { return }
        try installation.get()
    }

    private static let installation: Result<Void, Error> = Result {
        guard let process = NSClassFromString("XCUIApplicationProcess") else {
            throw failure("XCTest process class unavailable")
        }
        let modern = NSSelectorFromString("waitForQuiescenceIncludingAnimationsIdle:isPreEvent:")
        let legacy = NSSelectorFromString("waitForQuiescenceIncludingAnimationsIdle:")
        if let method = class_getInstanceMethod(process, modern) {
            typealias Function = @convention(c) (AnyObject, Selector, Bool, Bool) -> Void
            let original = unsafeBitCast(method_getImplementation(method), to: Function.self)
            let block: @convention(block) (AnyObject, Bool, Bool) -> Void = { object, animations, preEvent in
                let springboard = (object as? NSObject)?.value(forKey: "bundleID") as? String == "com.apple.springboard"
                if springboard { print("SYSTEM_IDLE_POLICY: excluding SpringBoard animations; app waits unchanged") }
                original(object, modern, springboard ? false : animations, preEvent)
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        } else if let method = class_getInstanceMethod(process, legacy) {
            typealias Function = @convention(c) (AnyObject, Selector, Bool) -> Void
            let original = unsafeBitCast(method_getImplementation(method), to: Function.self)
            let block: @convention(block) (AnyObject, Bool) -> Void = { object, animations in
                let springboard = (object as? NSObject)?.value(forKey: "bundleID") as? String == "com.apple.springboard"
                if springboard { print("SYSTEM_IDLE_POLICY: excluding SpringBoard animations; app waits unchanged") }
                original(object, legacy, springboard ? false : animations)
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        } else {
            throw failure("Unsupported XCTest idle-wait selector")
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "PhysicalSystemIdlePolicy", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
