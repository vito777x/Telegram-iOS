import Foundation
import UIKit
import Display
import TelegramPresentationData

// Covers the note field while the note is dictated: a recording capsule styled like a recorded voice message in
// chats (a filled accent capsule with a white waveform, timer and done button). The waveform scrolls smoothly, frame
// by frame, between the voice levels. When the recording is done, the waveform breaks into sparkles and the
// recognized text is written in by a shimmering sweep, ending exactly where the field draws its text.
final class ReplyReminderRecordingView: UIView {
    private let dotView = UIView()
    private let timerLabel = UILabel()
    private let waveformView = UIView()
    private let doneButton = UIButton(type: .custom)

    private var barLayers: [CALayer] = []
    private var levels: [CGFloat] = []
    private let barWidth: CGFloat = 3.0
    private let barSpacing: CGFloat = 2.0

    private var startDate = Date()
    private var timer: Foundation.Timer?
    private let accentColor: UIColor
    private let fieldColor: UIColor

    // Smooth scrolling: bars slide over by one step per voice level, spread over the time between levels.
    private var displayLink: SharedDisplayLinkDriver.Link?
    private var lastLevelTime: Double = 0.0
    private var levelInterval: Double = 0.05
    private var isLive = false

    var done: (() -> Void)?

    init(theme: PresentationTheme) {
        self.accentColor = theme.actionSheet.controlAccentColor
        self.fieldColor = theme.actionSheet.inputBackgroundColor
        super.init(frame: CGRect())

        self.backgroundColor = self.accentColor
        self.layer.cornerCurve = .continuous
        self.clipsToBounds = true

        self.dotView.backgroundColor = .white
        self.dotView.layer.cornerRadius = 4.0
        self.addSubview(self.dotView)

        self.timerLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 15.0, weight: .semibold)
        self.timerLabel.textColor = .white
        self.timerLabel.text = "0:00"
        self.addSubview(self.timerLabel)

        self.addSubview(self.waveformView)

