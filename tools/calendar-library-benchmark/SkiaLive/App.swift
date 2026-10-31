import Foundation
import QuartzCore
import Metal
@MainActor final class NativeTilePresentation {
    let layers = (0..<8).map { _ in CALayer() }
    init(parent: CALayer) { layers.forEach { parent.addSublayer($0) } }
    func install(_ page: LivePage) {
        precondition(page.surfaces.count == layers.count)
        let began = CACurrentMediaTime()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (index, layer) in layers.enumerated() {
            layer.frame = CGRect(x: 0, y: index*256, width: page.width, height: 256)
            layer.contentsScale = CGFloat(page.scale); layer.contents = page.surfaces[index]
        }
        CATransaction.commit()
        LiveLog.shared.add("nativeSurfacePublish", ["date": page.date.timeIntervalSince1970,
            "durationMS": (CACurrentMediaTime()-began)*1000,
            "scope": "Layer assignment/transaction submission only; not presented-frame timing"])
    }
}
#if os(macOS)
import AppKit

final class MetalCanvas: NSView {
    let metal = CAMetalLayer()
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layer = metal }
    required init?(coder: NSCoder) { fatalError() }
}
final class FlippedDocument: NSView { override var isFlipped: Bool { true } }
@MainActor final class LiveController: NSViewController {
    let model = LiveModel()
    let device = MTLCreateSystemDefaultDevice()!
    lazy var presenter = LivePresentation(device: device)
    let canvas = MetalCanvas(frame: .zero)
    let scroll = NSScrollView()
    let document = FlippedDocument(frame: .zero)
    var nativeTiles: NativeTilePresentation?
    let heading = NSTextField(labelWithString: "Preparing")
    let state = NSTextField(labelWithString: "Metal preview · experimental")
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1366, height: 900))
        let previous = NSButton(title: "Previous", target: self, action: #selector(previousPage))
        let next = NSButton(title: "Next", target: self, action: #selector(nextPage))
        let clear = NSButton(title: "Clear cache", target: self, action: #selector(clearCache))
        previous.setAccessibilityIdentifier("live.previous"); next.setAccessibilityIdentifier("live.next")
        clear.setAccessibilityIdentifier("live.clear"); heading.setAccessibilityIdentifier("live.date")
        state.setAccessibilityIdentifier("live.state"); scroll.setAccessibilityIdentifier("live.timeline")
        let bar = NSStackView(views: [previous, next, clear, heading, state])
        bar.spacing = 12
        [canvas, scroll, bar].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; view.addSubview($0) }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.topAnchor, constant: 10), bar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 10), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: scroll.topAnchor), canvas.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: scroll.leadingAnchor), canvas.trailingAnchor.constraint(equalTo: scroll.trailingAnchor)])
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.contentView.drawsBackground = false
        scroll.documentView = document; scroll.contentView.postsBoundsChangedNotifications = true
        if model.nativeSurfaces { document.wantsLayer = true; nativeTiles = NativeTilePresentation(parent: document.layer!) }
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        canvas.metal.device = device; canvas.metal.pixelFormat = .bgra8Unorm; canvas.metal.framebufferOnly = false
        canvas.metal.maximumDrawableCount = 3; presenter.layer = canvas.metal
        model.onStatus = { [weak self] in self?.heading.stringValue = $0 }
        model.onReady = { [weak self] page in
            guard let self else { return }
            if let nativeTiles = self.nativeTiles {
                nativeTiles.install(page); self.state.stringValue = "Ready · \(page.events) events"; return
            }
            self.presenter.current = page; self.presenter.generation += 1
            self.presenter.request(); self.state.stringValue = "Ready · \(page.events) events"
        }
        LiveLog.shared.add("platform", ["os": ProcessInfo.processInfo.operatingSystemVersionString, "device": device.name])
    }
    override func viewDidLayout() {
        super.viewDidLayout()
        let scale = Int(view.window?.backingScaleFactor ?? 2), width = Int(scroll.contentSize.width)
        document.frame = NSRect(x: 0, y: 0, width: width, height: 1920)
        canvas.metal.contentsScale = CGFloat(scale)
        let drawableSize = CGSize(width: CGFloat(width*scale), height: canvas.bounds.height*CGFloat(scale))
        let drawableChanged = canvas.metal.drawableSize != drawableSize
        canvas.metal.drawableSize = drawableSize
        model.configure(width: width, scale: scale)
        if drawableChanged, !model.nativeSurfaces, let page = presenter.current,
           page.width == width, page.scale == scale {
            presenter.inputKind = "resize"; presenter.inputTimestamp = CACurrentMediaTime(); presenter.request()
        }
    }
    @objc func scrolled() {
        if model.nativeSurfaces {
            LiveLog.shared.add("nativeScroll", ["offset": max(0, Double(scroll.contentView.bounds.minY))]); return
        }
        presenter.offset = max(0, Double(scroll.contentView.bounds.minY))
        presenter.inputKind = "scroll"; presenter.inputTimestamp = CACurrentMediaTime(); presenter.request()
    }
    @objc func previousPage() { presenter.inputKind = "page"; presenter.inputTimestamp = CACurrentMediaTime(); model.move(-1) }
    @objc func nextPage() { presenter.inputKind = "page"; presenter.inputTimestamp = CACurrentMediaTime(); model.move(1) }
    @objc func clearCache() { presenter.inputKind = "page"; presenter.inputTimestamp = CACurrentMediaTime(); model.clear() }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        let screen = NSScreen.screens.max { $0.maximumFramesPerSecond < $1.maximumFramesPerSecond }!
        let controller = LiveController()
        let width = min(1366.0, screen.visibleFrame.width), height = min(900.0, screen.visibleFrame.height)
        window = NSWindow(contentRect: NSRect(x: screen.visibleFrame.minX, y: screen.visibleFrame.minY, width: width, height: height),
            styleMask: [.titled,.closable,.resizable,.miniaturizable], backing: .buffered, defer: false, screen: screen)
        window.title = "Calendar Metal Review — isolated fixture"
        window.contentViewController = controller; window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        LiveLog.shared.add("display", ["maximumFramesPerSecond": screen.maximumFramesPerSecond, "name": screen.localizedName])
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
@main struct LiveApp {
    @MainActor static func main() {
        let app = NSApplication.shared; let delegate = AppDelegate(); app.delegate = delegate
        app.setActivationPolicy(.regular); app.run()
    }
}
#else
import UIKit
final class MetalCanvas: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metal: CAMetalLayer { layer as! CAMetalLayer }
}
@MainActor final class LiveController: UIViewController, UIScrollViewDelegate {
    let model = LiveModel(), device = MTLCreateSystemDefaultDevice()!
    lazy var presenter = LivePresentation(device: device)
    let canvas = MetalCanvas(), scroll = UIScrollView(), heading = UILabel(), state = UILabel()
    var nativeTiles: NativeTilePresentation?
    private var nativeUpdateLink: UIUpdateLink?
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemBackground
        let previous = UIButton(type: .system), next = UIButton(type: .system), clear = UIButton(type: .system)
        previous.setTitle("Previous", for: .normal); next.setTitle("Next", for: .normal); clear.setTitle("Clear cache", for: .normal)
        previous.addTarget(self, action: #selector(previousPage), for: .touchUpInside)
        next.addTarget(self, action: #selector(nextPage), for: .touchUpInside)
        clear.addTarget(self, action: #selector(clearCache), for: .touchUpInside)
        previous.accessibilityIdentifier = "live.previous"; next.accessibilityIdentifier = "live.next"; clear.accessibilityIdentifier = "live.clear"
        heading.accessibilityIdentifier = "live.date"; state.accessibilityIdentifier = "live.state"
        scroll.accessibilityIdentifier = "live.timeline"; scroll.delegate = self
        heading.font = .preferredFont(forTextStyle: .headline); state.font = .preferredFont(forTextStyle: .caption1)
        let buttons = UIStackView(arrangedSubviews: [previous,next,clear]); buttons.distribution = .equalSpacing
        let bar = UIStackView(arrangedSubviews: [buttons,heading,state]); bar.axis = .vertical; bar.spacing = 4
        for child in [canvas,scroll,bar] { child.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(child) }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), bar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8), scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: scroll.topAnchor), canvas.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: scroll.leadingAnchor), canvas.trailingAnchor.constraint(equalTo: scroll.trailingAnchor)])
        scroll.backgroundColor = .clear; canvas.metal.device = device; canvas.metal.pixelFormat = .bgra8Unorm
        canvas.metal.framebufferOnly = false; canvas.metal.maximumDrawableCount = 3; presenter.layer = canvas.metal
        if model.nativeSurfaces { nativeTiles = NativeTilePresentation(parent: scroll.layer) }
        let policy = model.config.value("--presentation-policy", "system")
        precondition(["system", "immediate", "prefer120", "both"].contains(policy))
        LiveLog.shared.add("nativePresentationPolicy", ["value": policy])
        if policy != "system" {
            precondition(model.nativeSurfaces)
            let link = UIUpdateLink(view: scroll) { _, _ in }
            link.requiresContinuousUpdates = false
            link.wantsImmediatePresentation = policy == "immediate" || policy == "both"
            if policy == "prefer120" || policy == "both" {
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
            }
            link.isEnabled = true; nativeUpdateLink = link
        }
        model.onStatus = { [weak self] in self?.heading.text = $0 }
        model.onReady = { [weak self] page in
            guard let self else { return }
            if let nativeTiles = self.nativeTiles {
                nativeTiles.install(page); self.state.text = "Ready · \(page.events) events"; return
            }
            self.presenter.current = page; self.presenter.generation += 1; self.presenter.request()
            self.state.text = "Ready · \(page.events) events"
        }
        UIApplication.shared.isIdleTimerDisabled = true
        LiveLog.shared.add("platform", ["os": ProcessInfo.processInfo.operatingSystemVersionString, "device": device.name])
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let screen = view.window?.windowScene?.screen ?? UIScreen.main
        let scale = Int(screen.scale), width = Int(scroll.bounds.width)
        scroll.contentSize = CGSize(width: width, height: 1920)
        canvas.metal.contentsScale = CGFloat(scale)
        let drawableSize = CGSize(width: width*scale, height: Int(canvas.bounds.height)*scale)
        let drawableChanged = canvas.metal.drawableSize != drawableSize
        canvas.metal.drawableSize = drawableSize
        model.configure(width: width, scale: scale)
        // Status labels can change only the viewport height after the first page
        // publishes. Repaint that size change even when cached page geometry is valid.
        if drawableChanged, !model.nativeSurfaces, let page = presenter.current,
           page.width == width, page.scale == scale {
            presenter.inputKind = "resize"; presenter.inputTimestamp = CACurrentMediaTime(); presenter.request()
        }
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if model.nativeSurfaces {
            LiveLog.shared.add("nativeScroll", ["offset": max(0, Double(scrollView.contentOffset.y)),
                "dragging": scrollView.isDragging, "decelerating": scrollView.isDecelerating]); return
        }
        presenter.offset = Double(scrollView.contentOffset.y); presenter.inputKind = "scroll"; presenter.inputTimestamp = CACurrentMediaTime(); presenter.request()
    }
    @objc func previousPage() { presenter.inputKind = "page"; presenter.inputTimestamp = CACurrentMediaTime(); model.move(-1) }
    @objc func nextPage() { presenter.inputKind = "page"; presenter.inputTimestamp = CACurrentMediaTime(); model.move(1) }
    @objc func clearCache() { presenter.inputKind = "page"; presenter.inputTimestamp = CACurrentMediaTime(); model.clear() }
}
@MainActor final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene); window.rootViewController = LiveController(); self.window = window; window.makeKeyAndVisible()
        LiveLog.shared.add("display", ["maximumFramesPerSecond": scene.screen.maximumFramesPerSecond])
    }
}
@main @MainActor final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Calendar", sessionRole: session.role)
        configuration.delegateClass = SceneDelegate.self; return configuration
    }
}
#endif
