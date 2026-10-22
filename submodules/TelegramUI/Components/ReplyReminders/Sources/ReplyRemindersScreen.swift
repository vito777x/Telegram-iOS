import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import ConvertOpusToAAC
import ChatScheduleTimeController
import OverlayStatusController
import PresentationDataUtils

// The reminders screen shows each reminder as a message of its own, like the reminders in Saved Messages:
// the bubble holds the note (or the message it was set from), its time is when the reminder fires.

// Stable message id of a reminder on the reminders screen.
public func replyReminderDisplayMessageId(reminderId: String) -> Int32 {
    var hash: UInt32 = 2166136261
    for byte in reminderId.utf8 {
        hash = (hash ^ UInt32(byte)) &* 16777619
    }
    return Int32(bitPattern: hash & 0x3fffffff) + 1
}

// The reminder a message on the reminders screen stands for.
public func replyReminderForDisplayMessage(context: AccountContext, messageId: EngineMessage.Id) -> ReplyReminder? {
    return ReplyReminderStore.shared.reminders(peerId: messageId.peerId, accountPeerId: context.account.peerId).first(where: { replyReminderDisplayMessageId(reminderId: $0.id) == messageId.id })
}

public func replyRemindersPresentation(context: AccountContext, peerId: EnginePeer.Id, peer: EnginePeer) -> ChatReplyRemindersPresentation {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let strings = ReplyReminderStrings(languageCode: presentationData.strings.baseLanguageCode)
    return ChatReplyRemindersPresentation(
        peerId: peerId,
        title: strings.remindersTitle,
        subtitle: peer.compactDisplayTitle,
        placeholder: strings.remindersPlaceholder,
        emptyTitle: strings.remindersEmptyTitle,
        emptyText: strings.remindersEmptyText
    )
}

// Opens the chat's reminders. Typing a note and sending it adds a reminder: the time sheet opens with the note filled in.
public func openReplyRemindersScreen(context: AccountContext, peerId: EnginePeer.Id, peer: EnginePeer, navigationController: NavigationController) {
    let contents = ReplyRemindersChatContents(context: context, peerId: peerId, peer: peer)
    let chatController = context.sharedContext.makeChatController(
        context: context,
        chatLocation: .customChatContents,
        subject: .customChatContents(contents: contents),
        botStart: nil,
        mode: .standard(.default),
        params: nil
    )
    contents.present = { [weak chatController] controller in
        chatController?.present(controller, in: .window(.root))
    }
    contents.composeVoice = { [weak chatController, weak navigationController] file in
        // The recorded voice shows up where the recorder was, as a voice capsule, then collapses and flies into the
        // note field of the sheet, where it turns into its text; like a voice message turned into a reminder in a chat.
        guard let chatController, let window = chatController.view.window else {
            return
        }
        chatController.view.endEditing(true)
        let levels = replyReminderVoiceLevels(file)
        // Straight from the microphone as a glowing ball into the note field, where it opens into the waveform.
        let micCenter = CGPoint(x: window.bounds.width - 52.0, y: window.bounds.height - window.safeAreaInsets.bottom - 26.0)
        let noteVoice = ChatScheduleTimeNoteVoice(text: replyReminderTranscribeVoice(context: context, resource: file.resource), levels: levels, flyingView: nil, orbOrigin: micCenter)
        presentReplyReminderEditor(context: context, peerId: peerId, peer: peer, noteVoice: noteVoice, push: { [weak chatController] controller in
            (chatController?.navigationController as? NavigationController ?? navigationController)?.pushViewController(controller)
        }, present: { [weak chatController] controller in
            chatController?.present(controller, in: .current)
        })
    }
    contents.compose = { [weak chatController, weak navigationController] text in
        // The sheet covers the input field: nothing of it (keyboard, recording controls) stays on top.
        chatController?.view.endEditing(true)
        presentReplyReminderEditor(context: context, peerId: peerId, peer: peer, initialNote: text, push: { controller in
            (chatController?.navigationController as? NavigationController ?? navigationController)?.pushViewController(controller)
        }, present: { controller in
            chatController?.present(controller, in: .current)
        })
    }
    // Slides up from the bottom, like the scheduled messages screen.
    chatController.navigationPresentation = .modal
    navigationController.pushViewController(chatController)
}

