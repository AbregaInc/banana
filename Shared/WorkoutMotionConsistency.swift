import Foundation

/// Pure, no-SwiftUI "technique consistency" measure for a page (lap, or 60 s window) of
/// phase-resampled acceleration cycles — the real number behind `MotionSignatureCard`'s caption.
///
/// This exists to fix a real mistake made about the 3D acceleration signature chart: the original
/// guidance was "a tight, overlapping cloud means consistent technique; a scattered one means
/// inconsistent." The owner caught this himself: "wouldn't a diffuse cloud actually be correct
/// assuming you move with a certain amount of force? The tightest cloud would be caused by
/// extremely consistently LOW-G movement?" He is right — the cloud's overall SIZE is set by how
/// forcefully he moved (and, since this is raw accelerometer signal with gravity still in it, by
/// wrist orientation too, not force alone), which has nothing to do with whether the SHAPE repeats
/// cycle to cycle. A gentle, perfectly even effort produces a small cloud that looks "tight" by
/// raw size alone despite the eye having no real technique signal to go on; a hard, well-drilled
/// effort can produce a big one. Absolute tightness conflates the two.
///
/// The fix: measure whether the cycles overlay ONE ANOTHER after removing each cycle's own
/// rotation (a Procrustes/Kabsch alignment — the cycles are compared by shape, not by their raw
/// orientation in accelerometer-axis space, which has no fixed meaning stroke to stroke), and
/// report that residual spread as a FRACTION of the aligned loop's own size. Dividing by the
/// loop's own size is what makes the number scale-invariant: multiply every cycle's acceleration
/// by the same constant (a harder push, not a less consistent one) and both the spread and the
/// size scale together, leaving the ratio unchanged — see `WorkoutMotionConsistencyTests` for the
/// exact property this is built to satisfy.
///
/// Same method the reconstruction-spike quality check already validated
/// (`scratchpad/truepath2/lib2.py`, `scratchpad/truepath/recon.py`): Generalized Procrustes
/// Alignment (GPA) to a converging mean loop, then median pairwise RMSD across the aligned loops
/// divided by the mean loop's own RMS-from-centroid size. Re-implemented here in pure Swift (no
/// SciPy/NumPy) so it can run off the main actor inside `WorkoutMotionAnalysis.analyze`.
enum WorkoutMotionConsistency {

    /// One phase-resampled cycle's (x, y, z) trace as `N` points, matching
    /// `WorkoutMotionAnalysis.Cycle.phaseX/phaseY/phaseZ`'s shape — kept decoupled from that type
    /// so this file's pure alignment/dispersion math can be exercised directly against synthetic
    /// point clouds without constructing a full `Cycle`.
    struct Point3: Sendable, Equatable {
        var x: Double
        var y: Double
        var z: Double
    }

    struct Loop: Sendable {
        var points: [Point3]
    }

    /// Scale-invariant consistency ratio for a set of same-length loops — lower means the cycles
    /// overlay more tightly relative to their own size (more repeatable technique); higher means
    /// they diverge more. `nil` when there's nothing to compare: fewer than two loops, loops of
    /// mismatched or zero length, or a degenerate (near-zero-size) aligned mean loop, which would
    /// otherwise blow the ratio up to a meaningless huge number instead of reporting nothing.
    static func consistencyRatio(loops loopsIn: [Loop], gpaIterations: Int = 6) -> Float? {
        let loops = loopsIn.compactMap(centered)
        guard loops.count >= 2 else { return nil }
        let count = loops[0].points.count
        guard count > 0, loops.allSatisfy({ $0.points.count == count }) else { return nil }

        var mean = loops[0]
        var aligned = loops
        for _ in 0..<max(gpaIterations, 1) {
            aligned = loops.map { align($0, to: mean) }
            mean = meanLoop(aligned)
        }

        let size = loopSize(mean)
        guard size > 1e-9, let median = medianPairwiseRMSD(aligned) else { return nil }
        return Float(median / size)
    }

    // MARK: - Centering

