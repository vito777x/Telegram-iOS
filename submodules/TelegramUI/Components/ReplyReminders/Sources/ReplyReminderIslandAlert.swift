import Foundation
import UIKit
import Display
import TelegramCore

// The reminder fired while the app is open: the reminder icon drops out of the Dynamic Island, folds into a paper
// plane and flies to the chat along a dotted trail, where it turns into the unread dot
// (or lands on the reminder line when the chat is open). `title` and `text` are only read out by VoiceOver.
public func presentReplyReminderIslandAlert(window: UIWindow, peerId: EnginePeer.Id, reminderId: String?, title: String, text: String, open: @escaping () -> Void) {
    let view = ReplyReminderIslandAlertView(window: window, peerId: peerId, reminderId: reminderId, title: title, text: text, open: open)
    window.addSubview(view)
    view.animateIn()
}

private let replyReminderAccentColor = UIColor(rgb: 0x2a9ef1)

private final class ReplyReminderIslandAlertView: UIView {
    private let peerId: EnginePeer.Id
    private let reminderId: String?
    private let open: () -> Void

    private let islandFrame: CGRect
    private let hoverCenter: CGPoint

    private let circleView = UIView()
    private let iconView = UIImageView()
    // Holds the plane; scaled on its own so that the view itself can follow the path and turn with it.
    private let planeHolder = UIView()
    private let planeWhiteView = UIImageView()
    private let planeColorView = UIImageView()

    private var isDismissing = false
    private var didStartFlight = false

    private static let size: CGFloat = 46.0

