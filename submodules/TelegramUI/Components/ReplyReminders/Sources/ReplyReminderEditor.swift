import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import AccountContext
import UndoUI
import ChatScheduleTimeController

// Opens the reminder sheet for a chat: note + date/time; for an existing reminder also Update / Delete.
// Shared by the chat list long-press menu and by the reminder line inside the chat.
public func presentReplyReminderEditor(context: AccountContext, peerId: EnginePeer.Id, peer: EnginePeer, push: @escaping (ViewController) -> Void, present: @escaping (ViewController) -> Void) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let strings = ReplyReminderStrings(languageCode: presentationData.strings.baseLanguageCode)
    let existingReminder = ReplyReminderStore.shared.reminder(peerId: peerId, accountPeerId: context.account.peerId)

    var currentTime: Int32?
    if let existingReminder, !existingReminder.isDue {
        currentTime = existingReminder.time
    }
    let controller = ChatScheduleTimeScreen(
        context: context,
        mode: .replyReminder(title: strings.pickerTitle, notePlaceholder: strings.notePlaceholder, note: existingReminder?.note, deleteTitle: existingReminder != nil ? strings.delete : nil, updateTitle: existingReminder != nil ? strings.update : nil),
        currentTime: currentTime,
        isDark: false,
        completion: { result in
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            if result.isDelete {
                if let existingReminder {
                    deleteReplyReminder(context: context, reminder: existingReminder, present: present)
                }
                return
            }
            let reminder = setReplyReminder(context: context, peerId: peerId, peer: peer, time: result.time, note: result.note, strings: strings)
            let content: UndoOverlayContent = .universal(
                animation: "anim_clock",
                scale: 0.058,
                colors: [:],
                title: strings.toastTitle(strings.relativeWhen(result.time)),
                text: strings.toastText(reminder.peerTitle, note: reminder.note),
                customUndoText: strings.undo,
                timeout: 5.0
            )
            present(UndoOverlayController(presentationData: presentationData, content: content, elevatedLayout: false, animateInAsReplacement: false, action: { action in
                if case .undo = action {
                    cancelReplyReminder(context: context, reminder: reminder)
                }
                return false
            }))
        }
    )
    push(controller)
}

public func deleteReplyReminder(context: AccountContext, reminder: ReplyReminder, present: @escaping (ViewController) -> Void) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let strings = ReplyReminderStrings(languageCode: presentationData.strings.baseLanguageCode)
    cancelReplyReminder(context: context, reminder: reminder)
    present(UndoOverlayController(presentationData: presentationData, content: .universal(animation: "anim_clock", scale: 0.058, colors: [:], title: nil, text: strings.cancelled, customUndoText: nil, timeout: nil), elevatedLayout: false, animateInAsReplacement: false, action: { _ in
        return true
    }))
}

// The pending reminder whose "reminder set" line is this local message, if any.
public func replyReminderForLocalMessage(context: AccountContext, messageId: EngineMessage.Id) -> ReplyReminder? {
    guard messageId.namespace == Namespaces.Message.Local, let reminder = ReplyReminderStore.shared.reminder(peerId: messageId.peerId, accountPeerId: context.account.peerId) else {
        return nil
    }
    return reminder.localMessageId == messageId.id ? reminder : nil
}
