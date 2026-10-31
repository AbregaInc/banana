import Foundation

/// Converts between a unit quaternion (as CoreMotion's `CMAttitude.quaternion` reports it) and
/// its rotation-vector (axis × angle, Rodrigues) form.
///
/// `FitnessSample` has room for exactly three doubles per record (`v1`, `v2`, `v3` — see
/// `FitnessModels.swift`), so a quaternion's four numbers can't be stored directly, and storing
/// only part of it (e.g. just the gravity/down direction) would throw away a degree of freedom —
/// two numbers describe "which way is down", not "which way the wrist is facing". A rotation
/// vector is a full, non-redundant 3-number encoding of the same orientation: its direction is
/// the rotation axis, its magnitude is the rotation angle in radians.
///
/// No CoreMotion import here on purpose — this is the pure math, callable from a plain `(x, y,
/// z, w)` tuple so it needs nothing device-specific and is trivially unit-testable.
enum RotationVector {
    /// Quaternion → rotation vector, for encoding a captured attitude into a sample.
    ///
    /// `w` is clamped into [-1, 1] first: a unit quaternion's real part can drift fractionally
    /// outside that range from accumulated floating-point error, and `acos` of anything outside
    /// it is NaN.
    static func encode(x: Double, y: Double, z: Double, w: Double) -> (x: Double, y: Double, z: Double) {
        let clampedW = max(-1, min(1, w))
        let angle = 2 * acos(clampedW)
        let sinHalfAngle = (1 - clampedW * clampedW).squareRoot()
        // Below this, the rotation is close enough to zero that any axis is as good as any
        // other — the angle carries all the information and it's already ~0 either way.
        guard sinHalfAngle > 1e-9 else { return (0, 0, 0) }
        let scale = angle / sinHalfAngle
        return (x * scale, y * scale, z * scale)
    }

    /// Rotation vector → quaternion, the inverse of `encode`. A zero vector decodes to the
    /// identity quaternion.
    static func decode(x: Double, y: Double, z: Double) -> (x: Double, y: Double, z: Double, w: Double) {
        let angle = (x * x + y * y + z * z).squareRoot()
        guard angle > 1e-9 else { return (0, 0, 0, 1) }
        let halfAngle = angle / 2
        let scale = sin(halfAngle) / angle
        return (x * scale, y * scale, z * scale, cos(halfAngle))
    }
}
