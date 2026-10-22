import Foundation
import ReplyReminders
import ChatScheduleTimeController
import AudioWaveform
import OverlayStatusController
import PresentationDataUtils
import TelegramPresentationData
import UIKit
import AsyncDisplayKit
import ContextUI
import Display
import SwiftSignalKit
import TelegramCore
import TelegramNotices
import ChatSendMessageActionUI
import AccountContext
import TopMessageReactions
import ReactionSelectionNode
import ChatControllerInteraction
import ChatSendAudioMessageContextPreview

extension ChatSendMessageEffect {
    convenience init(_ effect: ChatSendMessageActionSheetController.SendParameters.Effect) {
        self.init(id: effect.id)
    }
}

// Builds the send-options rich preview when the composed/edited content will be sent as a rich
// message — mirrors the real send gates (ChatControllerNode.swift for new messages,
// ChatControllerLoadDisplayNode.swift for edits). A blockquote is entity-expressible but is also
// shown through the rich preview (`.quotesRequireRichContent`), so a quote-bearing message previews
// as a rich bubble. Returns nil for plain / quote-free entity-expressible content, empty content, or
// when a media preview is already shown (media-preview-wins).
private func makeRichTextSendPreview(context: AccountContext, content: ChatInputContent, mediaPreview: ChatSendMessageContextScreenMediaPreview?) -> ChatSendMessageContextScreenRichTextPreview? {
    guard mediaPreview == nil, !content.isEmpty, !content.isEntityExpressible(options: [.quotesRequireRichContent]) else {
        return nil
    }
    return ChatSendMessageRichTextPreview(context: context, instantPage: instantPage(from: content))
}

