#if os(iOS) || os(macOS)
import SwiftUI
#if os(iOS)
import UIKit
#endif

// Meal photos full size: tap any meal photo in Nutrition — a logged meal's, one waiting to be
// logged, one being reviewed. On the iPhone and iPad it fills the screen: swipe between the
// meal's photos, pinch or double-tap to zoom, pull down or tap ✕ to close. On the Mac it's a
// sheet, with the arrow keys between photos.

/// Which photos to show, and which one first.
struct MealPhotoViewing: Identifiable {
    let ids: [UUID]
    let start: Int
    let id = UUID()
}

extension View {
    /// Tapping this shows `ids` full size, starting at `start`. The tap is the photo's, not the
    /// row's it sits in (which opens the meal to edit).
    func opensMealPhotos(_ ids: [UUID], at start: Int = 0) -> some View {
        modifier(OpensMealPhotos(ids: ids, start: start))
    }
}

private struct OpensMealPhotos: ViewModifier {
    let ids: [UUID]
    let start: Int
    @State private var viewing: MealPhotoViewing?

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .highPriorityGesture(TapGesture().onEnded { open() })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(ids.count > 1 ? "Photo \(start + 1) of \(ids.count)" : "Photo")
            .accessibilityHint("Shows it full size")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { open() }
            .accessibilityIdentifier("mealPhoto.thumb")
            #if os(iOS)
            .fullScreenCover(item: $viewing) { MealPhotoViewer(ids: $0.ids, start: $0.start) }
            #else
            .sheet(item: $viewing) { MealPhotoViewer(ids: $0.ids, start: $0.start) }
            #endif
    }

    private func open() {
        guard ids.indices.contains(start) else { return }
        viewing = MealPhotoViewing(ids: ids, start: start)
    }
}

struct MealPhotoViewer: View {
    let ids: [UUID]
    @State private var index: Int
    @Environment(\.dismiss) private var dismiss

    init(ids: [UUID], start: Int) {
        self.ids = ids
        _index = State(initialValue: min(max(start, 0), max(ids.count - 1, 0)))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            pages
        }
        .overlay(alignment: .top) { topBar }
        // Photos sit on black whatever the system look: the glass Done reads light-on-dark.
        .environment(\.colorScheme, .dark)
        #if os(macOS)
        .frame(minWidth: 560, idealWidth: 900, minHeight: 440, idealHeight: 700)
        .onKeyPress(.leftArrow) { step(-1) }
        .onKeyPress(.rightArrow) { step(1) }
        #endif
    }

    private var counter: String? { ids.count > 1 ? "\(index + 1) of \(ids.count)" : nil }

    #if os(iOS)
    private var pages: some View {
        TabView(selection: $index) {
            ForEach(Array(ids.enumerated()), id: \.offset) { offset, id in
                MealPhotoPage(id: id) { dismiss() }
                    .tag(offset)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .ignoresSafeArea()
        .accessibilityIdentifier("mealPhoto.viewer")
    }

    private var topBar: some View {
        HStack {
            Spacer()
            Button("Done") { dismiss() }
            .buttonStyle(.glass)
            .accessibilityIdentifier("mealPhoto.close")
        }
        .overlay {
            if let counter {
                Text(counter)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("mealPhoto.counter")
            }
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.top, DS.Space.s)
    }
    #else
    private var pages: some View {
        MealPhotoPage(id: ids[index])
            .id(ids[index])
            .padding(DS.Space.l)
    }

    private var topBar: some View {
        HStack(spacing: DS.Space.s) {
            if ids.count > 1 {
                Button { _ = step(-1) } label: { Image(systemName: "chevron.left") }
                    .disabled(index == 0)
                    .accessibilityLabel("Previous photo")
                Text(counter ?? "")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                Button { _ = step(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(index == ids.count - 1)
                    .accessibilityLabel("Next photo")
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .buttonStyle(.glass)
        .padding(DS.Space.m)
    }

    private func step(_ delta: Int) -> KeyPress.Result {
        let next = index + delta
        guard ids.indices.contains(next) else { return .ignored }
        index = next
        return .handled
    }
    #endif
}

/// One photo, decoded off the main thread; a placeholder while it's still on its way from
/// another device, filled in when it lands (`MealPhotoStore.version`).
private struct MealPhotoPage: View {
    let id: UUID
    var onPullDown: () -> Void = {}
    @ObservedObject private var photos = MealPhotoStore.shared
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                #if os(iOS)
                ZoomablePhoto(image: UIImage(cgImage: image), onPullDown: onPullDown)
                    .ignoresSafeArea()
                #else
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                #endif
            } else if photos.has(id) {
                ProgressView().tint(.white)
            } else {
                VStack(spacing: DS.Space.s) {
                    Image(systemName: "icloud.and.arrow.down").font(.largeTitle)
                    Text("This photo is still on its way from your other device.")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.white.opacity(0.7))
                .padding(DS.Space.xl)
            }
        }
        .task(id: "\(id)-\(photos.version)") {
            guard image == nil, photos.has(id) else { return }
            let url = photos.url(id)
            image = await Task.detached(priority: .userInitiated) {
                (try? Data(contentsOf: url)).flatMap {
                    MealPhotoImage.downscaled($0, maxPixels: MealPhotoImage.keptPixels)
                }
            }.value
        }
    }
}

#if os(iOS)
/// Pinch and double-tap zoom, the way Photos does it: a scroll view zooming the photo, kept
/// centred, and a pull down (at normal size) closes the viewer. UIKit rather than SwiftUI
/// gestures, which fight the page swipe between photos.
private struct ZoomablePhoto: UIViewRepresentable {
    let image: UIImage
    let onPullDown: () -> Void

    func makeUIView(context: Context) -> ZoomingPhotoView {
        let view = ZoomingPhotoView()
        view.onPullDown = onPullDown
        view.show(image)
        return view
    }

    func updateUIView(_ view: ZoomingPhotoView, context: Context) {
        view.onPullDown = onPullDown
        view.show(image)
    }
}

final class ZoomingPhotoView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    var onPullDown: () -> Void = {}
    private var laidOutFor: CGSize = .zero

    init() {
        super.init(frame: .zero)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 4
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        alwaysBounceVertical = true   // so it can be pulled down to close
        backgroundColor = .clear
        imageView.contentMode = .scaleAspectFit
        imageView.accessibilityIgnoresInvertColors = true
        addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ image: UIImage) {
        guard imageView.image !== image else { return }
        imageView.image = image
        laidOutFor = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != laidOutFor, let image = imageView.image, image.size.width > 0, image.size.height > 0
        else { return }
        laidOutFor = bounds.size
        zoomScale = 1
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let fitted = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        imageView.frame = CGRect(origin: .zero, size: fitted)
        contentSize = fitted
        centre()
    }

    /// Letterboxed while it's smaller than the screen, edge to edge once it's bigger.
    private func centre() {
        let x = max(0, (bounds.width - contentSize.width) / 2)
        let y = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centre() }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        guard zoomScale <= minimumZoomScale + 0.01 else { return }
        let pulled = -(contentOffset.y + contentInset.top)
        if pulled > 110 || (pulled > 30 && velocity.y < -1.2) { onPullDown() }
    }

    @objc private func toggleZoom(_ tap: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale + 0.01 {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        let point = tap.location(in: imageView)
        let scale: CGFloat = 2.5
        let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
        zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                        width: size.width, height: size.height), animated: true)
    }
}
#endif
#endif
