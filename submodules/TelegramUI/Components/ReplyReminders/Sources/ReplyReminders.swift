import Foundation
import UserNotifications
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext

// A personal reminder attached to a whole chat; the note says what it is for.
public struct ReplyReminder: Codable, Equatable {
    public let accountPeerId: Int64
    public let peerId: Int64
    public let peerTitle: String
    public let note: String?
    public let time: Int32
    public var localMessageId: Int32?
    // Set once the reminder has fired and its line was moved to the bottom of the chat.
    public var firedLocalMessageId: Int32?

    public var id: String {
        return "\(self.accountPeerId)_\(self.peerId)"
    }

    public var notificationIdentifier: String {
        return "replyReminder_\(self.id)"
    }

    public var enginePeerId: EnginePeer.Id {
        return EnginePeer.Id(self.peerId)
    }

    public var isDue: Bool {
        return self.time <= Int32(Date().timeIntervalSince1970)
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

    public func reminder(peerId: EnginePeer.Id, accountPeerId: EnginePeer.Id) -> ReplyReminder? {
        return self.items.first(where: { $0.accountPeerId == accountPeerId.toInt64() && $0.peerId == peerId.toInt64() })
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

    // Called when the user opens a chat: a reminder that already fired there is done.
    public func clearDue(peerId: EnginePeer.Id, accountPeerId: EnginePeer.Id) {
        let items = self.items.filter { !($0.accountPeerId == accountPeerId.toInt64() && $0.peerId == peerId.toInt64() && $0.isDue) }
        if items.count != self.items.count {
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
    public func historyText(when: String, note: String?) -> String {
        let base = self.isRussian ? "Напоминание на \(when)" : "Reminder set for \(when)"
        if let note {
            return "\(base)\n«\(note)»"
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

    // Short label shown instead of the date in the chat list row.
    public func chatListLabel(_ reminder: ReplyReminder) -> String {
        if reminder.isDue {
            return self.isRussian ? "Сейчас" : "Now"
        }
        let date = Date(timeIntervalSince1970: Double(reminder.time))
        let time = self.timeString(reminder.time)
        if Calendar.current.isDateInToday(date) {
            return time
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: self.isRussian ? "ru_RU" : "en_US")
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return "\(formatter.string(from: date)) \(time)"
    }

    public func timeString(_ timestamp: Int32) -> String {
        let formatter = DateFormatter()
        // Follow the device's 12/24-hour setting, like the rest of Telegram.
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("j:mm")
        return formatter.string(from: Date(timeIntervalSince1970: Double(timestamp)))
    }
}

@discardableResult
public func setReplyReminder(context: AccountContext, peerId: EnginePeer.Id, peer: EnginePeer, time: Int32, note: String?, strings: ReplyReminderStrings) -> ReplyReminder {
    let accountPeerId = context.account.peerId
    if let existing = ReplyReminderStore.shared.reminder(peerId: peerId, accountPeerId: accountPeerId) {
        cancelReplyReminder(context: context, reminder: existing)
    }

    let peerTitle = peer.compactDisplayTitle
    let reminder = ReplyReminder(
        accountPeerId: accountPeerId.toInt64(),
        peerId: peerId.toInt64(),
        peerTitle: peerTitle,
        note: note,
        time: time,
        localMessageId: nil
    )
    ReplyReminderStore.shared.set(reminder)

    // Local-only service message in the chat itself: never sent to the server, so the other side never sees it.
    let historyText = strings.historyText(when: strings.relativeWhen(time), note: note)
    let reminderId = reminder.id
    let account = context.account
    let _ = (account.postbox.transaction { transaction -> MessageId? in
        var randomId: Int64 = 0
        arc4random_buf(&randomId, 8)
        let message = StoreMessage(peerId: peerId, namespace: Namespaces.Message.Local, customStableId: nil, globallyUniqueId: randomId, groupingKey: nil, threadId: nil, timestamp: Int32(Date().timeIntervalSince1970), flags: [], tags: [], globalTags: [], localTags: [], forwardInfo: nil, authorId: account.peerId, text: "", attributes: [], media: [TelegramMediaAction(action: .customText(text: historyText, entities: [], additionalAttributes: nil))])
        return transaction.addMessages([message], location: .Random)[randomId]
    }
    |> deliverOnMainQueue).startStandalone(next: { messageId in
        if let messageId {
            ReplyReminderStore.shared.updateLocalMessageId(id: reminderId, localMessageId: messageId.id)
        }
    })

    // Local notification: fires even if the app is killed; tapping it opens the chat
    // through the regular notification handling in AppDelegate (peerId key).
    let content = UNMutableNotificationContent()
    content.title = strings.notificationTitle(peerTitle)
    content.body = note ?? strings.notificationBody
    content.sound = .default
    content.threadIdentifier = "replyReminders"
    content.userInfo = [
        "accountId": context.account.id.int64,
        "peerId": reminder.peerId,
        "replyReminder": true
    ]
    let interval = max(1.0, Double(time) - Date().timeIntervalSince1970)
    let request = UNNotificationRequest(identifier: reminder.notificationIdentifier, content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false))
    UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)

    return reminder
}

// When a reminder is due, replace its "reminder set" line with a "Reminder: note" line placed at the
// moment it fired, so the note sits right where you land in the chat instead of far up the history.
// Called when the chat opens (the app may not have been running when the notification fired).
public func materializeDueReplyReminder(context: AccountContext, peerId: EnginePeer.Id, strings: ReplyReminderStrings) {
    guard let reminder = ReplyReminderStore.shared.reminder(peerId: peerId, accountPeerId: context.account.peerId), reminder.isDue, reminder.firedLocalMessageId == nil else {
        return
    }
    let reminderId = reminder.id
    ReplyReminderStore.shared.modify(id: reminderId) { $0.firedLocalMessageId = 0 }

    let (text, boldLength) = strings.firedText(note: reminder.note, time: reminder.time)
    let account = context.account
    let previousLocalMessageId = reminder.localMessageId
    let _ = (account.postbox.transaction { transaction -> MessageId? in
        if let previousLocalMessageId {
            transaction.deleteMessages([MessageId(peerId: peerId, namespace: Namespaces.Message.Local, id: previousLocalMessageId)], forEachMedia: nil)
        }
        var randomId: Int64 = 0
        arc4random_buf(&randomId, 8)
        let entities = [MessageTextEntity(range: 0 ..< boldLength, type: .Bold)]
        let message = StoreMessage(peerId: peerId, namespace: Namespaces.Message.Local, customStableId: nil, globallyUniqueId: randomId, groupingKey: nil, threadId: nil, timestamp: reminder.time, flags: [], tags: [], globalTags: [], localTags: [], forwardInfo: nil, authorId: account.peerId, text: "", attributes: [], media: [TelegramMediaAction(action: .customText(text: text, entities: entities, additionalAttributes: nil))])
        return transaction.addMessages([message], location: .Random)[randomId]
    }
    |> deliverOnMainQueue).startStandalone(next: { messageId in
        if let messageId {
            ReplyReminderStore.shared.modify(id: reminderId) { $0.firedLocalMessageId = messageId.id }
        }
    })
}

public func cancelReplyReminder(context: AccountContext, reminder: ReplyReminder) {
    // Read the latest record: the local message id is filled in asynchronously after creation.
    let current = ReplyReminderStore.shared.reminder(peerId: reminder.enginePeerId, accountPeerId: context.account.peerId) ?? reminder
    ReplyReminderStore.shared.remove(id: reminder.id)
    UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [reminder.notificationIdentifier])
    if let localMessageId = current.localMessageId {
        let _ = context.engine.messages.deleteMessagesInteractively(messageIds: [EngineMessage.Id(peerId: current.enginePeerId, namespace: Namespaces.Message.Local, id: localMessageId)], type: .forLocalPeer).startStandalone()
    }

}
