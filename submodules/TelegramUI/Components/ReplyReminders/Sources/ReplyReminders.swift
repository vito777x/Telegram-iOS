import Foundation
import UIKit
import UserNotifications
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext

// A personal reminder in a chat; a chat can have several. The note says what it is for,
// and a reminder set from a message remembers that message.
public struct ReplyReminder: Codable, Equatable {
    public let id: String
    public let accountPeerId: Int64
    public let peerId: Int64
    public let peerTitle: String
    public let note: String?
    public let time: Int32
    // The message the reminder was set from, if any, and a short excerpt of it.
    public let messageId: Int32?
    public let messageNamespace: Int32?
    public let messageExcerpt: String?
    public var localMessageId: Int32?
    // Set once the reminder has fired and its line was moved to the bottom of the chat.
    public var firedLocalMessageId: Int32?
    // Repeating reminders move on to their next time once they fire; same periods as scheduled messages.
    public let repeatPeriod: Int32?
    // What the notification says and which account it opens; kept to schedule the next times of a repeating reminder.
    public let accountRecordId: Int64?
    public let notificationTitle: String?
    public let notificationBody: String?

    private enum CodingKeys: String, CodingKey {
        case id, accountPeerId, peerId, peerTitle, note, time, messageId, messageNamespace, messageExcerpt, localMessageId, firedLocalMessageId, repeatPeriod, accountRecordId, notificationTitle, notificationBody
    }

    public init(id: String, accountPeerId: Int64, peerId: Int64, peerTitle: String, note: String?, time: Int32, message: EngineMessage.Id?, messageExcerpt: String?, repeatPeriod: Int32? = nil, accountRecordId: Int64? = nil, notificationTitle: String? = nil, notificationBody: String? = nil) {
        self.id = id
        self.accountPeerId = accountPeerId
        self.peerId = peerId
        self.peerTitle = peerTitle
        self.note = note
        self.time = time
        self.messageId = message?.id
        self.messageNamespace = message?.namespace
        self.messageExcerpt = messageExcerpt
        self.localMessageId = nil
        self.firedLocalMessageId = nil
        self.repeatPeriod = repeatPeriod
        self.accountRecordId = accountRecordId
        self.notificationTitle = notificationTitle
        self.notificationBody = notificationBody
    }

    fileprivate func withTime(_ time: Int32) -> ReplyReminder {
        var result = ReplyReminder(id: self.id, accountPeerId: self.accountPeerId, peerId: self.peerId, peerTitle: self.peerTitle, note: self.note, time: time, message: self.linkedMessageId, messageExcerpt: self.messageExcerpt, repeatPeriod: self.repeatPeriod, accountRecordId: self.accountRecordId, notificationTitle: self.notificationTitle, notificationBody: self.notificationBody)
        result.localMessageId = nil
        result.firedLocalMessageId = nil
        return result
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.accountPeerId = try container.decode(Int64.self, forKey: .accountPeerId)
        self.peerId = try container.decode(Int64.self, forKey: .peerId)
        // Reminders saved when a chat could have only one had no id of their own; this keeps their notification identifier.
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? "\(self.accountPeerId)_\(self.peerId)"
        self.peerTitle = try container.decode(String.self, forKey: .peerTitle)
        self.note = try container.decodeIfPresent(String.self, forKey: .note)
        self.time = try container.decode(Int32.self, forKey: .time)
        self.messageId = try container.decodeIfPresent(Int32.self, forKey: .messageId)
        self.messageNamespace = try container.decodeIfPresent(Int32.self, forKey: .messageNamespace)
        self.messageExcerpt = try container.decodeIfPresent(String.self, forKey: .messageExcerpt)
        self.localMessageId = try container.decodeIfPresent(Int32.self, forKey: .localMessageId)
        self.firedLocalMessageId = try container.decodeIfPresent(Int32.self, forKey: .firedLocalMessageId)
        self.repeatPeriod = try container.decodeIfPresent(Int32.self, forKey: .repeatPeriod)
        self.accountRecordId = try container.decodeIfPresent(Int64.self, forKey: .accountRecordId)
        self.notificationTitle = try container.decodeIfPresent(String.self, forKey: .notificationTitle)
        self.notificationBody = try container.decodeIfPresent(String.self, forKey: .notificationBody)
    }