        self.doneButton.backgroundColor = .white
        self.doneButton.layer.cornerRadius = 15.0
        self.doneButton.tintColor = self.accentColor
        self.doneButton.setImage(UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13.0, weight: .bold)), for: .normal)
        self.doneButton.addTarget(self, action: #selector(self.donePressed), for: .touchUpInside)
        self.addSubview(self.doneButton)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.timer?.invalidate()
        self.displayLink?.invalidate()
    }

    @objc private func donePressed() {
        self.doneButton.isEnabled = false
        self.done?()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = self.bounds.size
        self.layer.cornerRadius = min(size.height / 2.0, 20.0)
        self.dotView.frame = CGRect(x: 16.0, y: floor((size.height - 8.0) / 2.0), width: 8.0, height: 8.0)
        self.timerLabel.frame = CGRect(x: 32.0, y: 0.0, width: 44.0, height: size.height)
        self.doneButton.frame = CGRect(x: size.width - 7.0 - 30.0, y: floor((size.height - 30.0) / 2.0), width: 30.0, height: 30.0)
        let waveformX: CGFloat = self.timerLabel.isHidden ? 16.0 : 78.0
        let waveformMaxX: CGFloat = self.doneButton.isHidden ? size.width - 16.0 : self.doneButton.frame.minX - 10.0
        self.waveformView.frame = CGRect(x: waveformX, y: 9.0, width: max(0.0, waveformMaxX - waveformX), height: max(0.0, size.height - 18.0))
        self.waveformView.layer.masksToBounds = true
        self.layoutBars(scroll: 0.0)
    }

    func animateIn() {
        self.startDate = Date()
        self.alpha = 0.0
        self.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
        UIView.animate(withDuration: 0.35, delay: 0.0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.0, options: [], animations: {
            self.alpha = 1.0
            self.transform = .identity
        })

        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.2
        pulse.duration = 0.6
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        self.dotView.layer.add(pulse, forKey: "pulse")

        self.timer = Foundation.Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true, block: { [weak self] _ in
            guard let self else {
                return
            }
            let seconds = Int(Date().timeIntervalSince(self.startDate))
            self.timerLabel.text = String(format: "%d:%02d", seconds / 60, seconds % 60)
        })

        self.isLive = true
        self.lastLevelTime = CACurrentMediaTime()
        self.displayLink = SharedDisplayLinkDriver.shared.add(framesPerSecond: .max, { [weak self] _ in
            self?.tick()
        })
    }

    private var capacity: Int {
        return max(1, Int((self.waveformView.bounds.width + self.barSpacing) / (self.barWidth + self.barSpacing)))
    }

    // The loudness range adapts to the room and the voice: silence is drawn flat, speech tall.
    private var noiseFloorDb: CGFloat = -55.0
    private var peakDb: CGFloat = -20.0

    // New voice peak amplitude, 0...1: the waveform scrolls to the left like in the chat recorder.
    func addLevel(_ amplitude: CGFloat) {
        let db = 20.0 * log10(max(amplitude, 0.00001))
        // The floor drops at once to quieter sound and creeps up slowly; the peak the other way round.
        self.noiseFloorDb = db < self.noiseFloorDb ? db : self.noiseFloorDb + 0.15
        self.peakDb = db > self.peakDb ? db : self.peakDb - 0.12
        self.peakDb = max(self.peakDb, self.noiseFloorDb + 24.0)
        let range = self.peakDb - (self.noiseFloorDb + 4.0)
        let normalized = max(0.0, min(1.0, (db - self.noiseFloorDb - 4.0) / max(1.0, range)))
        self.appendLevel(pow(normalized, 1.25))
    }

    private func appendLevel(_ level: CGFloat) {
        let now = CACurrentMediaTime()
        let interval = now - self.lastLevelTime
        if interval > 0.01 && interval < 0.3 {
            self.levelInterval = self.levelInterval * 0.8 + interval * 0.2
        }
        self.lastLevelTime = now
        self.levels.append(level)
        let keep = self.capacity + 2
        if self.levels.count > keep {
            self.levels.removeFirst(self.levels.count - keep)
        }
        if !self.isLive {
            self.layoutBars(scroll: 0.0)
        }
    }

    private func tick() {
        guard self.isLive else {
            return
        }
        let progress = CGFloat(max(0.0, min(1.0, (CACurrentMediaTime() - self.lastLevelTime) / max(0.02, self.levelInterval))))
        self.layoutBars(scroll: progress)
    }

    // `scroll` (0...1) is how far the bars have moved on towards the next level; the newest bar grows in meanwhile.
    private func layoutBars(scroll: CGFloat) {
        let bounds = self.waveformView.bounds
        guard bounds.width > 0.0 else {
            return
        }
        let step = self.barWidth + self.barSpacing
        let capacity = self.capacity
        let count = capacity + 1
        while self.barLayers.count < count {
            let bar = CALayer()
            bar.backgroundColor = UIColor.white.cgColor
            bar.cornerRadius = self.barWidth / 2.0
            self.waveformView.layer.addSublayer(bar)
            self.barLayers.append(bar)
        }
        let offset = self.isLive ? step * (1.0 - scroll) : 0.0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in self.barLayers.enumerated() {
            // Bars fill from the right: the newest level is the rightmost bar.
            let levelIndex = self.levels.count - (count - i)
            var level = levelIndex >= 0 && levelIndex < self.levels.count ? self.levels[levelIndex] : 0.0
            if self.isLive && levelIndex == self.levels.count - 1 {
                level *= scroll
            }
            let height = max(self.barWidth, bounds.height * (0.1 + 0.9 * level))
            let x = bounds.width - CGFloat(count - i) * step + self.barSpacing + offset
            bar.frame = CGRect(x: x, y: floor((bounds.height - height) / 2.0), width: self.barWidth, height: height)
            bar.opacity = levelIndex >= 0 ? 1.0 : 0.35
        }
        CATransaction.commit()
    }

    // A voice message: its own waveform across the capsule, no timer and no done button.
    func showVoice(levels: [CGFloat]) {
        self.isLive = false
        self.dotView.isHidden = true
        self.timerLabel.isHidden = true
        self.doneButton.isHidden = true
        self.setNeedsLayout()
        self.layoutIfNeeded()
        let capacity = self.capacity + 1
        if levels.isEmpty {
            self.levels = (0 ..< capacity).map { _ in CGFloat.random(in: 0.15 ... 0.8) }
        } else {
            self.levels = (0 ..< capacity).map { i in
                let index = min(levels.count - 1, Int(CGFloat(i) / CGFloat(capacity) * CGFloat(levels.count)))
                return levels[index]
            }
        }
        self.layoutBars(scroll: 0.0)
    }

    // While the last words are being recognized: a soft wave runs through the bars.
    func showProcessing() {
        self.timer?.invalidate()
        self.isLive = false
        self.displayLink?.invalidate()
        self.displayLink = nil
        self.layoutBars(scroll: 0.0)
        self.dotView.layer.removeAllAnimations()
        UIView.animate(withDuration: 0.2, animations: {
            self.dotView.alpha = 0.0
            self.doneButton.alpha = 0.4
        })
        for (i, bar) in self.barLayers.enumerated() {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = 1.0
            animation.toValue = 0.3
            animation.duration = 0.5
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.beginTime = CACurrentMediaTime() + Double(i) * 0.02
            bar.add(animation, forKey: "processing")
        }
    }

    // A wave runs through the capsule from the left: the bars it reaches swell and fade, the capsule disappears behind
    // it, and in the cleared space the note field shows with `text` on it. `textFrame` (in this view) is where the note
    // field draws its text, so what is revealed matches the field exactly and the hand-over is seamless.
    func writeText(_ text: String, font: UIFont, color: UIColor, textFrame: CGRect, completion: @escaping () -> Void) {
        guard let superview = self.superview else {
            completion()
            return
        }
        self.timer?.invalidate()
        self.isLive = false
        self.displayLink?.invalidate()
        self.displayLink = nil
        for bar in self.barLayers {
            bar.removeAllAnimations()
        }
        UIView.animate(withDuration: 0.2, animations: {
            self.doneButton.alpha = 0.0
            self.dotView.alpha = 0.0
        })

        let duration: Double = 0.75
        let width = self.bounds.width
        let edge: CGFloat = 46.0
        let startTime = CACurrentMediaTime() + 0.05

        // What is revealed: the note field with the text. It stops short of the field's microphone, which the
        // field itself shows, so the microphone is never covered or drawn twice.
        let back = UIView(frame: CGRect(x: self.frame.minX, y: self.frame.minY, width: max(0.0, self.frame.width - 44.0), height: self.frame.height))
        back.backgroundColor = self.fieldColor
        back.layer.cornerRadius = 12.0
        back.layer.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        back.layer.cornerCurve = .continuous
        back.clipsToBounds = true
        back.isUserInteractionEnabled = false
        let label = UILabel()
        label.font = font
        label.textColor = color
        label.text = text
        label.lineBreakMode = .byTruncatingTail
        label.frame = textFrame
        back.addSubview(label)
        superview.insertSubview(back, belowSubview: self)

        // The capsule is cut away behind a soft moving edge.
        let mask = CAGradientLayer()
        mask.startPoint = CGPoint(x: 0.0, y: 0.5)
        mask.endPoint = CGPoint(x: 1.0, y: 0.5)
        mask.colors = [UIColor.clear.cgColor, UIColor.clear.cgColor, UIColor.black.cgColor, UIColor.black.cgColor]
        let maskWidth = width * 2.0 + edge
        mask.locations = [0.0, NSNumber(value: Double(width / maskWidth)), NSNumber(value: Double((width + edge) / maskWidth)), 1.0]
        mask.bounds = CGRect(x: 0.0, y: 0.0, width: maskWidth, height: self.bounds.height)
        mask.anchorPoint = CGPoint(x: 0.0, y: 0.5)
        mask.position = CGPoint(x: 0.0, y: self.bounds.height / 2.0)
        self.layer.mask = mask
        let maskMove = CABasicAnimation(keyPath: "position.x")
        maskMove.fromValue = -(width + edge)
        maskMove.toValue = 0.0
        maskMove.beginTime = startTime
        maskMove.duration = duration
        maskMove.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        maskMove.fillMode = .both
        maskMove.isRemovedOnCompletion = false
        mask.add(maskMove, forKey: "wave")

        // A soft glow rides the wave front, kept inside the capsule.
        let glowContainer = UIView(frame: self.frame)
        glowContainer.isUserInteractionEnabled = false
        glowContainer.clipsToBounds = true
        glowContainer.layer.cornerRadius = self.layer.cornerRadius
        glowContainer.layer.cornerCurve = .continuous
        superview.insertSubview(glowContainer, aboveSubview: back)
        let glow = CAGradientLayer()
        glow.startPoint = CGPoint(x: 0.0, y: 0.5)
        glow.endPoint = CGPoint(x: 1.0, y: 0.5)
        glow.colors = [self.accentColor.withAlphaComponent(0.0).cgColor, self.accentColor.withAlphaComponent(0.45).cgColor, self.accentColor.withAlphaComponent(0.0).cgColor]
        glow.bounds = CGRect(x: 0.0, y: 0.0, width: edge, height: self.bounds.height)
        glow.position = CGPoint(x: -edge / 2.0, y: self.bounds.height / 2.0)
        glowContainer.layer.addSublayer(glow)
        let glowMove = CABasicAnimation(keyPath: "position.x")
        glowMove.fromValue = -edge / 2.0
        glowMove.toValue = width + edge / 2.0
        glowMove.beginTime = startTime
        glowMove.duration = duration
        glowMove.timingFunction = maskMove.timingFunction
        glowMove.fillMode = .both
        glowMove.isRemovedOnCompletion = false
        glow.add(glowMove, forKey: "wave")

        // The bars swell as the wave reaches them, then sink.
        let waveformOffset = self.waveformView.frame.minX
        for bar in self.barLayers {
            let x = (waveformOffset + bar.frame.midX) / max(1.0, width)
            let swell = CAKeyframeAnimation(keyPath: "transform.scale.y")
            swell.values = [1.0, 1.9, 0.2] as [NSNumber]
            swell.keyTimes = [0.0, 0.45, 1.0] as [NSNumber]
            swell.duration = 0.28
            swell.beginTime = startTime + max(0.0, duration * Double(x) - 0.2)
            swell.fillMode = .both
            swell.isRemovedOnCompletion = false
            bar.add(swell, forKey: "swell")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 + duration, execute: {
            glowContainer.removeFromSuperview()
            self.alpha = 0.0
            completion()
            back.removeFromSuperview()
        })
    }

    // Nothing was recognized: a short shake, then the capsule goes away.
    func dismissWithShake(completion: @escaping () -> Void) {
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shake.values = [0.0, -8.0, 8.0, -6.0, 6.0, -3.0, 0.0] as [NSNumber]
        shake.duration = 0.4
        self.layer.add(shake, forKey: "shake")
        UIView.animate(withDuration: 0.2, delay: 0.35, options: [], animations: {
            self.alpha = 0.0
        }, completion: { _ in
            completion()
        })
    }
}