// A recorded voice message as text, recognized on the device; nil when nothing could be recognized.
public func replyReminderTranscribeVoice(context: AccountContext, resource: MediaResource) -> Signal<String?, NoError> {
    return context.engine.resources.data(id: EngineMediaResource.Id(resource.id))
    |> filter { $0.isComplete }
    |> take(1)
    |> mapToSignal { data -> Signal<String?, NoError> in
        // Voice messages are Opus; the speech recognizer needs AAC.
        return convertOpusToAAC(sourcePath: data.path, allocateTempFile: {
            return EngineTempBox.shared.tempFile(fileName: "audio.m4a").path
        })
    }
    |> mapToSignal { path -> Signal<String?, NoError> in
        guard let path else {
            return .single(nil)
        }
        return replyReminderTranscribeAudioFile(path: path, languageCode: context.sharedContext.currentPresentationData.with { $0 }.strings.baseLanguageCode)
    }
    |> timeout(30.0, queue: .mainQueue(), alternate: .single(nil))
    |> map { text -> String? in
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

final class ReplyRemindersChatContents: ChatCustomContentsProtocol {
    let kind: ChatCustomContentsKind
    let messageLimit: Int? = nil

    private let context: AccountContext
    private let peerId: EnginePeer.Id
    var compose: ((String) -> Void)?
    var composeVoice: ((TelegramMediaFile) -> Void)?
    var present: ((ViewController) -> Void)?
    private let transcriptionDisposable = MetaDisposable()

    deinit {
        self.transcriptionDisposable.dispose()
    }

    init(context: AccountContext, peerId: EnginePeer.Id, peer: EnginePeer) {
        self.context = context
        self.peerId = peerId
        self.kind = .replyReminders(replyRemindersPresentation(context: context, peerId: peerId, peer: peer))
    }

    var historyView: Signal<(EngineRawMessageHistoryView, EngineViewUpdateType), NoError> {
        let context = self.context
        let peerId = self.peerId
        let accountPeerId = context.account.peerId
        let strings = ReplyReminderStrings(languageCode: context.sharedContext.currentPresentationData.with { $0 }.strings.baseLanguageCode)

        let peers = context.engine.data.get(
            TelegramEngine.EngineData.Item.Peer.Peer(id: accountPeerId),
            TelegramEngine.EngineData.Item.Peer.Peer(id: peerId)
        )
        let isFirst = Atomic<Bool>(value: true)
        return combineLatest(queue: .mainQueue(), ReplyReminderStore.shared.reminders(accountPeerId: accountPeerId), peers)
        |> map { reminders, peers -> (EngineRawMessageHistoryView, EngineViewUpdateType) in
            let (accountPeer, chatPeer) = peers
            var peerMap = SimpleDictionary<PeerId, Peer>()
            if let accountPeer {
                peerMap[accountPeer.id] = accountPeer._asPeer()
            }
            if let chatPeer {
                peerMap[chatPeer.id] = chatPeer._asPeer()
            }
            let entries = reminders
            .filter { $0.peerId == peerId.toInt64() }
            .map { reminder -> EngineRawMessageHistoryEntry in
                let displayId = replyReminderDisplayMessageId(reminderId: reminder.id)
                // Just the note: this is the list of reminders, so no "Reminder" word. The day is the date header
                // above, the time is the bubble's own; a repeating reminder says how often on a second line.
                var text = reminder.subject ?? strings.remindersDefaultText
                var header = ""
                if let repeatPeriod = reminder.repeatPeriod {
                    header = "🔁 " + strings.repeatTitle(repeatPeriod)
                    text = header + "\n" + text
                }
                let headerLength = (header as NSString).length
                let message = Message(
                    stableId: UInt32(bitPattern: displayId),
                    stableVersion: UInt32(truncatingIfNeeded: reminder.time) &+ UInt32(truncatingIfNeeded: text.hashValue),
                    id: MessageId(peerId: peerId, namespace: Namespaces.Message.Local, id: displayId),
                    globallyUniqueId: nil,
                    groupingKey: nil,
                    groupInfo: nil,
                    threadId: nil,
                    timestamp: reminder.time,
                    // Shown on the left like a message to you: scheduled messages are your own bubbles on the right.
                    flags: [.Incoming],
                    tags: [],
                    globalTags: [],
                    localTags: [],
                    customTags: [],
                    forwardInfo: nil,
                    author: accountPeer?._asPeer(),
                    text: text,
                    attributes: headerLength == 0 ? [] : [TextEntitiesMessageAttribute(entities: [MessageTextEntity(range: 0 ..< headerLength, type: .Italic)])],
                    media: [],
                    peers: peerMap,
                    associatedMessages: SimpleDictionary(),
                    associatedMessageIds: [],
                    associatedMedia: [:],
                    associatedThreadInfo: nil,
                    associatedStories: [:]
                )
                return EngineRawMessageHistoryEntry(message: message, isRead: true, location: nil, monthLocation: nil, attributes: EngineRawMutableMessageHistoryEntryAttributes(authorIsContact: false))
            }
            .sorted(by: { $0.message.index < $1.message.index })

            let view = EngineRawMessageHistoryView(tag: nil, namespaces: .just(Set([Namespaces.Message.Local])), entries: entries, holeEarlier: false, holeLater: false, isLoading: false)
            let updateType: EngineViewUpdateType = isFirst.swap(false) ? .Initial : .Generic
            return (view, updateType)
        }
    }

    // Sending text from the screen's input adds a reminder with that text as its note;
    // a voice message is recognized on the device and its text becomes the note.
    func enqueueMessages(messages: [EnqueueMessage]) {
        var text = ""
        for message in messages {
            if case let .message(messageText, _, _, mediaReference, _, _, _, _, _, _) = message {
                if let file = mediaReference?.media as? TelegramMediaFile, file.isVoice {
                    if let composeVoice = self.composeVoice {
                        // After the recording UI of the input field has gone.
                        Queue.mainQueue().after(0.25) {
                            composeVoice(file)
                        }
                    } else {
                        self.transcribeVoice(file: file)
                    }
                    return
                }
                text += messageText
            }
        }
        let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let compose = self.compose
        Queue.mainQueue().async {
            compose?(note)
        }
    }

    private func transcribeVoice(file: TelegramMediaFile) {
        let context = self.context
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let statusController = OverlayStatusController(theme: presentationData.theme, type: .loading(cancelled: nil))
        Queue.mainQueue().async {
            self.present?(statusController)
        }

        let signal = replyReminderTranscribeVoice(context: context, resource: file.resource)

        self.transcriptionDisposable.set((signal
        |> deliverOnMainQueue).startStrict(next: { [weak self, weak statusController] text in
            statusController?.dismiss()
            // Nothing recognized (or no permission): the sheet still opens, the note can be typed instead.
            self?.compose?(text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        }))
    }

    func deleteMessages(ids: [EngineMessage.Id]) {
        for id in ids {
            if let reminder = replyReminderForDisplayMessage(context: self.context, messageId: id) {
                cancelReplyReminder(context: self.context, reminder: reminder)
            }
        }
    }

    func editMessage(id: EngineMessage.Id, text: String, media: RequestEditMessageMedia, entities: TextEntitiesMessageAttribute?, webpagePreviewAttribute: WebpagePreviewMessageAttribute?, disableUrlPreview: Bool) {
    }

    func quickReplyUpdateShortcut(value: String) {
    }

    func businessLinkUpdate(message: String, entities: [MessageTextEntity], title: String?) {
    }

    func loadMore() {
    }

    func hashtagSearchUpdate(query: String) {
    }

    var hashtagSearchResultsUpdate: ((SearchMessagesResult, SearchMessagesState)) -> Void = { _ in }
}

// A voice message's waveform as levels 0...1: the attribute packs one 5-bit value per sample.
func replyReminderVoiceLevels(_ file: TelegramMediaFile) -> [CGFloat] {
    var waveform: Data?
    for attribute in file.attributes {
        if case let .Audio(_, _, _, _, data) = attribute {
            waveform = data
        }
    }
    guard let waveform, !waveform.isEmpty else {
        return []
    }
    let bytes = [UInt8](waveform)
    let count = bytes.count * 8 / 5
    var values: [CGFloat] = []
    values.reserveCapacity(count)
    for i in 0 ..< count {
        let bit = i * 5
        let byteIndex = bit / 8
        var value = UInt32(bytes[byteIndex])
        if byteIndex + 1 < bytes.count {
            value |= UInt32(bytes[byteIndex + 1]) << 8
        }
        values.append(CGFloat((value >> UInt32(bit % 8)) & 31) / 31.0)
    }
    let peak = max(0.1, values.max() ?? 1.0)
    return values.map { min(1.0, $0 / peak) }
}