    public var notificationIdentifier: String {
        return "replyReminder_\(self.id)"
    }

    public var enginePeerId: EnginePeer.Id {
        return EnginePeer.Id(self.peerId)
    }

    public var linkedMessageId: EngineMessage.Id? {
        guard let messageId = self.messageId, let messageNamespace = self.messageNamespace else {
            return nil
        }
        return EngineMessage.Id(peerId: self.enginePeerId, namespace: messageNamespace, id: messageId)
    }

    // What the reminder is about: the note, or else the message it was set from.
    public var subject: String? {
        return self.note ?? self.messageExcerpt
    }

    public var isDue: Bool {
        return self.time <= Int32(Date().timeIntervalSince1970)
    }

    // Still has something to remind about: not fired yet, or repeating (it moves on to its next time).
    public var isPending: Bool {
        return !self.isDue || self.repeatPeriod != nil
    }
}

// Local state of reminders; drives the chat list badge and the chat context menu.
// Reminders are deliberately device-local: you get the reminder where you set it.
public final class ReplyReminderStore {
    public static let shared = ReplyReminderStore()

    private let storageKey = "TG_ReplyReminders_v2"
    private var items: [ReplyReminder]
    private let itemsPromise: ValuePromise<[ReplyReminder]>

    private init() {
        var items: [ReplyReminder] = []
        if let data = UserDefaults.standard.data(forKey: self.storageKey), let decoded = try? JSONDecoder().decode([ReplyReminder].self, from: data) {
            items = decoded
        }
        self.items = items
        self.itemsPromise = ValuePromise(items, ignoreRepeated: true)
    }

    public func reminders(accountPeerId: EnginePeer.Id) -> Signal<[ReplyReminder], NoError> {
        let accountPeerIdValue = accountPeerId.toInt64()
        return self.itemsPromise.get()
        |> map { items -> [ReplyReminder] in
            return items.filter { $0.accountPeerId == accountPeerIdValue }
        }
    }

    // All reminders of a chat, soonest first.
    public func reminders(peerId: EnginePeer.Id, accountPeerId: EnginePeer.Id) -> [ReplyReminder] {
        return self.items.filter { $0.accountPeerId == accountPeerId.toInt64() && $0.peerId == peerId.toInt64() }.sorted(by: { $0.time < $1.time })
    }

    // The soonest reminder of a chat: the one its chat list row shows.
    public func nearestReminder(peerId: EnginePeer.Id, accountPeerId: EnginePeer.Id) -> ReplyReminder? {
        return self.reminders(peerId: peerId, accountPeerId: accountPeerId).first
    }

    // Whether the chat still has reminders to come; ones that fired are shown in the chat list, not on the reminders button.
    public func hasPendingReminders(peerId: EnginePeer.Id, accountPeerId: EnginePeer.Id) -> Bool {
        return self.reminders(peerId: peerId, accountPeerId: accountPeerId).contains(where: { $0.isPending })
    }

    public func reminder(id: String) -> ReplyReminder? {
        return self.items.first(where: { $0.id == id })
    }

    fileprivate func set(_ reminder: ReplyReminder) {
        var items = self.items.filter { $0.id != reminder.id }
        items.append(reminder)
        self.update(items)
    }

    fileprivate func updateLocalMessageId(id: String, localMessageId: Int32) {
        self.modify(id: id) { $0.localMessageId = localMessageId }
    }

    fileprivate func modify(id: String, _ f: (inout ReplyReminder) -> Void) {
        self.update(self.items.map { item in
            var item = item
            if item.id == id {
                f(&item)
            }
            return item
        })
    }

    fileprivate func remove(id: String) {
        self.update(self.items.filter { $0.id != id })
    }

