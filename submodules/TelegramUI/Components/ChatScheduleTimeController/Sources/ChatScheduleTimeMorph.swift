import Foundation
import UIKit
import Display

// The on-screen element a reminder sheet grows out of and collapses back into
// (the reminder line in the chat or the reminder label in the chat list).
public struct ChatScheduleTimeMorphAnchor {
    // In window coordinates.
    public let frame: CGRect
    public let cornerRadius: CGFloat
    public let color: UIColor
    // Hidden while the morph covers it.
    public let hiddenView: UIView?
    public let land: (() -> Void)?

    public init(frame: CGRect, cornerRadius: CGFloat, color: UIColor, hiddenView: UIView?, land: (() -> Void)?) {
        self.frame = frame
        self.cornerRadius = cornerRadius
        self.color = color
        self.hiddenView = hiddenView
        self.land = land
    }
}

// A rounded shape that flies between the sheet card and an anchor, following the anchor if it moves
// (the reminder line is inserted into the chat while the sheet is already collapsing).
final class ChatScheduleTimeMorphView: UIView {
    private let startFrame: CGRect
    private let startCornerRadius: CGFloat
    private let startColor: UIColor
    private let snapshotView: UIView?
    private let snapshotStartFrame: CGRect
    private let target: () -> ChatScheduleTimeMorphAnchor?
    private let fallbackTarget: CGRect
    private let fadesSnapshot: Bool
    private let completion: () -> Void

    private var displayLink: SharedDisplayLinkDriver.Link?
    private var startTime: Double?
    private var currentTarget: ChatScheduleTimeMorphAnchor?
    private var hiddenViews: [UIView] = []
    private var isFinished = false

    // Waits this long for the anchor to appear before falling back to a plain shrink.
    private let anchorWaitTimeout: Double = 0.12
    private var waitStartTime: Double?

