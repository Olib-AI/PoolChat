// RichChatMessageTests.swift
// PoolChatTests

import XCTest
@testable import PoolChat

final class RichChatMessageTests: XCTestCase {

    // MARK: - Factory Methods

    func testTextMessageFactory() {
        let msg = RichChatMessage.textMessage(
            from: "sender-1",
            senderName: "Alice",
            text: "Hello",
            isFromLocalUser: true
        )
        XCTAssertEqual(msg.contentType, .text)
        XCTAssertEqual(msg.text, "Hello")
        XCTAssertEqual(msg.senderID, "sender-1")
        XCTAssertEqual(msg.senderName, "Alice")
        XCTAssertTrue(msg.isFromLocalUser)
        XCTAssertTrue(msg.isEncrypted) // default
    }

    func testSystemMessageFactory() {
        let msg = RichChatMessage.systemMessage(text: "User joined")
        XCTAssertEqual(msg.contentType, .system)
        XCTAssertEqual(msg.senderID, "system")
        XCTAssertFalse(msg.isEncrypted)
        XCTAssertFalse(msg.isFromLocalUser)
    }

    func testEmojiMessageFactory() {
        let msg = RichChatMessage.emojiMessage(
            from: "sender-2",
            senderName: "Bob",
            emoji: "fire-emoji",
            isFromLocalUser: false
        )
        XCTAssertEqual(msg.contentType, .emoji)
        XCTAssertEqual(msg.emoji, "fire-emoji")
    }

    func testImageMessageFactory() {
        let data = Data([0xFF, 0xD8, 0xFF]) // mock JPEG header
        let msg = RichChatMessage.imageMessage(
            from: "sender-3",
            senderName: "Carol",
            imageData: data,
            isFromLocalUser: false
        )
        XCTAssertEqual(msg.contentType, .image)
        XCTAssertEqual(msg.imageData, data)
    }

    func testVoiceMessageFactory() {
        let data = Data([0x00, 0x01, 0x02])
        let msg = RichChatMessage.voiceMessage(
            from: "sender-4",
            senderName: "Dave",
            voiceData: data,
            duration: 5.5,
            isFromLocalUser: true
        )
        XCTAssertEqual(msg.contentType, .voice)
        XCTAssertEqual(msg.voiceData, data)
        XCTAssertEqual(msg.voiceDuration, 5.5)
    }

    // MARK: - Reactions

    func testAddReaction() {
        let msg = RichChatMessage.textMessage(from: "s", senderName: "S", text: "Hi", isFromLocalUser: true)
        let reacted = msg.withReaction("thumbs-up", from: "peer-1")
        XCTAssertTrue(reacted.hasReacted(peerID: "peer-1", emoji: "thumbs-up"))
        XCTAssertEqual(reacted.sortedReactions.count, 1)
    }

    func testRemoveReaction() {
        var msg = RichChatMessage.textMessage(from: "s", senderName: "S", text: "Hi", isFromLocalUser: true)
        msg = msg.withReaction("heart", from: "peer-1")
        XCTAssertTrue(msg.hasReacted(peerID: "peer-1", emoji: "heart"))

        // Toggle removes it
        msg = msg.withReaction("heart", from: "peer-1")
        XCTAssertFalse(msg.hasReacted(peerID: "peer-1", emoji: "heart"))
    }

    func testSortedReactionsOrderedByCount() {
        var msg = RichChatMessage.textMessage(from: "s", senderName: "S", text: "Hi", isFromLocalUser: true)
        msg = msg.withReaction("a", from: "peer-1")
        msg = msg.withReaction("b", from: "peer-1")
        msg = msg.withReaction("b", from: "peer-2")

        let sorted = msg.sortedReactions
        // "b" has 2 reactions, "a" has 1
        XCTAssertEqual(sorted.first?.emoji, "b")
        XCTAssertEqual(sorted.first?.peerIDs.count, 2)
    }

    // MARK: - Poll

    func testPollMessageFactory() {
        let msg = RichChatMessage.pollMessage(
            from: "s",
            senderName: "S",
            question: "Favorite color?",
            options: ["Red", "Blue", "Green"],
            isFromLocalUser: true
        )
        XCTAssertEqual(msg.contentType, .poll)
        XCTAssertEqual(msg.pollData?.question, "Favorite color?")
        XCTAssertEqual(msg.pollData?.options, ["Red", "Blue", "Green"])
        XCTAssertEqual(msg.pollData?.totalVotes, 0)
    }

    func testPollVote() {
        let msg = RichChatMessage.pollMessage(
            from: "s",
            senderName: "S",
            question: "Q?",
            options: ["A", "B"],
            isFromLocalUser: true
        )
        let voted = msg.withPollVote(from: "voter-1", for: "A")
        XCTAssertNotNil(voted)
        XCTAssertEqual(voted?.pollData?.totalVotes, 1)
        XCTAssertEqual(voted?.pollData?.voteCount(for: "A"), 1)
        XCTAssertTrue(voted?.pollData?.hasVoted(peerID: "voter-1") ?? false)
    }