// A voice message moving from one shape to another: it collapses into a glowing point like a dying star, the point
// flies over, and bursts open into the note field.
enum ReplyReminderImplosion {
    // The bubble flares a little, then collapses into its center while sparkles are pulled in; returns the glowing point.
    static func collapse(_ view: UIView, in window: UIWindow, color: UIColor, completion: @escaping (UIView) -> Void) {
        let center = CGPoint(x: view.frame.midX, y: view.frame.midY)

        let orb = UIView(frame: CGRect(x: 0.0, y: 0.0, width: 14.0, height: 14.0))
        orb.center = center
        orb.backgroundColor = .white
        orb.layer.cornerRadius = 7.0
        orb.layer.shadowColor = color.cgColor
        orb.layer.shadowRadius = 10.0
        orb.layer.shadowOpacity = 1.0
        orb.layer.shadowOffset = .zero
        orb.alpha = 0.0
        orb.transform = CGAffineTransform(scaleX: 0.2, y: 0.2)
        window.addSubview(orb)

        // Sparkles from all over the bubble, pulled into the center.
        for _ in 0 ..< 18 {
            let start = CGPoint(x: CGFloat.random(in: view.frame.minX ... view.frame.maxX), y: CGFloat.random(in: view.frame.minY ... view.frame.maxY))
            let sparkle = makeSparkle(color: color, size: CGFloat.random(in: 3.0 ... 6.0))
            sparkle.center = start
            sparkle.alpha = 0.0
            window.addSubview(sparkle)
            let delay = Double.random(in: 0.0 ... 0.12)
            UIView.animate(withDuration: 0.1, delay: delay, options: [], animations: {
                sparkle.alpha = 1.0
            })
            UIView.animate(withDuration: 0.32, delay: delay, options: [.curveEaseIn], animations: {
                sparkle.center = center
                sparkle.transform = CGAffineTransform(scaleX: 0.3, y: 0.3)
            }, completion: { _ in
                sparkle.removeFromSuperview()
            })
        }

        UIView.animateKeyframes(withDuration: 0.42, delay: 0.0, options: [], animations: {
            UIView.addKeyframe(withRelativeStartTime: 0.0, relativeDuration: 0.25, animations: {
                view.transform = CGAffineTransform(scaleX: 1.06, y: 1.06)
            })
            UIView.addKeyframe(withRelativeStartTime: 0.25, relativeDuration: 0.75, animations: {
                view.transform = CGAffineTransform(scaleX: 0.02, y: 0.02)
            })
            UIView.addKeyframe(withRelativeStartTime: 0.6, relativeDuration: 0.4, animations: {
                view.alpha = 0.0
            })
        }, completion: { _ in
            view.removeFromSuperview()
        })

        UIView.animate(withDuration: 0.3, delay: 0.3, usingSpringWithDamping: 0.45, initialSpringVelocity: 0.0, options: [], animations: {
            orb.alpha = 1.0
            orb.transform = .identity
        }, completion: { _ in
            let pulse = CABasicAnimation(keyPath: "transform.scale")
            pulse.fromValue = 1.0
            pulse.toValue = 1.25
            pulse.duration = 0.35
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            orb.layer.add(pulse, forKey: "pulse")
            completion(orb)
        })
    }