    // Called when the user opens a chat: reminders that already fired there are done; repeating ones move on
    // to their next time.
    public func clearDue(peerId: EnginePeer.Id, accountPeerId: EnginePeer.Id) {
        var changed = false
        var items: [ReplyReminder] = []
        let now = Int32(Date().timeIntervalSince1970)
        for item in self.items {
            guard item.accountPeerId == accountPeerId.toInt64() && item.peerId == peerId.toInt64() && item.isDue else {
                items.append(item)
                continue
            }
            changed = true
            if let repeatPeriod = item.repeatPeriod {
                let next = item.withTime(replyReminderNextTime(after: item.time, period: repeatPeriod, now: now))
                items.append(next)
                scheduleReplyReminderNotifications(next)
            }
        }
        if changed {
            self.update(items)
        }
    }

    private func update(_ items: [ReplyReminder]) {
        self.items = items
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: self.storageKey)
        }
        self.itemsPromise.set(items)
    }
}

public struct ReplyReminderStrings {
    public let isRussian: Bool

    public init(languageCode: String) {
        self.isRussian = languageCode.lowercased().hasPrefix("ru") || languageCode.lowercased().hasPrefix("uk")
    }

    public var menuTitle: String { return self.isRussian ? "Напомнить" : "Remind Me" }
    public var pickerTitle: String { return self.isRussian ? "Напоминание" : "Set Reminder" }
    public var menuChangeTitle: String { return self.isRussian ? "Изменить напоминание" : "Change Reminder" }
    public var delete: String { return self.isRussian ? "Удалить" : "Delete" }
    public var deleteReminder: String { return self.isRussian ? "Удалить напоминание" : "Delete Reminder" }
    public var update: String { return self.isRussian ? "Изменить" : "Change" }
    public var undo: String { return self.isRussian ? "Отменить" : "Undo" }
    public var cancelled: String { return self.isRussian ? "Напоминание отменено" : "Reminder cancelled" }
    public var notePlaceholder: String { return self.isRussian ? "Заметка, например «созвон в 15:00»" : "Note, e.g. “call at 3 PM”" }
    public var showMessage: String { return self.isRussian ? "Показать сообщение" : "Show Message" }
    public var mediaMessageExcerpt: String { return self.isRussian ? "Сообщение" : "Message" }

    public func remindersMenuTitle(count: Int) -> String {
        return self.isRussian ? "Напоминания (\(count))" : "Reminders (\(count))"
    }

    public var remindForMe: String { return self.isRussian ? "Напомнить мне" : "Remind Me" }
    public var remindersTitle: String { return self.isRussian ? "Напоминания" : "Reminders" }
    public var remindersPlaceholder: String { return self.isRussian ? "Заметка для напоминания" : "Reminder note" }
    public var remindersEmptyTitle: String { return self.isRussian ? "Нет напоминаний" : "No Reminders" }
    public var remindersEmptyText: String { return self.isRussian ? "Здесь пока нет напоминаний..." : "No reminders here yet..." }
    public var remindersDefaultText: String { return self.isRussian ? "Напоминание" : "Reminder" }

    public func repeatTitle(_ period: Int32) -> String {
        switch period {
        case 86400:
            return self.isRussian ? "каждый день" : "daily"
        case 7 * 86400:
            return self.isRussian ? "каждую неделю" : "weekly"
        case 14 * 86400:
            return self.isRussian ? "раз в 2 недели" : "every 2 weeks"
        case 30 * 86400:
            return self.isRussian ? "каждый месяц" : "monthly"
        case 91 * 86400:
            return self.isRussian ? "раз в 3 месяца" : "every 3 months"
        case 182 * 86400:
            return self.isRussian ? "раз в 6 месяцев" : "every 6 months"
        case 365 * 86400:
            return self.isRussian ? "каждый год" : "yearly"
        default:
            return self.isRussian ? "повтор" : "repeats"
        }
    }