    private static func centered(_ loop: Loop) -> Loop? {
        guard !loop.points.isEmpty else { return nil }
        let n = Double(loop.points.count)
        var cx = 0.0, cy = 0.0, cz = 0.0
        for p in loop.points { cx += p.x; cy += p.y; cz += p.z }
        cx /= n; cy /= n; cz /= n
        return Loop(points: loop.points.map { Point3(x: $0.x - cx, y: $0.y - cy, z: $0.z - cz) })
    }

    // MARK: - Kabsch rotation-only alignment via Horn's closed-form quaternion method

    /// Rotates `loop` (already zero-mean) onto `reference` (already zero-mean) by the least-
    /// squares-optimal PURE rotation — Horn's 1987 closed-form absolute-orientation solution: the
    /// eigenvector of the largest eigenvalue of a 4×4 matrix built from the cross-covariance of
    /// the two point sets is the optimal rotation quaternion. Chosen over the textbook SVD form of
    /// Kabsch specifically because a unit quaternion cannot represent a reflection — the SVD
    /// version needs an explicit determinant-sign correction to rule reflections out; this method
    /// rules them out by construction.
    private static func align(_ loop: Loop, to reference: Loop) -> Loop {
        guard loop.points.count == reference.points.count, !loop.points.isEmpty else { return loop }
        var sxx = 0.0, sxy = 0.0, sxz = 0.0
        var syx = 0.0, syy = 0.0, syz = 0.0
        var szx = 0.0, szy = 0.0, szz = 0.0
        for i in 0..<loop.points.count {
            let p = loop.points[i], q = reference.points[i]
            sxx += p.x * q.x; sxy += p.x * q.y; sxz += p.x * q.z
            syx += p.y * q.x; syy += p.y * q.y; syz += p.y * q.z
            szx += p.z * q.x; szy += p.z * q.y; szz += p.z * q.z
        }
        let n = [
            [sxx + syy + szz, syz - szy, szx - sxz, sxy - syx],
            [syz - szy, sxx - syy - szz, sxy + syx, szx + sxz],
            [szx - sxz, sxy + syx, -sxx + syy - szz, syz + szy],
            [sxy - syx, szx + sxz, syz + szy, -sxx - syy + szz],
        ]
        guard let q = dominantEigenvector(symmetric4x4: n) else { return loop }
        let (w, x, y, z) = (q[0], q[1], q[2], q[3])
        // Standard unit-quaternion -> rotation-matrix conversion.
        let r00 = 1 - 2 * (y * y + z * z), r01 = 2 * (x * y - z * w), r02 = 2 * (x * z + y * w)
        let r10 = 2 * (x * y + z * w), r11 = 1 - 2 * (x * x + z * z), r12 = 2 * (y * z - x * w)
        let r20 = 2 * (x * z - y * w), r21 = 2 * (y * z + x * w), r22 = 1 - 2 * (x * x + y * y)
        return Loop(points: loop.points.map { p in
            Point3(x: r00 * p.x + r01 * p.y + r02 * p.z,
                   y: r10 * p.x + r11 * p.y + r12 * p.z,
                   z: r20 * p.x + r21 * p.y + r22 * p.z)
        })
    }

    private static func meanLoop(_ loops: [Loop]) -> Loop {
        guard let count = loops.first?.points.count, count > 0, !loops.isEmpty else { return Loop(points: []) }
        var sum = [Point3](repeating: Point3(x: 0, y: 0, z: 0), count: count)
        for loop in loops {
            for i in 0..<count {
                sum[i].x += loop.points[i].x
                sum[i].y += loop.points[i].y
                sum[i].z += loop.points[i].z
            }
        }
        let n = Double(loops.count)
        return Loop(points: sum.map { Point3(x: $0.x / n, y: $0.y / n, z: $0.z / n) })
    }

    /// RMS distance from centroid — `mean` is already zero-mean (average of zero-mean, rotated-
    /// but-not-translated loops), so this is just its RMS magnitude.
    private static func loopSize(_ loop: Loop) -> Double {
        guard !loop.points.isEmpty else { return 0 }
        let sumSq = loop.points.reduce(0.0) { $0 + $1.x * $1.x + $1.y * $1.y + $1.z * $1.z }
        return (sumSq / Double(loop.points.count)).squareRoot()
    }