    // A glowing point that pops up at `point` and pulses until it flies off with `burst`.
    static func makeOrb(at point: CGPoint, in window: UIWindow, color: UIColor) -> UIView {
        let orb = UIView(frame: CGRect(x: 0.0, y: 0.0, width: 14.0, height: 14.0))
        orb.center = point
        orb.backgroundColor = .white
        orb.layer.cornerRadius = 7.0
        orb.layer.shadowColor = color.cgColor
        orb.layer.shadowRadius = 10.0
        orb.layer.shadowOpacity = 1.0
        orb.layer.shadowOffset = .zero
        orb.isUserInteractionEnabled = false
        orb.transform = CGAffineTransform(scaleX: 0.2, y: 0.2)
        window.addSubview(orb)
        UIView.animate(withDuration: 0.3, delay: 0.0, usingSpringWithDamping: 0.45, initialSpringVelocity: 0.0, options: [], animations: {
            orb.transform = .identity
        }, completion: { _ in
            let pulse = CABasicAnimation(keyPath: "transform.scale")
            pulse.fromValue = 1.0
            pulse.toValue = 1.25
            pulse.duration = 0.35
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            orb.layer.add(pulse, forKey: "pulse")
        })
        return orb
    }

    // The point travels to `targetView` along an arc and bursts there; `targetView` unfolds out of it.
    static func burst(orb: UIView, into targetView: UIView, in window: UIWindow, color: UIColor, completion: @escaping () -> Void) {
        let targetFrame = targetView.convert(targetView.bounds, to: window)
        let targetCenter = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
        let start = orb.center

        window.bringSubviewToFront(orb)
        let path = UIBezierPath()
        path.move(to: start)
        path.addQuadCurve(to: targetCenter, controlPoint: CGPoint(x: (start.x + targetCenter.x) / 2.0 + 60.0, y: min(start.y, targetCenter.y) - 80.0))
        let move = CAKeyframeAnimation(keyPath: "position")
        move.path = path.cgPath
        move.duration = 0.38
        move.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 0.2, 1.0)
        move.fillMode = .forwards
        move.isRemovedOnCompletion = false

