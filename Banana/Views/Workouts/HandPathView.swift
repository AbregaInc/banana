import SwiftUI

/// SwiftUI `Canvas` renderer for one workout's hand-path helix — shared verbatim by iOS and Mac.
/// Swift Charts has **no 3D line mark**: `Chart3DContent` admits only `PointMark`, `RectangleMark`,
/// `RuleMark`, and `SurfacePlot` (verified against the iOS 26.5 SDK), so a tube isn't expressible
/// there. A plain `Canvas` also renders inside the headless Mac snapshot harness, which `Chart3D`
/// may not.
///
/// Self-contained like `WorkoutMotionSection`'s `MotionSignatureCard`: takes the whole
/// `WorkoutHandPath.Analysis` and picks its own default lap, camera, and radius exaggeration — a
/// caller drops this in once `WorkoutMotionCache.shared.handPath(for:fitness:)` has resolved, and
/// never recomputes anything from raw samples (all geometry comes from `HandPathScene`, all
/// numbers from `analysis` and its laps).
struct HandPathView: View {
    let analysis: WorkoutHandPath.Analysis
    /// 0-based array index into `analysis.laps` — overrides `Self.defaultLapIndex(analysis.laps)`
    /// on first appearance when it names a valid lap. Used only by `WorkoutMotionSection`'s DEBUG
    /// `--hand-path-lap <lap>` screenshot route so a specific lap can be captured; that flag is
    /// 1-based (matching the "Lap N of M" the `pager` below shows), and `WorkoutMotionSection` is
    /// what converts it to this 0-based index before passing it in. Every normal call site leaves
    /// this `nil` and gets the picked-for-you default.
    var initialLapIndex: Int? = nil

    /// -1 = "not yet defaulted"; set in `onAppear` from `initialLapIndex` or
    /// `Self.defaultLapIndex(analysis.laps)`, same sentinel pattern as `MotionSignatureCard.page`.
    @State private var lapIndex = -1
    @State private var camera = HandPathScene.Camera.default
    @State private var dragLock: DragLock = .none
    @State private var dragStartCamera: HandPathScene.Camera?
    @State private var zoomAtGestureStart: Double = 1
    /// Drives the "play" button (`playButton`) via `.task(id: isPlaying)` below — see
    /// `LapPlayback`'s doc comment for why a boolean + `.task` rather than a `Timer`.
    @State private var isPlaying = false