func chatMessageDisplaySendMessageOptions(selfController: ChatControllerImpl, node: ASDisplayNode, gesture: ContextGesture) {
    guard let peerId = selfController.chatLocation.peerId, let textInputView = selfController.chatDisplayNode.textInputView(), let layout = selfController.validLayout else {
        return
    }
    let previousSupportedOrientations = selfController.supportedOrientations
    if layout.size.width > layout.size.height {
        selfController.supportedOrientations = ViewControllerSupportedOrientations(regularSize: .all, compactSize: .landscape)
    } else {
        selfController.supportedOrientations = ViewControllerSupportedOrientations(regularSize: .all, compactSize: .portrait)
    }
    
    let _ = ApplicationSpecificNotice.incrementChatMessageOptionsTip(accountManager: selfController.context.sharedContext.accountManager, count: 4).startStandalone()
    
    var hasEntityKeyboard = false
    if case .media = selfController.presentationInterfaceState.inputMode {
        hasEntityKeyboard = true
    }
    
    let effectItems: Signal<[ReactionItem]?, NoError>
    if peerId != selfController.context.account.peerId && peerId.namespace == Namespaces.Peer.CloudUser {
        effectItems = effectMessageReactions(context: selfController.context)
        |> map(Optional.init)
    } else {
        effectItems = .single(nil)
    }
    
    let availableMessageEffects = selfController.context.availableMessageEffects |> take(1)
    let hasPremium = selfController.context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: selfController.context.account.peerId))
    |> map { peer -> Bool in
        guard case let .user(user) = peer else {
            return false
        }
        return user.isPremium
    }
    
    let editMessages: Signal<[EngineMessage], NoError>
    if let editMessage = selfController.presentationInterfaceState.interfaceState.editMessage {
        editMessages = selfController.context.engine.data.get(
            TelegramEngine.EngineData.Item.Messages.MessageGroup(id: editMessage.messageId)
        )
    } else {
        editMessages = .single([])
    }
    
    var currentMessageEffect: ChatSendMessageActionSheetControllerSendParameters.Effect?
    if selfController.presentationInterfaceState.interfaceState.editMessage == nil {
        if let sendMessageEffect = selfController.presentationInterfaceState.interfaceState.sendMessageEffect {
            currentMessageEffect = ChatSendMessageActionSheetControllerSendParameters.Effect(id: sendMessageEffect)
        }
    }
    
    let _ = (combineLatest(
        selfController.context.account.viewTracker.peerView(peerId) |> take(1),
        effectItems,
        availableMessageEffects,
        hasPremium,
        editMessages,
        ChatSendMessageContextScreen.initialData(context: selfController.context, currentMessageEffectId: currentMessageEffect?.id)
    )
    |> deliverOnMainQueue).startStandalone(next: { [weak selfController] peerView, effectItems, availableMessageEffects, hasPremium, editMessages, initialData in
        guard let selfController, let peer = peerViewMainPeer(peerView) else {
            return
        }
        
        if let editMessage = selfController.presentationInterfaceState.interfaceState.editMessage {
            if editMessages.isEmpty {
                return
            }
            
            var mediaPreview: ChatSendMessageContextScreenMediaPreview?
            if editMessages.contains(where: { message in
                return message.media.contains(where: { media in
                    if media is TelegramMediaImage {
                        return true
                    } else if let file = media as? TelegramMediaFile, file.isVideo {
                        return true
                    } else if media is TelegramMediaPaidContent {
                        return true
                    }
                    return false
                })
            }) {
                mediaPreview = ChatSendGroupMediaMessageContextPreview(
                    context: selfController.context,
                    presentationData: selfController.presentationData,
                    wallpaperBackgroundNode: selfController.chatDisplayNode.backgroundNode,
                    messages: editMessages
                )
            }
            
            let mediaCaptionIsAbove: Bool
            if let value = editMessage.mediaCaptionIsAbove {
                mediaCaptionIsAbove = value
            } else {
                mediaCaptionIsAbove = editMessages.contains(where: {
                    $0.attributes.contains(where: {
                        $0 is InvertMediaMessageAttribute
                    })
                })
            }
            
            let controller = makeChatSendMessageActionSheetController(
                initialData: initialData,
                context: selfController.context,
                updatedPresentationData: selfController.updatedPresentationData,
                peerId: selfController.presentationInterfaceState.chatLocation.peerId,
                params: .editMessage(SendMessageActionSheetControllerParams.EditMessage(
                    messages: editMessages,
                    mediaPreview: mediaPreview,
                    mediaCaptionIsAbove: (mediaCaptionIsAbove, { [weak selfController] updatedMediaCaptionIsAbove in
                        guard let selfController else {
                            return
                        }
                        selfController.updateChatPresentationInterfaceState(animated: false, interactive: false, { state in
                            return state.updatedInterfaceState { interfaceState in
                                guard var editMessage = interfaceState.editMessage else {
                                    return interfaceState
                                }
                                editMessage.mediaCaptionIsAbove = updatedMediaCaptionIsAbove
                                return interfaceState.withUpdatedEditMessage(editMessage)
                            }
                        })
                    })
                )),
                hasEntityKeyboard: hasEntityKeyboard,
                gesture: gesture,
                sourceSendButton: node.view,
                textInputSource: textInputView,
                emojiViewProvider: selfController.chatDisplayNode.textInputPanelNode?.emojiViewProvider,
                wallpaperBackgroundNode: selfController.chatDisplayNode.backgroundNode,
                completion: { [weak selfController] in
                    guard let selfController else {
                        return
                    }
                    selfController.supportedOrientations = previousSupportedOrientations
                },
                sendMessage: { [weak selfController] mode, parameters in
                    guard let selfController else {
                        return
                    }
                    selfController.interfaceInteraction?.editMessage()
                },
                schedule: { _ in
                },
                editPrice: { _ in
                }, openPremiumPaywall: { [weak selfController] c in
                    guard let selfController else {
                        return
                    }
                    selfController.push(c)
                },
                reactionItems: nil,
                availableMessageEffects: nil,
                isPremium: hasPremium,
                richTextPreview: makeRichTextSendPreview(context: selfController.context, content: editMessage.inputState.content, mediaPreview: mediaPreview)
            )
            selfController.sendMessageActionsController = controller
            if layout.isNonExclusive {
                selfController.present(controller, in: .window(.root))
            } else {
                selfController.presentInGlobalOverlay(controller, with: nil)
            }
        } else {
            var sendWhenOnlineAvailable = false
            if let presence = peerView.peerPresences[peer.id] as? TelegramUserPresence, case let .present(until) = presence.status {
                let currentTime = Int32(CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970)
                if currentTime > until {
                    sendWhenOnlineAvailable = true
                }
            }
            if peer.id.namespace == Namespaces.Peer.CloudUser && peer.id.id._internalGetInt64Value() == 777000 {
                sendWhenOnlineAvailable = false
            }
            
            if sendWhenOnlineAvailable {
                let _ = ApplicationSpecificNotice.incrementSendWhenOnlineTip(accountManager: selfController.context.sharedContext.accountManager, count: 4).startStandalone()
            }
            
            var mediaPreview: ChatSendMessageContextScreenMediaPreview?
            if let videoRecorderValue = selfController.videoRecorderValue {
                mediaPreview = videoRecorderValue.makeSendMessageContextPreview()
            }
            if let mediaDraftState = selfController.presentationInterfaceState.interfaceState.mediaDraftState {
                if case let .audio(audio) = mediaDraftState {
                    mediaPreview = ChatSendAudioMessageContextPreview(
                        context: selfController.context,
                        presentationData: selfController.presentationData,
                        wallpaperBackgroundNode: selfController.chatDisplayNode.backgroundNode,
                        waveform: audio.waveform
                    )
                }
            }

            let controller = makeChatSendMessageActionSheetController(
                initialData: initialData,
                context: selfController.context,
                updatedPresentationData: selfController.updatedPresentationData,
                peerId: selfController.presentationInterfaceState.chatLocation.peerId,
                params: .sendMessage(SendMessageActionSheetControllerParams.SendMessage(
                    isScheduledMessages: false,
                    mediaPreview: mediaPreview,
                    mediaCaptionIsAbove: nil,
                    messageEffect: (currentMessageEffect, { [weak selfController] updatedEffect in
                        guard let selfController else {
                            return
                        }
                        selfController.updateChatPresentationInterfaceState(transition: .immediate, interactive: true, { presentationInterfaceState in
                            return presentationInterfaceState.updatedInterfaceState { interfaceState in
                                return interfaceState.withUpdatedSendMessageEffect(updatedEffect?.id)
                            }
                        })
                    }),
                    attachment: false,
                    canSendWhenOnline: sendWhenOnlineAvailable,
                    forwardMessageIds: selfController.presentationInterfaceState.interfaceState.forwardMessageIds ?? [],
                    canMakePaidContent: false,
                    currentPrice: nil,
                    hasTimers: false,
                    sendPaidMessageStars: selfController.presentationInterfaceState.sendPaidMessageStars,
                    isMonoforum: selfController.presentationInterfaceState.renderedPeer?.peer?.isMonoForum ?? false
                )),
                hasEntityKeyboard: hasEntityKeyboard,
                gesture: gesture,
                sourceSendButton: node.view,
                textInputSource: textInputView,
                emojiViewProvider: selfController.chatDisplayNode.textInputPanelNode?.emojiViewProvider,
                wallpaperBackgroundNode: selfController.chatDisplayNode.backgroundNode,
                completion: { [weak selfController] in
                    guard let selfController else {
                        return
                    }
                    selfController.supportedOrientations = previousSupportedOrientations
                },
                sendMessage: { [weak selfController] mode, parameters in
                    guard let selfController else {
                        return
                    }
                    switch mode {
                    case .generic:
                        selfController.controllerInteraction?.sendCurrentMessage(false, parameters?.effect.flatMap(ChatSendMessageEffect.init))
                    case .silently:
                        selfController.controllerInteraction?.sendCurrentMessage(true, parameters?.effect.flatMap(ChatSendMessageEffect.init))
                    case .whenOnline:
                        selfController.chatDisplayNode.sendCurrentMessage(scheduleTime: scheduleWhenOnlineTimestamp, messageEffect: parameters?.effect.flatMap(ChatSendMessageEffect.init)) { [weak selfController] in
                            guard let selfController else {
                                return
                            }
                            selfController.updateChatPresentationInterfaceState(animated: true, interactive: false, saveInterfaceState: selfController.presentationInterfaceState.subject != .scheduledMessages, {
                                $0.updatedInterfaceState { $0.withUpdatedReplyMessageSubject(nil).withUpdatedSendMessageEffect(nil).withUpdatedPostSuggestionState(nil).withUpdatedForwardMessageIds(nil).withUpdatedForwardOptionsState(nil).withUpdatedComposeInputState(ChatTextInputState(inputText: NSAttributedString(string: ""))) }
                            })
                            selfController.openScheduledMessages()
                        }
                    }
                },
                schedule: { [weak selfController] params in
                    guard let selfController else {
                        return
                    }
                    selfController.controllerInteraction?.scheduleCurrentMessage(params)
                }, editPrice: { _ in
                }, openPremiumPaywall: { [weak selfController] c in
                    guard let selfController else {
                        return
                    }
                    selfController.push(c)
                },
                reactionItems: (!((textInputView.attributedText?.string ?? "").isEmpty) || mediaPreview != nil) ? effectItems : nil,
                availableMessageEffects: availableMessageEffects,
                isPremium: hasPremium,
                richTextPreview: {
                    if case .customChatContents = selfController.presentationInterfaceState.subject {
                        return nil
                    }
                    return makeRichTextSendPreview(context: selfController.context, content: selfController.presentationInterfaceState.interfaceState.composeInputState.content, mediaPreview: mediaPreview)
                }(),
                extraAction: replyReminderSendMenuAction(selfController: selfController, peer: EnginePeer(peer), hasMedia: mediaPreview != nil)
            )
            selfController.sendMessageActionsController = controller
            if layout.isNonExclusive {
                selfController.present(controller, in: .window(.root))
            } else {
                selfController.presentInGlobalOverlay(controller, with: nil)
            }
        }
    })
}