        CATransaction.begin()
        CATransaction.setCompletionBlock {
            orb.layer.removeAllAnimations()
            orb.center = targetCenter
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()

            // The point blows up and fades.
            UIView.animate(withDuration: 0.3, delay: 0.0, options: [.curveEaseOut], animations: {
                orb.transform = CGAffineTransform(scaleX: 4.0, y: 4.0)
                orb.alpha = 0.0
            }, completion: { _ in
                orb.removeFromSuperview()
            })

            // A shockwave ring.
            let ring = CAShapeLayer()
            ring.path = UIBezierPath(ovalIn: CGRect(x: -10.0, y: -10.0, width: 20.0, height: 20.0)).cgPath
            ring.position = targetCenter
            ring.fillColor = UIColor.clear.cgColor
            ring.strokeColor = color.cgColor
            ring.lineWidth = 2.0
            window.layer.addSublayer(ring)
            let ringScale = CABasicAnimation(keyPath: "transform.scale")
            ringScale.fromValue = 0.3
            ringScale.toValue = max(4.0, targetFrame.width / 20.0)
            let ringFade = CABasicAnimation(keyPath: "opacity")
            ringFade.fromValue = 0.9
            ringFade.toValue = 0.0
            let ringGroup = CAAnimationGroup()
            ringGroup.animations = [ringScale, ringFade]
            ringGroup.duration = 0.45
            ringGroup.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ringGroup.fillMode = .forwards
            ringGroup.isRemovedOnCompletion = false
            ring.add(ringGroup, forKey: "wave")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: {
                ring.removeFromSuperlayer()
            })