    // "2 напоминания" / "2 reminders" under the chat list menu item.
    public func remindersCount(_ count: Int) -> String {
        if self.isRussian {
            let mod10 = count % 10
            let mod100 = count % 100
            let word: String
            if mod10 == 1 && mod100 != 11 {
                word = "напоминание"
            } else if (2 ... 4).contains(mod10) && !(12 ... 14).contains(mod100) {
                word = "напоминания"
            } else {
                word = "напоминаний"
            }
            return "\(count) \(word)"
        }
        return count == 1 ? "1 reminder" : "\(count) reminders"
    }

    public func toastTitle(_ when: String) -> String {
        return self.isRussian ? "Напомню \(when)" : "I'll remind you \(when)"
    }

    public func toastText(_ name: String, note: String?) -> String {
        if let note {
            return "\(name) · \(note)"
        }
        return name
    }

    public func notificationTitle(_ name: String) -> String {
        return self.isRussian ? "Напоминание: \(name)" : "Reminder: \(name)"
    }

    // Gray service line in the chat history, visible only on this device.
    // `subject` is the note, or else an excerpt of the message the reminder was set from.
    public func historyText(when: String, subject: String?) -> String {
        let base = self.isRussian ? "Напоминание на \(when)" : "Reminder set for \(when)"
        if let subject {
            return "\(base)\n«\(subject)»"
        }
        return base
    }

    // Gray line added at the bottom of the chat when the reminder fires; the first `boldLength` characters are bold.
    public func firedText(note: String?, time: Int32) -> (text: String, boldLength: Int) {
        // Service lines have no timestamp of their own, so the time goes into the text.
        let title = self.isRussian ? "Напоминание в \(self.timeString(time))" : "Reminder at \(self.timeString(time))"
        if let note {
            let text = "\(title): \(note)"
            return (text, (title as NSString).length + 1)
        }
        return (title, (title as NSString).length)
    }

    // A notification reads like a message from the chat: "📝 Напоминание: note".
    public func notificationText(subject: String?) -> String {
        let title = "📝 " + (self.isRussian ? "Напоминание" : "Reminder")
        if let subject, !subject.isEmpty {
            return "\(title): \(subject)"
        }
        return title
    }

    public var notificationBody: String {
        return self.isRussian ? "Вы просили напомнить об этом чате" : "You asked to be reminded about this chat"
    }

    // "сегодня в 19:00" / "завтра в 9:00" / "12 окт. в 9:00"
    public func relativeWhen(_ timestamp: Int32) -> String {
        let date = Date(timeIntervalSince1970: Double(timestamp))
        let calendar = Calendar.current
        let time = self.timeString(timestamp)
        if calendar.isDateInToday(date) {
            return self.isRussian ? "сегодня в \(time)" : "today at \(time)"
        } else if calendar.isDateInTomorrow(date) {
            return self.isRussian ? "завтра в \(time)" : "tomorrow at \(time)"
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: self.isRussian ? "ru_RU" : "en_US")
            formatter.setLocalizedDateFormatFromTemplate("d MMM")
            return self.isRussian ? "\(formatter.string(from: date)) в \(time)" : "\(formatter.string(from: date)) at \(time)"
        }
    }

    // Short label shown instead of the date in the chat list row: the soonest reminder, plus "+N" for the others.
    public func chatListLabel(_ reminder: ReplyReminder, totalCount: Int = 1) -> String {
        let more = totalCount > 1 ? " +\(totalCount - 1)" : ""
        if reminder.isDue {
            return (self.isRussian ? "Сейчас" : "Now") + more
        }
        let date = Date(timeIntervalSince1970: Double(reminder.time))
        let time = self.timeString(reminder.time)
        if Calendar.current.isDateInToday(date) {
            return time + more
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: self.isRussian ? "ru_RU" : "en_US")
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return "\(formatter.string(from: date)) \(time)" + more
    }

    // Start of the chat list preview of a reminder that fired: "Напоминаю · 18:20", followed by the note.
    public func chatListFiredTitle(time: Int32) -> String {
        let date = Date(timeIntervalSince1970: Double(time))
        var when = self.timeString(time)
        if !Calendar.current.isDateInToday(date) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: self.isRussian ? "ru_RU" : "en_US")
            formatter.setLocalizedDateFormatFromTemplate("d MMM")
            when = "\(formatter.string(from: date)) \(when)"
        }
        return (self.isRussian ? "Напоминаю · " : "Reminder · ") + when
    }

    public func timeString(_ timestamp: Int32) -> String {
        let formatter = DateFormatter()
        // Follow the device's 12/24-hour setting, like the rest of Telegram.
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("j:mm")
        return formatter.string(from: Date(timeIntervalSince1970: Double(timestamp)))
    }
}

