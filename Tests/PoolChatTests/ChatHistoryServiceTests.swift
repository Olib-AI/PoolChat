// ChatHistoryServiceTests.swift
// PoolChatTests

import XCTest
@testable import PoolChat

// MARK: - Mock Storage Provider

@available(macOS 14.0, iOS 17.0, *)
@MainActor
final class MockSecureStorageProvider: SecureStorageProvider {
    var storage: [String: Data] = [:]
    var rawStorage: [String: Data] = [:]

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func save<T: Codable>(_ object: T, forKey key: String, category: StorageDataCategory) async throws {
        storage[key] = try encoder.encode(object)
    }

    func load<T: Codable>(_ type: T.Type, forKey key: String, category: StorageDataCategory) async throws -> T? {
        guard let data = storage[key] else { return nil }
        return try decoder.decode(type, from: data)
    }

    func delete(forKey key: String, category: StorageDataCategory) async throws {
        storage.removeValue(forKey: key)
        rawStorage.removeValue(forKey: key)
    }

    func listKeys(in category: StorageDataCategory) -> [String] {
        Array(storage.keys) + Array(rawStorage.keys)
    }

    func saveData(_ data: Data, forKey key: String, category: StorageDataCategory) async throws {
        rawStorage[key] = data
    }

    func loadData(forKey key: String, category: StorageDataCategory) async throws -> Data? {
        rawStorage[key]
    }
}

// MARK: - Tests

@available(macOS 14.0, iOS 17.0, *)
@MainActor
final class ChatHistoryServiceTests: XCTestCase {

    private var mockStorage: MockSecureStorageProvider!

    override func setUp() async throws {
        try await super.setUp()
        let storage = MockSecureStorageProvider()
        self.mockStorage = storage
        PoolChatConfiguration.storageProvider = storage
        ChatHistoryService.shared.clearCache()
    }

    override func tearDown() async throws {
        ChatHistoryService.shared.clearCache()
        PoolChatConfiguration.storageProvider = nil
        try await super.tearDown()
    }

    // MARK: - Session Management

    func testMarkSessionActive() {
        let sut = ChatHistoryService.shared
        sut.markSessionActive("session-1")
        XCTAssertTrue(sut.isSessionActive("session-1"))
    }

    func testMarkSessionInactive() {
        let sut = ChatHistoryService.shared
        sut.markSessionActive("session-2")
        sut.markSessionInactive("session-2")
        XCTAssertFalse(sut.isSessionActive("session-2"))
    }

    // MARK: - Conversation Cache

    func testInvalidateCache() async {
        let sut = ChatHistoryService.shared
        let conversationID = "test-conv"
        let message = RichChatMessage.textMessage(from: "s", senderName: "S", text: "cached", isFromLocalUser: true)
        await sut.addMessage(message, to: conversationID, isGroupChat: true, participantIDs: ["s"])

        let loaded = await sut.loadConversation(id: conversationID)
        XCTAssertNotNil(loaded)

        sut.invalidateCache(for: conversationID)
        mockStorage.storage.removeAll()

        let afterInvalidate = await sut.loadConversation(id: conversationID)
        XCTAssertNil(afterInvalidate, "After invalidation + storage clear, conversation should be nil")
    }

    // MARK: - Add Message & Deduplication

    func testAddMessageCreatesConversation() async {
        let sut = ChatHistoryService.shared
        let conversationID = "new-conv"
        let message = RichChatMessage.textMessage(from: "sender", senderName: "Sender", text: "First", isFromLocalUser: false)

        await sut.addMessage(message, to: conversationID, isGroupChat: true, participantIDs: ["sender", "local"])

        let conversation = await sut.loadConversation(id: conversationID)
        XCTAssertNotNil(conversation)
        XCTAssertEqual(conversation?.messages.count, 1)
        XCTAssertEqual(conversation?.messages.first?.text, "First")
        XCTAssertEqual(conversation?.isGroupChat, true)
    }

    func testDeduplication() async {
        let sut = ChatHistoryService.shared
        let conversationID = "dedup-conv"
        let messageID = UUID()
        let message = RichChatMessage(
            id: messageID,
            senderID: "s",
            senderName: "S",
            contentType: .text,
            isFromLocalUser: true,
            text: "Duplicate me"
        )

        await sut.addMessage(message, to: conversationID, isGroupChat: false, participantIDs: ["s", "r"])
        await sut.addMessage(message, to: conversationID, isGroupChat: false, participantIDs: ["s", "r"])
        await sut.addMessage(message, to: conversationID, isGroupChat: false, participantIDs: ["s", "r"])

        let conversation = await sut.loadConversation(id: conversationID)
        XCTAssertEqual(conversation?.messages.count, 1, "Duplicate messages must be deduplicated")
    }