            // Sparkles thrown out.
            for i in 0 ..< 16 {
                let sparkle = makeSparkle(color: color, size: CGFloat.random(in: 3.0 ... 6.0))
                sparkle.center = targetCenter
                window.addSubview(sparkle)
                let angle = CGFloat(i) / 16.0 * .pi * 2.0 + CGFloat.random(in: -0.2 ... 0.2)
                let distance = CGFloat.random(in: 30.0 ... max(40.0, targetFrame.width * 0.45))
                UIView.animate(withDuration: 0.5, delay: 0.0, options: [.curveEaseOut], animations: {
                    sparkle.center = CGPoint(x: targetCenter.x + cos(angle) * distance, y: targetCenter.y + sin(angle) * distance * 0.4)
                    sparkle.alpha = 0.0
                    sparkle.transform = CGAffineTransform(scaleX: 0.4, y: 0.4)
                }, completion: { _ in
                    sparkle.removeFromSuperview()
                })
            }

            // The note field capsule unfolds out of the point.
            targetView.alpha = 1.0
            targetView.transform = CGAffineTransform(scaleX: 0.05, y: 0.3)
            UIView.animate(withDuration: 0.5, delay: 0.0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0.0, options: [], animations: {
                targetView.transform = .identity
            }, completion: { _ in
                completion()
            })
        }
        orb.layer.add(move, forKey: "move")
        CATransaction.commit()
    }

    private static func makeSparkle(color: UIColor, size: CGFloat) -> UIView {
        let sparkle = UIView(frame: CGRect(x: 0.0, y: 0.0, width: size, height: size))
        sparkle.backgroundColor = Bool.random() ? .white : color
        sparkle.layer.cornerRadius = size / 2.0
        sparkle.layer.shadowColor = color.cgColor
        sparkle.layer.shadowRadius = 4.0
        sparkle.layer.shadowOpacity = 0.9
        sparkle.layer.shadowOffset = .zero
        sparkle.isUserInteractionEnabled = false
        return sparkle
    }
}