// Short one-line excerpt of a message for the reminder line and notification.
public func replyReminderMessageExcerpt(_ message: EngineMessage, strings: ReplyReminderStrings) -> String {
    var text = message.text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty {
        return strings.mediaMessageExcerpt
    }
    let limit = 60
    if (text as NSString).length > limit {
        text = (text as NSString).substring(to: limit).trimmingCharacters(in: .whitespaces) + "…"
    }
    return text
}

// Links a local reminder line to the message the reminder was set from, so tapping the line jumps there.
private func replyReminderLineAttributes(_ reminder: ReplyReminder) -> [MessageAttribute] {
    guard let linkedMessageId = reminder.linkedMessageId else {
        return []
    }
    return [ReplyMessageAttribute(messageId: linkedMessageId, threadMessageId: nil, quote: nil, isQuote: false, innerSubject: nil)]
}

// Adds a new reminder to the chat (a chat can have several). Pass `replacing` to change an existing one.
@discardableResult
public func setReplyReminder(context: AccountContext, peerId: EnginePeer.Id, peer: EnginePeer, time: Int32, note: String?, repeatPeriod: Int32? = nil, message: EngineMessage.Id? = nil, messageExcerpt: String? = nil, replacing existing: ReplyReminder? = nil, strings: ReplyReminderStrings) -> ReplyReminder {
    let accountPeerId = context.account.peerId
    if let existing {
        cancelReplyReminder(context: context, reminder: existing)
    }

    let peerTitle = peer.compactDisplayTitle
    let reminder = ReplyReminder(
        id: UUID().uuidString,
        accountPeerId: accountPeerId.toInt64(),
        peerId: peerId.toInt64(),
        peerTitle: peerTitle,
        note: note,
        time: time,
        message: message ?? existing?.linkedMessageId,
        messageExcerpt: messageExcerpt ?? existing?.messageExcerpt,
        repeatPeriod: repeatPeriod,
        accountRecordId: context.account.id.int64,
        notificationTitle: peerTitle,
        notificationBody: strings.notificationText(subject: note ?? messageExcerpt ?? existing?.messageExcerpt)
    )
    ReplyReminderStore.shared.set(reminder)

    // No line in the chat: pending reminders live on the reminders screen (the scheduled button in the input field).

    scheduleReplyReminderNotifications(reminder)

    return reminder
}

// Chats used to get a "Reminder set for …" line for every reminder; those lines are removed when the chat opens.
public func removeReplyReminderSetLines(context: AccountContext, peerId: EnginePeer.Id) {
    let reminders = ReplyReminderStore.shared.reminders(peerId: peerId, accountPeerId: context.account.peerId).filter { $0.localMessageId != nil }
    if reminders.isEmpty {
        return
    }
    var messageIds: [EngineMessage.Id] = []
    for reminder in reminders {
        if let localMessageId = reminder.localMessageId {
            messageIds.append(EngineMessage.Id(peerId: peerId, namespace: Namespaces.Message.Local, id: localMessageId))
        }
        ReplyReminderStore.shared.modify(id: reminder.id) { $0.localMessageId = nil }
    }
    let _ = context.engine.messages.deleteMessagesInteractively(messageIds: messageIds, type: .forLocalPeer).startStandalone()
}