    // MARK: - Message Limit Enforcement

    func testMessageLimitEnforcement() async {
        let sut = ChatHistoryService.shared
        let conversationID = "limit-conv"

        var storedMessages: [StoredChatMessage] = []
        for i in 0..<1005 {
            storedMessages.append(StoredChatMessage(
                id: UUID(),
                senderID: "s",
                senderName: "S",
                contentType: .text,
                timestamp: Date(),
                isFromLocalUser: true,
                text: "Message \(i)"
            ))
        }
        let conversation = ChatConversation(
            id: conversationID,
            participantIDs: ["s"],
            isGroupChat: true,
            messages: storedMessages
        )

        await sut.saveConversation(conversation)

        let loaded = await sut.loadConversation(id: conversationID)
        XCTAssertNotNil(loaded)
        XCTAssertLessThanOrEqual(loaded!.messages.count, 1000, "Messages must be trimmed to the max limit")
    }

    // MARK: - Unread Count

    func testUnreadCountIncrements() async {
        let sut = ChatHistoryService.shared
        let conversationID = "unread-conv"
        let remoteMessage = RichChatMessage.textMessage(from: "remote", senderName: "Remote", text: "Hi", isFromLocalUser: false)

        await sut.addMessage(remoteMessage, to: conversationID, isGroupChat: true, participantIDs: ["remote", "local"])

        let conversation = await sut.loadConversation(id: conversationID)
        XCTAssertEqual(conversation?.unreadCount, 1)
    }

    func testUnreadCountDoesNotIncrementForLocalUser() async {
        let sut = ChatHistoryService.shared
        let conversationID = "local-conv"
        let localMessage = RichChatMessage.textMessage(from: "local", senderName: "Me", text: "My message", isFromLocalUser: true)

        await sut.addMessage(localMessage, to: conversationID, isGroupChat: true, participantIDs: ["local"])

        let conversation = await sut.loadConversation(id: conversationID)
        XCTAssertEqual(conversation?.unreadCount, 0)
    }

    func testMarkAsRead() async {
        let sut = ChatHistoryService.shared
        let conversationID = "read-conv"
        let message = RichChatMessage.textMessage(from: "r", senderName: "R", text: "Hey", isFromLocalUser: false)
        await sut.addMessage(message, to: conversationID, isGroupChat: true, participantIDs: ["r"])

        await sut.markAsRead(conversationID: conversationID)

        let conversation = await sut.loadConversation(id: conversationID)
        XCTAssertEqual(conversation?.unreadCount, 0)
    }

    // MARK: - Conversation IDs

    func testGroupConversationID() {
        let id = ChatConversation.groupConversationID(sessionID: "abc-123")
        XCTAssertEqual(id, "group_abc-123")
    }

    func testPrivateConversationIDIsDeterministic() {
        let id1 = ChatConversation.privateConversationID(localPeerID: "alice", remotePeerID: "bob")
        let id2 = ChatConversation.privateConversationID(localPeerID: "bob", remotePeerID: "alice")
        XCTAssertEqual(id1, id2, "Private conversation ID must be symmetric (order-independent)")
    }

    func testHostBasedGroupConversationID() {
        let id = ChatConversation.hostBasedGroupConversationID(hostPeerID: "host-xyz")
        XCTAssertEqual(id, "group_host-xyz")
    }

    // MARK: - Delete Conversation

    func testDeleteConversation() async {
        let sut = ChatHistoryService.shared
        let conversationID = "delete-conv"
        let message = RichChatMessage.textMessage(from: "s", senderName: "S", text: "Bye", isFromLocalUser: true)
        await sut.addMessage(message, to: conversationID, isGroupChat: true, participantIDs: ["s"])

        let before = await sut.loadConversation(id: conversationID)
        XCTAssertNotNil(before)

        await sut.deleteConversation(id: conversationID)

        sut.invalidateCache(for: conversationID)
        let after = await sut.loadConversation(id: conversationID)
        XCTAssertNil(after, "Conversation must be deleted from storage")
    }
}