    init(window: UIWindow, peerId: EnginePeer.Id, reminderId: String?, title: String, text: String, open: @escaping () -> Void) {
        self.peerId = peerId
        self.reminderId = reminderId
        self.open = open

        let bounds = window.bounds
        let metrics = DeviceMetrics(screenSize: bounds.size, scale: UIScreen.main.scale, statusBarHeight: window.safeAreaInsets.top, onScreenNavigationHeight: nil)
        if metrics.hasDynamicIsland, let cutout = metrics.cutoutFrame, bounds.width < bounds.height {
            self.islandFrame = cutout
        } else {
            let top = max(6.0, window.safeAreaInsets.top - 30.0)
            self.islandFrame = CGRect(x: bounds.midX - 40.0, y: top, width: 80.0, height: 24.0)
        }
        self.hoverCenter = CGPoint(x: self.islandFrame.midX, y: self.islandFrame.maxY + 14.0 + ReplyReminderIslandAlertView.size / 2.0)

        let size = ReplyReminderIslandAlertView.size
        super.init(frame: CGRect(x: self.islandFrame.midX - size / 2.0, y: self.islandFrame.midY - size / 2.0, width: size, height: size))

        self.isAccessibilityElement = true
        self.accessibilityLabel = "\(title). \(text)"
        self.accessibilityTraits = .button

        self.circleView.frame = self.bounds
        self.circleView.backgroundColor = replyReminderAccentColor
        self.circleView.layer.cornerRadius = size / 2.0
        self.addSubview(self.circleView)

        self.iconView.image = replyReminderSymbol(pointSize: 20.0, weight: .semibold)?.withRenderingMode(.alwaysTemplate)
        self.iconView.tintColor = .white
        self.iconView.contentMode = .center
        self.iconView.frame = self.bounds
        self.addSubview(self.iconView)

        self.planeHolder.frame = self.bounds
        self.planeHolder.isUserInteractionEnabled = false
        self.planeHolder.alpha = 0.0
        self.addSubview(self.planeHolder)
        self.planeWhiteView.image = replyReminderPlaneImage(color: .white)
        self.planeWhiteView.frame = self.bounds
        self.planeHolder.addSubview(self.planeWhiteView)
        self.planeColorView.image = replyReminderPlaneImage(color: replyReminderAccentColor)
        self.planeColorView.frame = self.bounds
        self.planeColorView.alpha = 0.0
        self.planeHolder.addSubview(self.planeColorView)

        self.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.tapGesture)))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func animateIn() {
        // Drops out of the island: starts tiny at its center and springs down below it.
        self.transform = CGAffineTransform(scaleX: 0.2, y: 0.2)
        self.circleView.backgroundColor = .black
        UIView.animate(withDuration: 0.62, delay: 0.0, usingSpringWithDamping: 0.62, initialSpringVelocity: 0.0, options: [.allowUserInteraction], animations: {
            self.center = self.hoverCenter
            self.transform = .identity
        })
        UIView.animate(withDuration: 0.3, delay: 0.08, options: [.allowUserInteraction], animations: {
            self.circleView.backgroundColor = replyReminderAccentColor
        })
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) { [weak self] in
            self?.scribble()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) { [weak self] in
            self?.foldIntoPlane()
        }
    }

    // A little jot, as if someone is writing on the clipboard.
    private func scribble() {
        guard !self.isDismissing else {
            return
        }
        let animation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        animation.values = [0.0, -0.22, 0.18, -0.12, 0.06, 0.0] as [NSNumber]
        animation.duration = 0.6
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        self.iconView.layer.add(animation, forKey: "scribble")
    }

    private func foldIntoPlane() {
        guard !self.isDismissing else {
            return
        }
        UIView.animate(withDuration: 0.22, delay: 0.0, options: [.curveEaseIn], animations: {
            self.iconView.transform = CGAffineTransform(rotationAngle: 0.6).scaledBy(x: 0.3, y: 0.3)
            self.iconView.alpha = 0.0
        })
        self.planeHolder.transform = CGAffineTransform(rotationAngle: -0.8).scaledBy(x: 0.3, y: 0.3)
        UIView.animate(withDuration: 0.5, delay: 0.08, usingSpringWithDamping: 0.6, initialSpringVelocity: 0.0, options: [], animations: {
            self.planeHolder.alpha = 1.0
            self.planeHolder.transform = .identity
        })
        // Nose down, the way the flight starts, so the plane does not snap round when it takes off.
        UIView.animate(withDuration: 0.4, delay: 0.3, options: [.curveEaseInOut], animations: {
            self.transform = CGAffineTransform(rotationAngle: CGFloat.pi / 2.0)
        })
        // The circle melts away and the plane takes its color, so it shows on both light and dark backgrounds.
        UIView.animate(withDuration: 0.32, delay: 0.2, options: [.curveEaseInOut], animations: {
            self.circleView.transform = CGAffineTransform(scaleX: 0.2, y: 0.2)
            self.circleView.alpha = 0.0
            self.planeColorView.alpha = 1.0
            self.planeWhiteView.alpha = 0.0
        })
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
            self?.fly()
        }
    }

    @objc private func tapGesture() {
        guard !self.isDismissing, !self.didStartFlight else {
            return
        }
        self.isDismissing = true
        self.open()
        UIView.animate(withDuration: 0.2, animations: {
            self.alpha = 0.0
            self.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        }, completion: { _ in
            self.removeFromSuperview()
        })
    }

    private func fly() {
        guard !self.isDismissing, let window = self.window else {
            return
        }
        self.didStartFlight = true
        self.isUserInteractionEnabled = false

        let start = self.center
        let anchor = ReplyReminderAnchors.shared.landingAnchor(peerId: self.peerId, reminderId: self.reminderId)
        let end: CGPoint
        if let anchor {
            if anchor.hiddenView != nil {
                end = CGPoint(x: anchor.frame.midX, y: anchor.frame.midY)
            } else {
                // The leading part of the line inside the chat.
                end = CGPoint(x: anchor.frame.minX + min(anchor.frame.width / 2.0, 12.0), y: anchor.frame.midY)
            }
        } else {
            // Nothing of the chat on screen: off to the side and away.
            end = CGPoint(x: window.bounds.maxX + 60.0, y: start.y + 140.0)
        }
        anchor?.hiddenView?.isHidden = true
        // From here the path animation turns the view.
        self.transform = .identity

        // Down out of the island first, a loop out to the side, then onto the target.
        let path = UIBezierPath()
        path.move(to: start)
        let side: CGFloat = end.x > start.x ? -1.0 : 1.0
        path.addCurve(to: end, controlPoint1: CGPoint(x: start.x, y: start.y + 190.0), controlPoint2: CGPoint(x: end.x + side * 40.0 - (end.x - start.x) * 0.2, y: end.y - 190.0))

        let duration: CFTimeInterval = 0.95
        let timing = CAMediaTimingFunction(controlPoints: 0.35, 0.0, 0.25, 1.0)

        // Dotted trail behind the plane, drawn along with it and then faded.
        let trail = CAShapeLayer()
        trail.frame = window.bounds
        trail.path = path.cgPath
        trail.fillColor = UIColor.clear.cgColor
        trail.strokeColor = replyReminderAccentColor.withAlphaComponent(0.55).cgColor
        trail.lineWidth = 2.5
        trail.lineCap = .round
        trail.lineDashPattern = [0.0, 7.0]
        trail.strokeEnd = 1.0
        window.layer.insertSublayer(trail, below: self.layer)
        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0.0
        draw.toValue = 1.0
        draw.duration = duration
        draw.timingFunction = timing
        trail.add(draw, forKey: "draw")
        let erase = CABasicAnimation(keyPath: "strokeStart")
        erase.fromValue = 0.0
        erase.toValue = 1.0
        erase.beginTime = CACurrentMediaTime() + duration * 0.45
        erase.duration = duration * 0.75
        erase.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        erase.fillMode = .backwards
        trail.strokeStart = 1.0
        trail.add(erase, forKey: "erase")

        // The view follows the path and turns with it; the plane image points along +x.
        let position = CAKeyframeAnimation(keyPath: "position")
        position.path = path.cgPath
        position.duration = duration
        position.timingFunction = timing
        position.rotationMode = .rotateAuto
        position.fillMode = .forwards
        position.isRemovedOnCompletion = false

        var endScale: CGFloat = 0.6
        if let anchor {
            endScale = anchor.hiddenView != nil ? 0.55 : 0.45
        }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0
        scale.toValue = endScale
        scale.duration = duration
        scale.timingFunction = CAMediaTimingFunction(name: .easeIn)
        scale.fillMode = .forwards
        scale.isRemovedOnCompletion = false

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                trail.removeFromSuperlayer()
            }
            guard let self else {
                anchor?.hiddenView?.isHidden = false
                return
            }
            self.land(at: end, anchor: anchor, in: window)
        }
        self.layer.add(position, forKey: "position")
        self.planeHolder.layer.add(scale, forKey: "scale")
        CATransaction.commit()
    }

    // The plane folds down into a dot that pops in with a ripple, then hands over to the real unread dot.
    private func land(at point: CGPoint, anchor: ReplyReminderAnchor?, in window: UIWindow) {
        UIView.animate(withDuration: 0.16, animations: {
            self.alpha = 0.0
        }, completion: { _ in
            self.removeFromSuperview()
        })
        guard let anchor else {
            return
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        let isBadge = anchor.hiddenView != nil
        let diameter: CGFloat = isBadge ? anchor.frame.height : 10.0
        let color = isBadge ? anchor.color : replyReminderAccentColor

        let dot = UIView(frame: CGRect(x: point.x - diameter / 2.0, y: point.y - diameter / 2.0, width: diameter, height: diameter))
        if isBadge {
            dot.frame = anchor.frame
        }
        dot.backgroundColor = color
        dot.layer.cornerRadius = anchor.frame.height / 2.0
        dot.isUserInteractionEnabled = false
        window.addSubview(dot)

        let ripple = UIView(frame: CGRect(x: point.x - diameter / 2.0, y: point.y - diameter / 2.0, width: diameter, height: diameter))
        ripple.layer.cornerRadius = diameter / 2.0
        ripple.layer.borderWidth = 2.0
        ripple.layer.borderColor = color.cgColor
        ripple.isUserInteractionEnabled = false
        window.insertSubview(ripple, belowSubview: dot)

        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [0.1, 1.35, 0.88, 1.06, 1.0] as [NSNumber]
        pop.keyTimes = [0.0, 0.35, 0.62, 0.84, 1.0] as [NSNumber]
        pop.duration = 0.5
        dot.layer.add(pop, forKey: "pop")

        UIView.animate(withDuration: 0.6, delay: 0.05, options: [.curveEaseOut], animations: {
            ripple.transform = CGAffineTransform(scaleX: 2.8, y: 2.8)
            ripple.alpha = 0.0
        }, completion: { _ in
            ripple.removeFromSuperview()
        })

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            anchor.hiddenView?.isHidden = false
            anchor.land?()
            UIView.animate(withDuration: isBadge ? 0.12 : 0.25, animations: {
                dot.alpha = 0.0
            }, completion: { _ in
                dot.removeFromSuperview()
            })
        }
    }
}

// Telegram's paper plane pointing along +x.
private func replyReminderPlaneImage(color: UIColor) -> UIImage? {
    let size = CGSize(width: 46.0, height: 46.0)
    guard let plane = UIImage(systemName: "paperplane.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 24.0, weight: .semibold))?.withTintColor(color, renderingMode: .alwaysOriginal) else {
        return nil
    }
    let format = UIGraphicsImageRendererFormat()
    format.scale = UIScreen.main.scale
    return UIGraphicsImageRenderer(size: size, format: format).image { context in
        let cg = context.cgContext
        cg.translateBy(x: size.width / 2.0, y: size.height / 2.0)
        // The symbol points up and to the right.
        cg.rotate(by: CGFloat.pi / 4.0)
        plane.draw(in: CGRect(x: -plane.size.width / 2.0, y: -plane.size.height / 2.0, width: plane.size.width, height: plane.size.height))
    }
}
