//
// PrivateChatManager.swift
// bitchat
//
// Manages private chat sessions and messages
// This is free and unencumbered software released into the public domain.
//

import BitLogger
import Foundation
import SwiftUI

/// Manages all private chat functionality
final class PrivateChatManager: ObservableObject {
    @Published var privateChats: [String: [BitchatMessage]] = [:]
    @Published var selectedPeer: String? = nil
    @Published var unreadMessages: Set<String> = []
    
    private var selectedPeerFingerprint: String? = nil
    var sentReadReceipts: Set<String> = []  // Made accessible for ChatViewModel
    private var sentReadReceiptOrder: [String] = []
    
    weak var meshService: Transport?
    // Route acks/receipts via MessageRouter (chooses mesh or Nostr)
    weak var messageRouter: MessageRouter?
    
    init(meshService: Transport? = nil) {
        self.meshService = meshService
    }

    // Cap for messages stored per private chat
    private let privateChatCap = TransportConfig.privateChatCap
    private let sentReadReceiptsCap = TransportConfig.uiSentReadReceiptsCap
    
    /// Start a private chat with a peer
    func startChat(with peerID: String) {
        selectedPeer = peerID
        
        // Store fingerprint for persistence across reconnections
        if let fingerprint = meshService?.getFingerprint(for: PeerID(str: peerID)) {
            selectedPeerFingerprint = fingerprint
        }
        
        // Mark messages as read
        markAsRead(from: peerID)
        
        // Initialize chat if needed
        if privateChats[peerID] == nil {
            privateChats[peerID] = []
        }
    }
    
    /// End the current private chat
    func endChat() {
        selectedPeer = nil
        selectedPeerFingerprint = nil
    }

    /// Remove duplicate messages by ID and keep chronological order
    func sanitizeChat(for peerID: String) {
        guard let arr = privateChats[peerID] else { return }
        if arr.count <= 1 {
            return
        }

        var indexByID: [String: Int] = [:]
        indexByID.reserveCapacity(arr.count)
        var deduped: [BitchatMessage] = []
        deduped.reserveCapacity(arr.count)

        for msg in arr.sorted(by: { $0.timestamp < $1.timestamp }) {
            if let existing = indexByID[msg.id] {
                deduped[existing] = msg
            } else {
                indexByID[msg.id] = deduped.count
                deduped.append(msg)
            }
        }

        privateChats[peerID] = deduped
    }
    
    /// Mark messages from a peer as read
    func markAsRead(from peerID: String) {
        unreadMessages.remove(peerID)
        
        // Send read receipts for unread messages that haven't been sent yet
        if let messages = privateChats[peerID] {
            for message in messages {
                if let senderPeerID = message.senderPeerID,
                   WiFiPeerIdentity.isEquivalent(senderPeerID.id, peerID),
                   !message.isRelay,
                   !hasSentReadReceipt(message.id) {
                    sendReadReceipt(for: message)
                }
            }
        }
    }

    func markReadReceiptSent(_ messageID: String) {
        _ = prepareReadReceiptMessageID(messageID)
    }
    
    // MARK: - Private Methods

    private func hasSentReadReceipt(_ messageID: String) -> Bool {
        guard let safeMessageID = InputValidator.validateMessageID(messageID) else { return false }
        return sentReadReceipts.contains(safeMessageID)
    }

    private func prepareReadReceiptMessageID(_ messageID: String) -> String? {
        guard let safeMessageID = InputValidator.validateMessageID(messageID) else { return nil }
        guard !sentReadReceipts.contains(safeMessageID) else { return nil }
        sentReadReceipts.insert(safeMessageID)
        sentReadReceiptOrder.append(safeMessageID)
        if sentReadReceiptOrder.count > sentReadReceiptsCap {
            let overflow = sentReadReceiptOrder.count - sentReadReceiptsCap
            for _ in 0..<overflow {
                if let old = sentReadReceiptOrder.first {
                    sentReadReceiptOrder.removeFirst()
                    sentReadReceipts.remove(old)
                }
            }
        }
        return safeMessageID
    }
    
    private func sendReadReceipt(for message: BitchatMessage) {
        guard let senderPeerID = message.senderPeerID,
              senderPeerID.isValid,
              let safeMessageID = prepareReadReceiptMessageID(message.id) else {
            return
        }

        let readerNickname = InputValidator.validateNickname(meshService?.myNickname ?? "") ?? "user"
        
        // Create read receipt using the simplified method
        let receipt = ReadReceipt(
            originalMessageID: safeMessageID,
            readerID: meshService?.myPeerID.id ?? "",
            readerNickname: readerNickname
        )
        
        // Route via MessageRouter to avoid handshakeRequired spam when session isn't established
        if let router = messageRouter {
            SecureLogger.debug("PrivateChatManager: sending READ ack for \(safeMessageID.prefix(8))… to \(senderPeerID.id.prefix(8))… via router", category: .session)
            Task { @MainActor in
                router.sendReadReceipt(receipt, to: senderPeerID)
            }
        } else {
            // Fallback: preserve previous behavior
            meshService?.sendReadReceipt(receipt, to: senderPeerID)
        }
    }
}