// When reminders are due, replace each one's "reminder set" line with a "Reminder at …: note" line placed at the
// moment it fired, so the note sits right where you land in the chat instead of far up the history.
// Called when the chat opens (the app may not have been running when the notification fired).
public func materializeDueReplyReminder(context: AccountContext, peerId: EnginePeer.Id, strings: ReplyReminderStrings) {
    let dueReminders = ReplyReminderStore.shared.reminders(peerId: peerId, accountPeerId: context.account.peerId).filter { $0.isDue && $0.firedLocalMessageId == nil }
    let account = context.account
    for reminder in dueReminders {
        let reminderId = reminder.id
        ReplyReminderStore.shared.modify(id: reminderId) { $0.firedLocalMessageId = 0 }

        let (text, boldLength) = strings.firedText(note: reminder.subject, time: reminder.time)
        let attributes = replyReminderLineAttributes(reminder)
        let previousLocalMessageId = reminder.localMessageId
        let _ = (account.postbox.transaction { transaction -> MessageId? in
            if let previousLocalMessageId {
                transaction.deleteMessages([MessageId(peerId: peerId, namespace: Namespaces.Message.Local, id: previousLocalMessageId)], forEachMedia: nil)
            }
            var randomId: Int64 = 0
            arc4random_buf(&randomId, 8)
            let entities = [MessageTextEntity(range: 0 ..< boldLength, type: .Bold)]
            let message = StoreMessage(peerId: peerId, namespace: Namespaces.Message.Local, customStableId: nil, globallyUniqueId: randomId, groupingKey: nil, threadId: nil, timestamp: reminder.time, flags: [], tags: [], globalTags: [], localTags: [], forwardInfo: nil, authorId: account.peerId, text: "", attributes: attributes, media: [TelegramMediaAction(action: .customText(text: text, entities: entities, additionalAttributes: nil))])
            return transaction.addMessages([message], location: .Random)[randomId]
        }
        |> deliverOnMainQueue).startStandalone(next: { messageId in
            if let messageId {
                // A repeating reminder may have moved on to its next time meanwhile; that time has no line yet.
                ReplyReminderStore.shared.modify(id: reminderId) {
                    if $0.time == reminder.time {
                        $0.firedLocalMessageId = messageId.id
                    }
                }
            }
        })
    }
}

public func cancelReplyReminder(context: AccountContext, reminder: ReplyReminder) {
    // Read the latest record: the local message id is filled in asynchronously after creation.
    let current = ReplyReminderStore.shared.reminder(id: reminder.id) ?? reminder
    ReplyReminderStore.shared.remove(id: reminder.id)
    removeReplyReminderNotifications(reminder)
    if let localMessageId = current.localMessageId {
        let _ = context.engine.messages.deleteMessagesInteractively(messageIds: [EngineMessage.Id(peerId: current.enginePeerId, namespace: Namespaces.Message.Local, id: localMessageId)], type: .forLocalPeer).startStandalone()
    }
}

// Reminder glyph: a clipboard with a pencil. Not a bell (that is notifications) and not a clock (that is scheduled messages).
public func replyReminderSymbol(pointSize: CGFloat, weight: UIImage.SymbolWeight = .regular) -> UIImage? {
    let configuration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
    for name in ["pencil.and.list.clipboard", "list.clipboard", "note.text"] {
        if let image = UIImage(systemName: name, withConfiguration: configuration) {
            return image
        }
    }
    return nil
}

private func replyReminderIcon(color: UIColor, canvasSize: CGSize, pointSize: CGFloat, weight: UIImage.SymbolWeight) -> UIImage? {
    guard let symbol = replyReminderSymbol(pointSize: pointSize, weight: weight) else {
        return nil
    }
    let format = UIGraphicsImageRendererFormat()
    format.scale = UIScreen.main.scale
    return UIGraphicsImageRenderer(size: canvasSize, format: format).image { _ in
        let tinted = symbol.withTintColor(color, renderingMode: .alwaysOriginal)
        tinted.draw(in: CGRect(x: floor((canvasSize.width - symbol.size.width) / 2.0), y: floor((canvasSize.height - symbol.size.height) / 2.0), width: symbol.size.width, height: symbol.size.height))
    }
}

