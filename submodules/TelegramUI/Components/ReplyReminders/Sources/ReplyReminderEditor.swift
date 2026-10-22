import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import AccountContext
import UndoUI
import ChatScheduleTimeController

// Opens the reminder sheet: note + date/time. With `reminder` it edits that reminder (Change / Delete),
// otherwise it adds a new one to the chat; `message` links the new reminder to a message.
// Shared by the chat list menu, the reminder lines inside the chat and the message menu.
// `initialNote` pre-fills the note (text typed in the chat); `created` runs once the reminder is saved.
// `noteVoice` is a voice message that flies into the note field and turns into its text; `dismissed` runs when the
// sheet is gone, saved or not.
public func presentReplyReminderEditor(context: AccountContext, peerId: EnginePeer.Id, peer: EnginePeer, reminder existingReminder: ReplyReminder? = nil, message: EngineMessage? = nil, initialNote: String? = nil, noteVoice: ChatScheduleTimeNoteVoice? = nil, created: ((ReplyReminder) -> Void)? = nil, dismissed: (() -> Void)? = nil, push: @escaping (ViewController) -> Void, present: @escaping (ViewController) -> Void) {
    // One reminder sheet at a time: never a second one over the first.
    if let current = currentReplyReminderEditor, current.view.window != nil {
        return
    }
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let strings = ReplyReminderStrings(languageCode: presentationData.strings.baseLanguageCode)

    var currentTime: Int32?
    if let existingReminder, !existingReminder.isDue {
        currentTime = existingReminder.time
    } else {
        // A new reminder starts at one hour from now (to the minute).
        let inOneHour = Int32(Date().timeIntervalSince1970) + 60 * 60
        currentTime = inOneHour - inOneHour % 60
    }
    // The sheet always slides up from the bottom, for a new reminder and for a change alike.
    let morphSource: ChatScheduleTimeMorphAnchor? = nil
    // The sheet collapses into the line of the reminder it creates; its id is known once the completion runs.
    var createdReminderId: String?
    let controller = ChatScheduleTimeScreen(
        context: context,
        mode: .replyReminder(title: strings.pickerTitle, notePlaceholder: strings.notePlaceholder, note: existingReminder?.note ?? initialNote.flatMap { $0.isEmpty ? nil : $0 }, deleteTitle: existingReminder != nil ? strings.delete : nil, updateTitle: existingReminder != nil ? strings.update : nil),
        currentTime: currentTime,
        currentRepeatPeriod: existingReminder?.repeatPeriod,
        isDark: false,
        morphSource: morphSource,
        morphTarget: {
            guard let createdReminderId else {
                return nil
            }
            return ReplyReminderAnchors.shared.anchor(peerId: peerId, reminderId: createdReminderId).flatMap(ChatScheduleTimeMorphAnchor.init(replyReminderAnchor:))
        },
        noteVoice: noteVoice,
        completion: { result in
            if result.isDelete {
                if let existingReminder {
                    deleteReplyReminder(context: context, reminder: existingReminder, present: present)
                }
                return
            }
            // No toast: the sheet collapsing into the reminder line already shows what was set.
            let reminder = setReplyReminder(
                context: context,
                peerId: peerId,
                peer: peer,
                time: result.time,
                note: result.note,
                repeatPeriod: result.repeatPeriod,
                message: message?.id,
                messageExcerpt: message.flatMap { replyReminderMessageExcerpt($0, strings: strings) },
                replacing: existingReminder,
                strings: strings
            )
            createdReminderId = reminder.id
            created?(reminder)
        }
    )
    controller.didDismiss = dismissed
    currentReplyReminderEditor = controller
    push(controller)
}

private weak var currentReplyReminderEditor: ViewController?

public func deleteReplyReminder(context: AccountContext, reminder: ReplyReminder, present: @escaping (ViewController) -> Void) {
    // No toast: the reminder line disappearing from the chat is enough.
    cancelReplyReminder(context: context, reminder: reminder)
}

// The pending reminder whose "reminder set" line is this local message, if any.
public func replyReminderForLocalMessage(context: AccountContext, messageId: EngineMessage.Id) -> ReplyReminder? {
    guard messageId.namespace == Namespaces.Message.Local else {
        return nil
    }
    return ReplyReminderStore.shared.reminders(peerId: messageId.peerId, accountPeerId: context.account.peerId).first(where: { $0.localMessageId == messageId.id })
}

private extension ChatScheduleTimeMorphAnchor {
    init(replyReminderAnchor anchor: ReplyReminderAnchor) {
        self.init(frame: anchor.frame, cornerRadius: anchor.cornerRadius, color: anchor.color, hiddenView: anchor.hiddenView, land: anchor.land)
    }
}
