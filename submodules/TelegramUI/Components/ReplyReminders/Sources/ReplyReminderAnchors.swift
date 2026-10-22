import Foundation
import UIKit
import SwiftSignalKit
import TelegramCore

// Something on screen that shows a chat's reminder: the gray line inside the chat or the label in the chat list row.
// The reminder sheet grows out of it and collapses into it, and the bell lands on it when the reminder fires.
public struct ReplyReminderAnchor {
    // In window coordinates.
    public let frame: CGRect
    public let cornerRadius: CGFloat
    public let color: UIColor
    // The view the anchor belongs to; used to check that nothing covers it.
    public let sourceView: UIView
    // Hidden while an animation covers it, so the element does not show twice.
    public let hiddenView: UIView?
    // Small "something arrived" bounce.
    public let land: (() -> Void)?

    public init(frame: CGRect, cornerRadius: CGFloat, color: UIColor, sourceView: UIView, hiddenView: UIView?, land: (() -> Void)?) {
        self.frame = frame
        self.cornerRadius = cornerRadius
        self.color = color
        self.sourceView = sourceView
        self.hiddenView = hiddenView
        self.land = land
    }

    // True if the anchor is on screen and not covered by another screen or sheet.
    public var isVisible: Bool {
        guard let window = self.sourceView.window, window.bounds.intersects(self.frame) else {
            return false
        }
        let center = CGPoint(x: self.frame.midX, y: self.frame.midY)
        guard let hit = window.hitTest(center, with: nil) else {
            return false
        }
        return hit === self.sourceView || hit.isDescendant(of: self.sourceView)
    }
}

public enum ReplyReminderAnchorKind {
    case chatLine
    case chatListRow
    // The unread dot of a chat list row: only where the paper plane of a reminder that fired lands.
    case chatListBadge
}

public final class ReplyReminderAnchors {
    public static let shared = ReplyReminderAnchors()

    private final class Entry {
        let id: Int
        let peerId: EnginePeer.Id
        let kind: ReplyReminderAnchorKind
        let provider: (String?) -> ReplyReminderAnchor?
        let onFire: (() -> Void)?

        init(id: Int, peerId: EnginePeer.Id, kind: ReplyReminderAnchorKind, provider: @escaping (String?) -> ReplyReminderAnchor?, onFire: (() -> Void)?) {
            self.id = id
            self.peerId = peerId
            self.kind = kind
            self.provider = provider
            self.onFire = onFire
        }
    }

    private var nextId = 0
    private var entries: [Entry] = []

    private init() {
    }

    // The provider gets the id of the reminder to show (nil: any of the chat's reminders).
    public func register(peerId: EnginePeer.Id, kind: ReplyReminderAnchorKind, onFire: (() -> Void)? = nil, provider: @escaping (String?) -> ReplyReminderAnchor?) -> Disposable {
        assert(Thread.isMainThread)
        let id = self.nextId
        self.nextId += 1
        self.entries.append(Entry(id: id, peerId: peerId, kind: kind, provider: provider, onFire: onFire))
        return ActionDisposable { [weak self] in
            Queue.mainQueue().async {
                self?.entries.removeAll(where: { $0.id == id })
            }
        }
    }

    private func anchors(peerId: EnginePeer.Id, reminderId: String?) -> [ReplyReminderAnchor] {
        // The line inside an open chat wins over the chat list row underneath it.
        // Among lines, the newest registration is the screen on top (the reminders screen over its chat).
        let sorted = self.entries.filter { $0.peerId == peerId && $0.kind != .chatListBadge }.sorted(by: { lhs, rhs in
            if lhs.kind == .chatLine && rhs.kind == .chatLine {
                return lhs.id > rhs.id
            }
            return lhs.kind == .chatLine && rhs.kind != .chatLine
        })
        return sorted.compactMap { $0.provider(reminderId) }.filter { $0.sourceView.window != nil }
    }

    // Anchor the user can see right now.
    public func visibleAnchor(peerId: EnginePeer.Id, reminderId: String?) -> ReplyReminderAnchor? {
        return self.anchors(peerId: peerId, reminderId: reminderId).first(where: { $0.isVisible })
    }

    // Where the paper plane of a reminder that fired lands: the line in the open chat, else the chat list row's unread dot.
    public func landingAnchor(peerId: EnginePeer.Id, reminderId: String?) -> ReplyReminderAnchor? {
        let entries = self.entries.filter { $0.peerId == peerId }
        for kind in [ReplyReminderAnchorKind.chatLine, .chatListBadge, .chatListRow] {
            for entry in entries.reversed() where entry.kind == kind {
                if let anchor = entry.provider(reminderId), anchor.sourceView.window != nil, anchor.isVisible {
                    return anchor
                }
            }
        }
        return nil
    }

    // Anchor for an animation that runs while a sheet still covers the screen, so it is not checked for being covered.
    public func anchor(peerId: EnginePeer.Id, reminderId: String?) -> ReplyReminderAnchor? {
        return self.anchors(peerId: peerId, reminderId: reminderId).first
    }

    // The reminder fired while the app is open: an open chat shows its "Reminder at …" line right away.
    public func fire(peerId: EnginePeer.Id) {
        for entry in self.entries where entry.peerId == peerId {
            entry.onFire?()
        }
    }
}

// Shared bounce for an anchor that received the bell or the collapsed sheet.
public func replyReminderPlayLandAnimation(layer: CALayer) {
    let animation = CAKeyframeAnimation(keyPath: "transform.scale")
    animation.values = [1.0, 1.32, 0.9, 1.06, 1.0] as [NSNumber]
    animation.keyTimes = [0.0, 0.3, 0.6, 0.82, 1.0] as [NSNumber]
    animation.duration = 0.5
    animation.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .easeInEaseOut)]
    layer.add(animation, forKey: "replyReminderLand")
}