// "Remind Me" in the send button menu: instead of sending, the typed text (or a recorded voice message, recognized
// into text) becomes the note of a new personal reminder; it leaves the input field once the reminder is saved.
private func replyReminderSendMenuAction(selfController: ChatControllerImpl, peer: EnginePeer, hasMedia: Bool) -> ChatSendMessageContextScreenExtraAction? {
    guard selfController.presentationInterfaceState.subject == nil, case let .peer(peerId) = selfController.chatLocation, peerId != selfController.context.account.peerId else {
        return nil
    }
    let strings = ReplyReminderStrings(languageCode: selfController.presentationData.strings.baseLanguageCode)
    let icon: (PresentationTheme) -> UIImage? = { theme in
        return replyReminderMenuIcon(color: theme.contextMenu.primaryColor)
    }
    let openEditor: (ChatControllerImpl, String, @escaping () -> Void) -> Void = { selfController, note, created in
        presentReplyReminderEditor(context: selfController.context, peerId: peerId, peer: peer, initialNote: note, created: { _ in
            created()
        }, push: { [weak selfController] controller in
            selfController?.push(controller)
        }, present: { [weak selfController] controller in
            selfController?.present(controller, in: .current)
        })
    }

    if let mediaDraftState = selfController.presentationInterfaceState.interfaceState.mediaDraftState, case let .audio(audio) = mediaDraftState {
        // A recorded voice message: it flies from the input panel into the note field and turns into its text there;
        // the recording is dropped once the reminder is saved.
        return ChatSendMessageContextScreenExtraAction(title: strings.remindForMe, icon: icon, action: { [weak selfController] previewSnapshot in
            guard let selfController else {
                previewSnapshot?.removeFromSuperview()
                return
            }
            // The voice bubble of the send menu collapses into a point and reappears in the note field.
            let flyingView: UIView? = previewSnapshot
            var panelView: UIView?
            if let inputPanelView = selfController.chatDisplayNode.inputPanelNode?.view {
                inputPanelView.alpha = 0.0
                panelView = inputPanelView
            }
            let noteVoice = ChatScheduleTimeNoteVoice(
                text: replyReminderTranscribeVoice(context: selfController.context, resource: audio.resource),
                levels: replyReminderWaveformLevels(audio.waveform),
                flyingView: flyingView
            )
            presentReplyReminderEditor(context: selfController.context, peerId: peerId, peer: peer, noteVoice: noteVoice, created: { [weak selfController] _ in
                selfController?.interfaceInteraction?.deleteRecordedMedia()
            }, dismissed: { [weak panelView] in
                flyingView?.removeFromSuperview()
                UIView.animate(withDuration: 0.2, animations: {
                    panelView?.alpha = 1.0
                })
            }, push: { [weak selfController] controller in
                selfController?.push(controller)
            }, present: { [weak selfController] controller in
                selfController?.present(controller, in: .current)
            })
        })
    }

    if hasMedia {
        return nil
    }
    let text = selfController.presentationInterfaceState.interfaceState.composeInputState.inputText.string.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty {
        return nil
    }
    return ChatSendMessageContextScreenExtraAction(title: strings.remindForMe, icon: icon, action: { [weak selfController] previewSnapshot in
        UIView.animate(withDuration: 0.2, animations: {
            previewSnapshot?.alpha = 0.0
        }, completion: { _ in
            previewSnapshot?.removeFromSuperview()
        })
        guard let selfController else {
            return
        }
        selfController.chatDisplayNode.dismissInput()
        openEditor(selfController, text, { [weak selfController] in
            selfController?.updateChatPresentationInterfaceState(animated: true, interactive: false, {
                $0.updatedInterfaceState { $0.withUpdatedComposeInputState(ChatTextInputState(inputText: NSAttributedString(string: ""))) }
            })
        })
    })
}

// The voice message's waveform as levels 0...1 for the note field.
private func replyReminderWaveformLevels(_ waveform: AudioWaveform) -> [CGFloat] {
    let count = waveform.samples.count / 2
    if count == 0 {
        return []
    }
    let peak = max(1, CGFloat(waveform.peak))
    return waveform.samples.withUnsafeBytes { bytes -> [CGFloat] in
        let samples = bytes.bindMemory(to: Int16.self)
        return (0 ..< count).map { min(1.0, CGFloat(samples[$0]) / peak) }
    }
}
