import SwiftUI

#if os(iOS)
import UIKit

struct PrivacyMonitor: UIViewRepresentable {
    var activity: () -> Void
    var background: () -> Void
    func makeUIView(context: Context) -> Observer { Observer(activity, background) }
    func updateUIView(_ view: Observer, context: Context) {}

    final class Observer: UIView, UIGestureRecognizerDelegate {
        var activity: () -> Void
        var background: () -> Void
        var shield: UIWindow?
        var recognizer: UIGestureRecognizer?
        init(_ activity: @escaping () -> Void, _ background: @escaping () -> Void) {
            self.activity = activity
            self.background = background
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(cover), name: UIApplication.willResignActiveNotification, object: nil)
            center.addObserver(self, selector: #selector(hide), name: UIApplication.didBecomeActiveNotification, object: nil)
            center.addObserver(self, selector: #selector(lock), name: UIApplication.didEnterBackgroundNotification, object: nil)
            center.addObserver(self, selector: #selector(typeEvent), name: UITextField.textDidChangeNotification, object: nil)
            center.addObserver(self, selector: #selector(typeEvent), name: UITextView.textDidChangeNotification, object: nil)
        }
        required init?(coder: NSCoder) { nil }
        @objc private func typeEvent() { activity() }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            recognizer?.view?.removeGestureRecognizer(recognizer!)
            guard let window else { return }
            let tap = ActivityGesture()
            tap.activity = activity
            tap.cancelsTouchesInView = false
            tap.delaysTouchesBegan = false
            tap.delaysTouchesEnded = false
            tap.delegate = self
            window.addGestureRecognizer(tap)
            recognizer = tap
        }
        @objc func cover() {
            guard shield == nil, let scene = window?.windowScene else { return }
            let cover = UIWindow(windowScene: scene)
            cover.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
            let controller = UIViewController()
            controller.view.backgroundColor = .systemBackground
            cover.rootViewController = controller
            cover.isHidden = false
            shield = cover
        }
        @objc func hide() { shield?.isHidden = true; shield = nil }
        @objc func lock() { cover(); background() }
    }

    final class ActivityGesture: UIGestureRecognizer {
        var activity: (() -> Void)?
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { activity?() }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { activity?() }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { state = .failed }
        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    }
}
#else
import AppKit

struct PrivacyMonitor: NSViewRepresentable {
    var activity: () -> Void
    var background: () -> Void
    func makeNSView(context: Context) -> Observer { Observer(activity, background) }
    func updateNSView(_ view: Observer, context: Context) {}
    final class Observer: NSView {
        private var monitor: Any?
        private var cover: NSView?
        private let background: () -> Void
        init(_ activity: @escaping () -> Void, _ background: @escaping () -> Void) {
            self.background = background
            super.init(frame: .zero)
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown, .leftMouseDragged]) {
                activity(); return $0
            }
            NotificationCenter.default.addObserver(self, selector: #selector(conceal),
                name: NSApplication.willResignActiveNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(reveal),
                name: NSApplication.didBecomeActiveNotification, object: nil)
        }
        required init?(coder: NSCoder) { nil }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
        @objc private func conceal() {
            if cover == nil, let content = window?.contentView {
                let mask = NSView(frame: content.bounds)
                mask.wantsLayer = true
                mask.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                mask.autoresizingMask = [.width, .height]
                content.addSubview(mask, positioned: .above, relativeTo: nil)
                cover = mask
            }
            background()
        }
        @objc private func reveal() { cover?.removeFromSuperview(); cover = nil }
    }
}
#endif