    func testPollVoteChangeWhenAllowed() {
        var msg = RichChatMessage.pollMessage(
            from: "s",
            senderName: "S",
            question: "Q?",
            options: ["A", "B"],
            isFromLocalUser: true,
            allowVoteChange: true
        )
        msg = msg.withPollVote(from: "voter-1", for: "A")!
        let changed = msg.withPollVote(from: "voter-1", for: "B")
        XCTAssertNotNil(changed, "Vote change should be allowed")
        XCTAssertEqual(changed?.pollData?.voteCount(for: "A"), 0)
        XCTAssertEqual(changed?.pollData?.voteCount(for: "B"), 1)
    }

    func testPollVoteChangeRejectedWhenDisallowed() {
        var msg = RichChatMessage.pollMessage(
            from: "s",
            senderName: "S",
            question: "Q?",
            options: ["A", "B"],
            isFromLocalUser: true,
            allowVoteChange: false
        )
        msg = msg.withPollVote(from: "voter-1", for: "A")!
        let changed = msg.withPollVote(from: "voter-1", for: "B")
        XCTAssertNil(changed, "Vote change must be rejected when disallowed")
    }

    // MARK: - Preview Text

    func testPreviewTextForText() {
        let msg = RichChatMessage.textMessage(from: "s", senderName: "S", text: "Short", isFromLocalUser: true)
        XCTAssertEqual(msg.previewText, "Short")
    }

    func testPreviewTextTruncation() {
        let longText = String(repeating: "A", count: 100)
        let msg = RichChatMessage.textMessage(from: "s", senderName: "S", text: longText, isFromLocalUser: true)
        XCTAssertTrue(msg.previewText.hasSuffix("..."))
        XCTAssertLessThanOrEqual(msg.previewText.count, 53) // 50 chars + "..."
    }

    func testPreviewTextForImage() {
        let msg = RichChatMessage.imageMessage(from: "s", senderName: "S", imageData: Data(), isFromLocalUser: true)
        XCTAssertEqual(msg.previewText, "[Photo]")
    }

    func testPreviewTextForVoice() {
        let msg = RichChatMessage.voiceMessage(from: "s", senderName: "S", voiceData: Data(), duration: 1.0, isFromLocalUser: true)
        XCTAssertEqual(msg.previewText, "[Voice message]")
    }

    // MARK: - Mentions

    func testIsMentioning() {
        let msg = RichChatMessage(
            senderID: "s",
            senderName: "S",
            contentType: .text,
            isFromLocalUser: true,
            text: "Hey @bob",
            mentions: ["peer-bob"]
        )
        XCTAssertTrue(msg.isMentioning(peerID: "peer-bob"))
        XCTAssertFalse(msg.isMentioning(peerID: "peer-alice"))
    }

    // MARK: - Equality

    func testEqualityBasedOnID() {
        let id = UUID()
        let msg1 = RichChatMessage(id: id, senderID: "s", senderName: "S", contentType: .text, isFromLocalUser: true, text: "A")
        let msg2 = RichChatMessage(id: id, senderID: "s", senderName: "S", contentType: .text, isFromLocalUser: true, text: "B")
        XCTAssertEqual(msg1, msg2, "Equality should be based on ID only")
    }

    // MARK: - RichChatPayload Round-Trip

    func testPayloadRoundTrip() {
        let original = RichChatMessage.textMessage(
            from: "sender-rt",
            senderName: "RoundTrip",
            text: "Payload test",
            isFromLocalUser: true
        )
        let payload = RichChatPayload(from: original)
        let restored = payload.toMessage(isFromLocalUser: false)

        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.senderID, original.senderID)
        XCTAssertEqual(restored.senderName, original.senderName)
        XCTAssertEqual(restored.text, original.text)
        XCTAssertEqual(restored.contentType, original.contentType)
        XCTAssertFalse(restored.isFromLocalUser, "toMessage should use the passed isFromLocalUser")
        XCTAssertEqual(restored.status, .delivered)
    }

    func testPayloadCodable() throws {
        let original = RichChatMessage.textMessage(
            from: "sender-cod",
            senderName: "CodableTest",
            text: "Encode me",
            isFromLocalUser: true
        )
        let payload = RichChatPayload(from: original)

        let encoder = JSONEncoder()
        let data = try encoder.encode(payload)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(RichChatPayload.self, from: data)

        XCTAssertEqual(decoded.messageID, payload.messageID)
        XCTAssertEqual(decoded.text, "Encode me")
        XCTAssertEqual(decoded.senderID, "sender-cod")
    }
}