    private static func rmsd(_ a: Loop, _ b: Loop) -> Double? {
        guard a.points.count == b.points.count, !a.points.isEmpty else { return nil }
        var sum = 0.0
        for i in 0..<a.points.count {
            let dx = a.points[i].x - b.points[i].x
            let dy = a.points[i].y - b.points[i].y
            let dz = a.points[i].z - b.points[i].z
            sum += dx * dx + dy * dy + dz * dz
        }
        return (sum / Double(a.points.count)).squareRoot()
    }

    private static func medianPairwiseRMSD(_ loops: [Loop]) -> Double? {
        guard loops.count >= 2 else { return nil }
        var distances: [Double] = []
        distances.reserveCapacity(loops.count * (loops.count - 1) / 2)
        for i in 0..<loops.count {
            for j in (i + 1)..<loops.count {
                if let d = rmsd(loops[i], loops[j]) { distances.append(d) }
            }
        }
        guard !distances.isEmpty else { return nil }
        distances.sort()
        return distances[distances.count / 2]
    }

    // MARK: - Symmetric 4×4 dominant eigenvector (cyclic Jacobi eigenvalue algorithm)

    /// Classic cyclic Jacobi eigenvalue algorithm: repeatedly zeroes the largest off-diagonal
    /// pairs via Givens rotations until the matrix converges to diagonal. Chosen over power
    /// iteration because it converges reliably regardless of how close the top two eigenvalues
    /// are — a near-symmetric point cloud (a real risk here: many strokes look similar by design)
    /// can put them close together, which would make power iteration converge slowly or stall.
    /// Returns the eigenvector for the LARGEST eigenvalue, normalized, as `[w, x, y, z]` — Horn's
    /// closed-form absolute-orientation result. `nil` only when the input is degenerate enough
    /// that no eigenvector has meaningful magnitude (never expected for a real cross-covariance
    /// matrix built from actual motion, but guarded rather than assumed).
    private static func dominantEigenvector(symmetric4x4 input: [[Double]]) -> [Double]? {
        let n = 4
        var a = input
        var v = (0..<n).map { i in (0..<n).map { j in i == j ? 1.0 : 0.0 } }
        for _ in 0..<60 {
            var off = 0.0
            for p in 0..<n { for q in (p + 1)..<n { off += a[p][q] * a[p][q] } }
            if off < 1e-24 { break }
            for p in 0..<(n - 1) {
                for q in (p + 1)..<n {
                    guard abs(a[p][q]) > 1e-300 else { continue }
                    let theta = (a[q][q] - a[p][p]) / (2 * a[p][q])
                    let t = (theta >= 0 ? 1.0 : -1.0) / (abs(theta) + (theta * theta + 1).squareRoot())
                    let c = 1 / (t * t + 1).squareRoot()
                    let s = t * c
                    let app = a[p][p], aqq = a[q][q], apq = a[p][q]
                    a[p][p] = c * c * app - 2 * s * c * apq + s * s * aqq
                    a[q][q] = s * s * app + 2 * s * c * apq + c * c * aqq
                    a[p][q] = 0; a[q][p] = 0
                    for i in 0..<n where i != p && i != q {
                        let aip = a[i][p], aiq = a[i][q]
                        a[i][p] = c * aip - s * aiq; a[p][i] = a[i][p]
                        a[i][q] = s * aip + c * aiq; a[q][i] = a[i][q]
                    }
                    for i in 0..<n {
                        let vip = v[i][p], viq = v[i][q]
                        v[i][p] = c * vip - s * viq
                        v[i][q] = s * vip + c * viq
                    }
                }
            }
        }
        var bestIndex = 0
        var bestValue = a[0][0]
        for i in 1..<n where a[i][i] > bestValue { bestValue = a[i][i]; bestIndex = i }
        let vector = (0..<n).map { v[$0][bestIndex] }
        let norm = vector.reduce(0.0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 1e-12 else { return nil }
        return vector.map { $0 / norm }
    }
}