// For "Remind Me" menu items, sized like the other line icons of context menus.
public func replyReminderMenuIcon(color: UIColor) -> UIImage? {
    return replyReminderIcon(color: color, canvasSize: CGSize(width: 24.0, height: 24.0), pointSize: 17.0, weight: .regular)
}

// Small icon before the reminder time in a chat list row.
public func replyReminderListIcon(color: UIColor) -> UIImage? {
    return replyReminderIcon(color: color, canvasSize: CGSize(width: 14.0, height: 14.0), pointSize: 11.0, weight: .medium)
}

// How far ahead the times of a repeating reminder are scheduled; topped up every time it moves on.
private let replyReminderScheduledOccurrences = 8

// The next time of a repeating reminder after `time` that is later than `now`; months and years follow the calendar.
func replyReminderNextTime(after time: Int32, period: Int32, now: Int32) -> Int32 {
    let calendar = Calendar.current
    let component: Calendar.Component
    let value: Int
    switch period {
    case 30 * 86400:
        component = .month
        value = 1
    case 91 * 86400:
        component = .month
        value = 3
    case 182 * 86400:
        component = .month
        value = 6
    case 365 * 86400:
        component = .year
        value = 1
    default:
        component = .day
        value = max(1, Int(period / 86400))
    }
    var date = Date(timeIntervalSince1970: Double(time))
    repeat {
        guard let next = calendar.date(byAdding: component, value: value, to: date) else {
            return time + max(period, 60)
        }
        date = next
    } while Int32(date.timeIntervalSince1970) <= now
    return Int32(date.timeIntervalSince1970)
}

private func replyReminderNotificationIdentifiers(_ reminder: ReplyReminder) -> [String] {
    var identifiers = [reminder.notificationIdentifier]
    for i in 1 ..< replyReminderScheduledOccurrences {
        identifiers.append("\(reminder.notificationIdentifier)_\(i)")
    }
    return identifiers
}

// Local notifications: they fire even if the app is killed; tapping one opens the chat through the regular
// notification handling in AppDelegate (peerId key). A repeating reminder gets its next several times scheduled.
fileprivate func scheduleReplyReminderNotifications(_ reminder: ReplyReminder) {
    let center = UNUserNotificationCenter.current()
    center.removePendingNotificationRequests(withIdentifiers: replyReminderNotificationIdentifiers(reminder))

    let content = UNMutableNotificationContent()
    content.title = reminder.notificationTitle ?? reminder.peerTitle
    content.body = reminder.notificationBody ?? reminder.subject ?? ""
    content.sound = .default
    content.threadIdentifier = "replyReminders"
    var userInfo: [AnyHashable: Any] = [
        "peerId": reminder.peerId,
        "replyReminder": true,
        "replyReminderId": reminder.id
    ]
    if let accountRecordId = reminder.accountRecordId {
        userInfo["accountId"] = accountRecordId
    }
    content.userInfo = userInfo

    let now = Int32(Date().timeIntervalSince1970)
    var time = reminder.time
    let count = reminder.repeatPeriod == nil ? 1 : replyReminderScheduledOccurrences
    for i in 0 ..< count {
        let interval = max(1.0, Double(time) - Date().timeIntervalSince1970)
        let identifier = i == 0 ? reminder.notificationIdentifier : "\(reminder.notificationIdentifier)_\(i)"
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)), withCompletionHandler: nil)
        guard let repeatPeriod = reminder.repeatPeriod else {
            break
        }
        time = replyReminderNextTime(after: time, period: repeatPeriod, now: max(now, time))
    }
}

fileprivate func removeReplyReminderNotifications(_ reminder: ReplyReminder) {
    UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: replyReminderNotificationIdentifiers(reminder))
}