    #if os(iOS)
    /// iOS only — mirrors `MotionSignatureCard.showExpanded` (`WorkoutMotionSection.swift`): the
    /// inline card shows a fixed, non-interactive orbit angle so a one-finger drag on it can't
    /// compete with the detail screen's own vertical `ScrollView`. Tapping opens this full-screen
    /// sheet, where `orbitDrag`/`magnifyGesture` apply with nothing else on screen to contest the
    /// gesture with. See `canvas(for:drawing:zoom:)`'s doc comment for why this exists at all —
    /// `.simultaneousGesture` plus a direction gate, the approach that doc comment used to
    /// describe, measurably does NOT let the drag through on this platform.
    @State private var showExpanded = false
    #endif

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Tracks one `DragGesture`'s direction decision (see `orbitDrag`'s doc comment): `.none`
    /// until enough movement has happened to tell, then locked for the rest of that gesture.
    private enum DragLock: Equatable { case none, horizontal, rejected }

    /// Laps come from the analysis's own array, never `max(lapIndex, 0)` used bare — see `lap` and
    /// `pager` below, both of which key off this pair so a still-negative sentinel (before
    /// `onAppear` runs) reads as lap 0 instead of an out-of-range index.
    private var lapCount: Int { analysis.laps.count }
    private var currentLapIndex: Int { max(lapIndex, 0) }

    private var lap: WorkoutHandPath.Lap? {
        guard analysis.laps.indices.contains(currentLapIndex) else { return nil }
        return analysis.laps[currentLapIndex]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let lap {
                inlineCanvas(for: lap)
                statRow(lap)
                radiusControl
                #if os(macOS)
                zoomControl
                #endif
                colorKey
                captionBlock(lap)
            } else {
                WorkoutSectionNote(text: "No hand path for this workout.")
            }
        }
        .padding(WorkoutMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
        .onAppear {
            guard lapIndex < 0 else { return }
            if let initialLapIndex, analysis.laps.indices.contains(initialLapIndex) {
                lapIndex = initialLapIndex
            } else {
                lapIndex = Self.defaultLapIndex(analysis.laps)
            }
            #if DEBUG
            if let debugCamera = Self.debugInitialCamera() { camera = debugCamera }
            #endif
        }
        // Explicit belt-and-suspenders stop, on top of `.task(id:)`'s own automatic cancellation
        // on disappearance (see `LapPlayback`'s doc comment) — this view's `isPlaying` is
        // per-instance `@State`, so this only matters if SwiftUI ever reuses this exact view
        // instance's identity across a disappearance, which the flag being reset here rules out.
        .onDisappear { isPlaying = false }
        .task(id: isPlaying) {
            guard isPlaying else { return }
            await LapPlayback.run {
                let next = currentLapIndex + 1
                guard next < lapCount else {
                    isPlaying = false
                    return false
                }
                withAnimation(reduceMotion ? nil : .default) { lapIndex = next }
                return true
            }
        }
        #if os(iOS)
        .sheet(isPresented: $showExpanded) {
            if let lap { expandedCanvas(lap) }
        }
        #endif
    }

    // MARK: - Header: title, camera preset menu, lap pager

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Hand path").font(WorkoutType.chartTitle)
            Spacer()
            // Nothing to page through or orbit when there are no laps at all — the body below
            // falls back to `WorkoutSectionNote` in that case, so these would otherwise show a
            // hollow "Lap 1 of 1", both arrows disabled, implying a lap that doesn't exist.
            if !analysis.laps.isEmpty {
                // iOS: the orbit presets only mean anything where the orbit itself is live — the
                // expanded sheet (`expandedCanvas`'s own toolbar), not this inline card, which
                // shows a fixed angle. Mac keeps it here since the inline canvas stays orbitable.
                #if os(macOS)
                cameraMenu.iconButton()
                #endif
                pager
            }
        }
    }

    private var cameraMenu: some View {
        Menu {
            Button("Side-on") { setCameraPreset(.side) }
            Button("From above") { setCameraPreset(.above) }
            Button("Down the lane") { setCameraPreset(.downLane) }
        } label: {
            Image(systemName: "cube.transparent")
        }
        .accessibilityLabel("Camera angle")
    }

    private var pager: some View {
        HStack(spacing: 0) {
            playButton
            Button {
                isPlaying = false   // manual navigation always wins over auto-play, never fights it
                lapIndex = max(0, currentLapIndex - 1)
            } label: { Image(systemName: "chevron.left") }
                .iconButton()
                .disabled(currentLapIndex <= 0)
            Text("Lap \(currentLapIndex + 1) of \(max(lapCount, 1))")
                .font(.caption).monospacedDigit().frame(minWidth: 80)
            Button {
                isPlaying = false
                lapIndex = min(lapCount - 1, currentLapIndex + 1)
            } label: { Image(systemName: "chevron.right") }
                .iconButton()
                .disabled(currentLapIndex >= lapCount - 1)
        }
    }

    /// Auto-advances through every lap at `LapPlayback.stepInterval` — the owner's own reasoning
    /// (see `LapPlayback`'s doc comment) is that watching the hand path change lap by lap makes
    /// wobble over time visible in a way stepping one lap at a time does not. Disabled with only
    /// one lap to page through — nothing to animate.
    private var playButton: some View {
        Button {
            isPlaying.toggle()
        } label: {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
        }
        .iconButton()
        .disabled(lapCount <= 1)
        .accessibilityLabel(isPlaying ? "Pause lap playback" : "Play through every lap")
    }

    // MARK: - Canvas

    /// A CEILING, not a fixed height — the actual rendered height is `aspectRatio(for:)` fit to
    /// the available width, up to this cap, so the card never carries the big empty band a fixed
    /// tall frame leaves above/below a wide, shallow helix. Phone-only taller cap on iOS, matching
    /// `MotionSignatureCard.signatureHeight`'s reasoning — the shared `WorkoutMetrics.chartHeight`
    /// (180pt) is tuned for a flat 2D chart, and a 3D scene reads as noise below that. Mac keeps
    /// the shared cap; it has the width to spare and this section already sits alongside several
    /// other fixed-height cards there.
    private var canvasHeight: CGFloat {
        #if os(iOS)
        300
        #else
        WorkoutMetrics.chartHeight
        #endif
    }

    /// Pure drawing — no gesture attached here. `zoom` is passed explicitly rather than read from
    /// `camera.zoom` directly so a caller can draw a FIXED orientation (the iOS inline card, via
    /// `inlineCamera`) while `camera.zoom` itself keeps whatever the expanded sheet last left it
    /// at; reading `camera.zoom` here unconditionally would re-couple the two.
    ///
    /// `identifier` distinguishes the inline card's canvas from the iOS expanded sheet's own copy
    /// of this same drawing — both can be in the view hierarchy at once (a `.sheet` doesn't tear
    /// down its presenter), so a shared identifier would make either ambiguous to a UI test.
    private func canvas(for lap: WorkoutHandPath.Lap, drawing: HandPathScene.Drawing, zoom: Double,
                         identifier: String = "workout.handPathCanvas") -> some View {
        Canvas { context, size in
            let transform = Self.fitTransform(drawing: drawing, size: size, zoom: zoom)
            Self.draw(lane: drawing.laneBehind, context: &context, transform: transform)
            Self.draw(segments: drawing.segments, context: &context, transform: transform)
            Self.draw(lane: drawing.laneFront, context: &context, transform: transform)
            // Always drawn last, on top of everything — see `HandPathScene.Drawing.markers`'s doc
            // comment for why these deliberately skip the depth-based fading every other layer
            // here gets: "unmistakable from any angle" means never receding into the tube.
            Self.draw(markers: drawing.markers, context: &context, transform: transform)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(accessibilityLabel(for: lap))
    }

    /// The card's own display camera: on Mac, the live, orbitable `camera` (unchanged from
    /// before). On iOS, a fixed default orientation — only `radiusExaggeration` (driven by
    /// `radiusControl`'s `Slider`, never a drag) still tracks the live value, since that control
    /// has never been part of the scroll conflict.
    private var inlineCamera: HandPathScene.Camera {
        #if os(macOS)
        camera
        #else
        var displayCamera = HandPathScene.Camera.default
        displayCamera.radiusExaggeration = camera.radiusExaggeration
        return displayCamera
        #endif
    }

    /// The card's own canvas — orbitable inline on Mac (unchanged), a tappable fixed-angle preview
    /// on iOS. See `expandedCanvas`'s doc comment for why iOS moved the live orbit off this view
    /// entirely instead of trying to gate the drag in place.
    @ViewBuilder
    private func inlineCanvas(for lap: WorkoutHandPath.Lap) -> some View {
        let drawing = HandPathScene.build(lap: lap, radiusMeters: analysis.radiusMeters, camera: inlineCamera)
        let sized = canvas(for: lap, drawing: drawing, zoom: inlineCamera.zoom)
            .aspectRatio(CGFloat(HandPathScene.aspectRatio(for: drawing)), contentMode: .fit)
            .frame(maxHeight: canvasHeight)
        #if os(macOS)
        sized
            .contentShape(Rectangle())
            .simultaneousGesture(orbitDrag)
            .simultaneousGesture(magnifyGesture)
            .onTapGesture(count: 2) { resetCamera() }
        #else
        sized
            .contentShape(Rectangle())
            .onTapGesture { showExpanded = true }
            .overlay(alignment: .topTrailing) {
                Image(systemName: "arrow.up.left.and.arrow.down.right.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("\(accessibilityLabel(for: lap)) Tap to explore in full screen.")
        #endif
    }

    #if os(iOS)
    /// The interactive counterpart to the inline card's fixed angle above — same drawing, but with
    /// the real `orbitDrag`/`magnifyGesture` and nothing else on screen to contest them with. Same
    /// shape as `WorkoutMotionSection.MotionSignatureCard.expandedSignature`.
    ///
    /// This — not the inline card — is where `HandPathScene.Camera`'s live orbit actually lives on
    /// iOS. `canvas(for:drawing:zoom:)`'s old inline doc comment claimed `.simultaneousGesture`
    /// plus a direction gate (matching `orbitDrag`'s own gate below) would let a vertical drag
    /// through to the ancestor `ScrollView` untouched. Measured on-device with a real touch drag
    /// (`WorkoutDetailScrollUITest` in `BananaUITests`, plus the same technique applied ad hoc to
    /// `WorkoutChartsSection`'s scrub gesture, which had the identical defect): that claim does not
    /// hold. A drag beginning on a view carrying ANY `.simultaneousGesture`-attached `DragGesture`
    /// — direction-gated or not, `minimumDistance: 4` or a `LongPressGesture.sequenced` that fails
    /// outright on a quick swipe — measured 0pt of page movement, while the identical drag with no
    /// gesture attached at all measured 300+pt. `.simultaneousGesture`'s "the ancestor ScrollView
    /// is never pre-empted" guarantee did not hold for a `DragGesture`-bearing descendant of this
    /// `ScrollView` on this SDK, full stop — so the fix is not a better gate, it's no competing
    /// gesture on the scrolling page at all. Trade-off: exploring the hand path by dragging now
    /// takes an extra tap (open this sheet) instead of working inline; that is the same trade the
    /// codebase already made for `MotionSignatureCard`'s 3D point cloud on iOS, for the same reason.
    private func expandedCanvas(_ lap: WorkoutHandPath.Lap) -> some View {
        let drawing = HandPathScene.build(lap: lap, radiusMeters: analysis.radiusMeters, camera: camera)
        return NavigationStack {
            VStack(spacing: 16) {
                canvas(for: lap, drawing: drawing, zoom: camera.zoom, identifier: "workout.handPathCanvas.expanded")
                    .aspectRatio(CGFloat(HandPathScene.aspectRatio(for: drawing)), contentMode: .fit)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .simultaneousGesture(orbitDrag)
                    .simultaneousGesture(magnifyGesture)
                    .onTapGesture(count: 2) { resetCamera() }
                radiusControl
            }
            .padding()
            .navigationTitle("Hand path")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { cameraMenu }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showExpanded = false }
                }
            }
        }
    }
    #endif

    // MARK: - Gestures

    /// Claims the drag only once it is clearly horizontal. Below a small movement threshold the
    /// direction isn't known yet, so nothing happens; once it is, the decision is locked for the
    /// rest of that one gesture (a drag that starts orbiting doesn't suddenly stop because the
    /// user's hand wavers, and a drag that started scrolling doesn't suddenly start orbiting).
    private var orbitDrag: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if dragStartCamera == nil { dragStartCamera = camera }
                if dragLock == .none {
                    let width = abs(value.translation.width)
                    let height = abs(value.translation.height)
                    if width > height * 1.2 {
                        dragLock = .horizontal
                    } else if height > 6 {
                        dragLock = .rejected
                    } else {
                        return   // not enough movement yet to tell — wait for the next update
                    }
                }
                guard dragLock == .horizontal, let start = dragStartCamera else { return }
                let sensitivity = 0.012
                camera.azimuth = start.azimuth + Double(value.translation.width) * sensitivity
                camera.elevation = Self.clampElevation(start.elevation - Double(value.translation.height) * sensitivity)
            }
            .onEnded { _ in
                dragLock = .none
                dragStartCamera = nil
            }
    }

    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in camera.zoom = Self.clampZoom(zoomAtGestureStart * Double(value)) }
            .onEnded { _ in zoomAtGestureStart = camera.zoom }
    }

    /// Stays short of the poles so an interactive orbit never flattens into the disorienting
    /// "azimuth does nothing" feel exactly at ±90° — the `above` preset can still reach exactly
    /// ±90° via `cameraMenu`, since presets bypass this clamp.
    private static func clampElevation(_ value: Double) -> Double { min(max(value, -1.45), 1.45) }
    private static func clampZoom(_ value: Double) -> Double { min(max(value, 0.4), 3.0) }

    private func resetCamera() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
            camera.azimuth = HandPathScene.Camera.default.azimuth
            camera.elevation = HandPathScene.Camera.default.elevation
            camera.zoom = HandPathScene.Camera.default.zoom
        }
        zoomAtGestureStart = HandPathScene.Camera.default.zoom
    }

    /// Orientation only — `camera.radiusExaggeration` is a separate, user-facing display control
    /// (`radiusControl` below) and is left untouched by both this and `resetCamera()`.
    private func setCameraPreset(_ preset: HandPathScene.Camera) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
            camera.azimuth = preset.azimuth
            camera.elevation = preset.elevation
        }
    }

    // MARK: - Stats, radius control, caption

    private func statRow(_ lap: WorkoutHandPath.Lap) -> some View {
        HStack(spacing: 20) {
            WorkoutMetricTile(value: Self.formatMeters(lap.distancePerStroke), label: "Per stroke",
                               alignment: .leading)
            WorkoutMetricTile(value: "\(lap.strokeCount)", label: "Strokes", alignment: .leading)
            WorkoutMetricTile(value: WorkoutComparisons.durationText(lap.duration), label: "Lap time", alignment: .leading)
            Spacer(minLength: 0)
        }
    }

    private var radiusControl: some View {
        HStack(spacing: 8) {
            Text("Radius ×\(camera.radiusExaggeration, specifier: "%.1f")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Slider(value: $camera.radiusExaggeration, in: 1...8)
                .accessibilityLabel("Radius exaggeration")
                .accessibilityValue(String(format: "%.1f times", camera.radiusExaggeration))
        }
    }

    #if os(macOS)
    /// `magnifyGesture` only fires from a multi-touch trackpad pinch — a mouse-only Mac (a Magic
    /// Mouse without pinch, or a wired mouse) has no way to zoom otherwise, unlike
    /// `WorkoutRouteMap`'s `MapZoomStepper`, which exists for exactly this reason on its `Map`.
    /// `Canvas` has no built-in pointer zoom control, so this is a plain slider bound to the same
    /// `camera.zoom` the pinch gesture drives, keeping `zoomAtGestureStart` in sync so a pinch
    /// started right after a slider drag continues from where the slider left off.
    private var zoomControl: some View {
        HStack(spacing: 8) {
            Text("Zoom ×\(camera.zoom, specifier: "%.1f")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Slider(value: zoomBinding, in: 0.4...3.0)
                .accessibilityLabel("Zoom")
                .accessibilityValue(String(format: "%.1f times", camera.zoom))
        }
    }

    private var zoomBinding: Binding<Double> {
        Binding(
            get: { camera.zoom },
            set: { newValue in
                camera.zoom = Self.clampZoom(newValue)
                zoomAtGestureStart = camera.zoom
            }
        )
    }
    #endif

    /// One-line legend for `effortColor`'s ramp — without it there's no way to tell which end of
    /// the colour scale means hard work; the tube's colour would just be decoration.
    private var colorKey: some View {
        HStack(spacing: 6) {
            Text("Low")
                .font(.caption2)
                .foregroundStyle(.secondary)
            LinearGradient(colors: WorkoutPalette.handPathEffortGradient, startPoint: .leading, endPoint: .trailing)
                .frame(width: 70, height: 6)
                .clipShape(Capsule())
            Text("High acceleration")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Colour key: dark and cool is low acceleration, bright and warm is high acceleration.")
    }

    private func captionBlock(_ lap: WorkoutHandPath.Lap) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(captionText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(readingHintText)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let caveat = caveatText(lap) {
                Text(caveat)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// One line, plain English, no jargon — states what's measured and what's assumed rather than
    /// letting the picture imply more precision than the sensor actually supports. Names the S/F
    /// markers here (not only in `accessibilityLabel`) because the picture alone — see
    /// `HandPathScene.CapMarker`'s doc comment — can be rotated to any angle, including one where
    /// direction can't be read from the tube's own shape at a glance.
    private var captionText: String {
        "Turns and pitch come from measured stroke timing; radius is assumed at \(Self.formatMeters(analysis.radiusMeters))"
        + " and shown ×\(String(format: "%.1f", camera.radiusExaggeration)); the angle within each stroke is spread evenly."
        + " S marks the wall this lap started at, F the wall it finished at."
    }

    /// What to actually do with the picture — `captionText` above says which values are measured
    /// vs. assumed, but never says what a good one looks like. Only turn count, pitch, and colour
    /// are measured (per `captionText`), so those are the only three things worth reading: pitch as
    /// distance-per-stroke, colour as timing repeatability. Pool-swim only, so no activity branch
    /// is needed here the way `MotionSignatureCard.readingHintText` needs one.
    private var readingHintText: String {
        "Open coils mean more distance per stroke, tight coils mean more strokes for the same distance."
        + " A bright band that returns at the same point each turn means repeatable timing."
    }

    /// Surfaced, not hidden, per the honesty rules: a lap with no stroke data, an unstable
    /// rotation plane, an interpolated accelerometer gap, or synthesised stroke boundaries still
    /// gets a caveat instead of a picture that looks exactly as confident as a clean lap.
    ///
    /// Reads `lap.warnings` directly rather than re-deriving the same thresholds
    /// (`planarity < 2.0`, `syntheticBoundaryCount > 0`, …) a second time — `WorkoutHandPath.
    /// buildLap` is the one place that decides when a lap's data is untrustworthy, so this view
    /// only ever formats what that already flagged instead of risking a second copy of the logic
    /// silently drifting from it.
    private func caveatText(_ lap: WorkoutHandPath.Lap) -> String? {
        guard !lap.points.isEmpty else { return "No stroke data detected for this lap." }
        guard !lap.warnings.isEmpty else { return nil }
        let joined = lap.warnings.joined(separator: " · ")
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }

    private func accessibilityLabel(for lap: WorkoutHandPath.Lap) -> String {
        "Hand path for lap \(lap.id + 1): \(lap.strokeCount) strokes, "
        + "\(Self.formatMeters(lap.distancePerStroke)) per stroke, radius exaggerated "
        + "\(String(format: "%.0f", camera.radiusExaggeration)) times. "
        + "Marked S at the start wall and F at the finish wall."
    }

    private static func formatMeters(_ value: Double) -> String { String(format: "%.2f m", value) }

    private static func defaultLapIndex(_ laps: [WorkoutHandPath.Lap]) -> Int {
        guard !laps.isEmpty else { return 0 }
        let mid = laps.count / 2
        for offset in 0..<laps.count {
            for candidate in [mid + offset, mid - offset] where laps.indices.contains(candidate) {
                if laps[candidate].strokeCount > 0, !laps[candidate].points.isEmpty {
                    return candidate
                }
            }
        }
        return mid
    }

    // MARK: - DEBUG screenshot route: `--hand-path-camera <side|above|downLane>` rides on the same
    // `--workout-detail` / `--mac-workout-id` visual-audit routes as `--hand-path-lap` (see
    // `WorkoutMotionSection`'s own DEBUG section) — verifies the start/end markers (`CapMarker`)
    // read correctly when the view is rotated away from `.default`, not just at it.
    #if DEBUG
    private static func debugInitialCamera() -> HandPathScene.Camera? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--hand-path-camera"), i + 1 < args.count else { return nil }
        switch args[i + 1] {
        case "side": return .side
        case "above": return .above
        case "downLane": return .downLane
        default: return nil
        }
    }
    #endif

    // MARK: - Drawing (fits `HandPathScene`'s scene-unit output to this canvas's pixel size)

    /// One uniform scale (never independent X/Y) plus a translate, fitting a `Drawing`'s bounding
    /// box to the canvas with a margin, then the camera's own `zoom` layered on top.
    private struct FitTransform {
        var scale: Double
        var originX: Double
        var originY: Double
        var canvasCenter: CGPoint

        /// Flips Y (scene "up" is positive; `Canvas` draws with Y increasing downward). Converts
        /// to `CGFloat` here, at the one place scene units become screen points — `Double` and
        /// `CGFloat` don't implicitly convert in Swift, so every other computation in this file
        /// stays in plain `Double` scene units until this single crossing point.
        func point(_ p: HandPathScene.ProjectedPoint) -> CGPoint {
            CGPoint(x: canvasCenter.x + CGFloat((p.x - originX) * scale),
                    y: canvasCenter.y - CGFloat((p.y - originY) * scale))
        }
    }

    /// Bounding box and content aspect ratio now live on `HandPathScene` itself (`boundingBox(drawing:)`,
    /// `aspectRatio(for:)`) — pure scene-unit geometry, not a view concern, and moved there so
    /// `BananaTests` can exercise the aspect-ratio clamp directly without a host view. This
    /// function is the one place that still needs the box: `zoom` is a display-only concept
    /// (`HandPathView`'s own `Camera.zoom`), which `HandPathScene` has no reason to know about.
    private static func fitTransform(drawing: HandPathScene.Drawing, size: CGSize, zoom: Double) -> FitTransform {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        guard let box = HandPathScene.boundingBox(drawing: drawing) else {
            return FitTransform(scale: 1, originX: 0, originY: 0, canvasCenter: center)
        }
        let spanX = max(box.maxX - box.minX, 0.001)
        let spanY = max(box.maxY - box.minY, 0.001)
        let margin = 0.86   // leaves room so nothing clips the canvas edge at the default zoom
        let fitScale = min(Double(size.width) / spanX, Double(size.height) / spanY) * margin
        return FitTransform(scale: fitScale * max(zoom, 0.05), originX: (box.minX + box.maxX) / 2, originY: (box.minY + box.maxY) / 2,
                             canvasCenter: center)
    }

    private static func draw(lane marks: [HandPathScene.LaneMark], context: inout GraphicsContext, transform: FitTransform) {
        for mark in marks {
            var path = Path()
            path.move(to: transform.point(mark.a))
            path.addLine(to: transform.point(mark.b))
            // Three distinct weights so the cylinder actually reads as one: the end walls
            // strongest (they bound the lane), the silhouette pair next (they establish the
            // tube's outline), the regular interval rings quietest (they suggest the surface
            // without competing with the path drawn through them).
            let (opacity, width): (Double, CGFloat)
            switch mark.kind {
            case .wallMarker: (opacity, width) = (0.55, 1.6)
            case .silhouette: (opacity, width) = (0.38, 1.1)
            case .ring: (opacity, width) = (0.28, 0.75)
            }
            context.stroke(path, with: .color(.secondary.opacity(opacity)), lineWidth: width)
        }
    }

    private static func draw(segments: [HandPathScene.Segment], context: inout GraphicsContext, transform: FitTransform) {
        for segment in segments {
            var path = Path()
            path.move(to: transform.point(segment.a))
            path.addLine(to: transform.point(segment.b))
            let width = CGFloat(max(segment.width * transform.scale, 1.2))
            context.stroke(path, with: .color(effortColor(segment.effort).opacity(segment.opacity)),
                            style: StrokeStyle(lineWidth: width, lineCap: .round))
        }
    }

    /// A constant SCREEN size, not scaled by `transform.scale` like every other layer here — a
    /// map-pin, not a scene object, so it stays exactly as readable zoomed out as zoomed in. Shape
    /// AND a one-letter label both carry the distinction (never colour alone, per the spec this
    /// exists to satisfy — colour on this chart is already spent on acceleration): start is a
    /// filled disc labelled "S", end is a filled diamond labelled "F". Fixed, non-depth-varying
    /// opacity — see `HandPathScene.Drawing.markers`'s doc comment for why these never fade.
    private static let markerRadius: CGFloat = 8

    private static func draw(markers: [HandPathScene.CapMarker], context: inout GraphicsContext, transform: FitTransform) {
        for marker in markers {
            let center = transform.point(marker.point)
            let (fill, label): (Color, String) = marker.kind == .start ? (WorkoutPalette.good, "S") : (WorkoutPalette.bad, "F")
            var shape = Path()
            switch marker.kind {
            case .start:
                shape.addEllipse(in: CGRect(x: center.x - markerRadius, y: center.y - markerRadius,
                                             width: markerRadius * 2, height: markerRadius * 2))
            case .end:
                // A diamond (45°-rotated square) — visually distinct from the start disc by
                // silhouette alone, not just by fill colour or label.
                shape.move(to: CGPoint(x: center.x, y: center.y - markerRadius))
                shape.addLine(to: CGPoint(x: center.x + markerRadius, y: center.y))
                shape.addLine(to: CGPoint(x: center.x, y: center.y + markerRadius))
                shape.addLine(to: CGPoint(x: center.x - markerRadius, y: center.y))
                shape.closeSubpath()
            }
            context.fill(shape, with: .color(fill))
            context.stroke(shape, with: .color(.white), lineWidth: 1.5)
            context.draw(Text(label).font(.caption2.bold()).foregroundColor(.white), at: center)
        }
    }

    /// Interpolates through `WorkoutPalette.handPathEffortGradient` — one perceptually ordered
    /// sequential ramp (dim/cool → bright/warm), not `routeGradient`, whose blue→...→orange run
    /// doubles back through the same brightness and doesn't read as a single low→high scale (see
    /// that palette entry's doc comment).
    private static func effortColor(_ effort: Float) -> Color {
        let stops = WorkoutPalette.handPathEffortGradient
        guard let first = stops.first else { return WorkoutPalette.motionSignature }
        guard stops.count > 1 else { return first }
        let clamped = Double(min(max(effort, 0), 1))
        let scaled = clamped * Double(stops.count - 1)
        let low = Int(scaled)
        let high = min(low + 1, stops.count - 1)
        return stops[low].mix(with: stops[high], by: scaled - Double(low))
    }
}
