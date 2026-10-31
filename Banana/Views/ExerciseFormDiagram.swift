import SwiftUI

/// A deliberately deterministic two-frame form guide. It never claims to assess the person;
/// it shows the catalog's reviewed start/end positions without a network or generation delay.
struct ExerciseFormDiagram: View {
    let exercise: ExerciseDefinition

    var body: some View {
        HStack(spacing: 10) {
            frame(phase: 0, label: "START")
            Image(systemName: "arrow.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            frame(phase: 1, label: exercise.defaultDurationSeconds == nil ? "FINISH" : "HOLD")
        }
        // A phone's width at most: on the Mac's and the iPad's wide pages two frames stretched
        // across the whole window.
        .frame(maxWidth: 560, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Form guide for \(exercise.name), start and \(exercise.defaultDurationSeconds == nil ? "finish" : "hold") positions")
    }

    private func frame(phase: Int, label: String) -> some View {
        VStack(spacing: 5) {
            Canvas { context, size in
                let pose = FormPose.make(exercise.visual, phase: phase)
                func point(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * size.width, y: p.y * size.height) }
                var ground = Path()
                ground.move(to: CGPoint(x: size.width * 0.08, y: size.height * 0.9))
                ground.addLine(to: CGPoint(x: size.width * 0.92, y: size.height * 0.9))
                context.stroke(ground, with: .color(.secondary.opacity(0.28)), lineWidth: 1)

                for (a, b) in FormPose.bones {
                    var path = Path()
                    path.move(to: point(pose[a]))
                    path.addLine(to: point(pose[b]))
                    context.stroke(path, with: .color(.primary), style: .init(lineWidth: 5, lineCap: .round, lineJoin: .round))
                }
                let headCenter = point(pose[.head])
                let radius = max(5, size.width * 0.055)
                let head = Path(ellipseIn: CGRect(x: headCenter.x - radius, y: headCenter.y - radius,
                                                  width: radius * 2, height: radius * 2))
                context.fill(head, with: .color(.primary))
                for joint in FormJoint.allCases where joint != .head {
                    let center = point(pose[joint])
                    let marker = Path(ellipseIn: CGRect(x: center.x - 2.5, y: center.y - 2.5, width: 5, height: 5))
                    context.fill(marker, with: .color(.orange))
                }
            }
            .frame(height: 124)
            Text(label).font(.caption2.weight(.bold)).tracking(0.7).foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(DS.Palette.accent.opacity(DS.Tint.subtle), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private enum FormJoint: CaseIterable { case head, neck, leftShoulder, rightShoulder, leftElbow, rightElbow, leftHand, rightHand, hip, leftKnee, rightKnee, leftFoot, rightFoot }

private struct FormPose {
    var points: [FormJoint: CGPoint]
    subscript(_ joint: FormJoint) -> CGPoint { points[joint] ?? CGPoint(x: 0.5, y: 0.5) }

    static let bones: [(FormJoint, FormJoint)] = [
        (.head, .neck), (.neck, .leftShoulder), (.neck, .rightShoulder),
        (.leftShoulder, .leftElbow), (.leftElbow, .leftHand),
        (.rightShoulder, .rightElbow), (.rightElbow, .rightHand),
        (.neck, .hip), (.hip, .leftKnee), (.leftKnee, .leftFoot),
        (.hip, .rightKnee), (.rightKnee, .rightFoot),
    ]

    static func make(_ kind: ExerciseVisualKind, phase: Int) -> FormPose {
        switch kind {
        case .squat: return phase == 0 ? standing() : squat()
        case .lunge, .hipFlexorStretch: return phase == 0 ? standing() : lunge()
        case .pushup: return pushup(low: phase == 1)
        case .plank: return plank()
        case .bridge: return bridge(lifted: phase == 1)
        case .deadBug: return deadBug(reached: phase == 1)
        case .birdDog: return birdDog(reached: phase == 1)
        case .row: return row(pulled: phase == 1)
        case .overheadPress: return overhead(raised: phase == 1)
        case .curl: return curl(curled: phase == 1)
        case .hamstringStretch: return phase == 0 ? standing() : hamstring()
        case .calfStretch: return calf(deep: phase == 1)
        case .childPose: return childPose(reached: phase == 1)
        case .thoracicRotation: return rotation(open: phase == 1)
        case .chestStretch: return chest(open: phase == 1)
        }
    }

    private static func pose(_ values: [FormJoint: (Double, Double)]) -> FormPose {
        FormPose(points: values.mapValues { CGPoint(x: $0.0, y: $0.1) })
    }

    private static func standing() -> FormPose { pose([
        .head:(0.5,0.12),.neck:(0.5,0.23),.leftShoulder:(0.42,0.26),.rightShoulder:(0.58,0.26),
        .leftElbow:(0.39,0.43),.rightElbow:(0.61,0.43),.leftHand:(0.4,0.59),.rightHand:(0.6,0.59),
        .hip:(0.5,0.55),.leftKnee:(0.44,0.72),.rightKnee:(0.56,0.72),.leftFoot:(0.4,0.89),.rightFoot:(0.6,0.89)]) }
    private static func squat() -> FormPose { pose([
        .head:(0.49,0.18),.neck:(0.5,0.29),.leftShoulder:(0.42,0.31),.rightShoulder:(0.58,0.31),
        .leftElbow:(0.35,0.42),.rightElbow:(0.65,0.42),.leftHand:(0.47,0.45),.rightHand:(0.53,0.45),
        .hip:(0.52,0.58),.leftKnee:(0.34,0.66),.rightKnee:(0.68,0.66),.leftFoot:(0.27,0.88),.rightFoot:(0.75,0.88)]) }
    private static func lunge() -> FormPose { pose([
        .head:(0.48,0.13),.neck:(0.49,0.24),.leftShoulder:(0.41,0.27),.rightShoulder:(0.57,0.27),
        .leftElbow:(0.39,0.43),.rightElbow:(0.59,0.43),.leftHand:(0.42,0.58),.rightHand:(0.58,0.58),
        .hip:(0.5,0.55),.leftKnee:(0.32,0.69),.rightKnee:(0.67,0.75),.leftFoot:(0.23,0.88),.rightFoot:(0.77,0.88)]) }
    private static func pushup(low: Bool) -> FormPose { pose([
        .head:(0.22,low ? 0.6:0.46),.neck:(0.3,low ? 0.62:0.48),.leftShoulder:(0.35,low ? 0.62:0.49),.rightShoulder:(0.35,low ? 0.62:0.49),
        .leftElbow:(0.31,0.73),.rightElbow:(0.42,0.73),.leftHand:(0.4,0.86),.rightHand:(0.45,0.86),
        .hip:(0.58,low ? 0.64:0.57),.leftKnee:(0.73,low ? 0.69:0.63),.rightKnee:(0.73,low ? 0.69:0.63),.leftFoot:(0.88,0.79),.rightFoot:(0.88,0.79)]) }
    private static func plank() -> FormPose { pushup(low: false) }
    private static func bridge(lifted: Bool) -> FormPose { pose([
        .head:(0.18,0.76),.neck:(0.27,0.75),.leftShoulder:(0.34,0.76),.rightShoulder:(0.34,0.76),
        .leftElbow:(0.44,0.81),.rightElbow:(0.44,0.81),.leftHand:(0.54,0.86),.rightHand:(0.54,0.86),
        .hip:(0.58,lifted ? 0.48:0.76),.leftKnee:(0.75,0.57),.rightKnee:(0.75,0.57),.leftFoot:(0.84,0.87),.rightFoot:(0.84,0.87)]) }
    private static func deadBug(reached: Bool) -> FormPose { pose([
        .head:(0.2,0.75),.neck:(0.29,0.73),.leftShoulder:(0.36,0.72),.rightShoulder:(0.36,0.72),
        .leftElbow:(reached ? 0.29:0.4,reached ? 0.4:0.51),.rightElbow:(0.42,0.5),.leftHand:(reached ? 0.2:0.42,reached ? 0.22:0.31),.rightHand:(0.44,0.3),
        .hip:(0.57,0.72),.leftKnee:(reached ? 0.7:0.58,reached ? 0.62:0.48),.rightKnee:(0.58,0.48),.leftFoot:(reached ? 0.87:0.75,reached ? 0.69:0.48),.rightFoot:(0.75,0.48)]) }
    private static func birdDog(reached: Bool) -> FormPose { pose([
        .head:(0.25,0.46),.neck:(0.34,0.49),.leftShoulder:(0.4,0.51),.rightShoulder:(0.4,0.51),
        .leftElbow:(reached ? 0.26:0.4,reached ? 0.43:0.69),.rightElbow:(0.44,0.69),.leftHand:(reached ? 0.12:0.4,reached ? 0.38:0.87),.rightHand:(0.44,0.87),
        .hip:(0.63,0.55),.leftKnee:(reached ? 0.78:0.64,reached ? 0.55:0.72),.rightKnee:(0.65,0.74),.leftFoot:(reached ? 0.91:0.61,reached ? 0.54:0.88),.rightFoot:(0.64,0.89)]) }
    private static func row(pulled: Bool) -> FormPose { pose([
        .head:(0.25,0.29),.neck:(0.34,0.34),.leftShoulder:(0.41,0.38),.rightShoulder:(0.42,0.38),
        .leftElbow:(0.55,pulled ? 0.45:0.59),.rightElbow:(0.31,0.56),.leftHand:(0.48,pulled ? 0.51:0.75),.rightHand:(0.28,0.75),
        .hip:(0.63,0.51),.leftKnee:(0.73,0.68),.rightKnee:(0.58,0.69),.leftFoot:(0.82,0.88),.rightFoot:(0.5,0.88)]) }
    private static func overhead(raised: Bool) -> FormPose { var p = standing(); p.points[.leftElbow] = CGPoint(x: 0.39, y: raised ? 0.18:0.34); p.points[.rightElbow] = CGPoint(x: 0.61, y: raised ? 0.18:0.34); p.points[.leftHand] = CGPoint(x: 0.43, y: raised ? 0.05:0.23); p.points[.rightHand] = CGPoint(x: 0.57, y: raised ? 0.05:0.23); return p }
    private static func curl(curled: Bool) -> FormPose { var p = standing(); p.points[.leftHand] = CGPoint(x: 0.43, y: curled ? 0.31:0.6); p.points[.rightHand] = CGPoint(x: 0.57, y: curled ? 0.31:0.6); return p }
    private static func hamstring() -> FormPose { pose([.head:(0.31,0.34),.neck:(0.38,0.39),.leftShoulder:(0.43,0.42),.rightShoulder:(0.45,0.42),.leftElbow:(0.53,0.51),.rightElbow:(0.53,0.51),.leftHand:(0.62,0.62),.rightHand:(0.62,0.62),.hip:(0.58,0.57),.leftKnee:(0.42,0.7),.rightKnee:(0.68,0.69),.leftFoot:(0.27,0.88),.rightFoot:(0.74,0.88)]) }
    private static func calf(deep: Bool) -> FormPose { pose([.head:(0.29,0.2),.neck:(0.35,0.29),.leftShoulder:(0.4,0.31),.rightShoulder:(0.4,0.31),.leftElbow:(0.28,0.44),.rightElbow:(0.28,0.44),.leftHand:(0.16,0.52),.rightHand:(0.16,0.52),.hip:(0.54,0.51),.leftKnee:(0.48,0.69),.rightKnee:(0.72,deep ? 0.67:0.72),.leftFoot:(0.43,0.88),.rightFoot:(0.88,0.88)]) }
    private static func childPose(reached: Bool) -> FormPose { pose([.head:(0.36,0.63),.neck:(0.43,0.6),.leftShoulder:(0.49,0.6),.rightShoulder:(0.49,0.6),.leftElbow:(reached ? 0.29:0.46,0.69),.rightElbow:(reached ? 0.29:0.46,0.69),.leftHand:(reached ? 0.14:0.43,0.78),.rightHand:(reached ? 0.14:0.43,0.78),.hip:(0.7,0.61),.leftKnee:(0.62,0.78),.rightKnee:(0.62,0.78),.leftFoot:(0.78,0.88),.rightFoot:(0.78,0.88)]) }
    private static func rotation(open: Bool) -> FormPose { var p = deadBug(reached: false); p.points[.leftElbow] = CGPoint(x: open ? 0.5:0.34, y: open ? 0.38:0.6); p.points[.leftHand] = CGPoint(x: open ? 0.67:0.42, y: open ? 0.25:0.68); return p }
    private static func chest(open: Bool) -> FormPose { var p = standing(); p.points[.leftElbow] = CGPoint(x: open ? 0.25:0.39, y: 0.31); p.points[.rightElbow] = CGPoint(x: open ? 0.75:0.61, y: 0.31); p.points[.leftHand] = CGPoint(x: open ? 0.14:0.4, y: 0.24); p.points[.rightHand] = CGPoint(x: open ? 0.86:0.6, y: 0.24); return p }
}