// A recorded voice message drawn like the note field's voice capsule, e.g. to fly from the input field into the note.
public func makeReplyReminderVoiceCapsule(theme: PresentationTheme, levels: [CGFloat], frame: CGRect) -> UIView {
    let view = ReplyReminderRecordingView(theme: theme)
    view.frame = frame
    view.showVoice(levels: levels)
    return view
}

// The reminder note: one line with the rest cut off while it is not being edited; tapped, it grows downwards to show
// the whole text over several lines, and shrinks back to one line when editing ends (Done or a tap elsewhere).
final class ReplyReminderNoteField: UIView, UITextViewDelegate {
    static let collapsedHeight: CGFloat = 44.0
    private static let maxExpandedLines: CGFloat = 6.0
    private static let maxLength = 500

    // The sheet around the field is a scroll view that closes when scrolled away. A text view that does not scroll
    // keeps the caret visible by scrolling its ancestors, which pushed the whole sheet off the screen while typing.
    // So the text view always scrolls itself, and this container takes any request to scroll further up.
    private final class ScrollStopper: UIScrollView {
        override func scrollRectToVisible(_ rect: CGRect, animated: Bool) {
        }

        override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
        }
    }

    private let scrollStopper = ScrollStopper()
    private let textView = UITextView()
    private let placeholderLabel = UILabel()
    // Right of the first line, e.g. the microphone.
    var accessoryView: UIView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let accessoryView {
                self.addSubview(accessoryView)
                self.setNeedsLayout()
            }
        }
    }

    var editingChanged: (() -> Void)?
    // The height the field wants changed (it grows and shrinks with editing and with the text).
    var heightChanged: (() -> Void)?

    private let leftInset: CGFloat = 14.0
    private let rightInset: CGFloat = 44.0

    override init(frame: CGRect) {
        super.init(frame: frame)

        self.layer.cornerRadius = 12.0
        self.layer.cornerCurve = .continuous
        self.clipsToBounds = true

        self.textView.backgroundColor = .clear
        self.textView.font = Font.regular(17.0)
        self.textView.returnKeyType = .done
        self.textView.isScrollEnabled = true
        self.textView.alwaysBounceVertical = false
        self.textView.showsVerticalScrollIndicator = false
        self.textView.textContainer.lineFragmentPadding = 0.0
        self.textView.textContainer.maximumNumberOfLines = 1
        self.textView.textContainer.lineBreakMode = .byTruncatingTail
        self.textView.delegate = self
        self.scrollStopper.isScrollEnabled = false
        self.scrollStopper.scrollsToTop = false
        self.scrollStopper.contentInsetAdjustmentBehavior = .never
        self.addSubview(self.scrollStopper)
        self.scrollStopper.addSubview(self.textView)

        self.placeholderLabel.isUserInteractionEnabled = false
        self.addSubview(self.placeholderLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var text: String? {
        get {
            return self.textView.text
        }
        set {
            self.textView.text = newValue
            self.updatePlaceholderVisibility()
            self.textView.setContentOffset(.zero, animated: false)
            self.heightChanged?()
        }
    }

    var font: UIFont? {
        get {
            return self.textView.font
        }
        set {
            self.textView.font = newValue
        }
    }

    var textColor: UIColor? {
        get {
            return self.textView.textColor
        }
        set {
            self.textView.textColor = newValue
        }
    }

    override var tintColor: UIColor! {
        didSet {
            self.textView.tintColor = self.tintColor
        }
    }

    var attributedPlaceholder: NSAttributedString? {
        didSet {
            self.placeholderLabel.attributedText = self.attributedPlaceholder
            self.updatePlaceholderVisibility()
        }
    }

    override var isFirstResponder: Bool {
        return self.textView.isFirstResponder
    }

    @discardableResult
    override func resignFirstResponder() -> Bool {
        return self.textView.resignFirstResponder()
    }

    private var isExpanded: Bool {
        return self.textView.isFirstResponder
    }

    private var lineHeight: CGFloat {
        return (self.textView.font ?? Font.regular(17.0)).lineHeight
    }

    private var verticalInset: CGFloat {
        return floor((ReplyReminderNoteField.collapsedHeight - self.lineHeight) / 2.0)
    }

    // Where the first line of text is drawn, in the field's coordinates (like UITextField's text rect).
    func textRect(forBounds bounds: CGRect) -> CGRect {
        return CGRect(x: self.leftInset, y: self.verticalInset, width: max(0.0, bounds.width - self.leftInset - self.rightInset), height: self.lineHeight)
    }

    func preferredHeight(width: CGFloat) -> CGFloat {
        guard self.isExpanded else {
            return ReplyReminderNoteField.collapsedHeight
        }
        let textWidth = max(1.0, width - self.leftInset - self.rightInset)
        let text = (self.textView.text ?? "").isEmpty ? " " : (self.textView.text ?? "")
        let textHeight = (text as NSString).boundingRect(with: CGSize(width: textWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: self.textView.font ?? Font.regular(17.0)], context: nil).height
        let maxTextHeight = self.lineHeight * ReplyReminderNoteField.maxExpandedLines
        return max(ReplyReminderNoteField.collapsedHeight, ceil(min(textHeight, maxTextHeight)) + self.verticalInset * 2.0)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = self.bounds
        self.scrollStopper.frame = bounds
        self.scrollStopper.contentSize = bounds.size
        self.textView.frame = bounds
        self.textView.textContainerInset = UIEdgeInsets(top: self.verticalInset, left: self.leftInset, bottom: self.verticalInset, right: self.rightInset)
        let maxTextHeight = self.lineHeight * ReplyReminderNoteField.maxExpandedLines
        self.textView.showsVerticalScrollIndicator = self.isExpanded && self.textView.layoutManager.usedRect(for: self.textView.textContainer).height > maxTextHeight + 1.0
        if self.textView.contentSize.height <= bounds.height + 1.0 && self.textView.contentOffset.y != 0.0 {
            // Everything fits: no scrolling left over from while the field was growing.
            self.textView.contentOffset = .zero
        }
        self.placeholderLabel.frame = self.textRect(forBounds: bounds)
        if let accessoryView = self.accessoryView {
            accessoryView.frame = CGRect(x: bounds.width - 44.0, y: 0.0, width: 44.0, height: ReplyReminderNoteField.collapsedHeight)
        }
    }

    private func updatePlaceholderVisibility() {
        self.placeholderLabel.isHidden = !(self.textView.text ?? "").isEmpty
    }

    private func setExpanded(_ expanded: Bool) {
        self.textView.textContainer.maximumNumberOfLines = expanded ? 0 : 1
        self.textView.textContainer.lineBreakMode = expanded ? .byWordWrapping : .byTruncatingTail
        self.textView.layoutManager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: (self.textView.text as NSString).length), actualCharacterRange: nil)
        if !expanded {
            self.textView.setContentOffset(.zero, animated: false)
        }
        self.setNeedsLayout()
        self.heightChanged?()
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        self.setExpanded(true)
        self.editingChanged?()
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        self.setExpanded(false)
        self.editingChanged?()
    }

    func textViewDidChange(_ textView: UITextView) {
        self.updatePlaceholderVisibility()
        self.setNeedsLayout()
        self.heightChanged?()
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        // Return is Done: the note is a single paragraph.
        if text == "\n" {
            textView.resignFirstResponder()
            return false
        }
        let current = (textView.text ?? "") as NSString
        return current.replacingCharacters(in: range, with: text).count <= ReplyReminderNoteField.maxLength
    }
}