    init(startFrame: CGRect, startCornerRadius: CGFloat, startColor: UIColor, snapshotView: UIView?, snapshotFrame: CGRect, fadesSnapshot: Bool, fallbackTarget: CGRect, target: @escaping () -> ChatScheduleTimeMorphAnchor?, completion: @escaping () -> Void) {
        self.startFrame = startFrame
        self.startCornerRadius = startCornerRadius
        self.startColor = startColor
        self.snapshotView = snapshotView
        self.snapshotStartFrame = snapshotFrame
        self.fadesSnapshot = fadesSnapshot
        self.fallbackTarget = fallbackTarget
        self.target = target
        self.completion = completion

        super.init(frame: startFrame)

        self.isUserInteractionEnabled = false
        self.clipsToBounds = true
        self.layer.cornerCurve = .continuous
        self.layer.cornerRadius = startCornerRadius
        self.backgroundColor = startColor

        if let snapshotView {
            snapshotView.frame = snapshotFrame
            self.addSubview(snapshotView)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func start() {
        self.waitStartTime = CACurrentMediaTime()
        self.displayLink = SharedDisplayLinkDriver.shared.add(framesPerSecond: .max, { [weak self] _ in
            self?.tick()
        })
        self.tick()
    }

    // Critically damped-ish spring: quick, with a small overshoot at the end.
    private static func spring(_ t: Double) -> Double {
        let omega = 13.0
        let zeta = 0.78
        let omegaD = omega * sqrt(1.0 - zeta * zeta)
        return 1.0 - exp(-zeta * omega * t) * (cos(omegaD * t) + (zeta * omega / omegaD) * sin(omegaD * t))
    }

    private func tick() {
        guard !self.isFinished else {
            return
        }
        let now = CACurrentMediaTime()

        if let target = self.target() {
            if let hiddenView = target.hiddenView, !self.hiddenViews.contains(where: { $0 === hiddenView }) {
                hiddenView.alpha = 0.0
                self.hiddenViews.append(hiddenView)
            }
            self.currentTarget = target
        }
        if self.startTime == nil {
            if self.currentTarget != nil || now - (self.waitStartTime ?? now) >= self.anchorWaitTimeout {
                self.startTime = now
            } else {
                return
            }
        }

        let t = now - (self.startTime ?? now)
        let duration = 0.62
        let p = CGFloat(ChatScheduleTimeMorphView.spring(t))
        let linear = CGFloat(min(1.0, t / duration))

        let targetFrame = self.currentTarget?.frame ?? self.fallbackTarget
        let targetCornerRadius = self.currentTarget?.cornerRadius ?? (targetFrame.height / 2.0)
        let targetColor = self.currentTarget?.color ?? self.startColor.withAlphaComponent(0.0)

        let frame = CGRect(
            x: self.startFrame.minX + (targetFrame.minX - self.startFrame.minX) * p,
            y: self.startFrame.minY + (targetFrame.minY - self.startFrame.minY) * p,
            width: max(1.0, self.startFrame.width + (targetFrame.width - self.startFrame.width) * p),
            height: max(1.0, self.startFrame.height + (targetFrame.height - self.startFrame.height) * p)
        )
        self.frame = frame
        let clampedP = max(0.0, min(1.0, p))
        self.layer.cornerRadius = min(frame.height / 2.0, self.startCornerRadius + (targetCornerRadius - self.startCornerRadius) * clampedP)
        self.backgroundColor = self.startColor.interpolateTo(targetColor, fraction: clampedP) ?? targetColor

        if let snapshotView = self.snapshotView {
            // The card contents shrink along with the shape, keeping their proportions, and fade out early.
            let scale = frame.width / self.startFrame.width
            snapshotView.transform = CGAffineTransform(scaleX: scale, y: scale)
            snapshotView.center = CGPoint(x: self.snapshotStartFrame.midX * scale, y: self.snapshotStartFrame.midY * scale)
            if self.fadesSnapshot {
                snapshotView.alpha = max(0.0, 1.0 - linear * 3.0)
            } else {
                snapshotView.alpha = max(0.0, min(1.0, (linear - 0.55) * 3.0))
            }
        }
        if self.currentTarget == nil {
            self.alpha = 1.0 - linear
        }

        if t >= duration {
            self.finish()
        }
    }

    private func finish() {
        self.isFinished = true
        self.displayLink?.invalidate()
        self.displayLink = nil

        let hiddenViews = self.hiddenViews
        self.hiddenViews = []
        let land = self.currentTarget?.land
        UIView.animate(withDuration: 0.16, animations: {
            self.alpha = 0.0
            for view in hiddenViews {
                view.alpha = 1.0
            }
        }, completion: { _ in
            self.removeFromSuperview()
        })
        land?()
        self.completion()
    }
}

// The sheet folds into a small reminder icon that flies off to the chat the reminder is for and pops there:
// a chat list row, the reminders button of the open chat's input field or a bubble on the reminders screen.
final class ChatScheduleTimeFlyAwayView: UIView {
    private let startFrame: CGRect
    private let startCornerRadius: CGFloat
    private let startColor: UIColor
    private let accentColor: UIColor
    private let snapshotView: UIView?
    private let snapshotStartFrame: CGRect
    private let target: () -> ChatScheduleTimeMorphAnchor?

    private let iconView = UIImageView()
    private var displayLink: SharedDisplayLinkDriver.Link?
    private var startTime: Double?
    private var currentTarget: ChatScheduleTimeMorphAnchor?
    private var isFinished = false
    // The new reminder's bubble stays hidden until the icon reaches it.
    private var hiddenViews: [UIView] = []

    private let foldDuration = 0.36
    private let flightDuration = 0.62
    private let iconDiameter: CGFloat = 54.0

    private var foldedFrame: CGRect {
        return CGRect(x: self.startFrame.midX - self.iconDiameter / 2.0, y: self.startFrame.midY - self.iconDiameter / 2.0, width: self.iconDiameter, height: self.iconDiameter)
    }

    init(startFrame: CGRect, startCornerRadius: CGFloat, startColor: UIColor, accentColor: UIColor, snapshotView: UIView?, snapshotFrame: CGRect, target: @escaping () -> ChatScheduleTimeMorphAnchor?) {
        self.startFrame = startFrame
        self.startCornerRadius = startCornerRadius
        self.startColor = startColor
        self.accentColor = accentColor
        self.snapshotView = snapshotView
        self.snapshotStartFrame = snapshotFrame
        self.target = target

        super.init(frame: startFrame)

        self.isUserInteractionEnabled = false
        self.clipsToBounds = true
        self.layer.cornerCurve = .continuous
        self.layer.cornerRadius = startCornerRadius
        self.backgroundColor = startColor

        if let snapshotView {
            snapshotView.frame = snapshotFrame
            self.addSubview(snapshotView)
        }

        let configuration = UIImage.SymbolConfiguration(pointSize: 23.0, weight: .semibold)
        for name in ["pencil.and.list.clipboard", "list.clipboard", "note.text"] {
            if let image = UIImage(systemName: name, withConfiguration: configuration) {
                self.iconView.image = image.withRenderingMode(.alwaysTemplate)
                break
            }
        }
        self.iconView.tintColor = .white
        self.iconView.contentMode = .center
        self.iconView.alpha = 0.0
        self.addSubview(self.iconView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func start() {
        self.startTime = CACurrentMediaTime()
        self.displayLink = SharedDisplayLinkDriver.shared.add(framesPerSecond: .max, { [weak self] _ in
            self?.tick()
        })
        self.tick()
    }

    private static func easeInOut(_ t: CGFloat) -> CGFloat {
        return t < 0.5 ? 4.0 * t * t * t : 1.0 - pow(-2.0 * t + 2.0, 3.0) / 2.0
    }

    private static func easeOutBack(_ t: CGFloat) -> CGFloat {
        let c1: CGFloat = 1.4
        let c3 = c1 + 1.0
        return 1.0 + c3 * pow(t - 1.0, 3.0) + c1 * pow(t - 1.0, 2.0)
    }

    private func tick() {
        guard !self.isFinished, let startTime = self.startTime else {
            return
        }
        // The target can appear or move meanwhile (the reminders button slides into the input field).
        if let target = self.target() {
            if let hiddenView = target.hiddenView, !self.hiddenViews.contains(where: { $0 === hiddenView }) {
                hiddenView.alpha = 0.0
                self.hiddenViews.append(hiddenView)
            }
            self.currentTarget = target
        }
        let t = CACurrentMediaTime() - startTime

        if t < self.foldDuration {
            // The card shrinks into a round icon of the accent color.
            let linear = CGFloat(t / self.foldDuration)
            let p = ChatScheduleTimeFlyAwayView.easeOutBack(linear)
            let folded = self.foldedFrame
            let frame = CGRect(
                x: self.startFrame.minX + (folded.minX - self.startFrame.minX) * p,
                y: self.startFrame.minY + (folded.minY - self.startFrame.minY) * p,
                width: max(1.0, self.startFrame.width + (folded.width - self.startFrame.width) * p),
                height: max(1.0, self.startFrame.height + (folded.height - self.startFrame.height) * p)
            )
            self.bounds = CGRect(origin: CGPoint(), size: frame.size)
            self.center = CGPoint(x: frame.midX, y: frame.midY)
            let clamped = max(0.0, min(1.0, p))
            self.layer.cornerRadius = min(frame.height / 2.0, self.startCornerRadius + (self.iconDiameter / 2.0 - self.startCornerRadius) * clamped)
            self.backgroundColor = self.startColor.interpolateTo(self.accentColor, fraction: min(1.0, linear * 1.6)) ?? self.accentColor
            if let snapshotView = self.snapshotView {
                let scale = frame.width / self.startFrame.width
                snapshotView.transform = CGAffineTransform(scaleX: scale, y: scale)
                snapshotView.center = CGPoint(x: self.snapshotStartFrame.midX * scale, y: self.snapshotStartFrame.midY * scale)
                snapshotView.alpha = max(0.0, 1.0 - linear * 2.5)
            }
            self.iconView.frame = self.bounds
            self.iconView.alpha = max(0.0, min(1.0, (linear - 0.35) * 2.5))
            return
        }

        self.snapshotView?.removeFromSuperview()
        self.backgroundColor = self.accentColor
        self.iconView.alpha = 1.0
        self.bounds = CGRect(origin: CGPoint(), size: CGSize(width: self.iconDiameter, height: self.iconDiameter))
        self.layer.cornerRadius = self.iconDiameter / 2.0
        self.iconView.frame = self.bounds

        // Then it flies along an arc to the chat, shrinking and tilting like a note tossed onto it.
        let linear = CGFloat(min(1.0, (t - self.foldDuration) / self.flightDuration))
        let p = ChatScheduleTimeFlyAwayView.easeInOut(linear)
        let start = CGPoint(x: self.foldedFrame.midX, y: self.foldedFrame.midY)
        let end: CGPoint
        let endScale: CGFloat
        if let target = self.currentTarget {
            end = CGPoint(x: target.frame.midX, y: target.frame.midY)
            endScale = max(0.3, min(0.6, (target.frame.height + 6.0) / self.iconDiameter))
        } else {
            end = CGPoint(x: start.x, y: -self.iconDiameter)
            endScale = 0.4
        }
        let control = CGPoint(x: (start.x + end.x) / 2.0 + (end.x - start.x) * 0.25, y: min(start.y, end.y) - 140.0)
        let a = 1.0 - p
        self.center = CGPoint(x: a * a * start.x + 2.0 * a * p * control.x + p * p * end.x, y: a * a * start.y + 2.0 * a * p * control.y + p * p * end.y)
        let scale = 1.0 + (endScale - 1.0) * p
        let tilt = sin(p * .pi) * (end.x >= start.x ? 0.35 : -0.35)
        self.transform = CGAffineTransform(rotationAngle: tilt).scaledBy(x: scale, y: scale)

        if linear >= 1.0 {
            self.finish()
        }
    }

    private func finish() {
        self.isFinished = true
        self.displayLink?.invalidate()
        self.displayLink = nil

        let hiddenViews = self.hiddenViews
        self.hiddenViews = []
        UIView.animate(withDuration: 0.18, animations: {
            for view in hiddenViews {
                view.alpha = 1.0
            }
        })

        guard let target = self.currentTarget, let window = self.window else {
            UIView.animate(withDuration: 0.15, animations: {
                self.alpha = 0.0
            }, completion: { _ in
                self.removeFromSuperview()
            })
            return
        }

        // Pops on the chat with a ripple and is gone.
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let diameter = self.iconDiameter * (max(0.3, min(0.6, (target.frame.height + 6.0) / self.iconDiameter)))
        let ripple = UIView(frame: CGRect(x: self.center.x - diameter / 2.0, y: self.center.y - diameter / 2.0, width: diameter, height: diameter))
        ripple.isUserInteractionEnabled = false
        ripple.layer.cornerRadius = diameter / 2.0
        ripple.layer.borderWidth = 2.0
        ripple.layer.borderColor = self.accentColor.cgColor
        window.insertSubview(ripple, belowSubview: self)
        UIView.animate(withDuration: 0.5, delay: 0.0, options: [.curveEaseOut], animations: {
            ripple.transform = CGAffineTransform(scaleX: 2.6, y: 2.6)
            ripple.alpha = 0.0
        }, completion: { _ in
            ripple.removeFromSuperview()
        })

        let currentTransform = self.transform
        UIView.animate(withDuration: 0.22, delay: 0.0, options: [.curveEaseOut], animations: {
            self.transform = currentTransform.scaledBy(x: 1.35, y: 1.35)
            self.alpha = 0.0
        }, completion: { _ in
            self.removeFromSuperview()
        })
        target.land?()
    }
}
